import Darwin
import Darwin.POSIX.fcntl
import Foundation
import OSLog
import RepoPromptPlatform
import RepoPromptShared

package enum CodexJSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    func toAny() -> Any {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value
        case let .bool(value):
            value
        case let .object(value):
            value.mapValues { $0.toAny() }
        case let .array(value):
            value.map { $0.toAny() }
        case .null:
            NSNull()
        }
    }

    package static func from(_ value: Any) -> CodexJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dict as [String: Any]:
            var output: [String: CodexJSONValue] = [:]
            for (key, value) in dict {
                if let converted = CodexJSONValue.from(value) {
                    output[key] = converted
                }
            }
            return .object(output)
        case let array as [Any]:
            let converted = array.compactMap { CodexJSONValue.from($0) }
            return .array(converted)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

package enum CodexAppServerRequestID: Hashable {
    case int(Int)
    case string(String)

    init?(raw: Any) {
        if let value = raw as? Int {
            self = .int(value)
            return
        }
        if let value = raw as? NSNumber {
            self = .int(value.intValue)
            return
        }
        if let value = raw as? String {
            self = .string(value)
            return
        }
        return nil
    }

    var jsonValue: Any {
        switch self {
        case let .int(value): value
        case let .string(value): value
        }
    }

    package var displayValue: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}

/// R6: the immutable identity of one runtime-initiated request: the client instance and transport
/// generation it arrived on, plus its wire ID. Registered replies are routed by receipt, never by the
/// wire ID alone, because a replacement transport can issue its own request with the same ID.
package struct CodexServerRequestReceipt: Hashable {
    package let clientInstanceID: UUID
    package let transportGeneration: UInt64
    package let id: CodexAppServerRequestID
}

