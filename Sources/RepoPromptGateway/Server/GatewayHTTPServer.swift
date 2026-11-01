import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RepoPromptRemoteWire

final class GatewayHTTPServer: @unchecked Sendable {
    private let configuration: GatewayConfiguration
    private let runtime: RemoteGatewayRuntime
    private let authenticator: DeviceAuthenticator?
    private let appLinkPool: AppLinkPool?
    private let auditLog: RemoteAuditLog?
    private let pairingRelay: GatewayPairingRelay?
    private let vapidPublicKeyBase64URL: String?
    private let hostName: String
    private let logger: Logger
    /// Remote passkey unlock, Step 3: the single injected monotonic access clock shared by the
    /// device-access authority and every per-connection outbound sink this server creates.
    private let accessClock: GatewayAccessClock
    /// The principal-leg passkey relay used for ceremony begin/complete and activity trust refresh.
    /// Production passes a non-nil relay; a fixture may inject the same relay or leave it nil (passkey
    /// ceremonies then fail closed with a sanitized authentication failure).
    private let passkeyRelay: GatewayPasskeyRelay?
    /// Process-global monotonic allocator for per-connection `connection_generation` values.
    private let generationAllocator = GatewayConnectionGenerationAllocator()
    /// The main-owned trust-refresh action, applied for an activity renewal's OWN fresh refresh and
    /// after a successful registration. Set via `setPasskeyTrustRefreshAction` BEFORE `start`.
    private var passkeyTrustRefreshAction: (@Sendable () async throws -> GatewayCapabilityTrustRefreshReceipt)?
    private let connectionRegistry = GatewayWebSocketConnectionRegistry()
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    /// The primary listener on the configured bind host.
    private var channel: Channel?
    /// The optional `127.0.0.1` listener at the primary's port; see `needsLoopbackCompanion`.
    private var companionChannel: Channel?

    init(
        configuration: GatewayConfiguration,
        runtime: RemoteGatewayRuntime,
        authenticator: DeviceAuthenticator? = nil,
        appLinkPool: AppLinkPool? = nil,
        auditLog: RemoteAuditLog? = nil,
        pairingRelay: GatewayPairingRelay? = nil,
        vapidPublicKeyBase64URL: String? = nil,
        accessClock: GatewayAccessClock = GatewayContinuousAccessClock(),
        passkeyRelay: GatewayPasskeyRelay? = nil,
        hostName: String = GatewayHTTPServer.defaultHostName(),
        logger: Logger = Logger(label: "com.repoprompt.gateway.http")
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.authenticator = authenticator
        self.appLinkPool = appLinkPool
        self.auditLog = auditLog
        self.pairingRelay = pairingRelay
        self.vapidPublicKeyBase64URL = vapidPublicKeyBase64URL
        self.hostName = hostName
        self.accessClock = accessClock
        self.passkeyRelay = passkeyRelay
        self.logger = logger
    }

    /// Install the main-owned trust-refresh action. MUST be called before `start`; the upgrader
    /// pipeline captures it when the listener is bound. (Remote passkey unlock, Step 3.)
    func setPasskeyTrustRefreshAction(_ action: @escaping @Sendable () async throws -> GatewayCapabilityTrustRefreshReceipt) {
        passkeyTrustRefreshAction = action
    }

    /// Close connections the authority can no longer authorize at all: a static-token connection once
    /// any required passkey policy exists (or trust is invalid), and a paired connection whose trust
    /// is no longer `.valid`, whose device left trust, or whose device was revoked. A paired
    /// connection that is merely LOCKED under a required policy stays open so it can unlock via a
    /// passkey ceremony; unbound mid-hello connections are left alone. Called by main after an
    /// invalidation or required-policy publication barrier has settled.
    func closeAccessDeniedConnections() async {
        guard let authenticator else { return }
        let deniedSinkIDs = await authenticator.accessDeniedConnectionIDs()
        connectionRegistry.closeConnections(sinkIDs: Set(deniedSinkIDs))
    }

    static func defaultHostName() -> String {
        let candidates = [
            Host.current().localizedName,
            Host.current().name,
            ProcessInfo.processInfo.hostName
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return "RepoPrompt Host"
    }

    var localAddress: SocketAddress? {
        channel?.localAddress
    }

    var companionLocalAddress: SocketAddress? {
        companionChannel?.localAddress
    }

    static let loopbackCompanionHost = "127.0.0.1"

    /// Whether a browser origin also needs a `127.0.0.1` listener at the primary's port. The
    /// owner's same-host `tailscale serve` dials its backend outside the tailnet, so it cannot reach
    /// a listener bound only to this Mac's Tailscale address. The companion shares the primary's
    /// pipeline, Host allowlist, and authentication; a local source address grants nothing.
    /// `127.0.0.1` and the IPv4 wildcard already cover it; an IPv6 wildcard covers it only when the
    /// bound socket is dual-stack (`isIPv6Only == false`), and unknown coverage is an error.
    static func needsLoopbackCompanion(primary: SocketAddress?, isIPv6Only: Bool?) throws -> Bool {
        switch primary {
        case .v4:
            let ip = primary?.ipAddress
            return ip != loopbackCompanionHost && ip != "0.0.0.0"
        case .v6:
            guard primary?.ipAddress == "::" else { return true }
            guard let isIPv6Only else {
                throw GatewayHTTPServerError.loopbackCoverageUnknown(String(describing: primary))
            }
            return isIPv6Only
        case .unixDomainSocket, .none:
            throw GatewayHTTPServerError.loopbackCoverageUnknown(String(describing: primary))
        }
    }

    func start() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        do {
            let runtime = runtime
            let configuration = configuration
            let authenticator = authenticator
            let appLinkPool = appLinkPool
            let auditLog = auditLog
            let connectionRegistry = connectionRegistry
            let pairingRelay = pairingRelay
            let vapidPublicKeyBase64URL = vapidPublicKeyBase64URL
            let hostName = hostName
            let accessClock = accessClock
            let passkeyRelay = passkeyRelay
            let generationAllocator = generationAllocator
            let passkeyTrustRefreshAction = passkeyTrustRefreshAction
            let logger = logger
            let upgrader = NIOWebSocketServerUpgrader(
                shouldUpgrade: { channel, head in
                    let hostAllowlist = GatewayHostAllowlist(
                        configuration: configuration,
                        localAddress: channel.localAddress
                    )
                    guard hostAllowlist.allows(head),
                          GatewayHTTPHandler.pathOnly(from: head.uri) == "/ws",
                          GatewayHTTPHandler.isWebSocketUpgrade(head),
                          GatewayHTTPHandler.isUpgradeAuthorized(head, configuration: configuration)
                    else {
                        return channel.eventLoop.makeSucceededFuture(nil)
                    }
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                },
                upgradePipelineHandler: { channel, _ in
                    channel.pipeline.addHandler(GatewayWebSocketFrameHandler(
                        configuration: configuration,
                        runtime: runtime,
                        authenticator: authenticator,
                        appLinkPool: appLinkPool,
                        auditLog: auditLog,
                        connectionRegistry: connectionRegistry,
                        vapidPublicKeyBase64URL: vapidPublicKeyBase64URL,
                        hostName: hostName,
                        accessClock: accessClock,
                        passkeyRelay: passkeyRelay,
                        generationAllocator: generationAllocator,
                        passkeyTrustRefreshAction: passkeyTrustRefreshAction,
                        logger: logger
                    ))
                }
            )
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let httpHandler = GatewayHTTPHandler(
                        configuration: configuration,
                        hostAllowlist: GatewayHostAllowlist(
                            configuration: configuration,
                            localAddress: channel.localAddress
                        ),
                        pairingRelay: pairingRelay
                    )
                    // The plain HTTP handler must leave the pipeline once the WebSocket
                    // upgrade completes, otherwise post-upgrade frames reach its
                    // HTTPServerRequestPart unwrap and crash the process.
                    let upgradeConfig = NIOHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        completionHandler: { context in
                            context.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: upgradeConfig,
                        withErrorHandling: true
                    ).flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let boundChannel = try await bootstrap.bind(
                host: configuration.bindHost,
                port: configuration.port
            ).get()
            let boundCompanion: Channel?
            do {
                boundCompanion = try await Self.bindLoopbackCompanionIfNeeded(
                    primary: boundChannel,
                    configuration: configuration,
                    bootstrap: bootstrap
                )
            } catch {
                // All or nothing: a browser origin without its backend is a failed start.
                try? await boundChannel.close().get()
                throw error
            }
            eventLoopGroup = group
            channel = boundChannel
            companionChannel = boundCompanion
            logger.notice("Gateway HTTP server listening on \(String(describing: boundChannel.localAddress))")
            if let boundCompanion {
                logger.notice("Gateway HTTP server loopback companion listening on \(String(describing: boundCompanion.localAddress))")
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func bindLoopbackCompanionIfNeeded(
        primary: Channel,
        configuration: GatewayConfiguration,
        bootstrap: ServerBootstrap
    ) async throws -> Channel? {
        guard configuration.browserOriginAuthority != nil else { return nil }
        let primaryAddress = primary.localAddress
        var isIPv6Only: Bool?
        if case .v6 = primaryAddress, primaryAddress?.ipAddress == "::" {
            let option = ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_v6only)
            isIPv6Only = try await primary.getOption(option).get() != 0
        }
        guard try needsLoopbackCompanion(primary: primaryAddress, isIPv6Only: isIPv6Only) else { return nil }
        guard let port = primaryAddress?.port else {
            throw GatewayHTTPServerError.loopbackCoverageUnknown(String(describing: primaryAddress))
        }
        return try await bootstrap.bind(host: loopbackCompanionHost, port: port).get()
    }

    func closeConnections(forDevice deviceID: String) {
        connectionRegistry.closeConnections(forDevice: deviceID)
    }

    func shutdown() async {
        let currentChannels = [channel, companionChannel].compactMap(\.self)
        channel = nil
        companionChannel = nil
        for currentChannel in currentChannels {
            try? await currentChannel.close().get()
        }
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        eventLoopGroup = nil
    }
}

enum GatewayHTTPServerError: Error, Equatable, CustomStringConvertible {
    case loopbackCoverageUnknown(String)

    var description: String {
        switch self {
        case let .loopbackCoverageUnknown(address):
            "Cannot tell whether the gateway listener \(address) covers 127.0.0.1 for the browser origin"
        }
    }
}

private final class GatewayWebSocketConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channelsByDevice: [String: [UUID: Channel]] = [:]

    func register(deviceID: String, sinkID: UUID, channel: Channel) {
        lock.lock()
        var channels = channelsByDevice[deviceID] ?? [:]
        channels[sinkID] = channel
        channelsByDevice[deviceID] = channels
        lock.unlock()
    }

    func unregister(deviceID: String, sinkID: UUID) {
        lock.lock()
        if var channels = channelsByDevice[deviceID] {
            channels.removeValue(forKey: sinkID)
            if channels.isEmpty {
                channelsByDevice.removeValue(forKey: deviceID)
            } else {
                channelsByDevice[deviceID] = channels
            }
        }
        lock.unlock()
    }

    func closeConnections(forDevice deviceID: String) {
        lock.lock()
        let channels = channelsByDevice.removeValue(forKey: deviceID).map { Array($0.values) } ?? []
        lock.unlock()
        close(channels)
    }

    /// Close exactly the registered connections whose sink IDs are in `sinkIDs`, across all devices.
    /// Used by `closeAccessDeniedConnections()` so a trust invalidation or required-policy flip can
    /// drop precisely the connections the authority can no longer authorize, leaving merely-locked
    /// paired connections open.
    func closeConnections(sinkIDs: Set<UUID>) {
        guard !sinkIDs.isEmpty else { return }
        lock.lock()
        var channels: [Channel] = []
        for (deviceID, var connections) in channelsByDevice {
            for sinkID in sinkIDs where connections[sinkID] != nil {
                if let channel = connections.removeValue(forKey: sinkID) {
                    channels.append(channel)
                }
            }
            if connections.isEmpty {
                channelsByDevice.removeValue(forKey: deviceID)
            } else {
                channelsByDevice[deviceID] = connections
            }
        }
        lock.unlock()
        close(channels)
    }

    private func close(_ channels: [Channel]) {
        for channel in channels {
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                let buffer = channel.allocator.buffer(capacity: 0)
                let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
                channel.writeAndFlush(closeFrame).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }
}

/// Process-global monotonic allocator for per-connection `connection_generation` values. A fresh
/// generation is stamped on every accepted WebSocket connection so a reconnect cannot complete a
/// passkey ceremony begun on a prior connection, and is never client-supplied. (Step 3 plan §6.)
final class GatewayConnectionGenerationAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0

    func allocate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        next &+= 1
        return next
    }
}

