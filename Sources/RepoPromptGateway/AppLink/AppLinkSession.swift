import Darwin
import Foundation
import Logging
import MCP
import RepoPromptMCPClientKit
import RepoPromptShared

public typealias MCPToolResult = CallTool.Result

enum AppLinkState: Equatable {
    case disconnected(reason: String)
    case connected
    case reconnecting(attempt: Int, reason: String)
    case reconnected
    /// The app link could not be re-established within the configured reconnect budget.
    case failed(reason: String)
    /// M6.3: the app announced an imminent, graceful channel teardown
    /// (`repoprompt/control/channel_closing`) before dropping the transport.
    case closing(reason: String, message: String?)
}

/// MCP notification wrapper for the app's pre-shutdown channel-closing announcement.
/// Uses `RepoPromptChannelClosingParams` from shared `MCPControlMessages`.
struct AppChannelClosingNotification: MCP.Notification {
    typealias Parameters = RepoPromptChannelClosingParams
    static let name: String = RepoPromptControlMethod.channelClosing
}

/// Sanitized category of a tool-call failure whose provenance the pinned MCP SDK does not
/// preserve. The first three are SDK `MCPError` cases that both local client/transport paths and
/// wire-decoded server responses (codes -32603/-32000/-32001) produce; `unclassified` is any other
/// non-`AppLinkError`, non-`MCPError` throw (for example the SDK's response-decoding failure).
/// The case names are not provenance: none proves an outage or an authoritative app statement.
enum AppLinkUncertainFailureKind: String, Equatable, CaseIterable {
    case internalError
    case connectionClosed
    case transportError
    case unclassified
}

enum AppLinkError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case socketCreationFailed(errno: Int32)
    case descriptorConfigurationFailed(Int32)
    case pathTooLong(String)
    case connectFailed(errno: Int32)
    case handshakeEncodingFailed
    case handshakeTimeout
    case handshakeRejected(errorCode: String?, reason: String?)
    case invalidHandshakeResponse(String)
    case toolCallTimedOut(TimeInterval)
    case appLinkLost(String)
    /// The app answered the tool call with a JSON-RPC error response whose code no local
    /// client or transport path produces. It proves a response was received, not that the link
    /// stays healthy afterward, and not whether the call executed. Carries only the JSON-RPC
    /// code; the app's error message is deliberately not retained.
    case authoritativeToolFailure(code: Int)
    /// The SDK threw an error whose provenance cannot be distinguished between a local
    /// client/transport failure and an authoritative (rejected or malformed) app response.
    /// Carries only the sanitized kind; no SDK message, response body, or underlying error.
    case uncertainToolFailure(kind: AppLinkUncertainFailureKind)

    var description: String {
        switch self {
        case .notConnected:
            "App link is not connected"
        case let .socketCreationFailed(errno):
            "Could not create bootstrap socket (errno \(errno))"
        case let .descriptorConfigurationFailed(errno):
            "Could not configure bootstrap socket descriptor (errno \(errno))"
        case let .pathTooLong(path):
            "Bootstrap socket path is too long: \(path)"
        case let .connectFailed(errno):
            "Could not connect to bootstrap socket (errno \(errno))"
        case .handshakeEncodingFailed:
            "Could not encode bootstrap handshake"
        case .handshakeTimeout:
            "Timed out waiting for bootstrap handshake response"
        case let .handshakeRejected(errorCode, reason):
            "Bootstrap handshake rejected (\(errorCode ?? "unknown")): \(reason ?? "unknown")"
        case let .invalidHandshakeResponse(type):
            "Invalid bootstrap handshake response: \(type)"
        case let .toolCallTimedOut(timeout):
            "MCP tool call timed out after \(timeout)s"
        case let .appLinkLost(reason):
            "App link was lost during tool call: \(reason)"
        case let .authoritativeToolFailure(code):
            "App rejected the tool call (JSON-RPC error \(code))"
        case let .uncertainToolFailure(kind):
            "App link tool call failed with indistinguishable provenance (\(kind.rawValue))"
        }
    }

    /// Classifies an error thrown by the MCP client for one tool call. Grounded in the pinned
    /// swift-sdk: a server JSON-RPC error response resumes the request with the wire-decoded
    /// `MCPError` (`Client.handleResponse`), while local client/transport failures surface as
    /// `.connectionClosed`, `.transportError`, or `.internalError("Client connection not
    /// initialized")`. Wire codes -32000/-32001/-32603 decode to those same cases, so only the
    /// remaining cases are provably server-originated; the overlapping ones are uncertain.
    static func authoritativeResponseCode(for error: Error) -> Int? {
        guard let mcpError = error as? MCPError else { return nil }
        switch mcpError {
        case .parseError, .invalidRequest, .methodNotFound, .invalidParams,
             .serverError, .urlElicitationRequired:
            return mcpError.code
        case .internalError, .connectionClosed, .transportError:
            return nil
        }
    }

    /// Sanitized uncertainty for a non-cancellation, non-`AppLinkError` throw that
    /// `authoritativeResponseCode(for:)` did not classify.
    static func uncertainFailureKind(for error: Error) -> AppLinkUncertainFailureKind {
        switch error as? MCPError {
        case .internalError: .internalError
        case .connectionClosed: .connectionClosed
        case .transportError: .transportError
        default: .unclassified
        }
    }
}

