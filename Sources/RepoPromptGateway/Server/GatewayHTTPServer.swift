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
        self.logger = logger
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
        /// `enforced` is true for ticket-authenticated connections that require
        /// per-frame device signatures and scope checks; the developer-only
        /// static-token path is unenforced (Phase 0 semantics).
        case ready(deviceID: String, enforced: Bool)
        case closing
    }

    private let configuration: GatewayConfiguration
    private let runtime: RemoteGatewayRuntime
    private let authenticator: DeviceAuthenticator?
    private let appLinkPool: AppLinkPool?
    private let auditLog: RemoteAuditLog?
    private let connectionRegistry: GatewayWebSocketConnectionRegistry
    private let vapidPublicKeyBase64URL: String?
    private let hostName: String
    private let logger: Logger
    private let sinkID = UUID()
    private var sink: GatewayWebSocketFrameSink?
    private var state: State = .awaitingHello
    /// Serializes async frame processing so counters are checked in arrival order.
    private var frameProcessingTask: Task<Void, Never>?

    init(
        configuration: GatewayConfiguration,
        runtime: RemoteGatewayRuntime,
        authenticator: DeviceAuthenticator?,
        appLinkPool: AppLinkPool?,
        auditLog: RemoteAuditLog?,
        connectionRegistry: GatewayWebSocketConnectionRegistry,
        vapidPublicKeyBase64URL: String? = nil,
        hostName: String,
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
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        sink = GatewayWebSocketFrameSink(channel: context.channel)
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
                sendAndClose(
                    .commandError(requestID: nil, code: "fragmented_frames_unsupported", message: "Fragmented WebSocket frames are not supported."),
                    context: context
                )
                return
            }
            var buffer = frame.unmaskedData
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            handleRemoteData(Data(bytes), context: context)
        default:
            sendAndClose(
                .commandError(requestID: nil, code: "unsupported_ws_opcode", message: "Unsupported WebSocket opcode."),
                context: context
            )
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        if case let .ready(deviceID, _) = state {
            let sinkID = sinkID
            let runtime = runtime
            let authenticator = authenticator
            connectionRegistry.unregister(deviceID: deviceID, sinkID: sinkID)
            Task {
                await runtime.removeSink(deviceID: deviceID, sinkID: sinkID)
                await authenticator?.endConnection(sinkID)
            }
        } else {
            let sinkID = sinkID
            let authenticator = authenticator
            Task { await authenticator?.endConnection(sinkID) }
        }
        state = .closing
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("Gateway websocket error: \(String(describing: error))")
        context.close(promise: nil)
    }

    private func handleRemoteData(_ data: Data, context: ChannelHandlerContext) {
        let frame: RemoteClientFrame
        do {
            frame = try RemoteWireProtocol.decodeClientFrame(from: data)
        } catch let error as RemoteWireProtocolError {
            sendAndMaybeClose(
                .commandError(requestID: nil, code: error.code, message: error.description),
                close: false,
                context: context
            )
            return
        } catch {
            sendAndMaybeClose(
                .commandError(requestID: nil, code: "invalid_frame", message: String(describing: error)),
                close: false,
                context: context
            )
            return
        }

        switch state {
        case .awaitingHello:
            guard frame.type == "hello" else {
                sendAndClose(
                    .commandError(
                        requestID: frame.requestID,
                        sessionID: frame.sessionID,
                        code: "hello_required",
                        message: "hello must be the first WebSocket frame."
                    ),
                    context: context
                )
                return
            }
            if frame.payload?.objectValue?["ticket"] != nil {
                handleTicketHello(rawData: data, frame: frame, context: context)
                return
            }
            handleStaticTokenHello(frame, context: context)
        case .authenticating:
            sendAndClose(
                .commandError(
                    requestID: frame.requestID,
                    sessionID: frame.sessionID,
                    code: "hello_in_progress",
                    message: "Wait for hello_ack before sending frames."
                ),
                context: context
            )
        case let .ready(deviceID, enforced):
            guard let sink else { return }
            if enforced {
                handleEnforcedFrame(rawData: data, frame: frame, deviceID: deviceID, sink: sink, context: context)
            } else {
                let runtime = runtime
                let sinkID = sinkID
                Task {
                    if let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink) {
                        await sink.send(response)
                        await runtime.didQueueResponse(
                            for: frame,
                            response: response,
                            deviceID: deviceID,
                            sinkID: sinkID
                        )
                    }
                }
            }
        case .closing:
            return
        }
    }

    /// M4 normal path: hello carries an app-minted one-time ticket plus a device frame
    /// signature. The used ticket is persisted before the connection is accepted; any
    /// auth failure rejects the hello before translation and audits the outcome.
    private func handleTicketHello(rawData: Data, frame: RemoteClientFrame, context: ChannelHandlerContext) {
        guard let sink else { return }
        guard let authenticator else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "ticket_auth_unavailable")
            sendAndClose(
                .commandError(
                    requestID: frame.requestID,
                    code: "ticket_auth_unavailable",
                    message: "Ticket authentication is not available."
                ),
                context: context
            )
            return
        }
        state = .authenticating
        let loop = context.eventLoop
        let channel = context.channel
        let runtime = runtime
        let appLinkPool = appLinkPool
        let sinkID = sinkID
        enqueueFrameProcessing { [weak self] in
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
                loop.execute { self.state = .closing }
                await sink.send(.commandError(requestID: frame.requestID, code: error.code, message: error.description))
                channel.close(promise: nil)
                return
            } catch {
                audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "hello_failed")
                loop.execute { self.state = .closing }
                await sink.send(.commandError(
                    requestID: frame.requestID,
                    code: "hello_failed",
                    message: String(describing: error)
                ))
                channel.close(promise: nil)
                return
            }

            if let appLinkPool {
                do {
                    try await appLinkPool.ensureLink(forDevice: device.deviceID)
                } catch let error as AppLinkPoolError {
                    // Connection capacity must surface to the remote client as
                    // channel_closing {reason}, never silence.
                    self.audit(deviceID: device.deviceID, frame: frame, outcome: "failure", code: error.code)
                    loop.execute { self.state = .closing }
                    await sink.send(RemoteServerFrame(
                        type: "channel_closing",
                        payload: .object([
                            "reason": .string(error.code),
                            "message": .string(error.description)
                        ])
                    ))
                    channel.close(promise: nil)
                    return
                } catch {
                    audit(deviceID: device.deviceID, frame: frame, outcome: "failure", code: "app_link_unavailable")
                    loop.execute { self.state = .closing }
                    await sink.send(RemoteServerFrame(
                        type: "channel_closing",
                        payload: .object([
                            "reason": .string("app_link_unavailable"),
                            "message": .string(String(describing: error))
                        ])
                    ))
                    channel.close(promise: nil)
                    return
                }
            }

            connectionRegistry.register(deviceID: device.deviceID, sinkID: sinkID, channel: channel)
            await runtime.registerSink(deviceID: device.deviceID, sinkID: sinkID, sink: sink)
            loop.execute { self.state = .ready(deviceID: device.deviceID, enforced: true) }
            audit(deviceID: device.deviceID, frame: frame, outcome: "success", code: nil)
            var helloAckPayload: [String: JSONValue] = [
                "device_id": .string(device.deviceID),
                "auth": .string("ticket"),
                "ticket_id": .string(device.ticketID.uuidString.lowercased()),
                "scopes": .array(device.scopes.sorted().map(JSONValue.string)),
                "host_name": .string(hostName),
                "features": .array(RemoteWireFeatures.all.map(JSONValue.string))
            ]
            if let vapidPublicKeyBase64URL {
                helloAckPayload["vapid_public_key"] = .string(vapidPublicKeyBase64URL)
            }
            await sink.send(.helloAck(payload: .object(helloAckPayload)))
        }
    }

    /// Phase 0 static-token authentication survives only behind the explicit
    /// developer-only `allowStaticTokenAuth` flag.
    private func handleStaticTokenHello(_ frame: RemoteClientFrame, context: ChannelHandlerContext) {
        guard configuration.allowStaticTokenAuth else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "ticket_required")
            sendAndClose(
                .commandError(
                    requestID: frame.requestID,
                    code: "ticket_required",
                    message: "hello requires an app-minted ticket; static-token auth is disabled."
                ),
                context: context
            )
            return
        }
        guard isHelloAuthorized(frame) else {
            audit(deviceID: "unknown", frame: frame, outcome: "denied", code: "unauthorized")
            sendAndClose(
                .commandError(
                    requestID: frame.requestID,
                    code: "unauthorized",
                    message: "Invalid static token."
                ),
                context: context
            )
            return
        }
        guard let sink else { return }
        let deviceID = RemoteGatewayRuntime.phase0DeviceID
        state = .ready(deviceID: deviceID, enforced: false)
        connectionRegistry.register(deviceID: deviceID, sinkID: sinkID, channel: context.channel)
        let runtime = runtime
        let sinkID = sinkID
        let vapidPublicKeyBase64URL = vapidPublicKeyBase64URL
        let hostName = hostName
        Task {
            await runtime.registerSink(deviceID: deviceID, sinkID: sinkID, sink: sink)
            var helloAckPayload: [String: JSONValue] = [
                "device_id": .string(deviceID),
                "auth": .string("static_token"),
                "host_name": .string(hostName),
                "sig": .null,
                "features": .array(RemoteWireFeatures.all.map(JSONValue.string))
            ]
            if let vapidPublicKeyBase64URL {
                helloAckPayload["vapid_public_key"] = .string(vapidPublicKeyBase64URL)
            }
            await sink.send(.helloAck(payload: .object(helloAckPayload)))
        }
    }

    /// Ticket-authenticated frames are rejected before translation on any device
    /// signature, counter, revocation, or scope failure. Signature-integrity failures
    /// terminate the connection; scope denials reject only the frame.
    private func handleEnforcedFrame(
        rawData: Data,
        frame: RemoteClientFrame,
        deviceID: String,
        sink: GatewayWebSocketFrameSink,
        context: ChannelHandlerContext
    ) {
        guard let authenticator else {
            sendAndClose(
                .commandError(requestID: frame.requestID, code: "ticket_auth_unavailable", message: "Ticket authentication is not available."),
                context: context
            )
            return
        }
        let loop = context.eventLoop
        let channel = context.channel
        let runtime = runtime
        let sinkID = sinkID
        enqueueFrameProcessing { [weak self] in
            guard let self else { return }
            let device: DeviceAuthenticator.AuthenticatedDevice
            do {
                device = try await authenticator.verifyFrame(rawFrame: rawData, frame: frame, connectionID: sinkID)
            } catch let error as DeviceAuthenticationError {
                self.audit(deviceID: deviceID, frame: frame, outcome: "denied", code: error.code)
                loop.execute { self.state = .closing }
                await sink.send(.commandError(
                    requestID: frame.requestID,
                    sessionID: frame.sessionID,
                    code: error.code,
                    message: error.description
                ))
                if case .deviceRevoked = error {
                    await sink.send(RemoteServerFrame(
                        type: "channel_closing",
                        payload: .object([
                            "reason": .string(error.code),
                            "message": .string(error.description)
                        ])
                    ))
                }
                channel.close(promise: nil)
                return
            } catch {
                audit(deviceID: deviceID, frame: frame, outcome: "denied", code: "frame_verification_failed")
                loop.execute { self.state = .closing }
                await sink.send(.commandError(
                    requestID: frame.requestID,
                    sessionID: frame.sessionID,
                    code: "frame_verification_failed",
                    message: String(describing: error)
                ))
                channel.close(promise: nil)
                return
            }

            switch ScopeEnforcer.decision(frameType: frame.type, grantedScopes: device.scopes) {
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
                    message: "Remote frame type '\(frame.type)' is not supported."
                ))
                return
            }

            if let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink) {
                await sink.send(response)
                await runtime.didQueueResponse(
                    for: frame,
                    response: response,
                    deviceID: deviceID,
                    sinkID: sinkID
                )
            }
        }
    }

    /// Chains async frame work so verification happens strictly in arrival order.
    private func enqueueFrameProcessing(_ operation: @escaping @Sendable () async -> Void) {
        let previous = frameProcessingTask
        frameProcessingTask = Task {
            await previous?.value
            await operation()
        }
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

    private func sendAndClose(_ frame: RemoteServerFrame, context: ChannelHandlerContext) {
        sendAndMaybeClose(frame, close: true, context: context)
    }

    private func sendAndMaybeClose(_ frame: RemoteServerFrame, close: Bool, context: ChannelHandlerContext) {
        guard let data = try? RemoteWireProtocol.encodeServerFrame(frame) else {
            if close {
                context.close(promise: nil)
            }
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let wsFrame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(wsFrame)).whenComplete { _ in
            if close {
                context.close(promise: nil)
            }
        }
    }
}

private final class GatewayWebSocketFrameSink: RemoteFrameSink, @unchecked Sendable {
    private static let maximumQueuedFrames = 128

    private let channel: Channel
    private let lock = NSLock()
    private var pendingFrameCount = 0

    init(channel: Channel) {
        self.channel = channel
    }

    func send(_ frame: RemoteServerFrame) async {
        guard channel.isActive else { return }
        guard let data = try? RemoteWireProtocol.encodeServerFrame(frame) else { return }

        guard reserveOutboundSlot(for: frame) else { return }

        channel.eventLoop.execute { [weak self, channel] in
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let wsFrame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(wsFrame).whenComplete { _ in
                self?.decrementPendingFrameCount()
            }
        }
    }

    func close() async {
        guard channel.isActive else { return }
        channel.eventLoop.execute { [channel] in
            channel.close(promise: nil)
        }
    }

    private func reserveOutboundSlot(for frame: RemoteServerFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pendingFrameCount >= Self.maximumQueuedFrames, frame.type == "session_update" {
            return false
        }
        pendingFrameCount += 1
        return true
    }

    private func decrementPendingFrameCount() {
        lock.lock()
        pendingFrameCount = max(0, pendingFrameCount - 1)
        lock.unlock()
    }
}