package actor CodexAppServerClient {
    package struct RequestFailure: Equatable {
        let method: String
        let code: Int?
        let message: String
        let data: CodexJSONValue?

        var userFacingMessage: String {
            guard ["initialize", "thread/resume"].contains(method),
                  code == -32601 || code == -32602
            else {
                return message
            }
            return "\(message) Update the installed Codex CLI and try again; it rejected RepoPrompt's required \(method) request shape."
        }
    }

    struct RemoteReasoningEffort: Hashable {
        let reasoningEffort: String
        let description: String
    }

    struct RemoteServiceTier: Hashable {
        let id: String
        let name: String
        let description: String
    }

    package struct RemoteModel: Hashable {
        let id: String
        let model: String
        let displayName: String
        let description: String
        let isDefault: Bool
        let supportedReasoningEfforts: [RemoteReasoningEffort]
        let defaultReasoningEffort: String?
        let additionalSpeedTiers: [String]
        let serviceTiers: [RemoteServiceTier]
        let defaultServiceTier: String?
        let hasSupportedReasoningEffortsEvidence: Bool
        let hasAdditionalSpeedTiersEvidence: Bool
        let hasServiceTiersEvidence: Bool

        init(
            id: String,
            model: String,
            displayName: String,
            description: String,
            isDefault: Bool,
            supportedReasoningEfforts: [RemoteReasoningEffort] = [],
            defaultReasoningEffort: String? = nil,
            additionalSpeedTiers: [String] = [],
            serviceTiers: [RemoteServiceTier] = [],
            defaultServiceTier: String? = nil,
            hasSupportedReasoningEffortsEvidence: Bool = true,
            hasAdditionalSpeedTiersEvidence: Bool = true,
            hasServiceTiersEvidence: Bool = true
        ) {
            self.id = id
            self.model = model
            self.displayName = displayName
            self.description = description
            self.isDefault = isDefault
            self.supportedReasoningEfforts = supportedReasoningEfforts
            self.defaultReasoningEffort = defaultReasoningEffort
            self.additionalSpeedTiers = additionalSpeedTiers
            self.serviceTiers = serviceTiers
            self.defaultServiceTier = defaultServiceTier
            self.hasSupportedReasoningEffortsEvidence = hasSupportedReasoningEffortsEvidence
            self.hasAdditionalSpeedTiersEvidence = hasAdditionalSpeedTiersEvidence
            self.hasServiceTiersEvidence = hasServiceTiersEvidence
        }
    }

    struct ServerRequest {
        let id: CodexAppServerRequestID
        let method: String
        let params: [String: CodexJSONValue]
        /// R6: the receipt replies must present (`nil` only for fixtures built without a client).
        let receipt: CodexServerRequestReceipt?

        init(
            id: CodexAppServerRequestID,
            method: String,
            params: [String: CodexJSONValue],
            receipt: CodexServerRequestReceipt? = nil
        ) {
            self.id = id
            self.method = method
            self.params = params
            self.receipt = receipt
        }
    }

    struct Config {
        /// Ceiling for accepting and decoding one inbound JSON-RPC frame from Codex app-server stdout.
        ///
        /// This bounds which messages are accepted and decoded, not process memory: an oversized
        /// completed line is allocated before rejection, and an accepted frame's decode graph can be
        /// several times its text size. Frames above the ceiling terminate the transport generation
        /// with `ClientError.inboundFrameTooLarge` instead of being dropped silently.
        static let maxInboundFrameBytes = 32 * 1024 * 1024

        let commandName: String
        let additionalPathHints: [String]
        let enableDebugLogging: Bool
        let requestTimeout: TimeInterval?
        /// Working directory for the Codex app-server process.
        /// When nil, falls back to temp directory via CLIProcessConfiguration default.
        let workingDirectory: String?
        let processFeaturePolicy: CodexOverrides.FeaturePolicy
        /// Process-level `model_reasoning_summary` override for app-server launch.
        /// Nil preserves Codex CLI process defaults; pass a value only for an intentional process override.
        /// Agent Mode should prefer per-thread config instead of process launch config.
        let processModelReasoningSummary: CodexOverrides.ReasoningSummary?

        init(
            commandName: String = CLILaunchProfiles.codex.commandName,
            additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
            enableDebugLogging: Bool = false,
            requestTimeout: TimeInterval? = nil,
            workingDirectory: String? = nil,
            processFeaturePolicy: CodexOverrides.FeaturePolicy = .defaultDisabled,
            processModelReasoningSummary: CodexOverrides.ReasoningSummary? = nil
        ) {
            self.commandName = commandName
            self.additionalPathHints = additionalPathHints
            self.enableDebugLogging = enableDebugLogging
            self.requestTimeout = requestTimeout
            self.workingDirectory = workingDirectory
            self.processFeaturePolicy = processFeaturePolicy
            self.processModelReasoningSummary = processModelReasoningSummary
        }
    }

    package struct Notification {
        let method: String
        let params: [String: CodexJSONValue]

        package init(
            method: String,
            params: [String: CodexJSONValue]
        ) {
            self.method = method
            self.params = params
        }
    }

    enum ClientError: Error, LocalizedError {
        case processNotRunning
        case invalidResponse
        case jsonDecodeFailed
        case requestFailed(RequestFailure)
        case executableUnavailable(String)
        case transportWriteFailed(message: String, errno: Int32?)
        case transportReadSetupFailed(message: String, errno: Int32?)
        /// An inbound stdout frame exceeded the transport's frame ceiling. `observedBytes` is the
        /// size seen when the violation was detected; for an unfinished frame it is a lower bound.
        case inboundFrameTooLarge(observedBytes: Int, limitBytes: Int)

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                "Codex app-server process is not running."
            case .invalidResponse:
                "Codex app-server returned an invalid response."
            case .jsonDecodeFailed:
                "Failed to decode Codex app-server JSON response."
            case let .requestFailed(failure):
                failure.userFacingMessage
            case let .executableUnavailable(message):
                message
            case let .transportWriteFailed(message, _):
                message
            case let .transportReadSetupFailed(message, _):
                message
            case let .inboundFrameTooLarge(observedBytes, limitBytes):
                "Codex app-server sent a message of at least \(observedBytes) bytes, above the \(limitBytes)-byte inbound frame limit; the app-server connection was closed."
            }
        }
    }

    enum TransportTerminationReason: Equatable {
        case stdinWrite(method: String?, errno: Int32?)
        case stdoutEOF
        case timeout(method: String, requestID: String)
        case explicitStop
        case livenessCheckFailed(method: String?)
        case decodeRecoveryBudgetExceeded(generation: UInt64)
        case readSourceSetupFailed(stream: String, errno: Int32?)
        case inboundFrameLimitExceeded(observedBytes: Int, limitBytes: Int, generation: UInt64)
    }

    struct ExpectedAgentPIDRegistration: Equatable {
        let clientName: String
        let runID: UUID
    }

    package struct ExpectedAgentPIDRegistrar {
        let register: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
        let clear: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void

        static func mcpHost(_ mcpHost: any AgentMCPHosting) -> ExpectedAgentPIDRegistrar {
            ExpectedAgentPIDRegistrar(
                register: { pid, clientName, runID in
                    await mcpHost.registerExpectedAgentPID(
                        pid,
                        for: clientName,
                        runID: runID,
                        expectedProcessExecutablePath: nil,
                        expectedProcessExecutableIdentity: nil
                    )
                },
                clear: { pid, clientName, runID in
                    await mcpHost.clearExpectedAgentPID(pid, for: clientName, runID: runID)
                }
            )
        }
    }

    private struct RegisteredExpectedAgentPID: Equatable {
        let pid: pid_t
        let clientName: String
        let runID: UUID
    }

    private struct PendingRequestMetadata {
        let method: String
        let transportGeneration: UInt64
        let cancellationMarker: RequestCancellationMarker
    }

    /// Set synchronously by a request's cancellation handler, before the actor hop that removes the
    /// pending request. A failure that reaches the request after that point (transport teardown,
    /// timeout, write failure, or an error response) settles it as `CancellationError`, because the
    /// caller's cancellation came first. A failure that settled earlier is unaffected.
    private final class RequestCancellationMarker: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func markCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static func settlementError(_ error: Error, for metadata: PendingRequestMetadata?) -> Error {
        metadata?.cancellationMarker.isCancelled == true ? CancellationError() : error
    }

    private struct TerminatingTransport {
        let process: SpawnedProcess?
        let expectedAgentPIDToClear: RegisteredExpectedAgentPID?
        /// The exact launch owning `process` (captured; never the client's current launch).
        var runtimeLaunch: AgentRuntimeLaunch?
    }

    /// An oversized inbound frame detected while feeding stdout. Recorded from inside
    /// `LineFramer.feed` callbacks and acted on only after `feed` returns, because
    /// invalidating the transport mutates `stdoutFramer`.
    private struct InboundFrameViolation {
        let observedBytes: Int
        let limitBytes: Int
        let generation: UInt64
    }

    private static let transportLog = Logger(subsystem: "com.repoprompt.agents", category: "CodexAppServer")

    static func isInboundFrameLimitError(_ error: Error) -> Bool {
        guard let clientError = error as? ClientError,
              case .inboundFrameTooLarge = clientError
        else {
            return false
        }
        return true
    }

    static func isTimeoutError(_ error: Error) -> Bool {
        if let clientError = error as? ClientError,
           case let .requestFailed(failure) = clientError
        {
            return isTimeoutErrorMessage(failure.message)
        }

        let nsError = error as NSError
        let candidates = [
            error.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ].compactMap(\.self)
        return candidates.contains(where: isTimeoutErrorMessage)
    }

    private static func isTimeoutErrorMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("request timed out after")
            || normalized.contains("timed out after")
    }

    static func requestFailure(
        method: String,
        errorObject: [String: Any]
    ) -> RequestFailure? {
        guard let message = errorObject["message"] as? String else { return nil }
        let code: Int? = if let value = errorObject["code"] as? Int {
            value
        } else if let value = errorObject["code"] as? NSNumber {
            value.intValue
        } else {
            nil
        }
        return RequestFailure(
            method: method,
            code: code,
            message: message,
            data: errorObject["data"].flatMap(CodexJSONValue.from)
        )
    }

    /// Codex stdout framing. The shared framer checks the unfinished carry, which still holds a
    /// CR that arrived without its LF, so its line and carry ceilings sit one byte above the frame
    /// limit: an exactly-at-limit CRLF frame split between CR and LF stays acceptable. The payload
    /// ceiling itself stays exact because `handleJSONLine` rejects any completed (terminator-
    /// stripped) or flushed frame above `limitBytes`; an unfinished carry of exactly limit+1 bytes
    /// is therefore caught when its terminator, the next chunk, or EOF arrives instead of at once.
    /// No tail is retained on overflow because an oversized frame terminates the transport rather
    /// than attempting tail recovery.
    private static func makeStdoutFramer(limitBytes: Int) -> LineFramer {
        let carryCeiling = limitBytes + 1
        return LineFramer(limits: .init(
            maxLineBytes: carryCeiling,
            maxCarryBytes: carryCeiling,
            tailRetainBytes: 0
        ))
    }

    private func makeStdoutFramer() -> LineFramer {
        Self.makeStdoutFramer(limitBytes: inboundFrameLimitBytes)
    }

    /// Read-only identity of the current app-server transport. It increments each time a new
    /// process (or DEBUG test transport) is installed, so per-process capability memos can be
    /// keyed to it and re-probed after a restart.
    func currentTransportGeneration() -> UInt64 {
        transportGeneration
    }

    private static func shouldPoisonTransportOnTimeout(method: String) -> Bool {
        switch method {
        case "thread/start", "thread/resume":
            true
        default:
            false
        }
    }

    private var config = Config()
    private var process: SpawnedProcess?
    /// Runtime ownership of `process` (spec R6); `nil` while Phase 3 registration is off. The client
    /// owns the runtime; thread owners contribute conversation associations.
    private var runtimeLaunch: AgentRuntimeLaunch?
    /// Transport generation whose birth identity is committed (writes are refused otherwise).
    private var runtimeCommittedGeneration: UInt64?
    private let launchAuthority: AgentRuntimeLaunchAuthority
    /// R6: the session scope of starts and requests that carry none of their own (fixed at
    /// construction: `.sessionless` for non-agent clients; `.unavailable`, which fails closed under
    /// registration, otherwise). The client never holds a mutable "current session": thread owners
    /// pass the immutable scope their owner operation captured with each start and request.
    private let defaultRuntimeSession: AgentRuntimeSessionScope
    /// R6: distinguishes this client's request receipts from every other client's (transport
    /// generations restart at each client).
    private let clientInstanceID = UUID()
    /// Whether this client's launches are registered (fixed at construction): cleanup is then
    /// retained and joined before a successor reserves.
    package nonisolated let isRuntimeRegistrationActive: Bool
    /// R6: retained cleanup of registered terminated transports (reap report and post-reap
    /// discovery), joined by `stop()` and before the next launch reserves.
    private var pendingTransportCleanups: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
        /// Test-only suspension at R6 fence checkpoints (`ownerCaptured` right after a request
        /// captures its transport, `associated` after its association await), so fixtures can replace
        /// the transport inside a request's awaits. Never set outside tests.
        private var debugRuntimeFenceCheckpoint: (@Sendable (String) async -> Void)?
        /// Test-only replacement of process start and initialization (a fixture installs its test
        /// transport and registered launch, advancing the generation). Never set outside tests.
        private var debugStartupOverride: (@Sendable (CodexAppServerClient) async throws -> Void)?
    #endif
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestMetadata: [String: PendingRequestMetadata] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var nextRequestID: Int = 1
    private var notificationContinuations: [UUID: AsyncStream<Notification>.Continuation] = [:]
    private var serverRequestContinuations: [UUID: AsyncStream<ServerRequest>.Continuation] = [:]
    /// The transport each pending runtime-initiated request arrived on, keyed by its immutable
    /// receipt (reply routing, R6; registered transports only).
    private var inboundServerRequestOwners: [CodexServerRequestReceipt: RuntimeWriteOwner] = [:]
    private var isInitialized = false
    /// Inbound frame ceiling for this client; `Config.maxInboundFrameBytes` outside DEBUG test overrides.
    private var inboundFrameLimitBytes = Config.maxInboundFrameBytes
    private var stdoutFramer = CodexAppServerClient.makeStdoutFramer(limitBytes: Config.maxInboundFrameBytes)
    private var pendingInboundFrameViolation: InboundFrameViolation?
    private var didTerminateTransport = false
    private var lastTransportTerminationReason: TransportTerminationReason?
    /// Per-transport decode-recovery attempts, used to cap CPU spent on malformed lines.
    private var decodeRecoveryAttemptsByGeneration: [UInt64: Int] = [:]
    /// Monotonic counter incremented each time a new process is started.
    /// Captured by consumer tasks and stdin-failure teardown to scope teardown
    /// to the correct transport instance — prevents a stale task from killing a
    /// newly started process.
    private var transportGeneration: UInt64 = 0
    private var startupTask: (id: UUID, task: Task<Void, Error>)?
    private var expectedAgentPIDRegistration: ExpectedAgentPIDRegistration?
    private var registeredExpectedAgentPID: RegisteredExpectedAgentPID?
    private static let maxDecodeRecoveryAttemptsPerGeneration = 128
    private let writeFrameHandler: @Sendable (Int32, Data) throws -> Void
    private let livenessProbe: @Sendable (SpawnedProcess) -> Bool
    private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar

    deinit {
        emergencyTerminateTransportForDeinit()
    }

    /// `mcpHost` only builds the default PID registrar; an explicit
    /// `expectedAgentPIDRegistrar` takes precedence.
    package init(
        mcpHost: any AgentMCPHosting,
        writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { descriptor, frame in
            try FDWriteSupport.writeAll(frame, to: descriptor)
        },
        livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { process in
            CodexAppServerClient.defaultProcessAppearsAlive(process)
        },
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar? = nil,
        launchAuthority: AgentRuntimeLaunchAuthority = .production,
        defaultRuntimeSession: AgentRuntimeSessionScope = .unavailable
    ) {
        self.launchAuthority = launchAuthority
        isRuntimeRegistrationActive = launchAuthority.isRegistrationActive(family: .codexAppServer, provider: .codex)
        self.defaultRuntimeSession = defaultRuntimeSession
        self.writeFrameHandler = writeFrameHandler
        self.livenessProbe = livenessProbe
        self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar ?? .mcpHost(mcpHost)
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    func setExpectedAgentPIDRegistration(_ registration: ExpectedAgentPIDRegistration?) async {
        expectedAgentPIDRegistration = registration
        guard registration != nil else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        guard let process else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        await registerExpectedAgentPIDIfNeeded(for: process.pid)
    }

    func clearExpectedAgentPIDRegistration() async {
        expectedAgentPIDRegistration = nil
        await clearRegisteredExpectedAgentPIDIfNeeded()
    }

    private func registerExpectedAgentPIDIfNeeded(for pid: pid_t) async {
        guard let registration = expectedAgentPIDRegistration else { return }
        let target = RegisteredExpectedAgentPID(
            pid: pid,
            clientName: registration.clientName,
            runID: registration.runID
        )
        guard registeredExpectedAgentPID != target else { return }
        await clearRegisteredExpectedAgentPIDIfNeeded()
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else { return }
        registeredExpectedAgentPID = target
        await expectedAgentPIDRegistrar.register(target.pid, target.clientName, target.runID)
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else {
            if registeredExpectedAgentPID == target {
                registeredExpectedAgentPID = nil
            }
            await expectedAgentPIDRegistrar.clear(target.pid, target.clientName, target.runID)
            return
        }
    }

    private func clearRegisteredExpectedAgentPIDIfNeeded() async {
        guard let registered = takeRegisteredExpectedAgentPIDForDeferredClear() else { return }
        await expectedAgentPIDRegistrar.clear(registered.pid, registered.clientName, registered.runID)
    }

    private func takeRegisteredExpectedAgentPIDForDeferredClear() -> RegisteredExpectedAgentPID? {
        let registered = registeredExpectedAgentPID
        registeredExpectedAgentPID = nil
        return registered
    }

    /// Updates the working directory for the next process start.
    /// Must be called before `startIfNeeded()` to take effect.
    func updateWorkingDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        config = Config(
            commandName: config.commandName,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            requestTimeout: config.requestTimeout,
            workingDirectory: normalized,
            processFeaturePolicy: config.processFeaturePolicy,
            processModelReasoningSummary: config.processModelReasoningSummary
        )
    }

    func updateProcessFeaturePolicy(_ featurePolicy: CodexOverrides.FeaturePolicy) async {
        await updateProcessLaunchPolicy(
            featurePolicy: featurePolicy,
            modelReasoningSummary: config.processModelReasoningSummary
        )
    }

    func updateProcessLaunchPolicy(
        featurePolicy: CodexOverrides.FeaturePolicy,
        modelReasoningSummary: CodexOverrides.ReasoningSummary?
    ) async {
        guard featurePolicy != config.processFeaturePolicy
            || modelReasoningSummary != config.processModelReasoningSummary
        else { return }
        config = Config(
            commandName: config.commandName,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            requestTimeout: config.requestTimeout,
            workingDirectory: config.workingDirectory,
            processFeaturePolicy: featurePolicy,
            processModelReasoningSummary: modelReasoningSummary
        )
        if process != nil {
            await terminateTransport(flushStdout: true, reason: .explicitStop)
        }
    }

    package func subscribeNotifications() -> AsyncStream<Notification> {
        AsyncStream { continuation in
            let id = UUID()
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    func subscribeServerRequests() -> AsyncStream<ServerRequest> {
        AsyncStream { continuation in
            let id = UUID()
            serverRequestContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeServerRequestContinuation(id) }
            }
        }
    }

    /// Starts with the client's fixed default runtime session scope.
    package func startIfNeeded() async throws {
        try await startIfNeeded(runtimeSession: nil)
    }

    /// `runtimeSession`: the session scope the starting operation's owner captured (recorded by the
    /// launch reservation); `nil` uses the client's fixed default scope.
    package func startIfNeeded(runtimeSession: AgentRuntimeSessionScope?) async throws {
        if let existingStartupTask = startupTask?.task {
            return try await existingStartupTask.value
        }
        if let process {
            let appearsAlive = livenessProbe(process)
            if isInitialized, appearsAlive {
                return
            }
            if !appearsAlive {
                scheduleTransportCleanup(
                    invalidateTransport(
                        flushStdout: false,
                        requestFailure: .processNotRunning,
                        reason: .livenessCheckFailed(method: nil)
                    )
                )
            }
        }
        let startupID = UUID()
        let task = Task<Void, Error> {
            try await self.performStartupIfNeeded(runtimeSession: runtimeSession)
        }
        startupTask = (id: startupID, task: task)
        do {
            try await task.value
            if startupTask?.id == startupID {
                startupTask = nil
            }
        } catch {
            if startupTask?.id == startupID {
                startupTask = nil
            }
            throw error
        }
    }

    package func stop() async {
        startupTask?.task.cancel()
        startupTask = nil
        await terminateTransport(flushStdout: true, reason: .explicitStop)
        // R6: an earlier invalidation's registered cleanup (reap report and post-reap discovery)
        // also finishes before stop returns, so the caller's successor never races it.
        await joinPendingTransportCleanups()
    }

    private func joinPendingTransportCleanups() async {
        while let (id, cleanup) = pendingTransportCleanups.first {
            await cleanup.value
            pendingTransportCleanups[id] = nil
        }
    }

    private func finishPendingTransportCleanup(_ id: UUID) {
        pendingTransportCleanups[id] = nil
    }

    // MARK: - Authoritative transport termination

    /// Single, idempotent teardown path for the process transport layer.
    ///
    /// Called from `handleStdoutEOF()` (EOF detected on stdout) and `stop()` (explicit shutdown).
    /// Responsible for: flushing remaining stdout, cancelling consumer tasks, failing all
    /// pending requests, finishing all notification/serverRequest subscriber continuations,
    /// and cleaning up the process. Idempotent via `didTerminateTransport` flag.
    ///
    /// Note: `flushStdout` is best-effort; buffered channel bytes that have not yet been
    /// fed into `stdoutFramer` may still be dropped during teardown.
    ///
    /// When `expectedGeneration` is provided, the call is a no-op if the current
    /// `transportGeneration` doesn't match — this prevents a stale consumer task
    /// from tearing down a newly-started transport.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.handleStdoutEOF / shutdown (reference implementation)
    /// - FileHandleChunkChannel (FIFO chunk ordering)
    /// - CodexNativeSessionController.startNotificationStreamIfNeeded (downstream subscriber)
    private func terminateTransport(
        flushStdout: Bool,
        expectedGeneration: UInt64? = nil,
        requestFailure: ClientError = .processNotRunning,
        reason: TransportTerminationReason
    ) async {
        await finishTransportTermination(
            invalidateTransport(
                flushStdout: flushStdout,
                expectedGeneration: expectedGeneration,
                requestFailure: requestFailure,
                reason: reason
            )
        )
    }

    private func invalidateTransport(
        flushStdout: Bool,
        expectedGeneration: UInt64? = nil,
        requestFailure: ClientError,
        reason: TransportTerminationReason
    ) -> TerminatingTransport? {
        if let expected = expectedGeneration, expected != transportGeneration { return nil }
        guard !didTerminateTransport else { return nil }
        didTerminateTransport = true
        lastTransportTerminationReason = reason

        // 1. Flush remaining stdout lines before tearing down.
        if flushStdout {
            var remainingLines: [Data] = []
            stdoutFramer.flush { lineData in
                remainingLines.append(lineData)
            }
            for lineData in remainingLines {
                handleJSONLine(lineData)
            }
        }

        // 2. Tear down chunk channels and consumer tasks.
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil

        // 3. Cancel all timeout tasks and fail all pending requests.
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        let requests = pendingRequests
        let requestMetadata = pendingRequestMetadata
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        for (requestID, continuation) in requests {
            continuation.resume(throwing: Self.settlementError(requestFailure, for: requestMetadata[requestID]))
        }

        // 4. Finish all notification and serverRequest subscriber streams.
        let notifContinuations = notificationContinuations
        notificationContinuations.removeAll()
        for continuation in notifContinuations.values {
            continuation.finish()
        }

        let serverReqContinuations = serverRequestContinuations
        serverRequestContinuations.removeAll()
        inboundServerRequestOwners.removeAll()
        for continuation in serverReqContinuations.values {
            continuation.finish()
        }

        // 5. Snapshot and nil process BEFORE the await to prevent actor re-entrancy
        // issues: other calls (startIfNeeded, request, subscribe*) that interleave
        // during ProcessTermination.terminateAndReap will see process==nil and
        // correctly fail/bail out.
        let terminatingProcess = process
        let expectedAgentPIDToClear = takeRegisteredExpectedAgentPIDForDeferredClear()
        let terminatingLaunch = runtimeLaunch
        process = nil
        runtimeLaunch = nil
        runtimeCommittedGeneration = nil
        isInitialized = false

        // 6. Reset framer state for potential future restart.
        stdoutFramer = makeStdoutFramer()
        pendingInboundFrameViolation = nil
        decodeRecoveryAttemptsByGeneration.removeValue(forKey: transportGeneration)

        return TerminatingTransport(
            process: terminatingProcess,
            expectedAgentPIDToClear: expectedAgentPIDToClear,
            runtimeLaunch: terminatingLaunch
        )
    }

    private func scheduleTransportCleanup(_ terminatingTransport: TerminatingTransport?) {
        guard let terminatingTransport else { return }
        guard terminatingTransport.runtimeLaunch != nil else {
            Task {
                await self.finishTransportTermination(terminatingTransport)
            }
            return
        }
        // R6: a registered transport's cleanup is retained so stop() and the next reservation
        // join its reap report instead of racing it.
        let id = UUID()
        pendingTransportCleanups[id] = Task {
            await self.finishTransportTermination(terminatingTransport)
            await self.finishPendingTransportCleanup(id)
        }
    }

    private func emergencyTerminateTransportForDeinit() {
        startupTask?.task.cancel()
        startupTask = nil
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        let requests = pendingRequests
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: ClientError.processNotRunning)
        }
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
        for continuation in serverRequestContinuations.values {
            continuation.finish()
        }
        serverRequestContinuations.removeAll()
        let expectedAgentPIDToClear = registeredExpectedAgentPID
        registeredExpectedAgentPID = nil
        if let expectedAgentPIDToClear {
            let registrar = expectedAgentPIDRegistrar
            Task.detached {
                await registrar.clear(
                    expectedAgentPIDToClear.pid,
                    expectedAgentPIDToClear.clientName,
                    expectedAgentPIDToClear.runID
                )
            }
        }
        guard let process else { return }
        self.process = nil
        let launch = runtimeLaunch
        runtimeLaunch = nil
        runtimeCommittedGeneration = nil
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdin?.closeFile()
        let pid = process.pid
        let processGroupID = process.processGroupID
        Task.detached {
            let reaped = await ProcessTermination.terminateAndReapReportingRoot(pid: pid, processGroupID: processGroupID)
            await launch?.rootReaped(pid: pid, confirmed: reaped.rootReaped)
        }
    }

    private func finishTransportTermination(_ terminatingTransport: TerminatingTransport?) async {
        guard let terminatingTransport else { return }
        if let expectedAgentPIDToClear = terminatingTransport.expectedAgentPIDToClear {
            await expectedAgentPIDRegistrar.clear(
                expectedAgentPIDToClear.pid,
                expectedAgentPIDToClear.clientName,
                expectedAgentPIDToClear.runID
            )
        }
        guard let process = terminatingTransport.process else { return }
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdin?.closeFile()
        let pid = process.pid
        let reaped = await ProcessTermination.terminateAndReapReportingRoot(
            pid: pid,
            processGroupID: process.processGroupID,
            logger: config.enableDebugLogging ? { print("[CodexAppServer] \($0)") } : { _ in }
        )
        await terminatingTransport.runtimeLaunch?.rootReaped(pid: pid, confirmed: reaped.rootReaped)
    }

    /// The exact transport a request was issued on, captured before its first suspension: every
    /// fence step and the final synchronous write require the client to still be on this
    /// generation with this launch, so a replacement started meanwhile receives zero bytes.
    private struct RuntimeWriteOwner {
        let generation: UInt64
        let launch: AgentRuntimeLaunch?
    }

    private func isCurrent(_ owner: RuntimeWriteOwner) -> Bool {
        process != nil && transportGeneration == owner.generation && runtimeLaunch === owner.launch
    }

    /// R6 operation association on the captured transport, before any thread mutation or turn
    /// write (resumed threads: before `thread/resume`): the owner-captured session and run attempt,
    /// the thread and any permission configuration the request asks for. A conflicting writer or a
    /// missing Agent Mode session context throws.
    private func associateRuntimeConversation(
        _ threadID: String,
        session: AgentRuntimeSessionScope,
        permission: AgentRuntimePermissionSnapshot?,
        worktreePath: String?,
        launch: AgentRuntimeLaunch,
        owner: RuntimeWriteOwner
    ) async throws {
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The operation's own worktree (`cwd`), never the transport's launch directory or whichever
        // thread is current; the launch directory applies only when the operation names none.
        try await launch.associate(
            session: session,
            conversationID: trimmed,
            worktreePath: worktreePath,
            permission: permission
        )
        #if DEBUG
            if let checkpoint = debugRuntimeFenceCheckpoint { await checkpoint("associated") }
        #endif
        guard isCurrent(owner) else { throw ClientError.processNotRunning }
    }

    /// Lossless-restart Phase 4 recovery observation: associates the observed `threadID` with this
    /// client's current registered transport for the owner's session and worktree before its
    /// observational reads (registry attribution only; nothing is written to the transport). The
    /// transport must still be `expectedGeneration` with a registered launch; an unregistered,
    /// stopped or replaced transport throws, and a conflicting writer is refused by the registry.
    package func associateObservedConversation(
        _ threadID: String,
        runtimeSession: AgentRuntimeSessionScope?,
        worktreePath: String?,
        expectedGeneration: UInt64
    ) async throws {
        guard process != nil, transportGeneration == expectedGeneration, let launch = runtimeLaunch else {
            throw ClientError.processNotRunning
        }
        try await associateRuntimeConversation(
            threadID,
            session: runtimeSession ?? defaultRuntimeSession,
            permission: nil,
            worktreePath: worktreePath,
            launch: launch,
            owner: RuntimeWriteOwner(generation: expectedGeneration, launch: launch)
        )
    }

    /// R6 write fence on the captured transport: its launch is still the committed live owner and
    /// serves `threadID`.
    private func authorizeRuntimeWrite(
        threadID: String?,
        launch: AgentRuntimeLaunch,
        owner: RuntimeWriteOwner
    ) async throws {
        try await launch.authorizeWrite(conversationID: threadID)
        guard isCurrent(owner) else { throw ClientError.processNotRunning }
    }

    private static func defaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
        // Use a non-destructive child-state check so exited/zombie children do not
        // look healthy, while leaving final reap/cleanup to the normal teardown path.
        var info = siginfo_t()
        let waitResult = Darwin.waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if waitResult == 0, info.si_pid == process.pid {
            return false
        }
        if waitResult == -1, errno == ECHILD {
            return false
        }

        let pidState = Darwin.kill(process.pid, 0)
        if pidState == -1, errno == ESRCH {
            return false
        }
        guard let stdinDescriptor = process.stdinDescriptor else { return false }
        let descriptorFlags = fcntl(stdinDescriptor, F_GETFD)
        if descriptorFlags == -1, errno == EBADF {
            return false
        }
        return true
    }

    package func request(method: String, params: [String: Any]?, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        try await request(method: method, params: params, timeout: timeout, useDefaultTimeout: true)
    }

    /// `runtimeSession`: the session scope the requesting operation's owner captured, used for this
    /// request's association (a thread owner passes its own; `nil` uses the client's fixed default
    /// scope).
    package func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?,
        runtimeSession: AgentRuntimeSessionScope?
    ) async throws -> [String: Any] {
        try await request(
            method: method,
            params: params,
            timeout: timeout,
            useDefaultTimeout: true,
            runtimeSession: runtimeSession
        )
    }

    func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?,
        useDefaultTimeout: Bool,
        runtimeSession: AgentRuntimeSessionScope? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard process != nil else { throw ClientError.processNotRunning }
        // R6: capture the exact transport (generation and launch) before the first suspension.
        // Each request carries its own owner-captured session scope and the permission its own
        // params ask for; nothing is read from a session or shared across requests.
        let owner = RuntimeWriteOwner(generation: transportGeneration, launch: runtimeLaunch)
        let session = runtimeSession ?? defaultRuntimeSession
        let permission = Self.runtimePermission(fromParams: params)
        // R6: this operation's own worktree, captured with its owner before any await.
        let worktreePath = Self.runtimeWorktreePath(fromParams: params)
        #if DEBUG
            if let checkpoint = debugRuntimeFenceCheckpoint { await checkpoint("ownerCaptured") }
        #endif
        if let launch = owner.launch {
            try await fenceRuntimeRequest(
                method: method,
                params: params,
                session: session,
                permission: permission,
                worktreePath: worktreePath,
                launch: launch,
                owner: owner
            )
        }
        let result = try await sendRequest(
            method: method,
            params: params,
            timeout: timeout,
            useDefaultTimeout: useDefaultTimeout,
            owner: owner
        )
        if let launch = owner.launch, Self.runtimeThreadCreatingMethods.contains(method),
           let thread = result["thread"] as? [String: Any],
           let threadID = (thread["id"] ?? thread["threadId"]) as? String
        {
            // R6: a fresh thread is associated with the operation that created it (its session,
            // attempt and requested permission) before the caller can mutate it or start a turn.
            try await associateRuntimeConversation(
                threadID,
                session: session,
                permission: permission,
                worktreePath: worktreePath,
                launch: launch,
                owner: owner
            )
        }
        return result
    }

    /// The worktree an operation names (`cwd`), or `nil` when it names none.
    static func runtimeWorktreePath(fromParams params: [String: Any]?) -> String? {
        guard let cwd = (params?["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// The permission configuration a request asks for (`approvalPolicy`, `sandbox` or
    /// `sandboxPolicy.type`), or `nil` when it asks for none.
    static func runtimePermission(fromParams params: [String: Any]?) -> AgentRuntimePermissionSnapshot? {
        guard let params else { return nil }
        let approvalPolicy = params["approvalPolicy"] as? String
        let sandbox = params["sandbox"] as? String
            ?? (params["sandboxPolicy"] as? [String: Any])?["type"] as? String
        guard approvalPolicy != nil || sandbox != nil else { return nil }
        return .codex(approvalPolicy: approvalPolicy, sandbox: sandbox)
    }

    /// Thread-scoped reads: they name a thread but never write to it, so they authorize the
    /// transport without creating or requiring an association. Every other request that names a
    /// thread is treated as a write (deny by default).
    private static let runtimeThreadReadMethods: Set<String> = [
        "thread/read", "thread/turns/list", "thread/goal/get", "thread/list", "thread/loaded/list"
    ]
    /// Requests whose response creates a thread served by this runtime.
    private static let runtimeThreadCreatingMethods: Set<String> = ["thread/start", "thread/fork"]

    /// Turn writes that create no ownership: they only pass the write fence on a thread an owner
    /// operation already associated, so a late callback is never attributed to another run.
    private static let runtimeAuthorizeOnlyMethods: Set<String> = ["turn/interrupt"]

    /// R6 request fence on the captured transport while registration is active. Every request is
    /// authorized against its captured launch (models, auth, control and reads included):
    /// - thread creation first validates the owner's session context (before the write; the
    ///   returned thread is associated before it is returned);
    /// - `thread/resume` and every other request naming a thread (deny by default) associate the
    ///   thread for the owner's session, worktree and requested permission, then authorize it;
    /// - interrupts only authorize on an already-associated thread; thread reads and requests that
    ///   name no thread authorize the transport only.
    private func fenceRuntimeRequest(
        method: String,
        params: [String: Any]?,
        session: AgentRuntimeSessionScope,
        permission: AgentRuntimePermissionSnapshot?,
        worktreePath: String?,
        launch: AgentRuntimeLaunch,
        owner: RuntimeWriteOwner
    ) async throws {
        let threadID = (params?["threadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.runtimeThreadCreatingMethods.contains(method) {
            if case .unavailable = session { throw AgentProcessRegistryError.sessionContextUnavailable }
            try await authorizeRuntimeWrite(threadID: nil, launch: launch, owner: owner)
            return
        }
        guard let threadID, !threadID.isEmpty, !Self.runtimeThreadReadMethods.contains(method) else {
            try await authorizeRuntimeWrite(threadID: nil, launch: launch, owner: owner)
            return
        }
        if !Self.runtimeAuthorizeOnlyMethods.contains(method) {
            try await associateRuntimeConversation(
                threadID,
                session: session,
                permission: permission,
                worktreePath: worktreePath,
                launch: launch,
                owner: owner
            )
        }
        try await authorizeRuntimeWrite(threadID: threadID, launch: launch, owner: owner)
    }

    private func sendRequest(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?,
        useDefaultTimeout: Bool,
        owner: RuntimeWriteOwner
    ) async throws -> [String: Any] {
        let requestID = makeRequestID()
        let generation = transportGeneration
        let deadline = timeout ?? (useDefaultTimeout ? config.requestTimeout : nil)
        var payload: [String: Any] = [
            "method": method,
            "id": Int(requestID) ?? requestID
        ]
        if let params {
            payload["params"] = params
        }
        let cancellationMarker = RequestCancellationMarker()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = continuation
                pendingRequestMetadata[requestID] = PendingRequestMetadata(
                    method: method,
                    transportGeneration: generation,
                    cancellationMarker: cancellationMarker
                )
                if let deadline {
                    scheduleTimeout(for: requestID, after: deadline)
                }
                if Task.isCancelled {
                    cancelPendingRequestIfPresent(id: requestID)
                    return
                }
                do {
                    try sendJSONLine(payload, method: method, owner: owner)
                } catch {
                    failPendingRequestIfPresent(id: requestID, error: error)
                }
            }
        } onCancel: {
            cancellationMarker.markCancelled()
            Task { await self.cancelPendingRequestIfPresent(id: requestID) }
        }
    }

    /// A reply to a runtime-initiated request goes only to the transport that issued it, identified
    /// by the request's immutable receipt (R6: a registered transport never receives a reply meant
    /// for a replaced one, even when it issued a request with the same wire ID). The issuing launch
    /// must still authorize the write after the registry await; replies create no ownership.
    private func serverRequestReplyOwner(for receipt: CodexServerRequestReceipt) async throws -> RuntimeWriteOwner? {
        guard receipt.clientInstanceID == clientInstanceID else { throw ClientError.processNotRunning }
        let issued = inboundServerRequestOwners.removeValue(forKey: receipt)
        guard runtimeLaunch != nil || issued != nil else { return nil }
        guard let issued, receipt.transportGeneration == issued.generation, isCurrent(issued),
              let launch = issued.launch
        else { throw ClientError.processNotRunning }
        try await authorizeRuntimeWrite(threadID: nil, launch: launch, owner: issued)
        return issued
    }

    /// The reply for the request identified by `receipt`.
    func respondToServerRequest(receipt: CodexServerRequestReceipt, result: [String: Any]) async throws {
        guard process != nil else { throw ClientError.processNotRunning }
        let owner = try await serverRequestReplyOwner(for: receipt)
        let payload: [String: Any] = [
            "id": receipt.id.jsonValue,
            "result": result
        ]
        try sendJSONLine(payload, method: nil, owner: owner)
    }

    func respondToServerRequestError(
        receipt: CodexServerRequestReceipt,
        code: Int = -32601,
        message: String,
        data: [String: Any]? = nil
    ) async throws {
        guard process != nil else { throw ClientError.processNotRunning }
        let owner = try await serverRequestReplyOwner(for: receipt)
        try sendJSONLine(Self.errorReplyPayload(id: receipt.id, code: code, message: message, data: data), method: nil, owner: owner)
    }

    /// Legacy reply by wire ID alone (no receipt). Refused while the transport is registered: a
    /// wire ID cannot tell a replaced transport's request from the replacement's.
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws {
        guard process != nil else { throw ClientError.processNotRunning }
        guard runtimeLaunch == nil else { throw ClientError.processNotRunning }
        let payload: [String: Any] = [
            "id": id.jsonValue,
            "result": result
        ]
        try sendJSONLine(payload, method: nil)
    }

    /// Legacy error reply by wire ID alone; refused while the transport is registered.
    func respondToServerRequestError(
        id: CodexAppServerRequestID,
        code: Int = -32601,
        message: String,
        data: [String: Any]? = nil
    ) throws {
        guard process != nil else { throw ClientError.processNotRunning }
        guard runtimeLaunch == nil else { throw ClientError.processNotRunning }
        try sendJSONLine(Self.errorReplyPayload(id: id, code: code, message: message, data: data), method: nil)
    }

    private static func errorReplyPayload(
        id: CodexAppServerRequestID,
        code: Int,
        message: String,
        data: [String: Any]?
    ) -> [String: Any] {
        var errorObject: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let data {
            errorObject["data"] = data
        }
        return [
            "id": id.jsonValue,
            "error": errorObject
        ]
    }

    /// A notification on the current transport; a registered transport authorizes it against its
    /// captured launch first (no ownership is created).
    func notify(method: String, params: [String: Any]?) async throws {
        guard process != nil else { throw ClientError.processNotRunning }
        let owner = RuntimeWriteOwner(generation: transportGeneration, launch: runtimeLaunch)
        if let launch = owner.launch {
            try await authorizeRuntimeWrite(threadID: nil, launch: launch, owner: owner)
        }
        var payload: [String: Any] = [
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try sendJSONLine(payload, method: method, owner: owner.launch == nil ? nil : owner)
    }

    /// Returns all models exposed by Codex app-server `model/list`, following pagination.
    package func listModels(limit: Int = 100) async throws -> [RemoteModel] {
        do {
            return try await fetchModelPages(limit: limit)
        } catch let error as ClientError {
            switch error {
            case .processNotRunning, .transportWriteFailed, .transportReadSetupFailed:
                return try await fetchModelPages(limit: limit)
            default:
                throw error
            }
        } catch {
            throw error
        }
    }

    private func fetchModelPages(limit: Int) async throws -> [RemoteModel] {
        let pageLimit = max(1, limit)
        try await startIfNeeded()

        var cursor: String?
        var seenModelIDs = Set<String>()
        var models: [RemoteModel] = []

        while true {
            var params: [String: Any] = ["limit": pageLimit]
            if let cursor {
                params["cursor"] = cursor
            }

            let result = try await request(method: "model/list", params: params)
            guard let pageItems = result["data"] as? [[String: Any]] else {
                throw ClientError.invalidResponse
            }

            for entry in pageItems {
                guard let remoteModel = Self.parseRemoteModel(entry) else { continue }
                guard seenModelIDs.insert(remoteModel.id).inserted else { continue }
                models.append(remoteModel)
            }

            let nextCursor = result["nextCursor"] as? String
            guard let nextCursor, !nextCursor.isEmpty, nextCursor != cursor else {
                break
            }
            cursor = nextCursor
        }

        return models
    }

    static func parseRemoteModel(_ entry: [String: Any]) -> RemoteModel? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        let model = (entry["model"] as? String) ?? id
        let supportedReasoningEfforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
            .compactMap { effortEntry -> RemoteReasoningEffort? in
                guard let reasoningEffort = effortEntry["reasoningEffort"] as? String,
                      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return RemoteReasoningEffort(
                    reasoningEffort: reasoningEffort,
                    description: (effortEntry["description"] as? String) ?? ""
                )
            }
        let additionalSpeedTiers = (entry["additionalSpeedTiers"] as? [String] ?? [])
        let serviceTiers = (entry["serviceTiers"] as? [[String: Any]] ?? []).compactMap {
            tier -> RemoteServiceTier? in
            guard let id = tier["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return RemoteServiceTier(
                id: id,
                name: (tier["name"] as? String) ?? "",
                description: (tier["description"] as? String) ?? ""
            )
        }
        return RemoteModel(
            id: id,
            model: model,
            displayName: (entry["displayName"] as? String) ?? model,
            description: (entry["description"] as? String) ?? "",
            isDefault: entry["isDefault"] as? Bool ?? false,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: entry["defaultReasoningEffort"] as? String,
            additionalSpeedTiers: additionalSpeedTiers,
            serviceTiers: serviceTiers,
            defaultServiceTier: entry["defaultServiceTier"] as? String,
            hasSupportedReasoningEffortsEvidence: entry.keys.contains("supportedReasoningEfforts"),
            hasAdditionalSpeedTiersEvidence: entry.keys.contains("additionalSpeedTiers"),
            hasServiceTiersEvidence: entry.keys.contains("serviceTiers")
        )
    }

    private func initializeIfNeeded() async throws {
        if isInitialized {
            return
        }
        let clientInfo: [String: Any] = [
            "name": "repoprompt",
            "title": "RepoPrompt",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        ]
        let capabilities: [String: Any] = [
            "experimentalApi": true
        ]
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": clientInfo,
                "capabilities": capabilities
            ]
        )
        try await notify(method: "initialized", params: nil)
        isInitialized = true
    }

    private func performStartupIfNeeded(runtimeSession: AgentRuntimeSessionScope?) async throws {
        #if DEBUG
            if let debugStartupOverride {
                try await debugStartupOverride(self)
                return
            }
        #endif
        if process == nil {
            try await startProcess(runtimeSession: runtimeSession)
        }
        try await initializeIfNeeded()
    }

    private func startProcess(runtimeSession: AgentRuntimeSessionScope?) async throws {
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .codexAppServer,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        // Managed launch boundary: an inherited runtime marker never reaches the child.
        let environment = AgentRuntimeLaunchAuthority.strippingInheritedMarker(environmentResult.environment)
        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: config.commandName,
            environment: environment,
            additionalPathHints: config.additionalPathHints,
            logger: config.enableDebugLogging ? { print("[CodexAppServer] \($0)") } : nil
        )
        guard resolution.status == .available else {
            throw ClientError.executableUnavailable(resolution.userMessage)
        }
        let processOverrides = CodexOverrides.cliConfigArgs(
            toolPolicy: .init(
                toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
                modelReasoningSummary: config.processModelReasoningSummary
            ),
            featurePolicy: config.processFeaturePolicy
        )
        let args = processOverrides + ["app-server"]
        // R6: every transport start (models, auth, control, sessionless and thread work) reserves
        // its runtime immediately before the spawn; a refusal spawns nothing.
        // The process requests no permission configuration itself; threads request theirs.
        let launch: AgentRuntimeLaunch? = if isRuntimeRegistrationActive {
            launchAuthority.makeLaunch(AgentRuntimeLaunchContext(
                family: .codexAppServer,
                provider: .codex,
                session: runtimeSession ?? defaultRuntimeSession,
                worktreePath: config.workingDirectory,
                permission: .unavailable
            ))
        } else {
            nil
        }
        if launch != nil {
            // R6: an earlier registered transport's cleanup (reap report and post-reap discovery)
            // finishes before this launch reserves; revalidated after the await.
            await joinPendingTransportCleanups()
            try Task.checkCancellation()
            guard process == nil else { return }
        }
        let runtimeID = try await launch?.prepareSpawn()
        guard process == nil else {
            await launch?.spawnFailed()
            return
        }
        if launch != nil, Task.isCancelled {
            await launch?.spawnFailed()
            throw CancellationError()
        }
        let spawned: SpawnedProcess
        do {
            spawned = try ProcessLauncher.spawn(
                command: resolution.resolvedCommand,
                arguments: args,
                environment: environment,
                workingDirectory: config.workingDirectory,
                runtimeID: runtimeID
            )
        } catch {
            await launch?.spawnFailed()
            throw error
        }
        stdoutFramer = makeStdoutFramer()
        pendingInboundFrameViolation = nil
        didTerminateTransport = false
        transportGeneration &+= 1
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        process = spawned
        runtimeLaunch = launch
        runtimeCommittedGeneration = launch == nil ? transportGeneration : nil
        do {
            try startStdoutReader(spawned.stdout)
            try startStderrReader(spawned.stderr)
        } catch {
            let clientError = Self.transportReadSetupError(stream: "process pipe", error: error)
            let terminatingTransport = invalidateTransport(
                flushStdout: false,
                requestFailure: clientError,
                reason: .readSourceSetupFailed(stream: "process pipe", errno: Self.errnoValue(from: error))
            )
            await finishTransportTermination(terminatingTransport)
            throw clientError
        }
        if let launch {
            // R6: commit the birth identity before `initialize` (the first write).
            let generation = transportGeneration
            do {
                try await launch.commitSpawn(pid: spawned.pid, processGroupID: spawned.processGroupID)
            } catch {
                let terminatingTransport = invalidateTransport(
                    flushStdout: false,
                    expectedGeneration: generation,
                    requestFailure: .processNotRunning,
                    reason: .explicitStop
                )
                await finishTransportTermination(terminatingTransport)
                throw error
            }
            guard generation == transportGeneration, process?.pid == spawned.pid, runtimeLaunch === launch else {
                throw ClientError.processNotRunning
            }
            runtimeCommittedGeneration = generation
        }
        await registerExpectedAgentPIDIfNeeded(for: spawned.pid)
        guard process?.pid == spawned.pid, !didTerminateTransport else {
            throw ClientError.processNotRunning
        }
    }

    // SEARCH-HELPER: FIFO stdout, FileHandleChunkChannel, readabilityHandler, chunk ordering
    /// Sets up a FIFO channel + single consumer task for stdout, mirroring Claude's pattern.
    ///
    /// Using `FileHandleChunkChannel` ensures chunks are processed in the exact order
    /// delivered by the OS, avoiding the reordering that occurs when each
    /// `readabilityHandler` callback spawns an independent `Task`.
    ///
    /// Related:
    /// - FileHandleChunkChannel (FIFO ordering primitive)
    /// - ClaudeNativeProcessSessionController.startStdoutReader (reference implementation)
    private func startStdoutReader(_ handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Codex app-server stdout")
        stdoutConsumerTask?.cancel()
        stdoutConsumerTask = nil
        let channel = FileHandleChunkChannel()
        stdoutChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        let generation = transportGeneration
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk, generation: generation)
            }
            // Stream ended — could be genuine EOF or cancellation/finish from teardown.
            // Only trigger teardown on genuine EOF (not cancellation), and scope to
            // this transport generation so a stale task can't kill a new process.
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await handleStdoutEOF(generation: generation)
        }
    }

    /// Sets up a FIFO channel + single consumer task for stderr.
    private func startStderrReader(_ handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Codex app-server stderr")
        stderrConsumerTask?.cancel()
        stderrConsumerTask = nil
        let channel = FileHandleChunkChannel()
        stderrChunkChannel = channel
        let enableDebugLogging = config.enableDebugLogging
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stderrConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard self != nil else { break }
                if enableDebugLogging,
                   let line = String(data: chunk, encoding: .utf8),
                   !line.isEmpty
                {
                    print("[CodexAppServer][stderr] \(line)")
                }
            }
        }
    }

    /// Feeds one stdout chunk from the consumer task that owns `generation`.
    ///
    /// Chunks from a superseded or terminated transport are dropped. Completed lines that
    /// precede an overflow in the same chunk are self-contained frames and still route; an
    /// oversized frame is acted on only after `feed` returns.
    private func handleStdoutChunk(_ data: Data, generation: UInt64) {
        guard generation == transportGeneration, !didTerminateTransport else { return }
        stdoutFramer.feed(data, onDiagnostic: { [self] diagnostic in
            handleStdoutFramerDiagnostic(diagnostic)
        }, onLine: { [self] lineData in
            handleJSONLine(lineData)
        })
        terminateTransportForPendingInboundFrameViolation()
    }

    /// Called when the stdout consumer task's channel stream ends (EOF or explicit finish).
    /// Delegates to `terminateTransport` for authoritative cleanup, scoped to the
    /// transport generation that created the consumer task.
    private func handleStdoutEOF(generation: UInt64) async {
        await terminateTransport(
            flushStdout: true,
            expectedGeneration: generation,
            reason: .stdoutEOF
        )
    }

    private func handleStdoutFramerDiagnostic(_ diagnostic: LineFramer.Diagnostic) {
        switch diagnostic {
        case let .overflow(droppedBytes, retainedBytes):
            // Recorded regardless of debug logging: an unfinished frame above the ceiling
            // can never complete, so its request must fail instead of staying pending.
            recordInboundFrameViolation(observedBytes: droppedBytes + retainedBytes)
        case .nonJSONCandidateQuoteStateReset:
            guard config.enableDebugLogging else { return }
            print("[CodexAppServer] stdout LineFramer reset quote state for non-JSON candidate")
        }
    }

    private func recordInboundFrameViolation(observedBytes: Int) {
        guard pendingInboundFrameViolation == nil else { return }
        pendingInboundFrameViolation = InboundFrameViolation(
            observedBytes: observedBytes,
            limitBytes: inboundFrameLimitBytes,
            generation: transportGeneration
        )
    }

    /// Ends the transport generation that produced a recorded oversized frame. Every pending
    /// request fails exactly once with `.inboundFrameTooLarge`. Logs sizes, generation, and
    /// pending method names only, never payload content.
    private func terminateTransportForPendingInboundFrameViolation() {
        guard let violation = pendingInboundFrameViolation else { return }
        pendingInboundFrameViolation = nil
        let pendingMethods = pendingRequestMetadata.values
            .filter { $0.transportGeneration == violation.generation }
            .map(\.method)
            .sorted()
            .joined(separator: ",")
        Self.transportLog.error(
            "Codex app-server inbound frame exceeded limit: observedBytes=\(violation.observedBytes, privacy: .public) limitBytes=\(violation.limitBytes, privacy: .public) generation=\(violation.generation, privacy: .public) pendingMethods=[\(pendingMethods, privacy: .public)]; terminating transport"
        )
        if config.enableDebugLogging {
            print("[CodexAppServer] inbound frame exceeded limit: observedBytes=\(violation.observedBytes) limitBytes=\(violation.limitBytes) generation=\(violation.generation) pendingMethods=[\(pendingMethods)]; terminating transport")
        }
        scheduleTransportCleanup(
            invalidateTransport(
                flushStdout: false,
                expectedGeneration: violation.generation,
                requestFailure: .inboundFrameTooLarge(
                    observedBytes: violation.observedBytes,
                    limitBytes: violation.limitBytes
                ),
                reason: .inboundFrameLimitExceeded(
                    observedBytes: violation.observedBytes,
                    limitBytes: violation.limitBytes,
                    generation: violation.generation
                )
            )
        )
    }

    // SEARCH-HELPER: JSON decode, recovery, concatenated, embedded tail, JSON-RPC
    /// Attempts to decode and route a single JSON-RPC line from stdout.
    ///
    /// If direct decode fails, applies recovery heuristics (concatenated-object
    /// splitting and embedded-tail recovery) adapted from Claude's decode pipeline.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.handleLine (reference decode + recovery)
    /// - ClaudeNativeProcessSessionController.recoverConcatenatedInboundMessagesIfNeeded
    /// - ClaudeNativeProcessSessionController.recoverEmbeddedInboundTailIfNeeded
    private func handleJSONLine(_ lineData: Data) {
        // Size-check before trimming, decoding, or recovery. `LineFramer` only bounds the
        // unfinished carry, so a line completed within one chunk can exceed the ceiling.
        // Once a violation is recorded, later lines of the doomed generation are ignored.
        guard pendingInboundFrameViolation == nil else { return }
        guard lineData.count <= inboundFrameLimitBytes else {
            recordInboundFrameViolation(observedBytes: lineData.count)
            return
        }
        guard let trimmed = trimmedASCIIWhitespace(lineData) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            // Primary decode failed — attempt recovery heuristics.
            guard shouldAttemptDecodeRecovery() else {
                let generation = transportGeneration
                if config.enableDebugLogging {
                    print("[CodexAppServer] Decode recovery budget exhausted for generation \(generation); terminating poisoned transport")
                }
                Task { [generation] in
                    await self.terminateTransport(
                        flushStdout: false,
                        expectedGeneration: generation,
                        reason: .decodeRecoveryBudgetExceeded(generation: generation)
                    )
                }
                return
            }
            if recoverConcatenatedJSONLines(from: trimmed) {
                return
            }
            if recoverEmbeddedJSONTail(from: trimmed) {
                return
            }
            if recoverInvalidJSONStringControlChars(from: trimmed) {
                return
            }
            if config.enableDebugLogging {
                let preview = String(data: trimmed.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                print("[CodexAppServer] Failed to decode JSON line (no recovery): \(preview)")
            }
            return
        }
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        routeDecodedJSON(json)
    }

    private func shouldAttemptDecodeRecovery() -> Bool {
        let generation = transportGeneration
        let attempts = decodeRecoveryAttemptsByGeneration[generation, default: 0]
        guard attempts < Self.maxDecodeRecoveryAttemptsPerGeneration else {
            return false
        }
        decodeRecoveryAttemptsByGeneration[generation] = attempts + 1
        if decodeRecoveryAttemptsByGeneration.count > 4 {
            let minGeneration = max(transportGeneration > 0 ? transportGeneration - 2 : 0, 0)
            decodeRecoveryAttemptsByGeneration = decodeRecoveryAttemptsByGeneration.filter { $0.key >= minGeneration }
        }
        return true
    }

    /// Routes a successfully decoded JSON-RPC object to the appropriate handler
    /// (response, error, server request, or notification broadcast).
    private func routeDecodedJSON(_ json: [String: Any]) {
        if let idValue = json["id"] {
            let idString = String(describing: idValue)
            if let result = json["result"] as? [String: Any] {
                if let continuation = pendingRequests.removeValue(forKey: idString) {
                    pendingRequestMetadata.removeValue(forKey: idString)
                    cancelTimeout(for: idString)
                    if config.enableDebugLogging {
                        print("[CodexAppServer] Response for request \(idString)")
                    }
                    continuation.resume(returning: result)
                }
                return
            }
            if let error = json["error"] as? [String: Any],
               let continuation = pendingRequests.removeValue(forKey: idString)
            {
                let metadata = pendingRequestMetadata.removeValue(forKey: idString)
                cancelTimeout(for: idString)
                guard let failure = Self.requestFailure(
                    method: metadata?.method ?? "<unknown>",
                    errorObject: error
                ) else {
                    continuation.resume(throwing: Self.settlementError(ClientError.invalidResponse, for: metadata))
                    return
                }
                if config.enableDebugLogging {
                    print("[CodexAppServer] Error for request \(idString): \(failure.message)")
                }
                continuation.resume(throwing: Self.settlementError(ClientError.requestFailed(failure), for: metadata))
                return
            }
            if let method = json["method"] as? String,
               let requestID = CodexAppServerRequestID(raw: idValue)
            {
                let params = codexJSONDictionary(from: json["params"] as? [String: Any] ?? [:])
                if config.enableDebugLogging {
                    print("[CodexAppServer] Server request: \(method) -> broadcasting to \(serverRequestContinuations.count) listeners")
                }
                broadcastServerRequest(id: requestID, method: method, params: params)
                return
            }
            if let continuation = pendingRequests.removeValue(forKey: idString) {
                pendingRequestMetadata.removeValue(forKey: idString)
                cancelTimeout(for: idString)
                continuation.resume(throwing: ClientError.invalidResponse)
            }
            return
        }
        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            if config.enableDebugLogging {
                print("[CodexAppServer] Notification: \(method) -> broadcasting to \(notificationContinuations.count) listeners")
            }
            broadcastNotification(method: method, params: codexJSONDictionary(from: params))
        }
    }

    // MARK: - Decode recovery heuristics

    /// Maximum line size for concatenated-segment recovery to avoid expensive scans.
    private static let maxConcatenatedRecoveryBytes = 2 * 1024 * 1024 // 2 MB

    /// Attempts to split a corrupted line into multiple concatenated JSON objects
    /// using brace-depth scanning, then routes each successfully decoded object.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.recoverConcatenatedInboundMessagesIfNeeded
    private func recoverConcatenatedJSONLines(from lineData: Data) -> Bool {
        guard lineData.count <= Self.maxConcatenatedRecoveryBytes else { return false }
        let segments = Self.splitConcatenatedJSONObjects(lineData)
        guard !segments.isEmpty else { return false }
        let looksCorrupted =
            segments.count > 1
                || (segments.count == 1 && segments[0].count != lineData.count)
        guard looksCorrupted else { return false }

        var recoveredCount = 0
        for segment in segments {
            guard let json = try? JSONSerialization.jsonObject(with: segment) as? [String: Any] else {
                continue
            }
            recoveredCount += 1
            routeDecodedJSON(json)
        }

        if recoveredCount > 0 {
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
            if config.enableDebugLogging {
                print("[CodexAppServer] Recovered \(recoveredCount)/\(segments.count) JSON segment(s) from corrupted line")
            }
        }
        return recoveredCount > 0
    }

    /// Maximum trailing bytes to scan for embedded-tail recovery.
    private static let maxTailRecoveryScanBytes = 256 * 1024 // 256 KB

    /// JSON-RPC marker byte sequences used to locate potential object start positions.
    private static let jsonRPCMarkers: [[UInt8]] = [
        Array("{\"method\"".utf8),
        Array("{\"id\"".utf8),
        Array("{\"result\"".utf8),
        Array("{\"error\"".utf8),
        Array("{\"jsonrpc\"".utf8)
    ]

    /// Scans the tail of a corrupted line for an embedded valid JSON-RPC object.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.recoverEmbeddedInboundTailIfNeeded
    private func recoverEmbeddedJSONTail(from lineData: Data) -> Bool {
        guard !lineData.isEmpty else { return false }

        let scanWindow: Data
        let scanOffset: Int
        if lineData.count > Self.maxTailRecoveryScanBytes {
            scanOffset = lineData.count - Self.maxTailRecoveryScanBytes
            scanWindow = lineData.suffix(Self.maxTailRecoveryScanBytes)
        } else {
            scanOffset = 0
            scanWindow = lineData
        }

        let markerOffsets = Self.jsonRPCObjectStartOffsets(in: scanWindow, markers: Self.jsonRPCMarkers)
        guard !markerOffsets.isEmpty else { return false }

        // Skip offset 0 if it's the start of the original data (already failed upstream).
        let candidateOffsets: [Int] = if markerOffsets.first == 0, scanOffset == 0 {
            Array(markerOffsets.dropFirst())
        } else {
            markerOffsets
        }
        guard !candidateOffsets.isEmpty else { return false }

        // Try candidates from the end (prefer the rightmost / latest embedded JSON).
        for offset in candidateOffsets.reversed() {
            let absoluteOffset = scanOffset + offset
            let suffixData = lineData.suffix(from: lineData.startIndex + absoluteOffset)
            guard let json = try? JSONSerialization.jsonObject(with: suffixData) as? [String: Any] else {
                continue
            }
            if config.enableDebugLogging {
                let preview = String(data: suffixData.prefix(180), encoding: .utf8) ?? "<non-utf8>"
                print("[CodexAppServer] Recovered embedded JSON tail at offset \(absoluteOffset): \(preview)")
            }
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
            routeDecodedJSON(json)
            return true
        }
        return false
    }

    private func recoverInvalidJSONStringControlChars(from lineData: Data) -> Bool {
        guard let repaired = repairJSONStringControlCharacters(lineData) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: repaired) as? [String: Any] else {
            return false
        }
        if config.enableDebugLogging {
            print("[CodexAppServer] Recovered JSON by escaping control characters inside JSON strings")
        }
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        routeDecodedJSON(json)
        return true
    }

    /// Splits concatenated JSON objects from raw data using brace-depth scanning.
    /// Reused from Claude's `splitConcatenatedJSONObjectPayloads` algorithm.
    static func splitConcatenatedJSONObjects(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        var results: [Data] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if start == nil {
                if character == "{" {
                    start = index
                    depth = 1
                    inString = false
                    escaping = false
                }
                index = text.index(after: index)
                continue
            }

            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let segmentStart = start {
                        let segmentEnd = text.index(after: index)
                        let segment = String(text[segmentStart ..< segmentEnd])
                        if let segmentData = segment.data(using: .utf8), !segmentData.isEmpty {
                            results.append(segmentData)
                        }
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }
        return results
    }

    /// Finds byte offsets of JSON-RPC marker sequences in raw Data.
    private static func jsonRPCObjectStartOffsets(in data: Data, markers: [[UInt8]]) -> [Int] {
        guard !data.isEmpty, !markers.isEmpty else { return [] }
        var offsets = Set<Int>()
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for marker in markers {
                guard data.count >= marker.count else { continue }
                let searchLimit = data.count - marker.count
                for i in 0 ... searchLimit {
                    var matches = true
                    for j in 0 ..< marker.count {
                        if baseAddress[i + j] != marker[j] {
                            matches = false
                            break
                        }
                    }
                    if matches {
                        offsets.insert(i)
                    }
                }
            }
        }
        return offsets.sorted()
    }

    private func broadcastNotification(method: String, params: [String: CodexJSONValue]) {
        for continuation in notificationContinuations.values {
            continuation.yield(Notification(method: method, params: params))
        }
    }

    private func broadcastServerRequest(id: CodexAppServerRequestID, method: String, params: [String: CodexJSONValue]) {
        let receipt = CodexServerRequestReceipt(clientInstanceID: clientInstanceID, transportGeneration: transportGeneration, id: id)
        if runtimeLaunch != nil {
            inboundServerRequestOwners[receipt] = RuntimeWriteOwner(generation: transportGeneration, launch: runtimeLaunch)
        }
        let request = ServerRequest(id: id, method: method, params: params, receipt: receipt)
        for continuation in serverRequestContinuations.values {
            continuation.yield(request)
        }
    }

    private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
        var output: [String: CodexJSONValue] = [:]
        for (key, value) in value {
            if let converted = CodexJSONValue.from(value) {
                output[key] = converted
            }
        }
        return output
    }

    /// Writes a single JSON-RPC line to stdin as an atomic frame (payload + newline).
    ///
    /// Combining payload and newline into a single write prevents pipe interleaving
    /// that could theoretically occur with two separate writes.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.sendLine (reference atomic write pattern)
    private func sendJSONLine(_ payload: [String: Any], method: String?, owner: RuntimeWriteOwner? = nil) throws {
        guard let process else { throw ClientError.processNotRunning }
        // R6 final synchronous check: an owned write goes only to the exact transport (generation
        // and launch) its operation captured before its first suspension.
        if let owner, !isCurrent(owner) {
            throw ClientError.processNotRunning
        }
        // R6: a registered transport writes only after its birth identity is committed.
        if runtimeLaunch != nil, runtimeCommittedGeneration != transportGeneration {
            throw ClientError.processNotRunning
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        if config.enableDebugLogging {
            if let line = String(data: data, encoding: .utf8) {
                // A thread start/resume config can carry the read-only companion's launch
                // credential in its server environment; never print that frame.
                if line.contains(MCPBootstrapCompanionCredential.environmentKey) {
                    print("[CodexAppServer] -> \(method ?? "<response>") (frame redacted: companion credential)")
                } else {
                    print("[CodexAppServer] -> \(line)")
                }
            }
        }
        guard let stdinDescriptor = process.stdinDescriptor else {
            throw ClientError.processNotRunning
        }
        var frame = data
        frame.append(0x0A)
        let generation = transportGeneration
        do {
            try writeFrameHandler(stdinDescriptor, frame)
        } catch let error as FDWriteError {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: error.errnoValue),
                errno: error.errnoValue
            )
            scheduleTransportCleanup(
                invalidateTransport(
                    flushStdout: false,
                    expectedGeneration: generation,
                    requestFailure: failure,
                    reason: .stdinWrite(method: method, errno: error.errnoValue)
                )
            )
            throw failure
        } catch {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: nil),
                errno: nil
            )
            scheduleTransportCleanup(
                invalidateTransport(
                    flushStdout: false,
                    expectedGeneration: generation,
                    requestFailure: failure,
                    reason: .stdinWrite(method: method, errno: nil)
                )
            )
            throw failure
        }
    }

    private func transportWriteFailureMessage(method: String?, errno: Int32?) -> String {
        let operation = method ?? "transport write"
        if let errno {
            let message = String(cString: strerror(errno))
            return "Codex app-server stdin write failed during \(operation): \(message)"
        }
        return "Codex app-server stdin write failed during \(operation)."
    }

    private static func transportReadSetupError(stream: String, error: Error) -> ClientError {
        let errnoValue = errnoValue(from: error)
        if let errnoValue {
            let message = String(cString: strerror(errnoValue))
            return .transportReadSetupFailed(
                message: "Codex app-server \(stream) reader failed to start: \(message)",
                errno: errnoValue
            )
        }
        return .transportReadSetupFailed(
            message: "Codex app-server \(stream) reader failed to start: \(error.localizedDescription)",
            errno: nil
        )
    }

    private static func errnoValue(from error: Error) -> Int32? {
        if let preflightError = error as? ReadSourceFDPreflightError {
            switch preflightError {
            case .invalidFileDescriptor:
                return EBADF
            case let .descriptorCheckFailed(_, _, errnoValue):
                return errnoValue
            }
        }
        if let posixError = error as? POSIXError {
            return posixError.code.rawValue
        }
        return nil
    }

    private func scheduleTimeout(for requestID: String, after timeout: TimeInterval) {
        guard timeout > 0 else { return }
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutRequest(id: requestID, after: timeout)
        }
    }

    private func timeoutRequest(id: String, after timeout: TimeInterval) async {
        timeoutTasks.removeValue(forKey: id)
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            pendingRequestMetadata.removeValue(forKey: id)
            return
        }
        let metadata = pendingRequestMetadata.removeValue(forKey: id)
        if let metadata,
           Self.shouldPoisonTransportOnTimeout(method: metadata.method)
        {
            let terminatingTransport = invalidateTransport(
                flushStdout: false,
                expectedGeneration: metadata.transportGeneration,
                requestFailure: .processNotRunning,
                reason: .timeout(method: metadata.method, requestID: id)
            )
            scheduleTransportCleanup(terminatingTransport)
        }
        continuation.resume(throwing: Self.settlementError(ClientError.requestFailed(.init(
            method: metadata?.method ?? "<unknown>",
            code: nil,
            message: "Request timed out after \(timeout)s",
            data: nil
        )), for: metadata))
    }

    private func cancelTimeout(for requestID: String) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func cancelPendingRequestIfPresent(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pendingRequestMetadata.removeValue(forKey: id)
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func failPendingRequestIfPresent(id: String, error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        let metadata = pendingRequestMetadata.removeValue(forKey: id)
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: Self.settlementError(error, for: metadata))
        }
    }

    private func makeRequestID() -> String {
        let value = nextRequestID
        nextRequestID += 1
        return String(value)
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func removeServerRequestContinuation(_ id: UUID) {
        serverRequestContinuations.removeValue(forKey: id)
    }

    #if DEBUG
        func debugProcessID() -> pid_t? {
            process?.pid
        }

        func debugIsProcessRunning() -> Bool {
            process != nil
        }

        func debugNextRequestID() -> Int {
            nextRequestID
        }

        func debugTransportGeneration() -> UInt64 {
            transportGeneration
        }

        func debugLastTransportTerminationReason() -> TransportTerminationReason? {
            lastTransportTerminationReason
        }

        static func debugDefaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
            defaultProcessAppearsAlive(process)
        }

        func debugDecodeRecoveryAttempts(generation: UInt64? = nil) -> Int {
            let key = generation ?? transportGeneration
            return decodeRecoveryAttemptsByGeneration[key, default: 0]
        }

        func debugIngestRawStdoutLine(_ line: Data) {
            handleJSONLine(line)
            terminateTransportForPendingInboundFrameViolation()
        }

        /// Feeds raw bytes through the real stdout framing path for the current transport generation.
        func debugIngestRawStdoutChunk(_ chunk: Data) {
            handleStdoutChunk(chunk, generation: transportGeneration)
        }

        /// Feeds raw bytes as if delivered by the consumer task of `generation`.
        func debugIngestRawStdoutChunk(_ chunk: Data, generation: UInt64) {
            handleStdoutChunk(chunk, generation: generation)
        }

        /// Overrides the inbound frame ceiling so tests can use kilobyte-scale fixtures.
        /// Rebuilds the stdout framer; call before ingesting a frame.
        func debugSetMaxInboundFrameBytes(_ limitBytes: Int) {
            inboundFrameLimitBytes = max(1, limitBytes)
            stdoutFramer = makeStdoutFramer()
            pendingInboundFrameViolation = nil
        }

        func debugInboundFrameLimitBytes() -> Int {
            inboundFrameLimitBytes
        }

        /// Runs the stdout-EOF teardown for the current generation, as the consumer task does.
        func debugSimulateStdoutEOF() async {
            await handleStdoutEOF(generation: transportGeneration)
        }

        static func debugMaxDecodeRecoveryAttemptsPerGeneration() -> Int {
            maxDecodeRecoveryAttemptsPerGeneration
        }

        func debugPendingRequestCount() -> Int {
            pendingRequests.count
        }

        func debugTimeoutTaskCount() -> Int {
            timeoutTasks.count
        }

        func debugInstallTestTransport() {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process = SpawnedProcess(
                pid: pid_t.max,
                processGroupID: nil,
                stdin: stdinPipe.fileHandleForWriting,
                stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
            isInitialized = true
            didTerminateTransport = false
            lastTransportTerminationReason = nil
            stdoutFramer = makeStdoutFramer()
            pendingInboundFrameViolation = nil
            transportGeneration &+= 1
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        }

        /// Attaches a fixture runtime launch to the current test transport, committed (birth identity
        /// registered for this generation) or not, so request fences run without a real spawn.
        func debugInstallTestRuntimeLaunch(_ launch: AgentRuntimeLaunch, committed: Bool) {
            runtimeLaunch = launch
            runtimeCommittedGeneration = committed ? transportGeneration : nil
        }

        func debugSetRuntimeFenceCheckpoint(_ checkpoint: (@Sendable (String) async -> Void)?) {
            debugRuntimeFenceCheckpoint = checkpoint
        }

        func debugSetStartupOverride(_ override: (@Sendable (CodexAppServerClient) async throws -> Void)?) {
            debugStartupOverride = override
        }

    #endif
}