protocol AppLinkConnection: Sendable {
    func callTool(
        name: String,
        arguments: [String: Value],
        timeout: TimeInterval?
    ) async throws -> MCPToolResult
    func disconnect() async
}

protocol AppLinkConnecting: Sendable {
    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger: Logger
    ) async throws -> any AppLinkConnection

    /// M6.3 variant: registers `onChannelClosing` for the app's graceful
    /// `channel_closing` control notification. Defaulted so existing connectors
    /// and test doubles that do not surface the notification keep conforming.
    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger: Logger,
        onChannelClosing: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection
}

/// Derives the app-side bootstrap session token used by each gateway app link.
/// Stable per (gateway launch, link identity) and distinct across links: same-link
/// reconnects keep their token so the app's stale-predecessor replacement still
/// applies within that link. Device links use the accepted 8-character device
/// prefix, so two full device IDs with the same prefix intentionally collide here.
enum AppLinkSessionToken {
    static func derive(bootstrapToken: String, clientName: String) -> String {
        "\(bootstrapToken):\(clientName)"
    }
}

extension AppLinkConnecting {
    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger: Logger,
        onChannelClosing _: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection {
        try await connect(configuration: configuration, clientName: clientName, logger: logger)
    }
}

actor AppLinkSession {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let defaultInitialReconnectBackoff: TimeInterval = 0.25
    private static let defaultMaximumReconnectBackoff: TimeInterval = 5

    private let configuration: GatewayConfiguration
    nonisolated let clientName: String
    private let connector: any AppLinkConnecting
    private let logger: Logger
    private let sleep: Sleep
    private let initialReconnectBackoff: TimeInterval
    private let maximumReconnectBackoff: TimeInterval
    private let maximumReconnectAttempts: Int?
    private nonisolated let eventHub = AppLinkStateEventHub()

    /// Fixed `.appLinkLost` reason for a call that completed on a connection that had since been
    /// replaced or shut down: its result or failure is stale transport (in doubt) and is never
    /// published.
    static let supersededConnectionReason = "connection superseded"

    private var connection: (any AppLinkConnection)?
    /// Advanced whenever `connection` is installed, cleared, or shut down. A tool call captures
    /// it with the connection so a late completion from a superseded incarnation is rejected
    /// and can never clear or report against a newer healthy connection.
    private var connectionGeneration: UInt64 = 0
    private var reconnectTask: Task<Void, Never>?
    private var hasConnectedOnce = false
    private var shutdownRequested = false
    private var lastState: AppLinkState = .disconnected(reason: "not_started")

    nonisolated var stateEvents: AsyncStream<AppLinkState> {
        eventHub.stream()
    }

    func currentState() -> AppLinkState {
        lastState
    }

    init(
        config: GatewayConfiguration,
        clientName: String = "repoprompt-gateway",
        connector: any AppLinkConnecting = GatewayBootstrapMCPConnector(),
        logger: Logger = Logger(label: "com.repoprompt.gateway.applink"),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        initialReconnectBackoff: TimeInterval = AppLinkSession.defaultInitialReconnectBackoff,
        maximumReconnectBackoff: TimeInterval = AppLinkSession.defaultMaximumReconnectBackoff,
        maximumReconnectAttempts: Int? = nil
    ) {
        configuration = config
        self.clientName = clientName
        self.connector = connector
        self.logger = logger
        self.sleep = sleep
        self.initialReconnectBackoff = max(0.001, initialReconnectBackoff)
        self.maximumReconnectBackoff = max(self.initialReconnectBackoff, maximumReconnectBackoff)
        self.maximumReconnectAttempts = maximumReconnectAttempts.map { max(1, $0) }
    }

    func start() {
        guard reconnectTask == nil, !shutdownRequested else { return }
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func connect() async throws {
        let newConnection = try await connector.connect(
            configuration: configuration,
            clientName: clientName,
            logger: logger,
            onChannelClosing: { [weak self] params in
                await self?.handleChannelClosing(params)
            }
        )
        guard !shutdownRequested else {
            await newConnection.disconnect()
            throw CancellationError()
        }
        // Supersede the predecessor before awaiting its teardown, so its in-flight calls
        // failing during disconnect observe a stale generation.
        let predecessor = connection
        connectionGeneration &+= 1
        connection = newConnection
        await predecessor?.disconnect()
        if hasConnectedOnce {
            emit(.reconnected)
        } else {
            hasConnectedOnce = true
            emit(.connected)
        }
    }

    func callTool(
        name: String,
        arguments: [String: Value] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> MCPToolResult {
        guard let connection else {
            if !shutdownRequested {
                if case .failed = lastState {
                    // Reconnect budget has been exhausted; leave recovery to a fresh
                    // channel admission instead of silently resetting the budget here.
                } else {
                    start()
                }
            }
            throw AppLinkError.notConnected
        }
        // Every gateway consumer needs machine-parseable tool results. Without
        // `_rawJSON` the app renders results through its human-readable formatter
        // (```json fenced markdown), which RemoteMCPToolResultCodec cannot parse —
        // trust sync then never completes and remote connects fail with
        // `trust_unavailable`. Injected centrally so no call site can forget;
        // callers may still override explicitly.
        var arguments = arguments
        if arguments["_rawJSON"] == nil {
            arguments["_rawJSON"] = .bool(true)
        }
        let callGeneration = connectionGeneration
        let result: MCPToolResult
        do {
            result = try await connection.callTool(
                name: name,
                arguments: arguments,
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard callGeneration == connectionGeneration else {
                throw AppLinkError.appLinkLost(Self.supersededConnectionReason)
            }
            if let code = AppLinkError.authoritativeResponseCode(for: error) {
                // A JSON-RPC response arrived; do not clear or reconnect solely because of it.
                throw AppLinkError.authoritativeToolFailure(code: code)
            }
            if let error = error as? AppLinkError {
                switch error {
                case .toolCallTimedOut, .authoritativeToolFailure:
                    throw error
                case .uncertainToolFailure, .notConnected, .socketCreationFailed,
                     .descriptorConfigurationFailed, .pathTooLong, .connectFailed,
                     .handshakeEncodingFailed, .handshakeTimeout, .handshakeRejected,
                     .invalidHandshakeResponse, .appLinkLost:
                    throw recoverFromCurrentConnectionFailure(error)
                }
            }
            // Overlapping SDK cases and unknown throws (including response-decoding failures)
            // are uncertain, never a known outage; the captured connection still recovers.
            throw recoverFromCurrentConnectionFailure(
                .uncertainToolFailure(kind: AppLinkError.uncertainFailureKind(for: error))
            )
        }
        guard callGeneration == connectionGeneration else {
            throw AppLinkError.appLinkLost(Self.supersededConnectionReason)
        }
        return result
    }

    private func clearConnection() {
        connection = nil
        connectionGeneration &+= 1
    }

    /// Existing current-connection recovery: clear the captured connection and, unless shutting
    /// down, report the disconnect with the sanitized description and restart the reconnect loop.
    private func recoverFromCurrentConnectionFailure(_ error: AppLinkError) -> AppLinkError {
        clearConnection()
        guard !shutdownRequested else { return error }
        emit(.disconnected(reason: String(describing: error)))
        start()
        return error
    }

    func shutdown() async {
        shutdownRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if let connection {
            clearConnection()
            await connection.disconnect()
        }
        emit(.disconnected(reason: "shutdown"))
    }

    private func runReconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled, !shutdownRequested {
            do {
                try await connect()
                reconnectTask = nil
                return
            } catch {
                if shutdownRequested { break }
                attempt += 1
                let reason = String(describing: error)
                logger.warning("App link connect attempt \(attempt) failed: \(reason)")
                if let maximumReconnectAttempts, attempt >= maximumReconnectAttempts {
                    emit(.failed(reason: reason))
                    break
                }
                emit(.reconnecting(attempt: attempt, reason: reason))
                do {
                    try await sleep(backoffDuration(forAttempt: attempt))
                } catch {
                    break
                }
            }
        }
        reconnectTask = nil
    }

    private func backoffDuration(forAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 8)
        let seconds = min(maximumReconnectBackoff, initialReconnectBackoff * pow(2, Double(exponent)))
        return .milliseconds(Int64((seconds * 1000).rounded(.up)))
    }

    private func emit(_ state: AppLinkState) {
        lastState = state
        eventHub.emit(state)
    }

    /// M6.3: the app announced a graceful channel teardown. Emit `.closing` so
    /// observers (SessionWatchManager) can forward `channel_closing` to remote
    /// clients before the transport drop arrives. Connection teardown itself is
    /// left to the app; the existing disconnect/reconnect paths handle it.
    private func handleChannelClosing(_ params: RepoPromptChannelClosingParams) {
        logger.info("App link channel closing: \(params.reason.rawValue)")
        emit(.closing(reason: params.reason.rawValue, message: params.message))
    }
}

struct GatewayBootstrapMCPConnector: AppLinkConnecting {
    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger: Logger
    ) async throws -> any AppLinkConnection {
        try await connect(
            configuration: configuration,
            clientName: clientName,
            logger: logger,
            onChannelClosing: { _ in }
        )
    }

    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger: Logger,
        onChannelClosing: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection {
        let connectedFD = try await BootstrapHandshake.connectAndHandshake(
            socketURL: configuration.bootstrapSocketURL,
            sessionToken: AppLinkSessionToken.derive(
                bootstrapToken: configuration.bootstrapToken,
                clientName: clientName
            ),
            clientName: clientName,
            gatewayCredential: configuration.appLegCredential,
            logger: logger
        )

        let transport = try BootstrapSocketMCPTransport(connectedFD: connectedFD, logger: logger)
        let client = Client(name: clientName, version: "1.0")
        do {
            await client.onNotification(AppChannelClosingNotification.self) { message in
                await onChannelClosing(message.params)
            }
            _ = try await client.connect(transport: transport)
            return GatewayMCPAppConnection(client: client, transport: transport)
        } catch {
            await client.disconnect()
            await transport.disconnect()
            throw error
        }
    }
}