final class GatewayHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maximumBodyBytes = 64 * 1024

    private let configuration: GatewayConfiguration
    private let hostAllowlist: GatewayHostAllowlist
    private let pairingRelay: GatewayPairingRelay?
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var bodyTooLarge = false
    private var requestBodyLimit = maximumBodyBytes

    init(
        configuration: GatewayConfiguration,
        hostAllowlist: GatewayHostAllowlist,
        pairingRelay: GatewayPairingRelay? = nil
    ) {
        self.configuration = configuration
        self.hostAllowlist = hostAllowlist
        self.pairingRelay = pairingRelay
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case let .head(head):
            requestHead = head
            requestBody = Data()
            bodyTooLarge = false
            requestBodyLimit = Self.bodyLimit(for: head)
        case var .body(buffer):
            guard !bodyTooLarge else { return }
            if requestBody.count + buffer.readableBytes > requestBodyLimit {
                bodyTooLarge = true
                requestBody = Data()
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            guard let head = requestHead else {
                sendResponse(
                    status: .badRequest,
                    body: "missing request head\n",
                    contentType: "text/plain; charset=utf-8",
                    context: context
                )
                return
            }
            if bodyTooLarge {
                sendResponse(
                    status: .payloadTooLarge,
                    body: "request body too large\n",
                    contentType: "text/plain; charset=utf-8",
                    context: context
                )
                requestHead = nil
                return
            }
            route(head, body: requestBody, context: context)
            requestHead = nil
            requestBody = Data()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func route(_ head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        // Before any route. A WebSocket upgrade with a wrong Host is refused earlier, in
        // `shouldUpgrade` (NIO reports that refusal through errorCaught, which closes the channel).
        guard hostAllowlist.allows(head) else {
            sendResponse(
                status: .misdirectedRequest,
                body: "host not allowed\n",
                contentType: "text/plain; charset=utf-8",
                context: context
            )
            return
        }
        let path = Self.pathOnly(from: head.uri)
        if head.method == .GET, path == "/healthz" {
            sendResponse(
                status: .ok,
                body: Self.healthBody(configuration: configuration),
                contentType: "application/json; charset=utf-8",
                context: context
            )
            return
        }

        if head.method == .GET, path == "/readyz" {
            handleReadiness(context: context)
            return
        }

        if head.method == .GET || head.method == .HEAD, let asset = Self.pwaAsset(forPath: path) {
            servePWAAsset(asset, context: context)
            return
        }

        if head.method == .POST, GatewayPairingRelay.relayPaths.contains(path) {
            handlePairingRelay(path: path, body: body, context: context)
            return
        }

        if Self.isWebSocketUpgrade(head) {
            let status: HTTPResponseStatus = Self.isUpgradeAuthorized(head, configuration: configuration)
                ? .upgradeRequired
                : .unauthorized
            sendResponse(
                status: status,
                body: status == .unauthorized ? "unauthorized\n" : "websocket endpoint is /ws\n",
                contentType: "text/plain; charset=utf-8",
                context: context
            )
            return
        }

        sendResponse(
            status: .notFound,
            body: "not found\n",
            contentType: "text/plain; charset=utf-8",
            context: context
        )
    }

    private func handleReadiness(context: ChannelHandlerContext) {
        guard let pairingRelay else {
            sendResponse(
                status: .serviceUnavailable,
                body: "{\"status\":\"starting\",\"app_link\":\"unavailable\"}\n",
                contentType: "application/json; charset=utf-8",
                context: context
            )
            return
        }
        let channel = context.channel
        Task {
            let ready = await pairingRelay.isAppLinkReady()
            Self.writeResponse(
                on: channel,
                status: ready ? .ok : .serviceUnavailable,
                bodyData: Data(
                    ready
                        ? "{\"status\":\"ready\",\"app_link\":\"connected\"}\n".utf8
                        : "{\"status\":\"starting\",\"app_link\":\"connecting\"}\n".utf8
                ),
                contentType: "application/json; charset=utf-8"
            )
        }
    }

    /// `/healthz` also reports the build channel. The PWA keys its stored identity by it and
    /// sends it with pairing discovery, because the release and Dev gateways can share one browser
    /// origin while keeping separate paired-device lists and host keys.
    static func healthBody(configuration: GatewayConfiguration) -> String {
        "{\"status\":\"ok\",\"service\":\"repoprompt-gateway\",\"channel\":\"\(configuration.buildChannel.rawValue)\"}\n"
    }

    static func bodyLimit(for head: HTTPRequestHead) -> Int {
        let path = pathOnly(from: head.uri)
        if head.method == .POST, path == GatewayPairingRelay.discoveryPath {
            return GatewayPairingRelay.maximumDiscoveryRequestBytes
        }
        return maximumBodyBytes
    }

    /// Maps request paths onto packaged PWA assets. The PWA is served from the
    /// gateway only; `/` serves the app shell.
    static func pwaAsset(forPath path: String) -> String? {
        switch path {
        case "/", "/index.html":
            "index.html"
        case "/app.js":
            "app.js"
        case "/sw.js":
            "sw.js"
        case "/manifest.webmanifest":
            "manifest.webmanifest"
        default:
            nil
        }
    }

    private func servePWAAsset(_ asset: String, context: ChannelHandlerContext) {
        guard let data = GatewayPWAResources.data(forAsset: asset) else {
            sendResponse(
                status: .notFound,
                body: "PWA asset unavailable\n",
                contentType: "text/plain; charset=utf-8",
                context: context
            )
            return
        }
        sendResponse(
            status: .ok,
            bodyData: data,
            contentType: GatewayPWAResources.contentType(forAsset: asset),
            extraHeaders: [("Cache-Control", "no-cache")],
            context: context
        )
    }

    private func handlePairingRelay(path: String, body: Data, context: ChannelHandlerContext) {
        guard let pairingRelay else {
            sendResponse(
                status: .notFound,
                body: "pairing relay unavailable\n",
                contentType: "text/plain; charset=utf-8",
                context: context
            )
            return
        }
        let channel = context.channel
        Task {
            let response = await pairingRelay.handle(
                path: path,
                body: body,
                peerAddress: channel.remoteAddress?.ipAddress
            )
            let data = (try? RemoteWireProtocol.canonicalData(for: response.body)) ?? Data("{}".utf8)
            Self.writeResponse(
                on: channel,
                status: HTTPResponseStatus(statusCode: response.status),
                bodyData: data + Data("\n".utf8),
                contentType: "application/json; charset=utf-8"
            )
        }
    }

    /// Writes a full HTTP response from outside the handler (used after async relay
    /// work); all writes are marshaled onto the channel's event loop.
    private static func writeResponse(
        on channel: Channel,
        status: HTTPResponseStatus,
        bodyData: Data,
        contentType: String
    ) {
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    private func sendResponse(
        status: HTTPResponseStatus,
        body: String,
        contentType: String,
        context: ChannelHandlerContext
    ) {
        sendResponse(
            status: status,
            bodyData: Data(body.utf8),
            contentType: contentType,
            extraHeaders: [],
            context: context
        )
    }

    private func sendResponse(
        status: HTTPResponseStatus,
        bodyData: Data,
        contentType: String,
        extraHeaders: [(String, String)] = [],
        context: ChannelHandlerContext
    ) {
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
        headers.add(name: "Connection", value: "close")
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    static func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
        guard head.headers["Upgrade"].contains(where: { $0.lowercased() == "websocket" }) else {
            return false
        }
        return head.headers["Connection"].contains { value in
            value.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
        }
    }

    static func isUpgradeAuthorized(_ head: HTTPRequestHead, configuration: GatewayConfiguration) -> Bool {
        // Ticket-authenticated connections prove identity in the hello frame, so the
        // upgrade itself is permitted; the static-token header gate applies only to the
        // explicit developer-only static-token mode.
        guard configuration.allowStaticTokenAuth else { return true }
        guard let expected = configuration.staticToken, !expected.isEmpty else { return true }
        if head.headers["X-RepoPrompt-Gateway-Token"].contains(expected) {
            return true
        }
        if head.headers["Authorization"].contains(where: { header in
            header.trimmingCharacters(in: .whitespacesAndNewlines) == "Bearer \(expected)"
        }) {
            return true
        }
        return queryItems(from: head.uri)["token"] == expected
    }

    static func pathOnly(from uri: String) -> String {
        guard let question = uri.firstIndex(of: "?") else { return uri }
        return String(uri[..<question])
    }

    private static func queryItems(from uri: String) -> [String: String] {
        guard let question = uri.firstIndex(of: "?") else { return [:] }
        let query = uri[uri.index(after: question)...]
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            items[String(key)] = value.removingPercentEncoding ?? value
        }
        return items
    }
}

/// Mutable state is confined to the channel's event loop; async continuations touch
/// only thread-safe members or marshal state changes back through the event loop.
private final class GatewayWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private enum State {
        case awaitingHello
        case authenticating
        case ready(Ready)
        case closing
    }

    /// A ready connection. `enforced` is true for ticket-authenticated paired connections that require
    /// per-frame device signatures, the inbound lock gate, and scope checks; the developer-only
    /// static-token path is unenforced.
    private struct Ready {
        let deviceID: String
        let enforced: Bool
    }

    private let configuration: GatewayConfiguration
    private let runtime: RemoteGatewayRuntime
    private let authenticator: DeviceAuthenticator?
    private let appLinkPool: AppLinkPool?
    private let auditLog: RemoteAuditLog?
    private let connectionRegistry: GatewayWebSocketConnectionRegistry
    private let vapidPublicKeyBase64URL: String?
    private let hostName: String
    private let accessClock: GatewayAccessClock
    private let passkeyRelay: GatewayPasskeyRelay?
    private let generationAllocator: GatewayConnectionGenerationAllocator
    private let passkeyTrustRefreshAction: (@Sendable () async throws -> GatewayCapabilityTrustRefreshReceipt)?
    private let logger: Logger
    private let sinkID = UUID()
    private var sink: GatewayWebSocketFrameSink?
    /// The connection's event loop, captured in `handlerAdded`. All handler-field mutations
    /// (`state`, `admissionTask`, `runtimeTask`) are owned by this loop so they are never raced from
    /// an off-loop admission/runtime task executor.
    private var eventLoop: EventLoop?
    private var state: State = .awaitingHello
    /// This connection's process-local generation, stamped once in `handlerAdded` and echoed to the
    /// app at a ceremony begin/complete so a reconnect cannot complete a ceremony begun on a prior
    /// connection. Never client-supplied.
    private var connectionGeneration: UInt64 = 0
    /// Ordered admission chain: `verifyFrame` runs in strict arrival order so signed counters stay
    /// monotonic. Admission only verifies and routes; it never awaits runtime execution, so a long
    /// app call cannot delay admitting (and thus executing) a later Lock or ceremony frame.
    private var admissionTask: Task<Void, Never>?
    /// Ordered runtime execution chain, fed by admission in arrival order. Independent of the control
    /// (lock/activity/ceremony) tasks so Lock is never blocked behind an in-flight runtime call.
    private var runtimeTask: Task<Void, Never>?
    /// Frames that arrived AFTER `hello_ack` but BEFORE the connection became `.ready` (watch
    /// registration completing). A client obeying `hello_ack` may send its first command immediately;
    /// buffering it in arrival order on the event loop and draining it through the normal ready
    /// dispatch once registration completes avoids a spurious `hello_in_progress` rejection (S3-I04).
    /// Bounded to a small cap as a flood safety valve: beyond the cap the connection is terminated.
    private var framesBufferedDuringAuth: [(rawData: Data, frame: RemoteClientFrame)] = []
    private static let maxFramesBufferedDuringAuth = 16
    /// The device id under which this connection's channel was registered in the shared connection
    /// registry, recorded on the event loop as soon as registration happens (S3-R1-01: registration is
    /// now BEFORE the final authority denial recheck, so a concurrent sweep finds the channel). It lets
    /// `channelInactive`'s pre-`.ready` branch unregister a channel registered during `.authenticating`
    /// that would otherwise leak until a later sweep. Nil until the channel is registered.
    private var registeredDeviceID: String?

    init(
        configuration: GatewayConfiguration,
        runtime: RemoteGatewayRuntime,
        authenticator: DeviceAuthenticator?,
        appLinkPool: AppLinkPool?,
        auditLog: RemoteAuditLog?,
        connectionRegistry: GatewayWebSocketConnectionRegistry,
        vapidPublicKeyBase64URL: String? = nil,
        hostName: String,
        accessClock: GatewayAccessClock,
        passkeyRelay: GatewayPasskeyRelay?,
        generationAllocator: GatewayConnectionGenerationAllocator,
        passkeyTrustRefreshAction: (@Sendable () async throws -> GatewayCapabilityTrustRefreshReceipt)?,
        logger: Logger
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.authenticator = authenticator
        self.appLinkPool = appLinkPool
        self.auditLog = auditLog
        self.connectionRegistry = connectionRegistry
        self.vapidPublicKeyBase64URL = vapidPublicKeyBase64URL
        self.hostName = hostName
        self.accessClock = accessClock
        self.passkeyRelay = passkeyRelay
        self.generationAllocator = generationAllocator
        self.passkeyTrustRefreshAction = passkeyTrustRefreshAction
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Stamp this connection's process-local generation ONCE (echoed to the app at a ceremony so a
        // reconnect cannot complete a ceremony begun on a prior connection) and create the outbound
        // sink UNBOUND against the shared injected access clock. There is NO legacy unprotected bind:
        // the sink is closed-by-default and delivers no protected content until the authority
        // publishes an authorization snapshot at hello admission (`bindConnection`). Only the
        // unforgeable safe-control path (hello_ack, lock state, ceremony frames) reaches the browser
        // before then.
        eventLoop = context.eventLoop
        connectionGeneration = generationAllocator.allocate()
        sink = GatewayWebSocketFrameSink(channel: context.channel, clock: accessClock)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            state = .closing
            context.close(promise: nil)
        case .ping:
            var payload = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: payload)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .text, .binary:
            guard frame.fin else {
                failTerminal(requestID: nil, sessionID: nil, code: "protocol_error")
                return
            }
            var buffer = frame.unmaskedData
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            handleRemoteData(Data(bytes), context: context)
        default:
            failTerminal(requestID: nil, sessionID: nil, code: "protocol_error")
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        // Close the lifecycle fence synchronously so any in-flight authority commit (a late ceremony
        // or renewal) linearizes against this disconnect and cannot establish a shared grant for a
        // connection that is gone.
        sink?.fence.close()
        let sinkID = sinkID
        let authenticator = authenticator
        if case let .ready(ready) = state {
            let runtime = runtime
            connectionRegistry.unregister(deviceID: ready.deviceID, sinkID: sinkID)
            Task {
                await runtime.removeSink(deviceID: ready.deviceID, sinkID: sinkID)
                await authenticator?.detachConnection(sinkID)
                await authenticator?.endConnection(sinkID)
            }
        } else if let registeredDeviceID {
            // S3-R1-01: the channel was registered during `.authenticating` (before the hello's own
            // late-disconnect compensation ran). Unregister and tear down its runtime sink here so an
            // early disconnect never leaks a registry entry or sink. Idempotent against the hello
            // path's own compensation (unregister/removeSink are no-ops if already cleaned).
            let runtime = runtime
            connectionRegistry.unregister(deviceID: registeredDeviceID, sinkID: sinkID)
            Task {
                await runtime.removeSink(deviceID: registeredDeviceID, sinkID: sinkID)
                await authenticator?.detachConnection(sinkID)
                await authenticator?.endConnection(sinkID)
            }
        } else {
            Task {
                await authenticator?.detachConnection(sinkID)
                await authenticator?.endConnection(sinkID)
            }
        }
        state = .closing
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("Gateway websocket error: \(String(describing: error))")
        context.close(promise: nil)
    }

    private func handleRemoteData(_ data: Data, context: ChannelHandlerContext) {
        guard let sink else { return }
        let frame: RemoteClientFrame
        do {
            // Tolerate unknown frame types so a syntactically valid unknown frame on a signed paired
            // connection is still signature/counter verified and routed to the generic locked-deny /
            // unsupported path, instead of being rejected here with a raw decoder description.
            frame = try RemoteWireProtocol.decodeClientFrame(from: data, allowUnknownTypes: true)
        } catch {
            // Malformed bytes / wrong version / missing request_id: a sanitized generic protocol
            // error on the safe path. No identity is implied (these are not signature-verified) and
            // the connection is preserved, matching the prior non-terminal decode behavior.
            Task { await sink.sendSafeControl(.failure(requestID: nil, reason: .protocolError)) }
            return
        }

        switch state {
        case .awaitingHello:
            guard frame.type == "hello" else {
                failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "hello_required")
                return
            }
            if frame.payload?.objectValue?["ticket"] != nil {
                handleTicketHello(rawData: data, frame: frame, context: context)
                return
            }
            handleStaticTokenHello(frame, context: context)
        case .authenticating:
            // A client that obeyed `hello_ack` may send its first command before `.ready` is published
            // (watch registration still completing). Buffer in arrival order and drain on `.ready`
            // instead of rejecting a valid connection as `hello_in_progress` (S3-I04). The cap is a
            // flood safety valve only.
            guard framesBufferedDuringAuth.count < Self.maxFramesBufferedDuringAuth else {
                failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "hello_in_progress")
                return
            }
            framesBufferedDuringAuth.append((rawData: data, frame: frame))
        case let .ready(ready):
            dispatchReadyFrame(rawData: data, frame: frame, ready: ready, sink: sink, loop: context.eventLoop)
        case .closing:
            return
        }
    }

    /// M4 normal path: hello carries an app-minted one-time ticket plus a device frame
    /// signature. The used ticket is persisted before the connection is accepted; any
    /// auth failure rejects the hello before translation and audits the outcome. ALL failure and
    /// handshake JSON rides the sink's sanitized safe-control path (fixed codes, fixed messages); no
    /// raw decoder/app/SDK text is ever forwarded.
    private func handleTicketHello(rawData: Data, frame: RemoteClientFrame, context: ChannelHandlerContext) {
        guard let sink else { return }
        guard let authenticator else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "ticket_auth_unavailable")
            failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "ticket_auth_unavailable")
            return
        }
        state = .authenticating
        let loop = context.eventLoop
        let channel = context.channel
        let runtime = runtime
        let appLinkPool = appLinkPool
        let sinkID = sinkID
        let connectionGeneration = connectionGeneration
        let vapid = vapidPublicKeyBase64URL
        let hostName = hostName
        enqueueAdmission { [weak self] in
            guard let self else { return }
            let device: DeviceAuthenticator.AuthenticatedDevice
            do {
                device = try await authenticator.admitHello(rawFrame: rawData, frame: frame, connectionID: sinkID)
            } catch let error as DeviceAuthenticationError {
                self.audit(
                    deviceID: RemoteFrameSignature(jsonValue: frame.sig)?.deviceID ?? "unknown",
                    frame: frame,
                    outcome: "denied",
                    code: error.code
                )
                await self.failAdmission(sink: sink, requestID: frame.requestID, sessionID: frame.sessionID, code: error.code, loop: loop)
                return
            } catch {
                audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "hello_failed")
                await failAdmission(sink: sink, requestID: frame.requestID, sessionID: frame.sessionID, code: "hello_failed", loop: loop)
                return
            }

            if let appLinkPool {
                do {
                    try await appLinkPool.ensureLink(forDevice: device.deviceID)
                } catch let error as AppLinkPoolError {
                    self.audit(deviceID: device.deviceID, frame: frame, outcome: "failure", code: error.code)
                    await self.failChannelClosing(sink: sink, reason: error.code, loop: loop)
                    return
                } catch {
                    audit(deviceID: device.deviceID, frame: frame, outcome: "failure", code: "app_link_unavailable")
                    await failChannelClosing(sink: sink, reason: "app_link_unavailable", loop: loop)
                    return
                }
            }

            // The client may have disconnected during the ensureLink round-trip; nothing is bound yet.
            guard sink.fence.isActive else {
                _ = loop.submit { self.state = .closing }
                return
            }

            // Bind + publish, then WAIT for the barrier before any watch registration or hello_ack, so
            // the sink's authorization snapshot is in force before any protected content can be
            // enqueued. A required-policy device with no live grant binds LOCKED.
            let barrier = await authenticator.bindConnection(
                connectionID: sinkID,
                sink: sink,
                principal: .pairedDevice(deviceID: device.deviceID),
                connectionGeneration: connectionGeneration
            )
            await barrier.settle()

            // S3-R1-01: register the channel in the shared connection registry IMMEDIATELY after the
            // bind barrier and BEFORE the final authority denial recheck. A trust invalidation or
            // required-policy flip during the bind round-trip is then caught by EITHER this recheck
            // (which unregisters and closes below) OR a concurrent `closeAccessDeniedConnections()`
            // sweep, which can now find the channel — eliminating the window where the authority knows
            // the connection is denied but the registry has no channel to close. `registeredDeviceID`
            // is recorded on the loop so `channelInactive` can unregister a channel registered during
            // `.authenticating` if the client disconnects before `.ready`.
            connectionRegistry.register(deviceID: device.deviceID, sinkID: sinkID, channel: channel)
            _ = loop.submit { self.registeredDeviceID = device.deviceID }

            // Recheck current trust/device after the round-trip: a trust invalidation or device
            // revocation during ensureLink/bind denies admission outright (a merely LOCKED connection
            // is NOT denied and proceeds to a locked hello_ack so it can unlock).
            if await authenticator.accessDenied(forConnection: sinkID) {
                audit(deviceID: device.deviceID, frame: frame, outcome: "denied", code: "device_untrusted")
                connectionRegistry.unregister(deviceID: device.deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                await failChannelClosing(sink: sink, reason: "device_untrusted", loop: loop)
                return
            }
            guard let access = await authenticator.accessMetadata(forConnection: sinkID) else {
                connectionRegistry.unregister(deviceID: device.deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                _ = loop.submit { self.state = .closing }
                return
            }

            let identity = GatewayHelloAckIdentity(
                deviceID: device.deviceID,
                auth: "ticket",
                ticketID: device.ticketID.uuidString.lowercased(),
                scopes: Array(device.scopes),
                hostName: hostName,
                vapidPublicKeyBase64URL: vapid,
                includeNullSig: false
            )
            // hello_ack (current metadata) is delivered BEFORE watch registration so no session_update
            // can precede it, and rides the safe path so it reaches a locked connection too.
            await sink.sendSafeControl(.helloAck(identity: identity, access: access))

            await runtime.registerSink(deviceID: device.deviceID, sinkID: sinkID, sink: sink)
            _ = loop.submit { self.markReadyAndDrain(Ready(deviceID: device.deviceID, enforced: true)) }

            // Late-disconnect compensation: if the client disconnected during bind/ack/register,
            // `channelInactive` ran its non-ready branch (no removeSink/unregister), so the watch just
            // registered would leak. Clean it up here.
            if !sink.fence.isActive {
                connectionRegistry.unregister(deviceID: device.deviceID, sinkID: sinkID)
                await runtime.removeSink(deviceID: device.deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                _ = loop.submit { self.state = .closing }
                return
            }
            audit(deviceID: device.deviceID, frame: frame, outcome: "success", code: nil)
        }
    }

    /// Phase 0 static-token authentication survives only behind the explicit
    /// developer-only `allowStaticTokenAuth` flag.
    private func handleStaticTokenHello(_ frame: RemoteClientFrame, context: ChannelHandlerContext) {
        guard configuration.allowStaticTokenAuth else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "ticket_required")
            failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "ticket_required")
            return
        }
        guard isHelloAuthorized(frame) else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "unauthorized")
            failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "unauthorized")
            return
        }
        guard let sink else { return }
        // Static-token binding requires the access authority so the developer connection is gated by
        // the same closed-by-default sink as paired connections (any required policy, or trust not
        // valid, denies static access entirely).
        guard let authenticator else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "ticket_auth_unavailable")
            failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "ticket_auth_unavailable")
            return
        }
        state = .authenticating
        let deviceID = RemoteGatewayRuntime.phase0DeviceID
        let loop = context.eventLoop
        let channel = context.channel
        let runtime = runtime
        let sinkID = sinkID
        let connectionGeneration = connectionGeneration
        let vapid = vapidPublicKeyBase64URL
        let hostName = hostName
        enqueueAdmission { [weak self] in
            guard let self else { return }
            // Recheck current permission AT BIND: static access is permitted only while trust is valid
            // and NO device has a required policy. Otherwise the developer connection is closed.
            guard await authenticator.staticAccessAllowed() else {
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: "static_access_denied")
                await failAdmission(sink: sink, requestID: frame.requestID, sessionID: frame.sessionID, code: "static_access_denied", loop: loop)
                return
            }
            guard sink.fence.isActive else {
                _ = loop.submit { self.state = .closing }
                return
            }
            let barrier = await authenticator.bindConnection(
                connectionID: sinkID,
                sink: sink,
                principal: .staticDeveloper,
                connectionGeneration: connectionGeneration
            )
            await barrier.settle()
            // S3-R1-01 (completes S3-I01): register the channel in the shared connection registry
            // IMMEDIATELY after the bind barrier and BEFORE the final denial recheck. A concurrent
            // trust refresh (a required policy appearing, or trust going invalid) during the bind
            // round-trip is then caught by EITHER this recheck (which unregisters and closes below) OR
            // a concurrent `closeAccessDeniedConnections()` sweep, which can now find the channel —
            // the sweep can no longer miss a mid-hello developer connection that was bound but not yet
            // registered. `registeredDeviceID` is recorded on the loop so `channelInactive` can
            // unregister a channel registered during `.authenticating` on an early disconnect.
            connectionRegistry.register(deviceID: deviceID, sinkID: sinkID, channel: channel)
            _ = loop.submit { self.registeredDeviceID = deviceID }
            if await authenticator.accessDenied(forConnection: sinkID) {
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: "static_access_denied")
                connectionRegistry.unregister(deviceID: deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                await failChannelClosing(sink: sink, reason: "static_access_denied", loop: loop)
                return
            }
            guard let access = await authenticator.accessMetadata(forConnection: sinkID) else {
                connectionRegistry.unregister(deviceID: deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                _ = loop.submit { self.state = .closing }
                return
            }
            let identity = GatewayHelloAckIdentity(
                deviceID: deviceID,
                auth: "static_token",
                ticketID: nil,
                scopes: [],
                hostName: hostName,
                vapidPublicKeyBase64URL: vapid,
                includeNullSig: true
            )
            await sink.sendSafeControl(.helloAck(identity: identity, access: access))
            await runtime.registerSink(deviceID: deviceID, sinkID: sinkID, sink: sink)
            _ = loop.submit { self.markReadyAndDrain(Ready(deviceID: deviceID, enforced: false)) }
            if !sink.fence.isActive {
                connectionRegistry.unregister(deviceID: deviceID, sinkID: sinkID)
                await runtime.removeSink(deviceID: deviceID, sinkID: sinkID)
                await authenticator.detachConnection(sinkID)
                await authenticator.endConnection(sinkID)
                _ = loop.submit { self.state = .closing }
                return
            }
            audit(deviceID: deviceID, frame: frame, outcome: "success", code: nil)
        }
    }

    // MARK: Ready-connection dispatch (remote passkey unlock, Step 3)

    /// Client frame types the gateway handles itself: passkey ceremonies, explicit signed foreground
    /// activity, and the phone-initiated lock. NEVER translated to an app tool call; each is
    /// dispatched to the device-access authority / principal passkey relay on an INDEPENDENT task so a
    /// Lock or ceremony is never queued behind an in-flight runtime call.
    private static let controlFrameTypes: Set<String> = [
        "passkey_register_begin",
        "passkey_register_complete",
        "passkey_unlock_begin",
        "passkey_unlock_complete",
        "passkey_activity",
        "lock"
    ]

    /// Connection-management frames that may still EXECUTE (for their server-side effect) while the
    /// connection is locked under an unchanged binding. Their result is withheld behind a sanitized
    /// settlement; none expose protected session content. Every other ordinary frame is blocked
    /// unexecuted while locked.
    private static let lockedManagementFrameTypes: Set<String> = [
        "ping",
        "unsubscribe",
        "push_subscribe",
        "push_unsubscribe"
    ]

    private func dispatchReadyFrame(
        rawData: Data,
        frame: RemoteClientFrame,
        ready: Ready,
        sink: GatewayWebSocketFrameSink,
        loop: EventLoop
    ) {
        if ready.enforced {
            dispatchEnforcedFrame(rawData: rawData, frame: frame, deviceID: ready.deviceID, sink: sink, loop: loop)
        } else {
            dispatchStaticFrame(frame: frame, deviceID: ready.deviceID, sink: sink)
        }
    }

    /// Transition to `.ready` and drain any frames buffered during authentication, in arrival order,
    /// through the normal ready dispatch. Runs on the event loop (called via `loop.submit` from the
    /// hello task). If the connection disconnected during registration the buffer is dropped — the
    /// late-disconnect compensation path in the hello task performs the authority/watch cleanup.
    private func markReadyAndDrain(_ ready: Ready) {
        guard let eventLoop, let sink, sink.fence.isActive else {
            framesBufferedDuringAuth.removeAll()
            state = .closing
            return
        }
        state = .ready(ready)
        let buffered = framesBufferedDuringAuth
        framesBufferedDuringAuth.removeAll()
        for item in buffered {
            dispatchReadyFrame(rawData: item.rawData, frame: item.frame, ready: ready, sink: sink, loop: eventLoop)
        }
    }

    /// Paired frames are admitted in arrival order (`verifyFrame`) so signed counters stay monotonic;
    /// signature/counter/revocation failures terminate the connection. After admission a control
    /// frame runs on its own task and an ordinary runtime frame is enqueued on the serial runtime
    /// chain, which rechecks the lock at its head.
    private func dispatchEnforcedFrame(
        rawData: Data,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink,
        loop: EventLoop
    ) {
        guard let authenticator else {
            failTerminal(requestID: frame.requestID, sessionID: frame.sessionID, code: "ticket_auth_unavailable")
            return
        }
        let sinkID = sinkID
        enqueueAdmission { [weak self] in
            guard let self else { return }
            let device: DeviceAuthenticator.AuthenticatedDevice
            do {
                device = try await authenticator.verifyFrame(rawFrame: rawData, frame: frame, connectionID: sinkID)
            } catch let error as DeviceAuthenticationError {
                self.audit(deviceID: deviceID, frame: frame, outcome: "denied", code: error.code)
                // Verification failure: a sanitized fixed-code failure on the safe path (reaches a
                // locked connection too), then close. A revoked device additionally gets a sanitized
                // channel_closing. No raw error text is forwarded.
                await sink.sendSafeControl(.commandFailure(requestID: frame.requestID, sessionID: frame.sessionID, code: error.code))
                if case .deviceRevoked = error {
                    await sink.sendSafeControl(.channelClosing(reason: error.code))
                }
                _ = loop.submit { self.state = .closing }
                await sink.close()
                return
            } catch {
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: "frame_verification_failed")
                await failAdmission(sink: sink, requestID: frame.requestID, sessionID: frame.sessionID, code: "frame_verification_failed", loop: loop)
                return
            }

            if Self.controlFrameTypes.contains(frame.type) {
                // The SHORT authority mutations (lock / begin / take / renew-admission) run IN this
                // ordered admission stage so a Lock cannot be reordered behind a later begin/complete;
                // only the slow network/relay work is dispatched to an independent task.
                await admitControlFrame(frame: frame, deviceID: deviceID, sink: sink)
            } else {
                // Mint the correlated settlement context from authority state AT ADMISSION (in order),
                // so a request admitted before a Lock cannot later execute after an unlock: the runtime
                // head re-checks the current binding against this admission binding.
                let admissionView = await authenticator.accessView(forConnection: sinkID)
                // S3-I07: reject a protected/unknown operation that arrives WHILE LOCKED immediately at
                // admission (after signature/counter verification), so a later unlock of the SAME lock
                // generation cannot let a command received-while-locked execute. The runtime-head
                // binding recheck does not catch this because a successful assertion does NOT advance
                // the binding. The locked-management allowlist still runs for its side effect (handled
                // at the runtime head); control frames never reach here.
                if admissionView?.isLocked ?? true, !Self.lockedManagementFrameTypes.contains(frame.type) {
                    audit(deviceID: deviceID, frame: frame, outcome: "denied", code: GatewaySafeControlReason.locked.rawValue)
                    await sink.sendSafeControl(.lockSettlement(requestID: frame.requestID))
                    return
                }
                let context = GatewayRequestContext(
                    principal: .pairedDevice(deviceID: deviceID),
                    deviceID: deviceID,
                    requestID: frame.requestID,
                    admissionBinding: admissionView?.binding,
                    admissionRevision: admissionView?.revision ?? .initial
                )
                enqueueRuntime {
                    await self.handlePairedRuntimeFrame(frame: frame, deviceID: deviceID, scopes: device.scopes, sink: sink, context: context)
                }
            }
        }
    }

    /// The developer static-token connection has no passkey identity: control frames are rejected via
    /// the safe path; an unknown frame type defaults to a sanitized generic unsupported; ordinary
    /// frames run on the serial runtime chain and are gated/settled through the correlated path (static
    /// access, when allowed, is `.unprotected`).
    private func dispatchStaticFrame(frame: RemoteClientFrame, deviceID: String, sink: GatewayWebSocketFrameSink) {
        if Self.controlFrameTypes.contains(frame.type) {
            Task { await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .protocolError)) }
            return
        }
        guard RemoteWireProtocol.clientFrameTypes.contains(frame.type) else {
            // Unknown types default to protected: a sanitized generic unsupported, never translated.
            Task {
                await sink.send(.commandError(
                    requestID: frame.requestID,
                    sessionID: frame.sessionID,
                    code: "unsupported_frame_type",
                    message: "The requested operation is not supported."
                ))
            }
            return
        }
        enqueueRuntime {
            await self.handleStaticRuntimeFrame(frame: frame, deviceID: deviceID, sink: sink)
        }
    }

    /// Execute an admitted static-developer runtime frame. The runtime head re-checks access (a
    /// required policy appearing mid-connection flips static access to locked) and settles through the
    /// correlated path, so the deferred subscription validation is activated ONLY when the original
    /// response was actually enqueued; a withheld/dropped response discards it instead.
    private func handleStaticRuntimeFrame(frame: RemoteClientFrame, deviceID: String, sink: GatewayWebSocketFrameSink) async {
        guard let authenticator else { return }
        let sinkID = sinkID
        let runtime = runtime
        let view = await authenticator.accessView(forConnection: sinkID)
        // S3-I01: a static-developer connection's queued work must NOT execute once its access was
        // withdrawn (a required policy appeared, or trust went invalid) or the socket closed while the
        // request waited behind a slower one. The outbound sink suppresses the RESULT but cannot undo a
        // mutation, so gate on a LIVE connection and currently-authorized unprotected access BEFORE
        // `runtime.handle`. A withdrawn/dead connection gets a sanitized denial and its deferred
        // subscription validation is discarded.
        guard sink.fence.isActive, view?.access == .unprotected else {
            await sink.sendSafeControl(.commandFailure(requestID: frame.requestID, sessionID: frame.sessionID, code: "static_access_denied"))
            await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            return
        }
        let context = GatewayRequestContext(
            principal: .staticDeveloper,
            deviceID: deviceID,
            requestID: frame.requestID,
            admissionBinding: view?.binding,
            admissionRevision: view?.revision ?? .initial
        )
        await sink.registerPendingResponse(context)
        if let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink) {
            let outcome = await sink.sendResponse(response, for: context)
            if outcome == .originalEnqueued {
                await runtime.didQueueResponse(for: frame, response: response, deviceID: deviceID, sinkID: sinkID)
            } else {
                await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            }
        } else {
            await sink.discardPendingResponse(context)
        }
    }

    /// Execute an admitted ordinary runtime frame for a paired device, using the admission binding
    /// captured in-order at admission. If a Lock (or epoch/origin/launch change) landed since
    /// admission the binding differs and the request is withheld WITHOUT execution. While locked under
    /// the SAME binding, only a fixed allowlist of connection-management ops execute (for their side
    /// effect) behind a sanitized settlement; everything else is withheld. Otherwise scope is enforced
    /// and the correlated response is settled exactly once, activating any deferred validation only
    /// when the original response was actually enqueued.
    private func handlePairedRuntimeFrame(
        frame: RemoteClientFrame,
        deviceID: String,
        scopes: Set<String>,
        sink: GatewayWebSocketFrameSink,
        context: GatewayRequestContext
    ) async {
        guard let authenticator else { return }
        let sinkID = sinkID
        let runtime = runtime
        let view = await authenticator.accessView(forConnection: sinkID)
        // S3-I07: the execution head also checks LIVENESS. A connection that closed while this request
        // waited behind a slower one must not execute a protected mutation (the sink would suppress the
        // result, but the mutation would already have run). A dead/detached connection (`view` nil or
        // fence closed) withholds and discards without executing.
        guard sink.fence.isActive, let view else {
            await sink.sendSafeControl(.lockSettlement(requestID: frame.requestID))
            await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            return
        }
        let bindingChanged = view.binding != context.admissionBinding
        let locked = view.isLocked

        // A lock/epoch/origin/launch change since admission invalidates this request outright: withhold
        // a sanitized settlement and run nothing.
        if bindingChanged {
            audit(deviceID: deviceID, frame: frame, outcome: "denied", code: GatewaySafeControlReason.locked.rawValue)
            await sink.sendSafeControl(.lockSettlement(requestID: frame.requestID))
            await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            return
        }

        if locked {
            // Same binding, still locked (no lock boundary crossed since admission). Only the fixed
            // management allowlist executes for its side effect; its result is withheld behind a
            // sanitized settlement. Everything else (including unknown types) is blocked unexecuted.
            guard Self.lockedManagementFrameTypes.contains(frame.type) else {
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: GatewaySafeControlReason.locked.rawValue)
                await sink.sendSafeControl(.lockSettlement(requestID: frame.requestID))
                await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
                return
            }
            if case let .denied(requiredScope) = ScopeEnforcer.decision(frameType: frame.type, grantedScopes: scopes) {
                let scopeError = ScopeEnforcementError(operation: frame.type, requiredScope: requiredScope)
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: scopeError.code)
                await sink.sendSafeControl(.lockSettlement(requestID: frame.requestID))
                await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
                return
            }
            let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink)
            // S3-A-11: a connection-management op that actually RAN and SUCCEEDED gets its own fixed,
            // content-free result (a heartbeat `ping` → `pong`; `unsubscribe`/`push_*` → empty
            // `command_result`), not a `passkey_locked` settlement that a client reads as a FAILURE. No
            // session content rides this path.
            //
            // S3-R1-02: but a management op that FAILED (e.g. `unsubscribe` with no live binding, or
            // `push_subscribe` with push unavailable / invalid payload / storage error) returns a
            // `command_error`. Report that as a sanitized, closed-set failure carrying ONLY the bounded
            // code and a fixed message — never the runtime payload or app error text — so the browser
            // does not believe management state changed when it did not. A success (`command_result` /
            // `pong`) or a nil result keeps the fixed management acknowledgement.
            if let response, response.type == "command_error" {
                let code = response.payload?.objectValue?["code"]?.stringValue ?? "request_failed"
                await sink.sendSafeControl(.commandFailure(requestID: frame.requestID, sessionID: frame.sessionID, code: code))
            } else {
                await sink.sendSafeControl(.managementResult(requestID: frame.requestID, sessionID: frame.sessionID, frameType: frame.type))
            }
            await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            return
        }

        switch ScopeEnforcer.decision(frameType: frame.type, grantedScopes: scopes) {
        case .allowed:
            break
        case let .denied(requiredScope):
            let scopeError = ScopeEnforcementError(operation: frame.type, requiredScope: requiredScope)
            audit(deviceID: deviceID, frame: frame, outcome: "denied", code: scopeError.code)
            await sink.send(.commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: scopeError.code,
                message: scopeError.description,
                details: .object(["required_scope": .string(requiredScope)])
            ))
            return
        case .unknownOperation:
            audit(deviceID: deviceID, frame: frame, outcome: "denied", code: "unsupported_frame_type")
            await sink.send(.commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "unsupported_frame_type",
                message: "The requested operation is not supported."
            ))
            return
        }
        await sink.registerPendingResponse(context)
        if let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink) {
            let outcome = await sink.sendResponse(response, for: context)
            if outcome == .originalEnqueued {
                await runtime.didQueueResponse(for: frame, response: response, deviceID: deviceID, sinkID: sinkID)
            } else {
                await runtime.discardQueuedResponse(for: frame, deviceID: deviceID, sinkID: sinkID)
            }
        } else {
            await sink.discardPendingResponse(context)
        }
    }

    // MARK: Control-frame admission (ordered) + independent network work

    /// Runs the SHORT authority mutation for a signed control frame IN the ordered admission stage, so
    /// a Lock linearizes ahead of a later begin/complete. Only the slow network/relay/refresh work is
    /// dispatched to an independent task (and re-validates binding/generation on completion).
    private func admitControlFrame(frame: RemoteClientFrame, deviceID: String, sink: GatewayWebSocketFrameSink) async {
        switch frame.type {
        case "lock":
            await handleLockFrame(deviceID: deviceID)
        case "passkey_activity":
            await admitActivity(frame: frame, deviceID: deviceID)
        case "passkey_unlock_begin":
            await admitCeremonyBegin(kind: .assertion, frame: frame, deviceID: deviceID, sink: sink)
        case "passkey_register_begin":
            await admitCeremonyBegin(kind: .registration, frame: frame, deviceID: deviceID, sink: sink)
        case "passkey_unlock_complete":
            await admitCeremonyComplete(kind: .assertion, frame: frame, deviceID: deviceID, sink: sink)
        case "passkey_register_complete":
            await admitCeremonyComplete(kind: .registration, frame: frame, deviceID: deviceID, sink: sink)
        default:
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .protocolError))
        }
    }

    /// Phone-initiated lock: drop the shared grant immediately and publish the locked state to every
    /// one of the device's connections. Short and fully ordered in the admission stage so it is never
    /// reordered behind a later begin/complete.
    private func handleLockFrame(deviceID: String) async {
        guard let authenticator else { return }
        let barrier = await authenticator.lockDevice(deviceID)
        await barrier.settle()
    }

    /// Admit an explicit signed foreground-activity renewal. Requires the EXACT grant references the
    /// client signed (grant_id + epoch + lock_generation) and validates them against the CURRENT
    /// binding, so a stale activity frame (signed against a superseded grant/epoch/lock generation)
    /// cannot renew the current grant. The acceptance TIME is captured here, in the ordered admission
    /// stage, not in the delayed network task. The slow trust refresh + commit run independently.
    private func admitActivity(frame: RemoteClientFrame, deviceID: String) async {
        guard let authenticator else { return }
        let sinkID = sinkID
        guard let object = frame.payload?.objectValue,
              let grantID = object["grant_id"]?.stringValue,
              let epochString = object["epoch"]?.stringValue, let epoch = UInt64(epochString),
              let lockGenString = object["lock_generation"]?.stringValue, let lockGeneration = UInt64(lockGenString)
        else {
            return
        }
        guard let view = await authenticator.accessView(forConnection: sinkID),
              let binding = view.binding,
              binding.policyEpoch == epoch,
              binding.lockGeneration == lockGeneration
        else {
            return
        }
        let admission = await authenticator.beginActivityRenewal(
            deviceID: deviceID,
            grantID: grantID,
            connectionID: sinkID,
            at: accessClock.now()
        )
        guard case let .accepted(token) = admission else { return }
        Task { await self.completeActivity(deviceID: deviceID, token: token) }
    }

    /// The slow part of an activity renewal: its OWN fresh principal trust refresh, then commit. Run on
    /// an independent task so it never blocks the admission stage; the commit re-validates the
    /// binding/generation and original deadline. A transport failure or invalidation preserves the
    /// original deadline; a cancellation (shutdown) or any other throw never renews.
    private func completeActivity(deviceID: String, token: UUID) async {
        guard let authenticator else { return }
        let refreshSucceeded: Bool
        if let action = passkeyTrustRefreshAction {
            do {
                switch try await action() {
                case .applied: refreshSucceeded = true
                case .invalid, .transportFailure: refreshSucceeded = false
                }
            } catch {
                let barrier = await authenticator.commitActivityRenewal(deviceID: deviceID, token: token, refreshSucceeded: false)
                await barrier.settle()
                return
            }
        } else {
            refreshSucceeded = false
        }
        // S3-I02/I03: `commitActivityRenewal` publishes the renewed authorization AND the extended-deadline
        // access-state notice to every tab as ONE revision-bound transition (folded into `barrier`), so
        // the browser keeps the correct countdown and can sign the next activity frame without a
        // reconnect. A transition that superseded the renewal is a newer revision and drops the stale
        // notice. On a failed/rejected renewal the commit returns `.empty` (no notice). `passkey_activity`
        // carries no correlated response, so the notice is the only reply and needs no ordering split.
        let barrier = await authenticator.commitActivityRenewal(deviceID: deviceID, token: token, refreshSucceeded: refreshSucceeded)
        await barrier.settle()
    }

    /// Admit a ceremony begin: the SHORT authority mutation (`beginCeremony`) runs in the ordered
    /// admission stage so a Lock admitted afterward advances the generation and the later attach fails
    /// stale. The slow relay begin + attach + challenge run on an independent task.
    private func admitCeremonyBegin(
        kind: GatewayCeremonyKind,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink
    ) async {
        guard let authenticator, let relay = passkeyRelay else {
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .authenticationFailure))
            return
        }
        let sinkID = sinkID
        let connectionGeneration = connectionGeneration
        let token = switch kind {
        case .assertion: await authenticator.beginAssertionCeremony(deviceID: deviceID, connectionID: sinkID)
        case .registration: await authenticator.beginRegistrationCeremony(deviceID: deviceID, connectionID: sinkID)
        }
        guard let token else {
            // Not enforced, or no usable authoritative origin. (An already-pending ceremony of this kind
            // no longer blocks a begin: safe replacement always replaces it, so nil is never that case.)
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .protocolError))
            return
        }
        Task {
            await self.runCeremonyBegin(
                kind: kind, frame: frame, deviceID: deviceID, sink: sink,
                relay: relay, authenticator: authenticator, token: token,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func runCeremonyBegin(
        kind: GatewayCeremonyKind,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink,
        relay: GatewayPasskeyRelay,
        authenticator: DeviceAuthenticator,
        token: UUID,
        connectionGeneration: UInt64
    ) async {
        let outcome: GatewayPasskeyBeginOutcome
        do {
            switch kind {
            case .assertion: outcome = try await relay.unlockBegin(deviceID: deviceID, connectionGeneration: connectionGeneration)
            case .registration: outcome = try await relay.registerBegin(deviceID: deviceID, connectionGeneration: connectionGeneration)
            }
        } catch {
            // Cancellation (shutdown): discard the pending so a later connection can retry; emit nothing.
            await discardPendingCeremony(kind: kind, deviceID: deviceID, token: token, authenticator: authenticator)
            return
        }
        switch outcome {
        case .transportFailure, .rejected:
            await discardPendingCeremony(kind: kind, deviceID: deviceID, token: token, authenticator: authenticator)
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .protocolError))
        case let .began(result):
            let attached = switch kind {
            case .assertion: await authenticator.attachAssertionCeremonyAppID(deviceID: deviceID, token: token, appCeremonyID: result.appCeremonyID)
            case .registration: await authenticator.attachRegistrationCeremonyAppID(deviceID: deviceID, token: token, appCeremonyID: result.appCeremonyID)
            }
            guard attached else {
                // Binding/generation changed (or the fence closed) during the begin round-trip.
                await discardPendingCeremony(kind: kind, deviceID: deviceID, token: token, authenticator: authenticator)
                await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .staleCeremony))
                return
            }
            await sink.sendSafeControl(.passkeyChallenge(
                requestID: frame.requestID,
                kind: kind,
                deviceID: deviceID,
                ceremonyID: result.appCeremonyID,
                options: result.optionsPayload
            ))
        }
    }

    /// Admit a ceremony complete: payload validation and the one-shot `takePending` (which consumes
    /// completion eligibility so a replay cannot dispatch twice) run in the ordered admission stage.
    /// The slow relay verify + commit run on an independent task; the commit re-validates binding and
    /// generation, so a begin/complete whose metadata went stale behind a Lock cannot unlock.
    private func admitCeremonyComplete(
        kind: GatewayCeremonyKind,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink
    ) async {
        guard let authenticator, let relay = passkeyRelay else {
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .authenticationFailure))
            return
        }
        // The browser echoes the app-issued ceremony id plus the credential; the connection generation
        // is the server's OWN, never client-supplied. Bounds keep a malformed frame cheap.
        guard let object = frame.payload?.objectValue,
              let appCeremonyID = object["ceremony_id"]?.stringValue,
              (16 ... 64).contains(appCeremonyID.count),
              let credentialJSON = object["credential"]?.stringValue,
              credentialJSON.utf8.count <= 64 * 1024
        else {
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .protocolError))
            return
        }
        let connectionGeneration = connectionGeneration
        let pending = switch kind {
        case .assertion: await authenticator.takePendingAssertion(deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration)
        case .registration: await authenticator.takePendingRegistration(deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration)
        }
        guard let pending else {
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .staleCeremony))
            return
        }
        Task {
            await self.runCeremonyComplete(
                kind: kind, frame: frame, deviceID: deviceID, sink: sink,
                relay: relay, authenticator: authenticator, pending: pending,
                appCeremonyID: appCeremonyID, credentialJSON: credentialJSON,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func runCeremonyComplete(
        kind: GatewayCeremonyKind,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink,
        relay: GatewayPasskeyRelay,
        authenticator: DeviceAuthenticator,
        pending: GatewayPendingCeremony,
        appCeremonyID: String,
        credentialJSON: String,
        connectionGeneration: UInt64
    ) async {
        let outcome: GatewayPasskeyCompleteOutcome
        do {
            switch kind {
            case .assertion: outcome = try await relay.unlockComplete(deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration, credentialJSON: credentialJSON)
            case .registration: outcome = try await relay.registerComplete(deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration, credentialJSON: credentialJSON)
            }
        } catch {
            // Cancellation (shutdown): the pending is already consumed; emit nothing.
            return
        }
        switch outcome {
        case .transportFailure, .rejected:
            await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .authenticationFailure))
        case let .verified(result):
            switch kind {
            case .assertion:
                // Use THIS commit's own success (installed under the initiating fence with the binding
                // and generation still current), not a `hasGrant` probe that a concurrent ceremony
                // could have satisfied, so a stale begin/complete behind a Lock cannot report unlocked.
                let commit = await authenticator.commitVerifiedAssertion(
                    deviceID: deviceID,
                    pending: pending,
                    verifiedEpoch: result.epoch,
                    committedAt: accessClock.now()
                )
                // S3-I02/I03: `commitVerifiedAssertion` installs the grant and settles the unlocked
                // authorization's all-sink barrier (`commit.barrier`), but returns its access-state
                // notices (grant_id / epoch / lock_generation / remaining lifetime) UNDELIVERED. Send
                // `ceremony_complete` FIRST — the ceremony's own correlated frame — then flush the
                // captured notices to ALL of the device's tabs so the initiating browser (which
                // connected locked and had no grant reference in its hello) and its siblings learn the
                // unlocked state WITHOUT reconnecting. Delivery is revision-gated, so a transition that
                // superseded this unlock (e.g. a concurrent Lock) drops the stale notice, and no notice
                // precedes its own cross-tab barrier (S3-I02).
                await commit.barrier.settle()
                if commit.installedGrant {
                    await sink.sendSafeControl(.ceremonyCompletion(requestID: frame.requestID, kind: .assertion))
                    await authenticator.deliverGatedNotices(commit.capturedNotices).settle()
                } else {
                    await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .staleCeremony))
                }
            case .registration:
                // Registration NEVER installs a grant; a fresh assertion is still required. The app has
                // already PERSISTED the credential (the relay verified it), so a superseded gateway
                // ceremony slot must NOT make the browser re-run registration (a second native prompt
                // over a saved credential). B17/S3-A-17: ALWAYS run the post-registration trust refresh —
                // whether or not this gateway ceremony generation was superseded — to ADOPT the new
                // epoch/enrollment (S3-I05: otherwise the required separate assertion runs against the OLD
                // gateway epoch, which the refresh then invalidates). B25: registration does NOT call the
                // authority's generation-fenced commit here at all — it would install no grant and its
                // result was ignored, so completion is gated purely by the authority-confirmed refreshed
                // enrollment below, with the app's WebAuthn verifier authoritative for the registration
                // itself. (Assertion commits remain generation-fenced; only registration's generation
                // check was inert.)
                let refreshed: Bool
                if let action = passkeyTrustRefreshAction {
                    do {
                        switch try await action() {
                        case .applied: refreshed = true
                        case .invalid, .transportFailure: refreshed = false
                        }
                    } catch {
                        // Cancellation (shutdown) or any other throw: do not announce readiness.
                        refreshed = false
                    }
                } else {
                    // No refresh action wired (unit harnesses without one): rely solely on the
                    // authority's current enrolled state below.
                    refreshed = true
                }
                // Report completion ONLY when the authority's OWN refreshed state confirms the device is
                // enrolled at an epoch no older than the verified result. A failed/stale/lower-epoch
                // refresh yields a sanitized `unavailable` (no false success, no rollback, no auto-retry);
                // a successful refresh that changed enrollment already published the authoritative
                // access-state notice to the browser.
                let enrolledAtEpoch = await authenticator.isDeviceEnrolled(deviceID: deviceID, atLeastEpoch: result.epoch)
                if refreshed, enrolledAtEpoch {
                    await sink.sendSafeControl(.ceremonyCompletion(requestID: frame.requestID, kind: .registration))
                } else {
                    await sink.sendSafeControl(.failure(requestID: frame.requestID, reason: .unavailable))
                }
            }
        }
    }

    private func discardPendingCeremony(
        kind: GatewayCeremonyKind,
        deviceID: String,
        token: UUID,
        authenticator: DeviceAuthenticator
    ) async {
        switch kind {
        case .assertion: await authenticator.discardPendingAssertion(deviceID: deviceID, token: token)
        case .registration: await authenticator.discardPendingRegistration(deviceID: deviceID, token: token)
        }
    }

    // MARK: Ordered task chains

    /// Admission chain: `verifyFrame` runs strictly in arrival order so signed counters stay
    /// monotonic. Admission only verifies and routes; it never awaits runtime execution. Mutated only
    /// on the event loop (hello) or from within its own serialized chain.
    private func enqueueAdmission(_ operation: @escaping @Sendable () async -> Void) {
        onEventLoop {
            let previous = self.admissionTask
            self.admissionTask = Task {
                await previous?.value
                await operation()
            }
        }
    }

    /// Runtime chain: admitted ordinary frames execute and settle in arrival order so responses keep
    /// their order. Fed only from the admission chain (paired) or the event loop (static), so it is
    /// never mutated concurrently.
    private func enqueueRuntime(_ operation: @escaping @Sendable () async -> Void) {
        onEventLoop {
            let previous = self.runtimeTask
            self.runtimeTask = Task {
                await previous?.value
                await operation()
            }
        }
    }

    /// Run `body` on the connection's event loop so a handler-field mutation is never raced. If
    /// already on the loop (the channelRead/static path) it runs synchronously; otherwise (an
    /// off-loop admission task appending to the runtime chain) it is submitted, preserving FIFO order.
    private func onEventLoop(_ body: @escaping @Sendable () -> Void) {
        guard let eventLoop else { return }
        if eventLoop.inEventLoop {
            body()
        } else {
            eventLoop.execute(body)
        }
    }

    /// Terminal rejection from the event-loop path (channelRead/hello pre-admission). Marks the
    /// connection closing synchronously, then emits ONE sanitized `command_error` safe-control (fixed
    /// message, length-bounded code) and closes. Routed through the sink so no raw error text or
    /// arbitrary frame can bypass the authorization/sanitization boundary.
    private func failTerminal(requestID: String?, sessionID: String?, code: String) {
        state = .closing
        guard let sink else { return }
        Task {
            await sink.sendSafeControl(.commandFailure(requestID: requestID, sessionID: sessionID, code: code))
            await sink.close()
        }
    }

    /// Terminal rejection from within an admission/runtime task (already off the event loop). Awaits
    /// the sanitized `command_error` safe-control, marks the connection closing on the loop, then
    /// closes. The settlement is awaited before the close so the frame is enqueued first.
    private func failAdmission(
        sink: GatewayWebSocketFrameSink,
        requestID: String?,
        sessionID: String?,
        code: String,
        loop: EventLoop
    ) async {
        await sink.sendSafeControl(.commandFailure(requestID: requestID, sessionID: sessionID, code: code))
        _ = loop.submit { self.state = .closing }
        await sink.close()
    }

    /// Terminal connection teardown with a sanitized `channel_closing` safe-control (fixed message,
    /// length-bounded reason code). Used for app-link/trust failures discovered after admission; raw
    /// app-link or SDK error text never rides this path.
    private func failChannelClosing(
        sink: GatewayWebSocketFrameSink,
        reason: String,
        loop: EventLoop
    ) async {
        await sink.sendSafeControl(.channelClosing(reason: reason))
        _ = loop.submit { self.state = .closing }
        await sink.close()
    }

    private func audit(deviceID: String, frame: RemoteClientFrame, outcome: String, code: String?) {
        auditLog?.recordBestEffort(RemoteAuditRecord(
            deviceID: deviceID,
            requestID: frame.requestID,
            op: frame.type,
            sessionID: frame.sessionID,
            outcome: outcome,
            code: code
        ))
    }

    private func isHelloAuthorized(_ frame: RemoteClientFrame) -> Bool {
        guard let expected = configuration.staticToken, !expected.isEmpty else { return true }
        return frame.payload?.objectValue?["static_token"]?.stringValue == expected
    }
}

// `GatewayWebSocketFrameSink` was extracted to `Server/GatewayWebSocketFrameSink.swift` (remote
// passkey unlock, Step 3) so the production NIO sink is narrowly testable against an embedded channel
// and an injected clock, and so it can carry closed-by-default outbound authorization gating.