/// Internal (not private) only so a socketpair fixture can drive the pinned SDK decode path.
actor GatewayMCPAppConnection: AppLinkConnection {
    private let client: Client
    private let transport: BootstrapSocketMCPTransport

    init(client: Client, transport: BootstrapSocketMCPTransport) {
        self.client = client
        self.transport = transport
    }

    func callTool(
        name: String,
        arguments: [String: Value],
        timeout: TimeInterval?
    ) async throws -> MCPToolResult {
        let request = CallTool.request(.init(
            name: name,
            arguments: arguments.isEmpty ? nil : arguments
        ))
        let context = try await client.send(request)
        if let timeout {
            return try await withTimeout(seconds: timeout) {
                try await context.value
            }
        }
        return try await context.value
    }

    func disconnect() async {
        await client.disconnect()
        await transport.disconnect()
    }
}

private enum BootstrapHandshake {
    static func connectAndHandshake(
        socketURL: URL,
        sessionToken: String,
        clientName: String,
        gatewayCredential: String?,
        logger: Logger
    ) async throws -> Int32 {
        let fd = try connect(socketURL: socketURL)
        var shouldCloseFD = true
        defer {
            if shouldCloseFD {
                POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
                Darwin.close(fd)
            }
        }

        try writeHandshake(
            fd: fd,
            sessionToken: sessionToken,
            clientName: clientName,
            gatewayCredential: gatewayCredential
        )
        let response = try await readHandshakeResponse(
            fd: fd,
            timeout: MCPBootstrapTiming.initialResponseTimeout
        )

        switch response.type {
        case "accepted":
            shouldCloseFD = false
            logger.debug("Gateway bootstrap handshake accepted")
            return fd
        case "rejected":
            throw AppLinkError.handshakeRejected(
                errorCode: response.errorCode,
                reason: response.reason
            )
        default:
            throw AppLinkError.invalidHandshakeResponse(response.type)
        }
    }

    private static func connect(socketURL: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppLinkError.socketCreationFailed(errno: errno)
        }
        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch let error as POSIXDescriptorConfigurationError {
            Darwin.close(fd)
            throw AppLinkError.descriptorConfigurationFailed(error.errnoValue)
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw AppLinkError.pathTooLong(path)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            path.withCString { cString in
                _ = strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), cString)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPointer in
            addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, addrLen)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw AppLinkError.connectFailed(errno: code)
        }
        return fd
    }

    private static func writeHandshake(
        fd: Int32,
        sessionToken: String,
        clientName: String,
        gatewayCredential: String?
    ) throws {
        let request = MCPBootstrapRequest(
            sessionToken: sessionToken,
            clientPid: Int(getpid()),
            clientName: clientName,
            protocolVersion: MCPBootstrapProtocol.currentVersion,
            gatewayCredential: gatewayCredential
        )
        guard var payload = try? JSONEncoder().encode(request) else {
            throw AppLinkError.handshakeEncodingFailed
        }
        payload.append(UInt8(ascii: "\n"))
        try writeAll(payload, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < data.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: totalWritten),
                    data.count - totalWritten
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AppLinkError.connectFailed(errno: errno)
                }
                totalWritten += written
            }
        }
    }

    private static func readHandshakeResponse(fd: Int32, timeout: TimeInterval) async throws -> MCPBootstrapResponse {
        var buffer = Data()
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuffer.deallocate() }
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try Task.checkCancellation()
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let pollResult = poll(&pfd, 1, min(100, remaining))
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw AppLinkError.connectFailed(errno: errno)
            }
            if pollResult == 0 { continue }
            if pfd.revents & Int16(POLLIN) != 0 {
                let bytesRead = Darwin.read(fd, readBuffer, 4096)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw AppLinkError.connectFailed(errno: errno)
                }
                if bytesRead == 0 {
                    break
                }
                buffer.append(readBuffer, count: bytesRead)
                if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[..<newlineIndex]
                    return try JSONDecoder().decode(MCPBootstrapResponse.self, from: Data(line))
                }
            }
        }
        throw AppLinkError.handshakeTimeout
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
            throw AppLinkError.toolCallTimedOut(seconds)
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

private final class AppLinkStateEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppLinkState>.Continuation] = [:]

    func stream() -> AsyncStream<AppLinkState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func emit(_ state: AppLinkState) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(state)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
