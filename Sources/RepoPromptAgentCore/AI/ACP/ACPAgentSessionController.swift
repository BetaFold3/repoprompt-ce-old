import Darwin
import Foundation
import os
import RepoPromptPlatform

package enum ACPDynamicModelPublicationPolicy {
    case standard
    case capabilityOnly
}

enum ACPConfigurationMutationFailureClassification {
    case modelLocal
    case sessionFatal
}

package actor ACPAgentSessionController {
    package struct RequestTimeouts {
        let bootstrapSeconds: TimeInterval
        let setConfigOptionSeconds: TimeInterval

        init(
            bootstrapSeconds: TimeInterval,
            setConfigOptionSeconds: TimeInterval? = nil
        ) {
            self.bootstrapSeconds = bootstrapSeconds
            self.setConfigOptionSeconds = setConfigOptionSeconds ?? bootstrapSeconds
        }

        static let `default` = RequestTimeouts(
            bootstrapSeconds: 30
        )
    }

    package enum DiagnosticEvent {
        case phaseStarted(String)
        case phaseCompleted(String)
        case outboundJSON(String)
        case inboundJSON(String)
        case stderrLine(String)
        case info(String)
        case invalidJSON(String)
        case unmatchedResponse(id: String, line: String)
    }

    package typealias DiagnosticSink = @Sendable (DiagnosticEvent) -> Void

    enum State: String {
        case idle
        case launching
        case initialized
        case openingSession
        case sessionOpen
        case promptRunning
        case closing
        case closed
        case failed
    }

    struct BootstrapResult {
        let sessionID: String
        let providerSessionIdentity: ACPProviderSessionIdentity
        let loadSessionSupported: Bool
        let didFallbackToNewSessionAfterLoadFailure: Bool
        let invalidatedResumeSessionID: String?
    }

    private enum ControllerError: LocalizedError {
        case invalidState(expected: String, actual: State)
        case processNotRunning
        case protocolViolation(String)
        case requestFailed(String, code: Int? = nil)
        case requestTimedOut(method: String, timeoutSeconds: TimeInterval, launchDescription: String?, diagnosticHint: String?)
        case transportClosed

        var errorDescription: String? {
            switch self {
            case let .invalidState(expected, actual):
                return "ACP controller expected \(expected), but was \(actual.rawValue)."
            case .processNotRunning:
                return "ACP process is not running."
            case let .protocolViolation(message):
                return "ACP protocol violation: \(message)"
            case let .requestFailed(message, code):
                if let code {
                    return "ACP request failed: \(message) (code \(code))"
                }
                return "ACP request failed: \(message)"
            case let .requestTimedOut(method, timeoutSeconds, launchDescription, diagnosticHint):
                var message = "ACP request \(method) timed out after \(Self.formattedTimeout(timeoutSeconds))."
                if let launchDescription, !launchDescription.isEmpty {
                    message += " Launched: `\(launchDescription)`."
                }
                if let diagnosticHint, !diagnosticHint.isEmpty {
                    message += " \(diagnosticHint)"
                }
                return message
            case .transportClosed:
                return "ACP transport closed unexpectedly."
            }
        }

        private static func formattedTimeout(_ seconds: TimeInterval) -> String {
            if seconds.rounded(.towardZero) == seconds {
                return "\(Int(seconds))s"
            }
            return String(format: "%.1fs", seconds)
        }
    }

    private enum JSONRPCID: Hashable {
        case string(String)
        case int(Int)
        case double(Double)

        var storageKey: String {
            switch self {
            case let .string(value):
                "s:\(value)"
            case let .int(value):
                "i:\(value)"
            case let .double(value):
                "d:\(value)"
            }
        }

        var displayValue: String {
            switch self {
            case let .string(value):
                value
            case let .int(value):
                String(value)
            case let .double(value):
                String(value)
            }
        }

        var jsonValue: Any {
            switch self {
            case let .string(value):
                value
            case let .int(value):
                value
            case let .double(value):
                value
            }
        }
    }

    private struct PendingPermissionRequest {
        let rpcID: JSONRPCID
        let options: [PermissionOption]
        let request: AgentApprovalRequest
        /// R6: the runtime launch whose transport issued the request (`nil` while registration is
        /// off). Its reply goes only to that transport, never to a replacement.
        let issuingLaunch: AgentRuntimeLaunch?
    }

    private struct RequestResponse {
        let result: [String: Any]
        let inboundSequence: UInt64
    }

    private enum PendingRequestContinuation {
        case object(CheckedContinuation<RequestResponse, Error>)
        case raw(CheckedContinuation<Any, Error>)

        func resume(throwing error: Error) {
            switch self {
            case let .object(continuation):
                continuation.resume(throwing: error)
            case let .raw(continuation):
                continuation.resume(throwing: error)
            }
        }
    }

    private struct PendingRequest {
        let method: String
        let continuation: PendingRequestContinuation
        var timeoutTask: Task<Void, Never>?
    }

    private struct SessionModeSnapshot {
        let configID: String
        let currentValue: String
        let availableValues: [String]
    }

    private struct ParsedSelectConfigOption {
        let id: String
        let currentValue: String
        let choices: [[String: Any]]
    }

    private enum ParsedSelectConfigOptionResult {
        case absent
        case valid(ParsedSelectConfigOption)
        case malformed(String)
    }

    private enum ParsedModernModeSnapshot {
        case absent
        case valid(SessionModeSnapshot)
        case malformed(String)
    }

    private enum ParsedModernModelSnapshot {
        case absent
        case valid(configID: String, models: ACPDiscoveredSessionModels)
        case malformed(String)
    }

    private struct AuxiliarySelectorSnapshot {
        let configID: String
        let category: String?
        let currentValue: String
        let values: [String]
        let displayNames: [String]
    }

    private struct AuxiliarySelectorRollback {
        let configID: String
        let previousValue: String
        let requestedValue: String
    }

    private struct BufferedConfigOptionUpdate {
        let sessionID: String
        let update: [String: Any]
        let inboundSequence: UInt64
    }

    private struct PromptSettlementWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct OpenSessionResult {
        let sessionID: String
        let providerSessionIdentity: ACPProviderSessionIdentity
        let invalidatedResumeSessionID: String?
    }

    private struct PermissionOption {
        let optionID: String
        let kind: String
    }

    private struct AutoApprovalSelection {
        let optionID: String
        let match: MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch
    }

    private enum PermissionOptionPreference {
        case optionID(String)
        case kind(String)
    }

    private var eventsContinuation: AsyncStream<NormalizedAgentRuntimeEvent>.Continuation?
    private var eventsStream: AsyncStream<NormalizedAgentRuntimeEvent>
    var events: AsyncStream<NormalizedAgentRuntimeEvent> {
        eventsStream
    }

    func currentEventsStream() -> AsyncStream<NormalizedAgentRuntimeEvent> {
        eventsStream
    }

    func currentDiscoveredSessionModels() -> ACPDiscoveredSessionModels? {
        discoveredSessionModels
    }

    private let provider: any ACPAgentProvider
    private let runRequest: ACPRunRequest
    private let launchConfiguration: ACPLaunchConfiguration
    private let sessionConfiguration: ACPSessionConfiguration
    private let mcpClientNameHint: String?
    private let logPrefix: String
    private let diagnosticSink: DiagnosticSink?
    private let requestTimeouts: RequestTimeouts
    private let dynamicModelPublicationPolicy: ACPDynamicModelPublicationPolicy
    private let ohMyPiThinkingCapabilityPublisher: OhMyPiThinkingCapabilityPublisher

    /// Modern configOptions are the only configuration authority. Mutations are serialized,
    /// and complete snapshots apply in inbound wire order.
    private let configurationMutationMutex = AsyncMutex()
    #if DEBUG
        private var debugShouldSuspendNextConfigurationMutationPostcheck = false
        private var debugConfigurationMutationPostcheckIsSuspended = false
        private var debugConfigurationMutationPostcheckResumeWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    private var state: State = .idle
    private var process: SpawnedProcess?
    /// Runtime ownership of `process` (spec R6); `nil` while Phase 3 registration is off.
    private var runtimeLaunch: AgentRuntimeLaunch?
    /// Whether the current transport was spawned under a runtime launch; every stdin write then
    /// requires `runtimeLaunch` to be that committed launch (synchronous transport-owner check).
    private var runtimeManagedTransport = false
    private var runtimeCommittedLaunch: AgentRuntimeLaunch?
    #if DEBUG
        /// Test-only suspension at R6 fence checkpoints (`launchCaptured` before the first await,
        /// `associated`, `authorized`), so fixtures can replace the transport inside a write's awaits.
        private var debugRuntimeFenceCheckpoint: (@Sendable (String) async -> Void)?
    #endif
    private let launchAuthority: AgentRuntimeLaunchAuthority
    /// R6: registered launches join the tab's retained runtime retirements before a start, and a
    /// provider switch retires a registered controller instead of keeping it warm.
    package nonisolated var joinsRetirementBeforeSuccessor: Bool {
        registersLaunches
    }

    /// R6 subset activation: whether this backend's own ACP pair registers its launches (an
    /// unqualified backend launches unregistered, keeps its warm controllers and joins nothing).
    private nonisolated let registersLaunches: Bool

    private var stdoutChannel: FileHandleChunkChannel?
    private var stderrChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var processWaitTask: Task<Void, Never>?
    private var stdoutFramer = LineFramer()
    private var stderrFramer = LineFramer()
    private var launchDescription: String?
    private var stdoutByteCount = 0
    private var stdoutLineCount = 0
    private var invalidACPLineCount = 0
    private var stderrLineCount = 0
    private var lastStdoutPreview: String?
    private var lastInvalidACPLinePreview: String?
    private var lastStderrPreview: String?
    private var nextRequestID = 1
    private var inboundMessageSequence: UInt64 = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingPermissionRequests: [String: PendingPermissionRequest] = [:]
    private var activePromptTurnID: UUID?
    private var activePromptOpenCodeStderrError: String?
    #if DEBUG
        private var activePromptSessionUpdateCounts: [String: Int] = [:]
        private var activePromptNormalizedStreamCount = 0
    #endif
    private var activePromptNormalizedContentCount = 0
    private var activePromptNormalizedReasoningCount = 0
    /// O49: receipt evidence of one `session/prompt`, keyed by that prompt's own turn token and
    /// recorded only while it is the active prompt. A newer prompt's trace can neither lend nor
    /// reset an older prompt's evidence. Each prompt removes its entry when it returns or throws.
    private struct PromptReceiptEvidence {
        /// The agent streamed content or reasoning while this prompt was active.
        var agentStreamed = false
        /// RepoPrompt sent `session/cancel` (Stop or steering) while this prompt was active.
        var cancelledByClient = false
        /// Another prompt was outstanding while this one was: output is credited to whichever
        /// prompt is active, so neither prompt's evidence is attributable and neither ever reports
        /// receipt.
        var overlappedAnotherPrompt = false
        /// `repoPromptTeardownGeneration` when this prompt started.
        let teardownGenerationAtStart: UInt64

        func provesReceipt(teardownGeneration: UInt64) -> Bool {
            agentStreamed && !overlappedAnotherPrompt
                && (cancelledByClient || teardownGeneration != teardownGenerationAtStart)
        }
    }

    private var promptReceiptEvidenceByTurnID: [UUID: PromptReceiptEvidence] = [:]
    /// O49: bumped synchronously by RepoPrompt's own Stop, window close or quit before the run task
    /// is cancelled, so a prompt outstanding at that moment knows RepoPrompt tore it down even when
    /// it fails before `session/cancel` is written.
    private nonisolated let repoPromptTeardownGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var promptSettlementWaitersByTurnID: [UUID: [PromptSettlementWaiter]] = [:]
    private var sessionID: String?
    private var providerSessionIdentity: ACPProviderSessionIdentity
    private var didEmitTerminal = false
    private var providerProcessExitedUnexpectedly = false
    private var eventStreamFinished = false
    private var loadSessionSupported = false
    private var discoveredSessionModels: ACPDiscoveredSessionModels?
    private var sessionModelConfigOptionID: String?
    private var sessionModelFailureReason: String?
    private var sessionModeSnapshot: SessionModeSnapshot?
    private var sessionModeFailureReason: String?
    private var auxiliarySelectors: [String: AuxiliarySelectorSnapshot] = [:]
    private var authoritativeConfigOptions: [[String: Any]] = []
    private var lastAppliedConfigurationSequence: UInt64 = 0
    private var bufferedConfigOptionUpdates: [BufferedConfigOptionUpdate] = []
    private var suppressSessionLoadReplayUpdates = false
    private var fallbackResumeSessionIDForPromptClearing: String?
    private var autoApproveAllToolPermissions: Bool
    /// R6: the session scope the launch request's owner captured (reservation, `session/new` or
    /// `load`, and the launch's own first prompt). Later prompts carry their own request's scope;
    /// nothing is re-read from a session at write time.
    private let launchRuntimeSession: AgentRuntimeSessionScope
    /// R6: the most recently requested session mode (launch request, then `setSessionMode`).
    private var requestedSessionModeID: String?
    private var expectedMCPRunID: UUID?
    private var registeredExpectedAgentPID: pid_t?
    private let mcpHost: any AgentMCPHosting
    #if DEBUG
        private let rawACPCaptureURL: URL?
    #endif

    package init(
        provider: any ACPAgentProvider,
        runRequest: ACPRunRequest,
        mcpHost: any AgentMCPHosting,
        diagnosticSink: DiagnosticSink? = nil,
        requestTimeouts: RequestTimeouts = .default,
        dynamicModelPublicationPolicy: ACPDynamicModelPublicationPolicy = .standard,
        ohMyPiThinkingCapabilityPublisher: @escaping OhMyPiThinkingCapabilityPublisher = {
            _ = OhMyPiThinkingCapabilityRegistry.shared.record($0)
        },
        launchAuthority: AgentRuntimeLaunchAuthority = .production
    ) throws {
        self.launchAuthority = launchAuthority
        registersLaunches = launchAuthority.isRegistrationActive(family: .acp, provider: .acp(provider.providerID))
        try ACPConfigOptionAssignment.validate(
            runRequest.additionalConfigOptionValues,
            for: provider.providerID
        )
        self.provider = provider
        providerSessionIdentity = ACPProviderSessionIdentity(
            providerID: provider.providerID,
            loadSessionID: runRequest.resumeSessionID,
            loadSessionIDConfidence: runRequest.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .candidate : .unavailable
        )
        self.runRequest = runRequest
        self.mcpHost = mcpHost
        let sessionConfiguration = try provider.makeSessionConfiguration(
            for: runRequest,
            mcpServer: .repoPrompt
        )
        try Self.preflightInjectedMCPServers(in: sessionConfiguration)
        self.sessionConfiguration = sessionConfiguration
        launchConfiguration = try provider.makeLaunchConfiguration(for: runRequest)
        autoApproveAllToolPermissions = runRequest.autoApproveAllToolPermissions
        launchRuntimeSession = runRequest.runtimeSession
        requestedSessionModeID = runRequest.sessionModeID
        mcpClientNameHint = runRequest.agentKind.mcpClientNameHint
        logPrefix = "[ACP][\(provider.providerID.rawValue)]"
        self.diagnosticSink = diagnosticSink
        self.requestTimeouts = requestTimeouts
        self.dynamicModelPublicationPolicy = dynamicModelPublicationPolicy
        self.ohMyPiThinkingCapabilityPublisher = ohMyPiThinkingCapabilityPublisher
        #if DEBUG
            rawACPCaptureURL = Self.resolveRawACPCaptureURL(for: provider.providerID)
        #endif

        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
        #if DEBUG
            Self.captureLaunchConfigurationIfEnabled(
                rawACPCaptureURL: rawACPCaptureURL,
                providerID: provider.providerID,
                launchConfiguration: launchConfiguration
            )
        #endif
    }

    var hasReusableSession: Bool {
        state == .sessionOpen && process != nil && sessionID != nil
    }

    func isCompatibleWith(request: ACPRunRequest) -> Bool {
        guard let providerID = request.agentKind.acpProviderID,
              provider.providerID == providerID,
              normalizedWorkspacePath(runRequest.workspacePath) == normalizedWorkspacePath(request.workspacePath)
        else {
            return false
        }
        // Selection changes are already blocked/managed by the agent-mode UI while
        // a run is active. For live steering, controller identity + provider +
        // workspace are the safety boundary; model aliases/defaults/discovered
        // current-model values should not prevent session/cancel from being sent.
        return true
    }

    func normalizeError(_ error: Error) -> Error {
        provider.normalizeError(error)
    }

    /// Whether the provider process exited (or timed out) while this controller was not closing it:
    /// the exact provider-process-loss fact for a run's terminal cause (review A F06). Closing or
    /// shutting the controller down ourselves never sets it.
    package func providerProcessWasLost() -> Bool {
        providerProcessExitedUnexpectedly
    }

    nonisolated func classifyConfigurationMutationFailureForSweep(
        _ error: Error
    ) -> ACPConfigurationMutationFailureClassification {
        guard let controllerError = error as? ControllerError else { return .sessionFatal }
        switch controllerError {
        case .requestFailed:
            return .modelLocal
        case .invalidState, .processNotRunning, .protocolViolation, .requestTimedOut, .transportClosed:
            return .sessionFatal
        }
    }

    #if DEBUG
        func setExpectedMCPRunID(
            _ runID: UUID?,
            testDuringSet: (() async -> Void)? = nil
        ) async {
            expectedMCPRunID = runID
            await testDuringSet?()
        }
    #else
        func setExpectedMCPRunID(_ runID: UUID?) {
            expectedMCPRunID = runID
        }
    #endif

    func setAutoApproveAllToolPermissions(_ enabled: Bool) {
        autoApproveAllToolPermissions = enabled
    }

    @discardableResult
    func prepareForNextTurn() -> Bool {
        guard state == .sessionOpen, process != nil, sessionID != nil else { return false }
        didEmitTerminal = false
        eventStreamFinished = false
        resetEventsStreamForNextTurn()
        return true
    }

    func bootstrap() async throws -> BootstrapResult {
        guard state == .idle else {
            throw ControllerError.invalidState(expected: "idle", actual: state)
        }
        state = .launching
        log("Launching ACP transport")
        diagnose(.phaseStarted("launch"))
        let environment = await resolvedEnvironment()
        try Self.preflightInjectedMCPServers(in: sessionConfiguration, environment: environment)
        let workingDirectory = CommandPathResolver.expandPath(
            launchConfiguration.workingDirectory ?? FileManager.default.temporaryDirectory.path,
            environment: environment
        )
        let resolvedCommand = CommandPathResolver.resolve(
            launchConfiguration.command,
            environment: environment,
            additionalPaths: launchConfiguration.additionalPathHints,
            preferredBasenames: [launchConfiguration.command]
        )
        do {
            if let expectedExecutableIdentity = launchConfiguration.expectedExecutableIdentity {
                try expectedExecutableIdentity.validateForTrustedPathLaunch(atPath: resolvedCommand)
            }
        } catch {
            await recordRunLaunchContract(
                event: "acp_launch_validation_failed",
                resolvedCommand: resolvedCommand,
                workingDirectory: workingDirectory,
                pid: nil,
                error: error
            )
            throw error
        }
        launchDescription = Self.displayCommand(
            command: resolvedCommand,
            arguments: Self.redactedLaunchArguments(launchConfiguration.arguments)
        )
        logLaunchContract(command: resolvedCommand, workingDirectory: workingDirectory)
        diagnose(.info("Launching ACP command: \(launchDescription ?? resolvedCommand)"))
        // R6: reservation immediately before the spawn (generic lifecycle only: no provider
        // home, argument or writer-classification assumptions). A refusal spawns nothing.
        let resumeSessionID = runRequest.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let launch = launchAuthority.makeLaunch(AgentRuntimeLaunchContext(
            family: .acp,
            provider: .acp(provider.providerID),
            session: launchRuntimeSession,
            worktreePath: runRequest.workspacePath,
            conversationID: resumeSessionID?.isEmpty == false ? resumeSessionID : nil,
            permission: runtimePermission
        ))
        let runtimeID: UUID?
        do {
            runtimeID = try await launch?.prepareSpawn()
        } catch {
            state = .failed
            throw error
        }
        guard state == .launching else {
            await launch?.spawnFailed()
            throw ControllerError.invalidState(expected: "launching", actual: state)
        }
        let spawned: SpawnedProcess
        do {
            spawned = try ProcessLauncher.spawn(
                command: resolvedCommand,
                arguments: launchConfiguration.arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                runtimeID: runtimeID
            )
        } catch {
            await launch?.spawnFailed()
            await recordRunLaunchContract(
                event: "acp_launch_spawn_failed",
                resolvedCommand: resolvedCommand,
                workingDirectory: workingDirectory,
                pid: nil,
                error: error
            )
            throw error
        }
        process = spawned
        runtimeLaunch = launch
        runtimeManagedTransport = launch != nil
        runtimeCommittedLaunch = nil
        do {
            try startReaders(stdout: spawned.stdout, stderr: spawned.stderr)
            // R6: the birth identity is committed before `initialize` (the first write).
            try await launch?.commitSpawn(pid: spawned.pid, processGroupID: spawned.processGroupID)
            guard process?.pid == spawned.pid, state == .launching, runtimeLaunch === launch else {
                throw ControllerError.invalidState(expected: "launching", actual: state)
            }
            runtimeCommittedLaunch = launch
        } catch {
            spawned.stdout.readabilityHandler = nil
            spawned.stderr.readabilityHandler = nil
            spawned.stdin?.closeFile()
            if process?.pid == spawned.pid {
                process = nil
                runtimeLaunch = nil
            }
            let reaped = await ProcessTermination.terminateAndReapReportingRoot(
                pid: spawned.pid,
                processGroupID: spawned.processGroupID
            )
            await launch?.rootReaped(pid: spawned.pid, confirmed: reaped.rootReaped)
            state = .failed
            if error is AgentProcessRegistryError || error is ControllerError {
                throw error
            }
            throw ControllerError.protocolViolation("Failed to start ACP process readers: \(error.localizedDescription)")
        }
        await registerExpectedAgentPIDIfNeeded(spawned.pid)
        startProcessWaitTask(for: spawned, launch: launch)
        await recordRunLaunchContract(
            event: "acp_launch_contract_resolved",
            resolvedCommand: resolvedCommand,
            workingDirectory: workingDirectory,
            pid: nil,
            error: nil
        )
        await recordRunLaunchContract(
            event: "acp_process_spawned",
            resolvedCommand: resolvedCommand,
            workingDirectory: workingDirectory,
            pid: spawned.pid,
            error: nil
        )
        diagnose(.phaseCompleted("launch"))

        log("ACP initialize")
        diagnose(.phaseStarted("initialize"))
        var clientCapabilities: [String: Any] = [
            "fs": [
                "readTextFile": false,
                "writeTextFile": false
            ],
            "terminal": false
        ]
        let capabilityMetadata = provider.initializeClientCapabilityMetadata
        if !capabilityMetadata.isEmpty {
            clientCapabilities["_meta"] = capabilityMetadata
        }
        let initializeResponse = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "RepoPrompt",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                ],
                "clientCapabilities": clientCapabilities
            ]
        )
        diagnose(.phaseCompleted("initialize"))
        state = .initialized

        let authMethods = initializeResponse["authMethods"] as? [[String: Any]] ?? []
        let authContext = ACPAuthenticationContext(
            authMethodIDs: Self.authMethodIDs(from: authMethods),
            environment: environment
        )
        if let authMethodID = provider.preferredAuthMethodID(context: authContext) {
            log("ACP authenticate via \(authMethodID)")
            diagnose(.phaseStarted("authenticate"))
            _ = try await sendRequest(
                method: "authenticate",
                params: ["methodId": authMethodID]
            )
            diagnose(.phaseCompleted("authenticate"))
        }

        let capabilities = initializeResponse["agentCapabilities"] as? [String: Any] ?? [:]
        loadSessionSupported = capabilities["loadSession"] as? Bool ?? false

        state = .openingSession
        log("Opening ACP session")
        logSessionMCPInjection()
        let openSessionResult = try await openSession()
        // R6: the session is associated (two-writer check) before any prompt is written to it.
        try await runtimeLaunch?.associate(
            session: launchRuntimeSession,
            conversationID: openSessionResult.sessionID,
            permission: runtimePermission
        )
        sessionID = openSessionResult.sessionID
        state = .sessionOpen

        return BootstrapResult(
            sessionID: openSessionResult.sessionID,
            providerSessionIdentity: openSessionResult.providerSessionIdentity,
            loadSessionSupported: loadSessionSupported,
            didFallbackToNewSessionAfterLoadFailure: fallbackResumeSessionIDForPromptClearing != nil,
            invalidatedResumeSessionID: openSessionResult.invalidatedResumeSessionID
        )
    }

    func currentProviderSessionIdentity() -> ACPProviderSessionIdentity {
        providerSessionIdentity
    }

    func refreshProviderSessionIdentityAfterPromptInterruption() async -> ACPProviderSessionIdentity {
        providerSessionIdentity
    }

    /// Submits one prompt turn and returns when the provider answers `session/prompt` (turn end).
    /// `onSubmitted` runs once, synchronously on this actor, immediately after the request was
    /// written to the provider transport — the actual dispatch boundary — and never when building
    /// or writing the request failed.
    ///
    /// `onFailure` (O49) runs once, synchronously on this actor, before this prompt rethrows. Its
    /// argument is this prompt's own evidence that the agent received it: the agent streamed
    /// content or reasoning for it, RepoPrompt's own Stop or steer sent `session/cancel` or its own
    /// teardown was requested while it was outstanding, and no other prompt overlapped it.
    func prompt(
        _ message: AgentMessage,
        request overrideRunRequest: ACPRunRequest? = nil,
        onSubmitted: (@Sendable () -> Void)? = nil,
        onFailure: (@Sendable (_ receivedByAgent: Bool) -> Void)? = nil
    ) async throws {
        guard state == .sessionOpen || state == .promptRunning, let sessionID else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        // R6 owner operation: a prompt on a reused transport carries the scope its own request's
        // owner captured (the launch request's for the launch's own prompt), never a later one.
        let promptRuntimeOwner = overrideRunRequest?.runtimeSession ?? launchRuntimeSession
        var promptWriteOwner: AgentRuntimeLaunch?
        if runtimeManagedTransport {
            // R6 write fence before `session/prompt` (associates this attempt first); state is
            // revalidated after the await and the captured launch at the final write.
            promptWriteOwner = try await fenceRuntimeWrite(
                association: .owner(promptRuntimeOwner, permission: runtimePermission)
            )
            guard state == .sessionOpen || state == .promptRunning, self.sessionID == sessionID else {
                throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
            }
        }
        if state == .promptRunning, activePromptTurnID != nil {
            throw ControllerError.invalidState(expected: "no active prompt turn", actual: state)
        }
        suppressSessionLoadReplayUpdates = false
        let promptTurnID = UUID()
        activePromptTurnID = promptTurnID
        resetActivePromptTrace()
        // Fence: a prompt starting while another is outstanding makes both unattributable.
        let overlapsAnotherPrompt = !promptReceiptEvidenceByTurnID.isEmpty
        for outstandingTurnID in promptReceiptEvidenceByTurnID.keys {
            promptReceiptEvidenceByTurnID[outstandingTurnID]?.overlappedAnotherPrompt = true
        }
        promptReceiptEvidenceByTurnID[promptTurnID] = PromptReceiptEvidence(
            overlappedAnotherPrompt: overlapsAnotherPrompt,
            teardownGenerationAtStart: repoPromptTeardownGeneration.withLock { $0 }
        )
        state = .promptRunning
        log("Submitting ACP prompt")
        diagnose(.phaseStarted("prompt"))
        let response: [String: Any]
        do {
            let promptRequest = effectivePromptRunRequest(override: overrideRunRequest)
            let promptBlocks = try provider.buildPromptBlocks(for: message, request: promptRequest)
            #if DEBUG
                if isRawACPCaptureEnabled {
                    capturePromptTraceEvent(
                        kind: "session.prompt.start",
                        payload: [
                            "sessionId": sessionID,
                            "promptTurnID": promptTurnID.uuidString,
                            "modelString": promptRequest.modelString ?? "default",
                            "sessionModeID": promptRequest.sessionModeID ?? "",
                            "workspacePath": promptRequest.workspacePath ?? "",
                            "prompt": promptTraceSummary(for: promptBlocks)
                        ]
                    )
                }
            #endif
            response = try await sendRequestResponse(
                method: "session/prompt",
                params: [
                    "sessionId": sessionID,
                    "prompt": promptBlocks
                ],
                fence: .alreadyFenced(promptWriteOwner),
                onWritten: onSubmitted
            ).result
            #if DEBUG
                if isRawACPCaptureEnabled {
                    capturePromptTraceEvent(
                        kind: "session.prompt.response",
                        payload: [
                            "sessionId": sessionID,
                            "promptTurnID": promptTurnID.uuidString,
                            "response": response,
                            "observedSessionUpdates": promptTraceCountersPayload()
                        ]
                    )
                }
            #endif
        } catch {
            #if DEBUG
                if isRawACPCaptureEnabled {
                    capturePromptTraceEvent(
                        kind: "session.prompt.error",
                        payload: [
                            "sessionId": sessionID,
                            "promptTurnID": promptTurnID.uuidString,
                            "error": displayText(for: provider.normalizeError(error)),
                            "observedSessionUpdates": promptTraceCountersPayload()
                        ]
                    )
                }
            #endif
            let evidence = promptReceiptEvidenceByTurnID.removeValue(forKey: promptTurnID)
            let teardownGeneration = repoPromptTeardownGeneration.withLock { $0 }
            onFailure?(evidence?.provesReceipt(teardownGeneration: teardownGeneration) ?? false)
            settlePromptTurn(promptTurnID, result: .failure(error))
            if error is CancellationError {
                throw error
            }
            let message = displayText(for: provider.normalizeError(error))
            if case ControllerError.requestTimedOut = error {
                emit(.stream(AIStreamResult(type: "error", text: message)))
                log("ACP prompt request timed out; cancelling prompt")
            } else {
                log("ACP prompt request failed; cancelling prompt: \(message)")
            }
            emitTerminal(state: .failed, errorText: message)
            if state != .closing, state != .closed {
                state = .failed
            }
            await cancelPrompt()
            throw error
        }
        diagnose(.phaseCompleted("prompt"))
        promptReceiptEvidenceByTurnID.removeValue(forKey: promptTurnID)
        let stopReason = response["stopReason"] as? String
        // The stderr consumer task may not have processed pending stderr lines
        // before the JSON-RPC response unblocks sendRequest. Yield to let the
        // actor drain pending stderr so openCodeEmptyPromptDiagnosticMessage
        // sees the error line.
        await Task.yield()
        if let diagnosticMessage = openCodeEmptyPromptDiagnosticMessage(from: response, stopReason: stopReason) {
            #if DEBUG
                if isRawACPCaptureEnabled {
                    capturePromptTraceEvent(
                        kind: "session.prompt.empty_content",
                        payload: [
                            "sessionId": sessionID,
                            "promptTurnID": promptTurnID.uuidString,
                            "diagnostic": diagnosticMessage,
                            "response": response,
                            "observedSessionUpdates": promptTraceCountersPayload()
                        ]
                    )
                }
            #endif
            emit(.stream(AIStreamResult(type: "final_content", text: diagnosticMessage)))
        }
        emit(.stream(messageStopResult(from: response, sessionID: sessionID, stopReason: stopReason)))
        emitTerminal(
            state: terminalState(for: stopReason),
            errorText: terminalErrorText(for: stopReason)
        )
        if state != .closing, state != .closed {
            state = .sessionOpen
        }
        settlePromptTurn(promptTurnID, result: .success(()))
    }

    package func setSessionModel(_ rawModel: String) async throws {
        try await setSessionSelection(model: rawModel, additionalOptions: [])
    }

    func setSessionSelection(
        model rawModel: String,
        additionalOptions: [ACPConfigOptionAssignment]
    ) async throws {
        try await configurationMutationMutex.withLock { [weak self] in
            guard let self else { throw CancellationError() }
            try ACPConfigOptionAssignment.validate(additionalOptions, for: provider.providerID)
            try await setSessionSelectionSerialized(
                model: rawModel,
                additionalOptions: additionalOptions
            )
        }
    }

    private func setSessionSelectionSerialized(
        model rawModel: String,
        additionalOptions: [ACPConfigOptionAssignment]
    ) async throws {
        guard let sessionID else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty || model.lowercased() == "default" {
            guard additionalOptions.isEmpty else {
                throw ControllerError.requestFailed(
                    "Internal configuration error: Oh My Pi thinking requires an explicit model selection."
                )
            }
            return
        }
        guard state == .sessionOpen || state == .promptRunning else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }

        switch provider.providerID {
        case .openCode:
            if let sessionModelFailureReason {
                throw ControllerError.protocolViolation("malformed modern model config option: \(sessionModelFailureReason)")
            }
            guard let sessionModelConfigOptionID else {
                throw ControllerError.requestFailed("ACP runtime does not advertise model switching through configOptions.")
            }
            guard let mappedConfigValue = sessionModelConfigValue(forSelectedModel: model) else {
                throw ControllerError.requestFailed("ACP runtime does not advertise a safe config value for selected model '\(model)'.")
            }
            let configValue = try canonicalSessionModelValue(mappedConfigValue)
            if configValue != model {
                log("Mapping selected model \(model) to ACP config value \(configValue)")
            }
            if discoveredSessionModels?.currentModelRaw == configValue {
                return
            }
            let response = try await sendRequestResponse(
                method: "session/set_config_option",
                params: [
                    "sessionId": sessionID,
                    "configId": sessionModelConfigOptionID,
                    "value": configValue
                ]
            )
            try await applyVerifiedConfigOptionsMutationResponse(
                response,
                requiredModeValue: nil,
                requiredModelValue: configValue
            )

        case .ohMyPi:
            if let sessionModelFailureReason {
                throw ControllerError.protocolViolation("malformed modern model config option: \(sessionModelFailureReason)")
            }
            guard let sessionModelConfigOptionID else {
                throw ControllerError.requestFailed("ACP runtime does not advertise model switching through configOptions.")
            }
            try await setOhMyPiSessionSelectionSerialized(
                model: model,
                additionalOptions: additionalOptions,
                sessionID: sessionID,
                modelConfigID: sessionModelConfigOptionID
            )

        case .cursor:
            if let sessionModelFailureReason {
                throw ControllerError.protocolViolation("malformed modern model config option: \(sessionModelFailureReason)")
            }
            if normalizedCursorModelAlias(model) == AgentModel.cursorAuto.rawValue,
               sessionModelConfigOptionID == nil
            {
                return
            }
            guard let sessionModelConfigOptionID else {
                throw ControllerError.requestFailed("ACP runtime does not advertise model switching through configOptions.")
            }
            try await setCursorSessionModelSerialized(
                model,
                sessionID: sessionID,
                modelConfigID: sessionModelConfigOptionID
            )
        }
    }

    private func setOhMyPiSessionSelectionSerialized(
        model: String,
        additionalOptions: [ACPConfigOptionAssignment],
        sessionID: String,
        modelConfigID: String
    ) async throws {
        guard let mappedConfigValue = sessionModelConfigValue(forSelectedModel: model) else {
            throw ControllerError.requestFailed(
                "ACP runtime does not advertise a safe config value for selected model '\(model)'."
            )
        }
        let targetModel = try canonicalSessionModelValue(mappedConfigValue)
        if targetModel != model {
            log("Mapping selected model \(model) to ACP config value \(targetModel)")
        }

        let requestedThinking = additionalOptions.first {
            $0.key == .ohMyPiThinking
        }
        let previousModel = discoveredSessionModels?.currentModelRaw
        let previousThinking = try? resolvedOhMyPiThinkingSelector()
        var targetThinkingBeforeMutation: AuxiliarySelectorSnapshot?
        var didAttemptModelMutation = false
        var didAttemptThinkingMutation = false

        do {
            try Task.checkCancellation()

            if previousModel != targetModel {
                didAttemptModelMutation = true
                let response = try await sendRequestResponse(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": sessionID,
                        "configId": modelConfigID,
                        "value": targetModel
                    ]
                )
                try await applyVerifiedConfigOptionsMutationResponse(
                    response,
                    requiredModeValue: nil,
                    requiredModelValue: targetModel
                )
                try Task.checkCancellation()
            }

            guard let requestedThinking else {
                try Task.checkCancellation()
                return
            }

            let selector = try resolvedOhMyPiThinkingSelector()
            targetThinkingBeforeMutation = selector
            guard selector.values.contains(requestedThinking.value) else {
                throw ControllerError.requestFailed(
                    "Oh My Pi model '\(targetModel)' does not advertise thinking value '\(requestedThinking.value)'. Advertised choices: \(selector.values.joined(separator: ", "))."
                )
            }
            if selector.currentValue == requestedThinking.value {
                try Task.checkCancellation()
                return
            }

            didAttemptThinkingMutation = true
            let response = try await sendRequestResponse(
                method: "session/set_config_option",
                params: [
                    "sessionId": sessionID,
                    "configId": selector.configID,
                    "value": requestedThinking.value
                ]
            )
            try await applyVerifiedConfigOptionsMutationResponse(
                response,
                requiredModeValue: nil,
                requiredModelValue: targetModel,
                requiredSelectValue: (
                    configID: selector.configID,
                    value: requestedThinking.value
                )
            )
            try Task.checkCancellation()

            guard discoveredSessionModels?.currentModelRaw == targetModel,
                  auxiliarySelectors[selector.configID]?.currentValue == requestedThinking.value
            else {
                throw ControllerError.protocolViolation(
                    "final Oh My Pi configuration does not confirm model '\(targetModel)' and thinking '\(requestedThinking.value)'"
                )
            }
        } catch {
            let originalError = error
            let rollbackFailures = await rollbackOhMyPiSelection(
                sessionID: sessionID,
                modelConfigID: modelConfigID,
                previousModel: previousModel,
                previousThinking: previousThinking,
                targetModel: targetModel,
                targetThinkingBeforeMutation: targetThinkingBeforeMutation,
                didAttemptModelMutation: didAttemptModelMutation,
                didAttemptThinkingMutation: didAttemptThinkingMutation
            )
            guard !rollbackFailures.isEmpty else {
                throw originalError
            }
            throw ControllerError.requestFailed(
                "\(originalError.localizedDescription); Oh My Pi may retain partial configuration: \(rollbackFailures.joined(separator: "; "))"
            )
        }
    }

    private func rollbackOhMyPiSelection(
        sessionID: String,
        modelConfigID: String,
        previousModel: String?,
        previousThinking: AuxiliarySelectorSnapshot?,
        targetModel: String,
        targetThinkingBeforeMutation: AuxiliarySelectorSnapshot?,
        didAttemptModelMutation: Bool,
        didAttemptThinkingMutation: Bool
    ) async -> [String] {
        var failures: [String] = []

        if didAttemptThinkingMutation,
           discoveredSessionModels?.currentModelRaw == targetModel,
           let targetThinkingBeforeMutation
        {
            do {
                let selector = try resolvedOhMyPiThinkingSelector()
                guard selector.values.contains(targetThinkingBeforeMutation.currentValue) else {
                    throw ControllerError.requestFailed(
                        "thinking value '\(targetThinkingBeforeMutation.currentValue)' is no longer advertised"
                    )
                }
                let response = try await sendRequestResponse(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": sessionID,
                        "configId": selector.configID,
                        "value": targetThinkingBeforeMutation.currentValue
                    ]
                )
                try await applyVerifiedConfigOptionsMutationResponse(
                    response,
                    requiredModeValue: nil,
                    requiredModelValue: targetModel,
                    requiredSelectValue: (
                        configID: selector.configID,
                        value: targetThinkingBeforeMutation.currentValue
                    )
                )
            } catch {
                failures.append(
                    "thinking=\(targetThinkingBeforeMutation.currentValue) for model \(targetModel) (restore failed: \(error.localizedDescription))"
                )
            }
        }

        if didAttemptModelMutation, let previousModel {
            do {
                let response = try await sendRequestResponse(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": sessionID,
                        "configId": modelConfigID,
                        "value": previousModel
                    ]
                )
                try await applyVerifiedConfigOptionsMutationResponse(
                    response,
                    requiredModeValue: nil,
                    requiredModelValue: previousModel
                )
            } catch {
                failures.append(
                    "model=\(targetModel) (restore to \(previousModel) failed: \(error.localizedDescription))"
                )
            }
        }

        if didAttemptModelMutation,
           let previousModel,
           discoveredSessionModels?.currentModelRaw == previousModel,
           let previousThinking
        {
            do {
                let selector = try resolvedOhMyPiThinkingSelector()
                guard selector.values.contains(previousThinking.currentValue) else {
                    throw ControllerError.requestFailed(
                        "thinking value '\(previousThinking.currentValue)' is no longer advertised"
                    )
                }
                if selector.currentValue != previousThinking.currentValue {
                    let response = try await sendRequestResponse(
                        method: "session/set_config_option",
                        params: [
                            "sessionId": sessionID,
                            "configId": selector.configID,
                            "value": previousThinking.currentValue
                        ]
                    )
                    try await applyVerifiedConfigOptionsMutationResponse(
                        response,
                        requiredModeValue: nil,
                        requiredModelValue: previousModel,
                        requiredSelectValue: (
                            configID: selector.configID,
                            value: previousThinking.currentValue
                        )
                    )
                }
            } catch {
                failures.append(
                    "thinking=\(previousThinking.currentValue) for model \(previousModel) (restore failed: \(error.localizedDescription))"
                )
            }
        }

        return failures
    }

    private func setCursorSessionModelSerialized(
        _ model: String,
        sessionID: String,
        modelConfigID: String
    ) async throws {
        let availableValues = discoveredSessionModels?.options.map(\.rawValue) ?? []
        guard !availableValues.isEmpty else {
            throw ControllerError.protocolViolation("modern model selector has no advertised values")
        }

        if let advertisedValue = canonicalAdvertisedValue(model, in: availableValues) {
            try await applyCursorModelValueIfNeeded(
                advertisedValue,
                sessionID: sessionID,
                modelConfigID: modelConfigID
            )
            if CursorBracketModelID.parse(model)?.hasBracket == false {
                surfaceCursorEffectiveParametersForBareSelection()
            }
            return
        }

        guard let parsed = CursorBracketModelID.parse(model) else {
            throw ControllerError.requestFailed("Malformed Cursor model selection '\(model)'.")
        }

        guard parsed.hasBracket else {
            guard let mappedConfigValue = sessionModelConfigValue(forSelectedModel: parsed.base) else {
                throw ControllerError.requestFailed("ACP runtime does not advertise a safe config value for selected model '\(model)'.")
            }
            let configValue = try canonicalSessionModelValue(mappedConfigValue)
            if configValue != model {
                log("Mapping selected model \(model) to ACP config value \(configValue)")
            }
            try await applyCursorModelValueIfNeeded(
                configValue,
                sessionID: sessionID,
                modelConfigID: modelConfigID
            )
            surfaceCursorEffectiveParametersForBareSelection()
            return
        }

        guard let mappedBaseValue = sessionModelConfigValue(forSelectedModel: parsed.base) else {
            throw ControllerError.requestFailed("ACP runtime does not advertise a safe config value for selected Cursor model base '\(parsed.base)'.")
        }
        let cleanModelValue = try canonicalSessionModelValue(mappedBaseValue)
        if CursorBracketModelID.parse(cleanModelValue)?.hasBracket == true {
            throw ControllerError.requestFailed("This cursor-agent version does not support parameter selection; only its advertised default model configurations can be used.")
        }
        if cleanModelValue != parsed.base {
            log("Mapping selected Cursor model base \(parsed.base) to ACP config value \(cleanModelValue)")
        }

        let previousModelValue = discoveredSessionModels?.currentModelRaw
        let shouldRestoreModel = previousModelValue != nil && previousModelValue != cleanModelValue
        try await applyCursorModelValueIfNeeded(
            cleanModelValue,
            sessionID: sessionID,
            modelConfigID: modelConfigID
        )

        var rollbacks: [AuxiliarySelectorRollback] = []
        do {
            let orderedParameters = parsed.params.filter { $0.key.lowercased() != "fast" }
                + parsed.params.filter { $0.key.lowercased() == "fast" }
            for parameter in orderedParameters {
                guard let selector = auxiliarySelectors[parameter.key] else {
                    throw ControllerError.requestFailed("Cursor model '\(cleanModelValue)' does not advertise parameter selector '\(parameter.key)'.")
                }
                guard selector.values.contains(parameter.value) else {
                    throw ControllerError.requestFailed("Invalid value '\(parameter.value)' for Cursor parameter '\(parameter.key)'. Valid values: \(selector.values.joined(separator: ", ")).")
                }
            }

            for parameter in orderedParameters {
                guard let selector = auxiliarySelectors[parameter.key] else {
                    throw ControllerError.protocolViolation("Cursor parameter selector '\(parameter.key)' disappeared during model configuration")
                }
                if selector.currentValue == parameter.value {
                    continue
                }
                let rollback = AuxiliarySelectorRollback(
                    configID: parameter.key,
                    previousValue: selector.currentValue,
                    requestedValue: parameter.value
                )
                rollbacks.append(rollback)
                do {
                    let response = try await sendRequestResponse(
                        method: "session/set_config_option",
                        params: [
                            "sessionId": sessionID,
                            "configId": parameter.key,
                            "value": parameter.value
                        ]
                    )
                    try await applyVerifiedConfigOptionsMutationResponse(
                        response,
                        requiredModeValue: nil,
                        requiredModelValue: nil,
                        requiredSelectValue: (configID: parameter.key, value: parameter.value)
                    )
                } catch let controllerError as ControllerError {
                    if case .requestFailed = controllerError {
                        rollbacks.removeLast()
                    }
                    throw controllerError
                }
            }

            guard discoveredSessionModels?.currentModelRaw == cleanModelValue else {
                throw ControllerError.protocolViolation("final Cursor configuration no longer confirms requested model '\(cleanModelValue)'")
            }
            for parameter in orderedParameters {
                guard auxiliarySelectors[parameter.key]?.currentValue == parameter.value else {
                    throw ControllerError.protocolViolation("final Cursor configuration does not confirm requested value '\(parameter.value)' for selector '\(parameter.key)'")
                }
            }
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []
            for rollback in rollbacks.reversed() {
                do {
                    let response = try await sendRequestResponse(
                        method: "session/set_config_option",
                        params: [
                            "sessionId": sessionID,
                            "configId": rollback.configID,
                            "value": rollback.previousValue
                        ]
                    )
                    try await applyVerifiedConfigOptionsMutationResponse(
                        response,
                        requiredModeValue: nil,
                        requiredModelValue: nil,
                        requiredSelectValue: (configID: rollback.configID, value: rollback.previousValue)
                    )
                } catch {
                    rollbackFailures.append(
                        "\(rollback.configID)=\(rollback.requestedValue) (restore to \(rollback.previousValue) failed: \(error.localizedDescription))"
                    )
                }
            }
            if shouldRestoreModel, let previousModelValue {
                do {
                    try await applyCursorModelValueIfNeeded(
                        previousModelValue,
                        sessionID: sessionID,
                        modelConfigID: modelConfigID
                    )
                } catch {
                    rollbackFailures.append(
                        "model=\(cleanModelValue) (restore to \(previousModelValue) failed: \(error.localizedDescription))"
                    )
                }
            }
            guard !rollbackFailures.isEmpty else {
                throw originalError
            }
            throw ControllerError.requestFailed(
                "\(originalError.localizedDescription); cursor-agent may retain partial model configuration: \(rollbackFailures.joined(separator: "; "))"
            )
        }
    }

    private func applyCursorModelValueIfNeeded(
        _ configValue: String,
        sessionID: String,
        modelConfigID: String
    ) async throws {
        if discoveredSessionModels?.currentModelRaw == configValue {
            return
        }
        let response = try await sendRequestResponse(
            method: "session/set_config_option",
            params: [
                "sessionId": sessionID,
                "configId": modelConfigID,
                "value": configValue
            ]
        )
        try await applyVerifiedConfigOptionsMutationResponse(
            response,
            requiredModeValue: nil,
            requiredModelValue: configValue
        )
    }

    private func surfaceCursorEffectiveParametersForBareSelection() {
        guard !auxiliarySelectors.isEmpty else { return }
        let orderedIDs = auxiliarySelectors.keys.filter { $0.lowercased() != "fast" }.sorted()
            + auxiliarySelectors.keys.filter { $0.lowercased() == "fast" }.sorted()
        let effective = orderedIDs.compactMap { configID -> String? in
            guard let selector = auxiliarySelectors[configID] else { return nil }
            return "\(configID)=\(selector.currentValue)"
        }
        diagnose(.info("Cursor bare-base model selection inherited effective parameters: \(effective.joined(separator: ", "))."))
        if auxiliarySelectors["fast"]?.currentValue == "true" {
            emit(.stream(AIStreamResult(
                type: "system",
                text: "Cursor Fast mode is enabled for this bare-base model selection (effective fast=true)."
            )))
        }
    }

    func setSessionMode(_ modeID: String) async throws {
        try await configurationMutationMutex.withLock { [weak self] in
            guard let self else { throw CancellationError() }
            try await setSessionModeSerialized(modeID)
        }
    }

    private func setSessionModeSerialized(_ modeID: String) async throws {
        guard let sessionID else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        let trimmedModeID = modeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModeID.isEmpty else { return }
        guard state == .sessionOpen || state == .promptRunning else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        guard let snapshot = sessionModeSnapshot else {
            if let sessionModeFailureReason {
                throw ControllerError.protocolViolation("malformed modern session mode config option: \(sessionModeFailureReason)")
            }
            if trimmedModeID.caseInsensitiveCompare("default") == .orderedSame {
                return
            }
            throw ControllerError.requestFailed("ACP runtime does not advertise a modern session mode configOptions selector.")
        }
        let canonicalModeID = try canonicalSessionModeValue(trimmedModeID, in: snapshot)
        if snapshot.currentValue == canonicalModeID {
            return
        }
        // R6 owner operation: the requested mode is persisted by the request's fence, for the scope
        // the change's owner captured, before the request is written.
        requestedSessionModeID = canonicalModeID

        let response = try await sendRequestResponse(
            method: "session/set_config_option",
            params: [
                "sessionId": sessionID,
                "configId": snapshot.configID,
                "value": canonicalModeID
            ],
            fence: .associate(.owner(AgentRuntimeOperationOwner.current, permission: runtimePermission))
        )
        try await applyVerifiedConfigOptionsMutationResponse(
            response,
            requiredModeValue: canonicalModeID,
            requiredModelValue: nil
        )
    }

    package func respondToPermissionRequest(
        id: String,
        decision: AgentApprovalDecision
    ) async {
        guard let pending = pendingPermissionRequests.removeValue(forKey: id) else {
            return
        }
        let result: [String: Any] = switch decision {
        case .cancel:
            [
                "outcome": [
                    "outcome": "cancelled"
                ]
            ]
        case .accept:
            [
                "outcome": [
                    "outcome": "selected",
                    "optionId": preferredAllowOptionID(for: pending.options, sessionScoped: false)
                ]
            ]
        case .acceptForSession, .acceptWithExecpolicyAmendment:
            [
                "outcome": [
                    "outcome": "selected",
                    "optionId": preferredAllowOptionID(for: pending.options, sessionScoped: true)
                ]
            ]
        case .decline:
            if let optionID = preferredRejectOptionID(for: pending.options) {
                [
                    "outcome": [
                        "outcome": "selected",
                        "optionId": optionID
                    ]
                ]
            } else {
                [
                    "outcome": [
                        "outcome": "cancelled"
                    ]
                ]
            }
        }

        let issuingLaunch = pending.issuingLaunch
        do {
            // A reply to the agent's own request creates no ownership: authorize only, and only on
            // the transport that issued the request.
            let writeOwner = try await fenceRuntimeWrite(association: nil)
            guard writeOwner === issuingLaunch else { throw ControllerError.processNotRunning }
            try sendJSONLine([
                "jsonrpc": "2.0",
                "id": pending.rpcID.jsonValue,
                "result": result
            ], writeOwner: writeOwner)
        } catch {
            // R6: the issuing transport was replaced (before or during the fence); the stale reply
            // is dropped and never fails the replacement's session.
            guard runtimeLaunch === issuingLaunch else {
                log("Dropped ACP approval reply \(id): its issuing transport was replaced")
                return
            }
            let message = "Failed to submit ACP approval decision: \(error.localizedDescription)"
            emit(.stream(AIStreamResult(
                type: "error",
                text: message
            )))
            failPendingRequests(with: ControllerError.requestFailed(message))
            emitTerminal(state: .failed, errorText: message)
            if state != .closing, state != .closed {
                state = .failed
            }
        }
    }

    /// O49: RepoPrompt's own Stop, window close or quit is about to cancel the run. Synchronous, so
    /// callers record it before the run task is cancelled; the prompt outstanding now (if the agent
    /// streamed for it and no other prompt overlapped it) then reports receipt when it fails.
    package nonisolated func noteRepoPromptTeardownRequested() {
        repoPromptTeardownGeneration.withLock { $0 &+= 1 }
    }

    package func cancelPrompt() async {
        guard sessionID != nil else { return }
        do {
            try sendSessionCancelNotification()
        } catch {
            log("ACP cancel send failed: \(error.localizedDescription)")
        }
        cancelPendingPermissionRequestsLocally()
    }

    #if DEBUG
        func debugPromptSettlementWaiterCount() -> Int {
            promptSettlementWaitersByTurnID.values.reduce(0) { $0 + $1.count }
        }

        /// Attaches a fixture transport (pipes, no subprocess) with an open session, so the
        /// production write fences and final writer run without a spawn.
        func debugAttachTestTransport(_ transport: SpawnedProcess, sessionID: String?) {
            process = transport
            self.sessionID = sessionID
            state = .sessionOpen
        }

        /// Attaches a fixture runtime launch to the current transport, committed or not, as a
        /// registered spawn would.
        func debugInstallTestRuntimeLaunch(_ launch: AgentRuntimeLaunch, committed: Bool) {
            runtimeLaunch = launch
            runtimeManagedTransport = true
            runtimeCommittedLaunch = committed ? launch : nil
        }

        func debugSetRuntimeFenceCheckpoint(_ checkpoint: (@Sendable (String) async -> Void)?) {
            debugRuntimeFenceCheckpoint = checkpoint
        }

        /// The production inbound `session/request_permission` handler.
        func debugHandlePermissionRequest(id: Int, params: [String: Any]) {
            handlePermissionRequest(id: .int(id), params: params)
        }

        /// The production inbound `session/update` notification handler.
        func debugHandleSessionUpdate(params: [String: Any]) {
            handleNotification(method: "session/update", params: params, inboundSequence: 0)
        }

        /// Whether a `session/prompt` is currently awaiting its response.
        func debugHasActivePromptTurn() -> Bool {
            activePromptTurnID != nil
        }

        /// Ends the active prompt's activity without answering its request, so a second prompt
        /// can start while the first is still pending (an interleaving per-prompt receipt evidence
        /// must withstand).
        func debugAbandonActivePromptTurn() {
            activePromptTurnID = nil
            state = .sessionOpen
        }

        /// Fails every pending request as `shutdown()` does after its `cancelPrompt()`, without
        /// reaping the (fixture) transport's process.
        func debugFailPendingRequestsAsTransportClosed() {
            failAllPromptSettlementWaiters(with: ControllerError.transportClosed)
            failPendingRequests(with: ControllerError.transportClosed)
        }

        /// An owner request through the production request writer and its `.associate` fence (the
        /// path `setSessionMode` uses), carrying the operation owner's scope and `permission`.
        func debugSendOwnerRequest(
            method: String,
            params: [String: Any],
            permission: AgentRuntimePermissionSnapshot,
            timeoutSeconds: TimeInterval
        ) async throws -> [String: Any] {
            try await sendRequestResponse(
                method: method,
                params: params,
                explicitTimeoutInterval: timeoutSeconds,
                fence: .associate(.owner(AgentRuntimeOperationOwner.current, permission: permission))
            ).result
        }
    #endif

    func interruptActivePromptForSteering(timeoutSeconds: TimeInterval = 15) async throws {
        guard sessionID != nil else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        log("ACP steering interrupt requested state=\(state.rawValue) hasActiveTurn=\(activePromptTurnID != nil)")

        if let promptTurnID = activePromptTurnID {
            guard state == .promptRunning || state == .sessionOpen else {
                throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
            }
            if state == .promptRunning {
                log("ACP steering interrupt sending session/cancel turn=\(promptTurnID)")
                try sendSessionCancelNotification()
            } else {
                log("ACP steering interrupt waiting stale active turn=\(promptTurnID) state=\(state.rawValue)")
            }
            cancelPendingPermissionRequestsLocally()
            try await waitForPromptSettlement(turnID: promptTurnID, timeoutSeconds: timeoutSeconds)
            if activePromptTurnID == promptTurnID {
                log("ACP steering interrupt clearing settled turn still marked active turn=\(promptTurnID) state=\(state.rawValue)")
                settlePromptTurn(promptTurnID, result: .success(()))
            }
            log("ACP steering interrupt prompt settled turn=\(promptTurnID) state=\(state.rawValue) hasActiveTurn=\(activePromptTurnID != nil)")
            guard state != .closing, state != .closed else {
                throw ControllerError.transportClosed
            }
            resetPerTurnStateForSteeringPrompt()
            if state == .promptRunning {
                state = .sessionOpen
            }
            return
        }

        guard state == .sessionOpen || state == .promptRunning else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        if state == .promptRunning {
            log("ACP steering interrupt found promptRunning without active turn; resetting state for steering")
            state = .sessionOpen
        } else {
            log("ACP steering interrupt skipped; controller already sessionOpen")
        }
        resetPerTurnStateForSteeringPrompt()
    }

    private func sendSessionCancelNotification() throws {
        guard let sessionID else { return }
        try sendJSONLine([
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": [
                "sessionId": sessionID
            ]
        ])
        // Recorded only after the notification was written.
        if let activePromptTurnID {
            promptReceiptEvidenceByTurnID[activePromptTurnID]?.cancelledByClient = true
        }
    }

    private func cancelPendingPermissionRequestsLocally() {
        let pending = pendingPermissionRequests.values
        pendingPermissionRequests.removeAll()
        for request in pending {
            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "id": request.rpcID.jsonValue,
                    "result": [
                        "outcome": [
                            "outcome": "cancelled"
                        ]
                    ]
                ])
            } catch {
                log("Failed to cancel ACP permission request \(request.rpcID.displayValue): \(error.localizedDescription)")
            }
            emit(.approvalCancelled(request.request.requestID))
        }
    }

    private func resetPerTurnStateForSteeringPrompt() {
        didEmitTerminal = false
        eventStreamFinished = false
        suppressSessionLoadReplayUpdates = false
    }

    private func waitForPromptSettlement(turnID: UUID, timeoutSeconds: TimeInterval) async throws {
        guard activePromptTurnID == turnID else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw ControllerError.transportClosed }
                try await waitForPromptSettlement(turnID: turnID)
            }
            group.addTask { [launchDescription, diagnosticHint = timeoutDiagnosticHint()] in
                let duration = UInt64((timeoutSeconds * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: duration)
                throw ControllerError.requestTimedOut(
                    method: "session/cancel",
                    timeoutSeconds: timeoutSeconds,
                    launchDescription: launchDescription,
                    diagnosticHint: diagnosticHint
                )
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitForPromptSettlement(turnID: UUID) async throws {
        guard activePromptTurnID == turnID else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if activePromptTurnID != turnID {
                    continuation.resume(returning: ())
                    return
                }
                promptSettlementWaitersByTurnID[turnID, default: []].append(
                    PromptSettlementWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelPromptSettlementWaiter(turnID: turnID, waiterID: waiterID) }
        }
    }

    private func cancelPromptSettlementWaiter(turnID: UUID, waiterID: UUID) {
        guard var waiters = promptSettlementWaitersByTurnID[turnID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        promptSettlementWaitersByTurnID[turnID] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func failAllPromptSettlementWaiters(with error: Error) {
        activePromptTurnID = nil
        let waiters = promptSettlementWaitersByTurnID.values.flatMap(\.self)
        promptSettlementWaitersByTurnID.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func settlePromptTurn(_ turnID: UUID, result: Result<Void, Error>) {
        if activePromptTurnID == turnID {
            activePromptTurnID = nil
        }
        let waiters = promptSettlementWaitersByTurnID.removeValue(forKey: turnID) ?? []
        for waiter in waiters {
            switch result {
            case .success:
                waiter.continuation.resume(returning: ())
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    package func shutdown() async {
        #if DEBUG
            debugResumeConfigurationMutationPostcheck()
        #endif
        guard state != .closed, state != .closing else { return }
        state = .closing
        log("Shutting down ACP controller")

        await cancelPrompt()
        failAllPromptSettlementWaiters(with: ControllerError.transportClosed)
        failPendingRequests(with: ControllerError.transportClosed)

        stdoutChannel?.finish()
        stderrChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        let waitTask = processWaitTask
        waitTask?.cancel()

        let launch = runtimeLaunch
        runtimeLaunch = nil
        if let process {
            process.stdout.readabilityHandler = nil
            process.stderr.readabilityHandler = nil
            process.stdin?.closeFile()
            let reaped = await ProcessTermination.terminateAndReapReportingRoot(
                pid: process.pid,
                processGroupID: process.processGroupID
            )
            await launch?.rootReaped(pid: process.pid, confirmed: reaped.rootReaped)
        }
        // R6: a registered launch's wait task owns a reap report too (it may be the waiter that
        // actually reaped). Join it so a successor never reserves while this launch's reap report
        // and post-reap discovery are still in flight. It is cancelled and its wait is bounded.
        if launch != nil {
            await waitTask?.value
        }

        await clearExpectedAgentPIDIfNeeded()
        await cleanupLaunchArtifacts()

        stdoutChannel = nil
        stderrChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil
        processWaitTask = nil
        process = nil
        discoveredSessionModels = nil
        sessionModelConfigOptionID = nil
        sessionModelFailureReason = nil
        sessionModeSnapshot = nil
        sessionModeFailureReason = nil
        auxiliarySelectors.removeAll()
        authoritativeConfigOptions.removeAll()
        lastAppliedConfigurationSequence = 0
        bufferedConfigOptionUpdates.removeAll()
        sessionID = nil
        suppressSessionLoadReplayUpdates = false
        state = .closed
        finishEventsIfNeeded()
    }

    // MARK: - Transport

    private func startReaders(stdout: FileHandle, stderr: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(stdout.fileDescriptor, label: "ACP stdout")
        try ReadSourceFDPreflight.validateOpenFD(stderr.fileDescriptor, label: "ACP stderr")
        let stdoutChannel = FileHandleChunkChannel()
        self.stdoutChannel = stdoutChannel
        stdout.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                stdoutChannel.finish()
                readable.readabilityHandler = nil
            } else {
                stdoutChannel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in stdoutChannel.stream {
                await handleStdoutChunk(chunk)
            }
        }

        let stderrChannel = FileHandleChunkChannel()
        self.stderrChannel = stderrChannel
        stderr.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                stderrChannel.finish()
                readable.readabilityHandler = nil
            } else {
                stderrChannel.yield(data)
            }
        }
        stderrConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in stderrChannel.stream {
                await handleStderrChunk(chunk)
            }
        }
    }

    private func startProcessWaitTask(for process: SpawnedProcess, launch: AgentRuntimeLaunch?) {
        processWaitTask = Task { [weak self] in
            guard let self else { return }
            let result = try? await ProcessTermination.waitForTerminationReportingRoot(
                pid: process.pid,
                processGroupID: process.processGroupID,
                timeout: nil
            )
            // Captured launch event: the exact root this task waited on, whatever the controller
            // holds now; confirmed only when this wait itself reaped it.
            await launch?.rootReaped(pid: process.pid, confirmed: result?.rootReaped ?? false)
            await handleProcessExit(result?.exitCode ?? 0, timedOut: result?.timedOut ?? false)
        }
    }

    private func handleStdoutChunk(_ data: Data) {
        stdoutByteCount += data.count
        stdoutFramer.feed(data) { lineData in
            handleJSONLine(lineData)
        }
    }

    private func handleStderrChunk(_ data: Data) {
        stderrFramer.feed(data) { lineData in
            guard
                let trimmed = trimmedASCIIWhitespace(lineData),
                let text = String(data: trimmed, encoding: .utf8),
                !text.isEmpty
            else { return }
            stderrLineCount += 1
            lastStderrPreview = Self.truncatedDiagnosticPreview(text)
            recordActivePromptStderrLine(text)
            diagnose(.stderrLine(text))
            #if DEBUG
                captureFragmentDiagnosticIfEnabled(
                    source: "stderr",
                    streamType: "system",
                    sampleSource: text,
                    plainLength: text.count,
                    thoughtLength: 0,
                    sourceSessionUpdate: nil
                )
            #endif
            emit(.stream(AIStreamResult(type: "system", text: text)))
        }
    }

    private func handleJSONLine(_ lineData: Data) {
        guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return }
        let rawLine = String(data: trimmed, encoding: .utf8) ?? "<non-utf8>"
        stdoutLineCount += 1
        lastStdoutPreview = Self.truncatedDiagnosticPreview(rawLine)
        diagnose(.inboundJSON(rawLine))
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            let preview = String(data: trimmed.prefix(300), encoding: .utf8) ?? "<non-utf8>"
            invalidACPLineCount += 1
            lastInvalidACPLinePreview = Self.truncatedDiagnosticPreview(preview)
            diagnose(.invalidJSON(preview))
            handleProtocolViolation("Invalid ACP JSON line: \(preview)")
            return
        }
        #if DEBUG
            captureRawACPEvent(kind: "jsonrpc.inbound", payload: json)
        #endif
        inboundMessageSequence &+= 1
        let messageSequence = inboundMessageSequence

        if let id = parseJSONRPCID(json["id"]) {
            if let method = json["method"] as? String {
                handleServerRequest(id: id, method: method, params: json["params"] as? [String: Any] ?? [:])
                return
            }
            for storageKey in candidateStorageKeys(for: id) {
                guard let pendingRequest = pendingRequests.removeValue(forKey: storageKey) else { continue }
                pendingRequest.timeoutTask?.cancel()
                if let result = json["result"] {
                    switch pendingRequest.continuation {
                    case let .object(continuation):
                        guard let objectResult = result as? [String: Any] else {
                            continuation.resume(throwing: ControllerError.protocolViolation("Missing result/error for request \(id.displayValue)"))
                            return
                        }
                        continuation.resume(returning: RequestResponse(
                            result: objectResult,
                            inboundSequence: messageSequence
                        ))
                    case let .raw(continuation):
                        continuation.resume(returning: result)
                    }
                } else if let error = json["error"] as? [String: Any] {
                    let message = Self.responseErrorMessage(from: error)
                    let code = Self.responseErrorCode(from: error)
                    let codeText = code.map { " code=\($0)" } ?? ""
                    diagnose(.info("ACP request \(pendingRequest.method) failed\(codeText): \(message)"))
                    pendingRequest.continuation.resume(throwing: ControllerError.requestFailed(message, code: code))
                } else {
                    pendingRequest.continuation.resume(throwing: ControllerError.protocolViolation("Missing result/error for request \(id.displayValue)"))
                }
                return
            }
            diagnose(.unmatchedResponse(id: id.displayValue, line: rawLine))
            handleProtocolViolation("Received unmatched ACP response id \(id.displayValue).")
        }

        if let method = json["method"] as? String {
            handleNotification(
                method: method,
                params: json["params"] as? [String: Any] ?? [:],
                inboundSequence: messageSequence
            )
        }
    }

    private func handleServerRequest(id: JSONRPCID, method: String, params: [String: Any]) {
        switch method {
        case "session/request_permission":
            handlePermissionRequest(id: id, params: params)
        default:
            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "id": id.jsonValue,
                    "error": [
                        "code": -32601,
                        "message": "Unsupported ACP client method: \(method)"
                    ]
                ])
            } catch {
                log("Failed to reject unsupported ACP request \(method): \(error.localizedDescription)")
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any], inboundSequence: UInt64) {
        guard method == "session/update" else { return }
        #if DEBUG
            captureRawACPEvent(
                kind: "session.update.params",
                payload: [
                    "method": method,
                    "params": params
                ]
            )
        #endif
        guard let update = params["update"] as? [String: Any] else { return }
        let sessionID = (params["sessionId"] as? String) ?? sessionID ?? ""
        #if DEBUG
            captureRawACPEvent(
                kind: "session.update.raw",
                payload: [
                    "sessionId": sessionID,
                    "update": update
                ]
            )
        #endif

        if update["sessionUpdate"] as? String == "config_option_update" {
            handleConfigOptionUpdateNotification(
                paramsSessionID: params["sessionId"] as? String,
                update: update,
                inboundSequence: inboundSequence
            )
            return
        }

        if shouldSuppressSessionLoadReplayUpdate(update) {
            #if DEBUG
                captureRawACPEvent(
                    kind: "session.update.suppressed",
                    payload: [
                        "sessionId": sessionID,
                        "reason": "session_load_replay",
                        "update": update
                    ]
                )
            #endif
            return
        }

        let normalizedEvents = provider.normalizeSessionUpdate(update, sessionID: sessionID)
        #if DEBUG
            captureNormalizedACPEvents(normalizedEvents, sessionID: sessionID, sourceUpdate: update)
            captureFragmentDiagnosticsIfEnabled(normalizedEvents, sourceUpdate: update)
        #endif
        recordActivePromptTraceUpdate(sourceUpdate: update, normalizedEvents: normalizedEvents)
        for event in normalizedEvents {
            if shouldSuppressACPEvent(event) {
                continue
            }
            emit(event)
        }
    }

    private func shouldSuppressACPEvent(_: NormalizedAgentRuntimeEvent) -> Bool {
        false
    }

    private func shouldSuppressSessionLoadReplayUpdate(_ update: [String: Any]) -> Bool {
        guard suppressSessionLoadReplayUpdates,
              let sessionUpdate = (update["sessionUpdate"] as? String)?.lowercased()
        else {
            return false
        }
        switch sessionUpdate {
        case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "session_info_update", "available_commands_update", "plan", "usage_update":
            return true
        default:
            return false
        }
    }

    private func handlePermissionRequest(id: JSONRPCID, params: [String: Any]) {
        guard
            let sessionID = params["sessionId"] as? String,
            let toolCall = params["toolCall"] as? [String: Any]
        else {
            return
        }

        let toolCallID = (toolCall["toolCallId"] as? String) ?? UUID().uuidString
        let toolTitle = (toolCall["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolKind = (toolCall["kind"] as? String)?.lowercased()
        let rawInputJSON = serializeJSON(toolCall["rawInput"])
        let optionDictionaries = params["options"] as? [[String: Any]] ?? []
        let options = optionDictionaries.compactMap { optionDictionary -> PermissionOption? in
            guard
                let optionID = optionDictionary["optionId"] as? String,
                let kind = optionDictionary["kind"] as? String
            else { return nil }
            return PermissionOption(optionID: optionID, kind: kind)
        }

        let rawInput = toolCall["rawInput"] as? [String: Any]
        let requestToolName = Self.repoPromptPermissionRequestToolName(
            toolCall: toolCall,
            toolTitle: toolTitle
        )
        let autoApprovalPayload = Self.repoPromptPermissionAutoApprovalPayload(
            toolTitle: toolTitle,
            toolKind: toolKind,
            toolCall: toolCall,
            rawInput: rawInput,
            options: optionDictionaries
        )
        let request = AgentApprovalRequest(
            requestID: .acp(id.displayValue),
            method: "session/request_permission",
            kind: approvalKind(for: toolKind),
            threadID: sessionID,
            turnID: sessionID,
            itemID: toolCallID,
            reason: toolTitle,
            command: rawInputJSON,
            cwd: sessionConfiguration.workingDirectory,
            details: approvalDetails(
                toolTitle: toolTitle,
                toolKind: toolKind,
                rawInputJSON: rawInputJSON,
                options: optionDictionaries
            )
        )

        if let autoApproval = autoApprovalSelection(
            requestToolName: requestToolName,
            requestPayload: autoApprovalPayload,
            options: options
        ) {
            do {
                try sendPermissionSelectionResponse(id: id, optionID: autoApproval.optionID)
                log("Auto-approved ACP permission request for \(toolTitle ?? toolCallID) via option \(autoApproval.optionID) matchSource=\(autoApproval.match.source.rawValue) normalizedTool=\(autoApproval.match.normalizedToolName ?? "nil") serverIdentifier=\(autoApproval.match.serverIdentifier ?? "nil")")
                return
            } catch {
                log("Failed to auto-approve ACP permission request for \(toolTitle ?? toolCallID): \(error.localizedDescription)")
            }
        }

        if let fullAccessOptionID = fullAccessAutoApprovalOptionID(for: options) {
            do {
                try sendPermissionSelectionResponse(id: id, optionID: fullAccessOptionID)
                log("Auto-approved ACP permission request for \(toolTitle ?? toolCallID) via \(provider.providerID.rawValue) full access option \(fullAccessOptionID)")
                return
            } catch {
                log("Failed to auto-approve ACP permission request for \(toolTitle ?? toolCallID) via \(provider.providerID.rawValue) full access: \(error.localizedDescription)")
            }
        }

        pendingPermissionRequests[id.displayValue] = PendingPermissionRequest(
            rpcID: id,
            options: options,
            request: request,
            issuingLaunch: runtimeLaunch
        )
        emit(.approvalRequested(request))
    }

    private func handleProcessExit(_ exitCode: Int32, timedOut: Bool) async {
        guard state != .closing, state != .closed else {
            finishEventsIfNeeded()
            return
        }
        providerProcessExitedUnexpectedly = true

        if state == .promptRunning || !didEmitTerminal {
            let message = timedOut
                ? "ACP process timed out."
                : "ACP process exited unexpectedly with code \(exitCode)."
            emit(.stream(AIStreamResult(type: "error", text: message)))
            emitTerminal(state: .failed, errorText: message)
        }

        failAllPromptSettlementWaiters(with: ControllerError.transportClosed)
        failPendingRequests(with: ControllerError.transportClosed)
        state = .failed
        await clearExpectedAgentPIDIfNeeded()
        await cleanupLaunchArtifacts()
        finishEventsIfNeeded()
    }

    private func registerExpectedAgentPIDIfNeeded(_ pid: pid_t) async {
        guard let clientName = mcpClientNameHint else { return }
        await mcpHost.registerExpectedAgentPID(
            pid,
            for: clientName,
            runID: expectedMCPRunID,
            expectedProcessExecutablePath: launchConfiguration.expectedProcessExecutablePath,
            expectedProcessExecutableIdentity: launchConfiguration.expectedProcessExecutableIdentity
        )
        registeredExpectedAgentPID = pid
        log("Registered expected MCP parent PID \(pid) for \(clientName) runID=\(expectedMCPRunID?.uuidString ?? "nil")")
    }

    private func clearExpectedAgentPIDIfNeeded() async {
        guard let registeredExpectedAgentPID, let clientName = mcpClientNameHint else { return }
        await mcpHost.clearExpectedAgentPID(registeredExpectedAgentPID, for: clientName, runID: expectedMCPRunID)
        self.registeredExpectedAgentPID = nil
        log("Cleared expected MCP parent PID for \(clientName) runID=\(expectedMCPRunID?.uuidString ?? "nil")")
    }

    // MARK: - Requests

    private func openSession() async throws -> OpenSessionResult {
        switch sessionConfiguration.mode {
        case .new:
            return try await openNewSession()
        case let .load(existingSessionID):
            guard loadSessionSupported else {
                suppressSessionLoadReplayUpdates = false
                throw ControllerError.requestFailed("ACP runtime does not support session/load for existing session \(existingSessionID).")
            }
            do {
                suppressSessionLoadReplayUpdates = true
                defer { suppressSessionLoadReplayUpdates = false }
                beginOpeningSessionConfiguration()
                log("Starting ACP session/load mcpServers=\(sessionConfiguration.mcpServers.count)")
                diagnose(.phaseStarted("session/load"))
                let requestResponse = try await sendRequestResponse(
                    method: "session/load",
                    params: [
                        "sessionId": existingSessionID,
                        "cwd": sessionConfiguration.workingDirectory,
                        "mcpServers": sessionConfiguration.mcpServers.map(\.acpJSONObject)
                    ]
                )
                let response = requestResponse.result
                applyOpenedSessionConfiguration(
                    from: response,
                    sessionID: existingSessionID,
                    inboundSequence: requestResponse.inboundSequence
                )
                diagnose(.phaseCompleted("session/load"))
                log("Completed ACP session/load sessionID=\(existingSessionID)")
                let identity = ACPProviderSessionIdentity(
                    providerID: provider.providerID,
                    runtimeSessionID: existingSessionID,
                    loadSessionID: existingSessionID,
                    loadSessionIDConfidence: .verified
                )
                providerSessionIdentity = identity
                return OpenSessionResult(
                    sessionID: existingSessionID,
                    providerSessionIdentity: identity,
                    invalidatedResumeSessionID: nil
                )
            } catch {
                suppressSessionLoadReplayUpdates = false
                log("ACP session/load failed for \(existingSessionID): \(error.localizedDescription)")
                if shouldFallbackToNewSessionAfterLoadFailure(error, existingSessionID: existingSessionID) {
                    fallbackResumeSessionIDForPromptClearing = existingSessionID
                    log("Falling back to ACP session/new after missing \(provider.providerID.rawValue) session \(existingSessionID)")
                    diagnose(.info("ACP session/load could not find \(provider.providerID.rawValue) session \(existingSessionID); opening a fresh session."))
                    let fresh = try await openNewSession()
                    return OpenSessionResult(
                        sessionID: fresh.sessionID,
                        providerSessionIdentity: fresh.providerSessionIdentity,
                        invalidatedResumeSessionID: existingSessionID
                    )
                }
                throw error
            }
        }
    }

    private func openNewSession() async throws -> OpenSessionResult {
        suppressSessionLoadReplayUpdates = false
        beginOpeningSessionConfiguration()
        log("Starting ACP session/new mcpServers=\(sessionConfiguration.mcpServers.count)")
        diagnose(.phaseStarted("session/new"))
        let requestResponse = try await sendRequestResponse(
            method: "session/new",
            params: [
                "cwd": sessionConfiguration.workingDirectory,
                "mcpServers": sessionConfiguration.mcpServers.map(\.acpJSONObject)
            ]
        )
        let response = requestResponse.result
        guard let sessionID = response["sessionId"] as? String else {
            throw ControllerError.protocolViolation("session/new response missing sessionId")
        }
        applyOpenedSessionConfiguration(
            from: response,
            sessionID: sessionID,
            inboundSequence: requestResponse.inboundSequence
        )
        diagnose(.phaseCompleted("session/new"))
        log("Completed ACP session/new sessionID=\(sessionID)")
        let identity = ACPProviderSessionIdentity(
            providerID: provider.providerID,
            runtimeSessionID: sessionID,
            loadSessionID: sessionID,
            loadSessionIDConfidence: .verified
        )
        providerSessionIdentity = identity
        return OpenSessionResult(
            sessionID: sessionID,
            providerSessionIdentity: identity,
            invalidatedResumeSessionID: nil
        )
    }

    private func sendRequest(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        try await sendRequestResponse(method: method, params: params).result
    }

    func sendProviderExtensionRequest(
        method: String,
        params: [String: Any],
        timeoutSeconds: TimeInterval
    ) async throws -> Any {
        guard state == .sessionOpen || state == .promptRunning else {
            throw ControllerError.invalidState(expected: "sessionOpen or promptRunning", actual: state)
        }
        guard process != nil else { throw ControllerError.processNotRunning }
        let writeOwner = try await fenceRuntimeWrite(association: nil)

        let requestID = JSONRPCID.int(nextRequestID)
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = makeRequestTimeoutTaskIfNeeded(
                for: requestID,
                method: method,
                explicitInterval: timeoutSeconds
            )
            pendingRequests[requestID.storageKey] = PendingRequest(
                method: method,
                continuation: .raw(continuation),
                timeoutTask: timeoutTask
            )
            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "id": requestID.jsonValue,
                    "method": method,
                    "params": params
                ], writeOwner: writeOwner)
            } catch {
                let pendingRequest = pendingRequests.removeValue(forKey: requestID.storageKey)
                pendingRequest?.timeoutTask?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    static func isProviderExtensionMethodNotFoundError(_ error: Error) -> Bool {
        guard case ControllerError.requestFailed(_, code: -32601) = error else { return false }
        return true
    }

    /// How a request passes the R6 write fence.
    private enum RuntimeRequestFence {
        /// Creates no ownership (bootstrap, model/thinking options, extension calls): authorize.
        case authorize
        /// An owner write (a requested permission change): associate, then authorize.
        case associate(RuntimeWriteAssociation)
        /// The caller fenced with no suspension since (`session/prompt`) and captured this launch.
        case alreadyFenced(AgentRuntimeLaunch?)
    }

    private func sendRequestResponse(
        method: String,
        params: [String: Any],
        explicitTimeoutInterval: TimeInterval? = nil,
        fence: RuntimeRequestFence = .authorize,
        onWritten: (@Sendable () -> Void)? = nil
    ) async throws -> RequestResponse {
        switch state {
        case .closing, .closed, .failed:
            throw ControllerError.transportClosed
        default:
            break
        }
        guard process != nil else { throw ControllerError.processNotRunning }
        let writeOwner: AgentRuntimeLaunch?
        switch fence {
        case let .alreadyFenced(launch):
            writeOwner = launch
        case .authorize, .associate:
            let association: RuntimeWriteAssociation? = if case let .associate(association) = fence {
                association
            } else {
                nil
            }
            writeOwner = try await fenceRuntimeWrite(association: association)
            switch state {
            case .closing, .closed, .failed:
                throw ControllerError.transportClosed
            default:
                break
            }
        }

        let requestID = JSONRPCID.int(nextRequestID)
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = makeRequestTimeoutTaskIfNeeded(
                for: requestID,
                method: method,
                explicitInterval: explicitTimeoutInterval
            )
            pendingRequests[requestID.storageKey] = PendingRequest(
                method: method,
                continuation: .object(continuation),
                timeoutTask: timeoutTask
            )
            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "id": requestID.jsonValue,
                    "method": method,
                    "params": params
                ], writeOwner: writeOwner)
                onWritten?()
            } catch {
                let pendingRequest = pendingRequests.removeValue(forKey: requestID.storageKey)
                pendingRequest?.timeoutTask?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    /// An owner write's association: the scope its owner captured and the permission it requests.
    private enum RuntimeWriteAssociation {
        case owner(AgentRuntimeSessionScope, permission: AgentRuntimePermissionSnapshot)
    }

    /// R6 fence before an awaited outgoing write. The committed launch is captured before the first
    /// suspension; an owner write (prompt, requested mode change) associates its owner-captured
    /// session and run attempt, the open session and its permission first; every write then
    /// authorizes on the open session, and the captured launch is rechecked after each suspension.
    /// Callbacks and replies pass `nil` and never associate. Returns that launch: the final
    /// synchronous `sendJSONLine` writes only while it still owns the transport, so a replacement
    /// made during any await receives zero bytes. No-op (nil) while registration is off.
    private func fenceRuntimeWrite(association: RuntimeWriteAssociation?) async throws -> AgentRuntimeLaunch? {
        guard runtimeManagedTransport else { return nil }
        guard let launch = runtimeLaunch, runtimeCommittedLaunch === launch else {
            throw ControllerError.processNotRunning
        }
        let conversationID = sessionID
        #if DEBUG
            if let checkpoint = debugRuntimeFenceCheckpoint { await checkpoint("launchCaptured") }
        #endif
        if case let .owner(session, permission) = association {
            try await launch.associate(session: session, conversationID: conversationID, permission: permission)
            #if DEBUG
                if let checkpoint = debugRuntimeFenceCheckpoint { await checkpoint("associated") }
            #endif
            guard process != nil, runtimeLaunch === launch, runtimeCommittedLaunch === launch else {
                throw ControllerError.processNotRunning
            }
        }
        try await launch.authorizeWrite(conversationID: conversationID)
        #if DEBUG
            if let checkpoint = debugRuntimeFenceCheckpoint { await checkpoint("authorized") }
        #endif
        guard process != nil, runtimeLaunch === launch, runtimeCommittedLaunch === launch else {
            throw ControllerError.processNotRunning
        }
        return launch
    }

    /// `writeOwner`: the launch a preceding fence captured and authorized; the write goes only to
    /// the transport that launch still owns.
    private func sendJSONLine(_ payload: [String: Any], writeOwner: AgentRuntimeLaunch? = nil) throws {
        guard let stdinDescriptor = process?.stdinDescriptor else {
            throw ControllerError.processNotRunning
        }
        // R6 final synchronous check: a managed transport writes only while its committed launch
        // still owns it (never before the birth commit, never after the launch was released), and
        // a fenced write only while the launch its fence captured is that owner.
        if runtimeManagedTransport || writeOwner != nil {
            guard let launch = runtimeLaunch, runtimeCommittedLaunch === launch else {
                throw ControllerError.processNotRunning
            }
            if let writeOwner, writeOwner !== launch {
                throw ControllerError.processNotRunning
            }
        }
        #if DEBUG
            captureRawACPEvent(kind: "jsonrpc.outbound", payload: payload)
        #endif
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var frame = data
        frame.append(0x0A)
        if let line = String(data: data, encoding: .utf8) {
            diagnose(.outboundJSON(line))
        }
        try FDWriteSupport.writeAll(frame, to: stdinDescriptor)
    }

    private func failPendingRequests(with error: Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for pendingRequest in pending {
            pendingRequest.timeoutTask?.cancel()
            pendingRequest.continuation.resume(throwing: error)
        }
    }

    private func handleProtocolViolation(_ message: String) {
        emit(.stream(AIStreamResult(type: "error", text: message)))
        failPendingRequests(with: ControllerError.protocolViolation(message))
        if state == .promptRunning {
            emitTerminal(state: .failed, errorText: message)
        }
        if state != .closing, state != .closed {
            state = .failed
        }
    }

    private func requestTimeoutInterval(for method: String) -> TimeInterval? {
        switch method {
        case "initialize", "authenticate", "session/new", "session/load":
            requestTimeouts.bootstrapSeconds
        case "session/set_config_option":
            requestTimeouts.setConfigOptionSeconds
        default:
            nil
        }
    }

    private func makeRequestTimeoutTaskIfNeeded(
        for requestID: JSONRPCID,
        method: String,
        explicitInterval: TimeInterval? = nil
    ) -> Task<Void, Never>? {
        guard let timeoutSeconds = explicitInterval ?? requestTimeoutInterval(for: method),
              timeoutSeconds > 0
        else {
            return nil
        }
        return Task { [weak self] in
            let duration = UInt64((timeoutSeconds * 1_000_000_000).rounded())
            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }
            await self?.handleRequestTimeout(
                requestID: requestID,
                method: method,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private func handleRequestTimeout(
        requestID: JSONRPCID,
        method: String,
        timeoutSeconds: TimeInterval
    ) {
        for storageKey in candidateStorageKeys(for: requestID) {
            guard let pendingRequest = pendingRequests.removeValue(forKey: storageKey) else { continue }
            pendingRequest.timeoutTask?.cancel()
            let error = ControllerError.requestTimedOut(
                method: method,
                timeoutSeconds: timeoutSeconds,
                launchDescription: launchDescription,
                diagnosticHint: timeoutDiagnosticHint()
            )
            diagnose(.info(error.localizedDescription))
            pendingRequest.continuation.resume(throwing: error)
            return
        }
    }

    private func timeoutDiagnosticHint() -> String {
        if invalidACPLineCount > 0 {
            let preview = lastInvalidACPLinePreview.map { " Last non-ACP stdout line: `\($0)`." } ?? ""
            return "The process wrote stdout, but at least one line was not newline-delimited ACP JSON.\(preview)"
        }
        if stdoutLineCount > 0 {
            let preview = lastStdoutPreview.map { " Last stdout line: `\($0)`." } ?? ""
            return "The process wrote stdout, but no matching ACP response arrived for this request.\(preview)"
        }
        if stdoutByteCount > 0 {
            return "The process wrote \(stdoutByteCount) stdout byte(s), but no newline-delimited ACP JSON response was parsed."
        }
        if stderrLineCount > 0 {
            let preview = lastStderrPreview.map { " Last stderr line: `\($0)`." } ?? ""
            return "The process did not write ACP stdout before timing out, but it wrote stderr.\(preview)"
        }
        return "The process stayed silent on ACP stdout/stderr. This usually means the selected command started an interactive/non-ACP mode instead of an ACP stdio server."
    }

    private static func displayCommand(command: String, arguments: [String]) -> String {
        ([command] + arguments).map(displayShellToken).joined(separator: " ")
    }

    private static func displayShellToken(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let safeScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/=:"))
        if token.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return token
        }
        return "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func truncatedDiagnosticPreview(_ text: String, limit: Int = 240) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    // MARK: - Helpers

    /// The currently requested permission configuration (session mode and auto-approve).
    private var runtimePermission: AgentRuntimePermissionSnapshot {
        .acp(sessionModeID: requestedSessionModeID, autoApproveAllToolPermissions: autoApproveAllToolPermissions)
    }

    private func effectivePromptRunRequest(override: ACPRunRequest?) -> ACPRunRequest {
        let request = override ?? runRequest
        let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resume,
              !resume.isEmpty,
              resume == fallbackResumeSessionIDForPromptClearing
        else {
            return request
        }
        return ACPRunRequest(
            agentKind: request.agentKind,
            modelString: request.modelString,
            workspacePath: request.workspacePath,
            resumeSessionID: nil,
            attachments: request.attachments,
            taskLabelKind: request.taskLabelKind,
            sessionModeID: request.sessionModeID,
            autoApproveAllToolPermissions: request.autoApproveAllToolPermissions,
            runtimeSession: request.runtimeSession
        )
    }

    private func shouldFallbackToNewSessionAfterLoadFailure(_ error: Error, existingSessionID _: String) -> Bool {
        // OMP resume is exact-or-error: once history replay is bypassed for session/load,
        // opening a fresh session would silently lose the prior transcript.
        guard provider.providerID != .ohMyPi else { return false }
        guard case let ControllerError.requestFailed(message, code) = error else { return false }
        let lowercased = message.lowercased()
        let looksLikeMissingSession = lowercased.contains("session")
            && lowercased.contains("not found")
        let looksLikeInvalidParams = code == -32602
            || lowercased.contains("invalid params")
        if looksLikeMissingSession, looksLikeInvalidParams {
            return true
        }

        return false
    }

    private static func preflightInjectedMCPServers(in sessionConfiguration: ACPSessionConfiguration) throws {
        for server in sessionConfiguration.mcpServers {
            try server.validateACPLaunchCommand(workingDirectory: sessionConfiguration.workingDirectory)
        }
    }

    private static func preflightInjectedMCPServers(
        in sessionConfiguration: ACPSessionConfiguration,
        environment: [String: String]
    ) throws {
        for server in sessionConfiguration.mcpServers {
            let resolvedBareCommandPath = try resolvedBareACPCommandPath(
                for: server.command,
                serverName: server.name,
                environment: environment
            )
            try server.validateACPLaunchCommand(
                workingDirectory: sessionConfiguration.workingDirectory,
                resolvedBareCommandPath: resolvedBareCommandPath
            )
        }
    }

    private static func resolvedBareACPCommandPath(
        for command: String,
        serverName: String,
        environment: [String: String]
    ) throws -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"[/~]"#, options: .regularExpression) == nil else { return nil }
        let resolved = CommandPathResolver.resolve(
            trimmed,
            environment: environment,
            additionalPaths: [],
            preferredBasenames: [trimmed]
        )
        guard resolved != trimmed else {
            throw RepoPromptMCPServerConfiguration.ACPCommandValidationError.unresolvedCommand(serverName: serverName, command: trimmed)
        }
        return resolved
    }

    private func logLaunchContract(command resolvedCommand: String, workingDirectory: String) {
        log("ACP launch command=\(resolvedCommand) args=\(safeLaunchArgumentsDescription()) cwd=\(workingDirectory)")
    }

    private func recordRunLaunchContract(
        event: String,
        resolvedCommand: String,
        workingDirectory: String,
        pid: pid_t?,
        error: Error?
    ) async {
        #if DEBUG
            guard let runID = expectedMCPRunID else { return }
            var fields: [String: String] = [
                "provider_id": boundedRunDiagnosticField(provider.providerID.rawValue),
                "mcp_client_name": boundedRunDiagnosticField(mcpClientNameHint ?? "nil"),
                "configured_command": boundedRunDiagnosticField(displayRunDiagnosticPath(launchConfiguration.command)),
                "resolved_executable": boundedRunDiagnosticField(displayRunDiagnosticPath(resolvedCommand)),
                "canonical_executable": boundedRunDiagnosticField(displayRunDiagnosticPath(URL(fileURLWithPath: resolvedCommand).resolvingSymlinksInPath().standardizedFileURL.path)),
                "final_args": boundedRunDiagnosticField(safeLaunchArgumentsDescription()),
                "working_directory": boundedRunDiagnosticField(displayRunDiagnosticPath(workingDirectory)),
                "injected_mcp_command": boundedRunDiagnosticField(injectedMCPCommandDescription())
            ]
            if let pid {
                fields["acp_pid"] = String(pid)
            }
            if let error {
                fields["error_kind"] = runDiagnosticErrorKind(error)
                fields["error_type"] = boundedRunDiagnosticField(String(reflecting: type(of: error)))
                fields["error_code"] = String((error as NSError).code)
            }
            await mcpHost.debugRecordRunRoutingEvent(
                runID: runID,
                event: event,
                connectionID: nil,
                fields: fields
            )
        #endif
    }

    private func logSessionMCPInjection() {
        guard !sessionConfiguration.mcpServers.isEmpty else {
            log("ACP session mcpServers empty")
            return
        }
        for server in sessionConfiguration.mcpServers {
            log("ACP session mcpServer name=\(server.name) command=\(server.command) argsCount=\(server.args.count) envCount=\(server.env.count)")
        }
    }

    private func safeLaunchArgumentsDescription() -> String {
        safeArgumentsDescription(launchConfiguration.arguments)
    }

    private func safeArgumentsDescription(_ arguments: [String]) -> String {
        boundedRunDiagnosticField(Self.redactedLaunchArguments(arguments).joined(separator: " "))
    }

    private static func redactedLaunchArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext {
                result.append("<redacted>")
                redactNext = false
                continue
            }
            let lowercased = argument.lowercased()
            if lowercased.contains("authorization:")
                || lowercased.contains("proxy-authorization:")
                || lowercased.hasPrefix("bearer ")
            {
                result.append("<redacted>")
                continue
            }
            if let equals = argument.firstIndex(of: "="), shouldRedactLaunchArgumentName(String(argument[..<equals])) {
                result.append("\(argument[..<equals])=<redacted>")
                continue
            }
            if argument.hasPrefix("-"), shouldRedactLaunchArgumentName(argument) {
                result.append(argument)
                redactNext = true
                continue
            }
            result.append(redactedLaunchJSONArgument(argument) ?? argument)
        }
        return result
    }

    private static func redactedLaunchJSONArgument(_ argument: String) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let sanitizedData = try? JSONSerialization.data(
                  withJSONObject: sanitizedLaunchJSONValue(json),
                  options: [.sortedKeys]
              )
        else {
            return nil
        }
        return String(data: sanitizedData, encoding: .utf8)
    }

    private static func sanitizedLaunchJSONValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = shouldRedactLaunchJSONFieldName(entry.key)
                    ? "<redacted>"
                    : sanitizedLaunchJSONValue(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(sanitizedLaunchJSONValue)
        }
        return value
    }

    private func injectedMCPCommandDescription() -> String {
        var commands = sessionConfiguration.mcpServers.map { server in
            let args = safeArgumentsDescription(server.args)
            return args.isEmpty ? "\(server.name):\(server.command)" : "\(server.name):\(server.command) \(args)"
        }
        if let configContent = launchConfiguration.environment["OPENCODE_CONFIG_CONTENT"],
           let data = configContent.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = root["mcp"] as? [String: Any]
        {
            for key in servers.keys.sorted() where key.caseInsensitiveCompare(RepoPromptMCPServerConfiguration.defaultServerName) == .orderedSame {
                guard let server = servers[key] as? [String: Any],
                      server["enabled"] as? Bool != false,
                      let command = server["command"] as? [String],
                      let executable = command.first
                else { continue }
                let args = safeArgumentsDescription(Array(command.dropFirst()))
                commands.append(args.isEmpty ? "\(key):\(executable)" : "\(key):\(executable) \(args)")
            }
        }
        return boundedRunDiagnosticField(commands.isEmpty ? "none" : commands.joined(separator: " | "))
    }

    private func boundedRunDiagnosticField(_ value: String) -> String {
        Self.truncatedDiagnosticPreview(value, limit: 480)
    }

    private static func shouldRedactLaunchArgumentName(_ argument: String) -> Bool {
        let lowercased = argument.lowercased()
        return [
            "api-key", "api_key", "apikey", "auth", "bearer", "content", "cookie", "credential",
            "env", "header", "input", "instruction", "message", "password", "prompt", "query", "secret", "token"
        ].contains { lowercased.contains($0) }
            || lowercased == "--key"
            || lowercased.hasSuffix("-key")
            || lowercased.hasSuffix("_key")
    }

    private static func shouldRedactLaunchJSONFieldName(_ fieldName: String) -> Bool {
        let lowercased = fieldName.lowercased()
        return lowercased.contains("token")
            || lowercased.contains("password")
            || lowercased.contains("secret")
            || lowercased.contains("credential")
            || lowercased.hasSuffix("key")
    }

    private func displayRunDiagnosticPath(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard value == home || value.hasPrefix(home + "/") else { return value }
        return "~" + String(value.dropFirst(home.count))
    }

    private func runDiagnosticErrorKind(_ error: Error) -> String {
        if error is ExecutableFileIdentityError {
            return "executable_identity"
        }
        if error is CursorACPLaunchResolutionError || error is OpenCodeACPLaunchResolutionError {
            return "launch_resolution"
        }
        if error is CLIProcessRunnerError {
            return "process_runner"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "other"
    }

    private func resolvedEnvironment() async -> [String: String] {
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .acpAgent(providerID: provider.providerID.rawValue),
                overrides: launchConfiguration.environment,
                enableDebugLogging: launchConfiguration.enableDebugLogging
            )
        )
        // Managed launch boundary: an inherited runtime marker never reaches the child.
        return AgentRuntimeLaunchAuthority.strippingInheritedMarker(result.environment)
    }

    private func beginOpeningSessionConfiguration() {
        discoveredSessionModels = nil
        sessionModelConfigOptionID = nil
        sessionModelFailureReason = nil
        sessionModeSnapshot = nil
        sessionModeFailureReason = nil
        auxiliarySelectors.removeAll()
        authoritativeConfigOptions.removeAll()
        lastAppliedConfigurationSequence = 0
        bufferedConfigOptionUpdates.removeAll()
    }

    private func applyOpenedSessionConfiguration(
        from response: [String: Any],
        sessionID: String,
        inboundSequence: UInt64
    ) {
        applyInitialSessionConfiguration(from: response, inboundSequence: inboundSequence)
        let updates = bufferedConfigOptionUpdates
            .filter { $0.sessionID == sessionID && $0.inboundSequence > inboundSequence }
            .sorted { $0.inboundSequence < $1.inboundSequence }
        bufferedConfigOptionUpdates.removeAll()
        for update in updates {
            applyConfigOptionUpdate(update.update, inboundSequence: update.inboundSequence)
        }
    }

    private func applyInitialSessionConfiguration(from response: [String: Any], inboundSequence: UInt64) {
        switch parseModernModeSnapshot(from: response) {
        case let .valid(snapshot):
            sessionModeFailureReason = nil
            sessionModeSnapshot = snapshot
            if response["modes"] != nil {
                diagnose(.info("ACP session also advertised legacy modes; ignoring them because configOptions is the only supported mode authority."))
            }
        case .absent:
            sessionModeSnapshot = nil
            sessionModeFailureReason = nil
            if response["modes"] != nil {
                diagnose(.info("Ignoring legacy ACP modes metadata because mode selection requires a modern configOptions selector."))
            }
        case let .malformed(reason):
            sessionModeSnapshot = nil
            sessionModeFailureReason = reason
            diagnose(.info("ACP session advertised a malformed modern mode config option: \(reason)"))
        }
        let configOptions = response["configOptions"] as? [[String: Any]] ?? []
        applyDiscoveredSessionModels(from: response)
        rebuildAuxiliarySelectors(from: configOptions)
        authoritativeConfigOptions = configOptions
        lastAppliedConfigurationSequence = inboundSequence
        publishOhMyPiThinkingCapabilityIfAvailable()
    }

    private func parseModernModeSnapshot(from response: [String: Any]) -> ParsedModernModeSnapshot {
        guard let rawConfigOptions = response["configOptions"] else { return .absent }
        guard let configOptions = rawConfigOptions as? [[String: Any]] else {
            return .malformed("configOptions is not an array")
        }
        return parseModernModeSnapshot(fromConfigOptions: configOptions)
    }

    private func parseModernModeSnapshot(fromConfigOptions configOptions: [[String: Any]]) -> ParsedModernModeSnapshot {
        switch parseSelectConfigOption(category: "mode", from: configOptions) {
        case .absent:
            return .absent
        case let .malformed(reason):
            return .malformed(reason)
        case let .valid(option):
            let values = deduplicatedExactValues(option.choices.compactMap { normalizedConfigValue($0["value"] as? String) })
            guard !values.isEmpty else {
                return .malformed("mode selector '\(option.id)' has no usable values")
            }
            guard let currentValue = canonicalAdvertisedValue(option.currentValue, in: values) else {
                return .malformed("mode selector '\(option.id)' currentValue is not one of its advertised values")
            }
            return .valid(SessionModeSnapshot(
                configID: option.id,
                currentValue: currentValue,
                availableValues: values
            ))
        }
    }

    private func parseSelectConfigOption(
        category: String,
        from configOptions: [[String: Any]]
    ) -> ParsedSelectConfigOptionResult {
        let normalizedCategory = category.lowercased()
        let recognizedSemanticIDs: Set = ["mode", "model"]
        let conflicting = configOptions.contains { option in
            guard let optionID = normalizedConfigValue(option["id"] as? String)?.lowercased(),
                  let optionCategory = normalizedConfigValue(option["category"] as? String)?.lowercased(),
                  recognizedSemanticIDs.contains(optionID),
                  recognizedSemanticIDs.contains(optionCategory),
                  optionID != optionCategory
            else {
                return false
            }
            return optionID == normalizedCategory || optionCategory == normalizedCategory
        }
        guard !conflicting else {
            return .malformed("\(category) config option has conflicting id/category semantics")
        }

        let candidates = configOptions.filter { option in
            let optionCategory = normalizedConfigValue(option["category"] as? String)?.lowercased()
            if optionCategory == normalizedCategory {
                return true
            }
            guard optionCategory == nil else { return false }
            return normalizedConfigValue(option["id"] as? String)?.lowercased() == normalizedCategory
        }
        guard !candidates.isEmpty else { return .absent }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .malformed("multiple \(category) config options were advertised")
        }
        guard normalizedConfigValue(candidate["type"] as? String)?.lowercased() == "select" else {
            return .malformed("\(category) config option is not a select option")
        }
        guard let id = normalizedConfigValue(candidate["id"] as? String) else {
            return .malformed("\(category) config option is missing id")
        }
        guard let currentValue = normalizedConfigValue(candidate["currentValue"] as? String) else {
            return .malformed("\(category) config option '\(id)' is missing currentValue")
        }
        guard let choices = flattenedConfigOptionChoices(from: candidate["options"]), !choices.isEmpty else {
            return .malformed("\(category) config option '\(id)' has malformed or empty options")
        }
        return .valid(ParsedSelectConfigOption(id: id, currentValue: currentValue, choices: choices))
    }

    private func parseSelectConfigOptionByID(
        _ configID: String,
        from configOptions: [[String: Any]]
    ) -> ParsedSelectConfigOptionResult {
        guard let normalizedID = normalizedConfigValue(configID) else { return .absent }
        let candidates = configOptions.filter { option in
            normalizedConfigValue(option["id"] as? String) == normalizedID
        }
        guard !candidates.isEmpty else { return .absent }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .malformed("multiple select config options with id '\(normalizedID)' were advertised")
        }
        guard normalizedConfigValue(candidate["type"] as? String)?.lowercased() == "select" else {
            return .malformed("config option '\(normalizedID)' is not a select option")
        }
        guard let currentValue = normalizedConfigValue(candidate["currentValue"] as? String) else {
            return .malformed("config option '\(normalizedID)' is missing currentValue")
        }
        guard let choices = flattenedConfigOptionChoices(from: candidate["options"]), !choices.isEmpty else {
            return .malformed("config option '\(normalizedID)' has malformed or empty options")
        }
        return .valid(ParsedSelectConfigOption(
            id: normalizedID,
            currentValue: currentValue,
            choices: choices
        ))
    }

    private func flattenedConfigOptionChoices(from rawValue: Any?) -> [[String: Any]]? {
        guard let dictionaries = rawValue as? [[String: Any]] else { return nil }
        var choices: [[String: Any]] = []
        for dictionary in dictionaries {
            if normalizedConfigValue(dictionary["value"] as? String) != nil {
                choices.append(dictionary)
                continue
            }
            guard let nested = flattenedConfigOptionChoices(from: dictionary["options"]), !nested.isEmpty else {
                return nil
            }
            choices.append(contentsOf: nested)
        }
        return choices
    }

    private func normalizedConfigValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func deduplicatedExactValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func canonicalAdvertisedValue(_ requestedValue: String, in availableValues: [String]) -> String? {
        if let exact = availableValues.first(where: { $0 == requestedValue }) {
            return exact
        }
        let matches = availableValues.filter { $0.caseInsensitiveCompare(requestedValue) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    private func canonicalSessionModelValue(_ requestedValue: String) throws -> String {
        let availableValues = discoveredSessionModels?.options.map(\.rawValue) ?? []
        guard !availableValues.isEmpty else {
            throw ControllerError.protocolViolation("modern model selector has no advertised values")
        }
        if let exact = availableValues.first(where: { $0 == requestedValue }) {
            return exact
        }
        let matches = availableValues.filter { $0.caseInsensitiveCompare(requestedValue) == .orderedSame }
        if matches.count == 1, let canonical = matches.first {
            return canonical
        }
        if matches.count > 1 {
            throw ControllerError.requestFailed("ACP runtime advertises case-colliding models for '\(requestedValue)'. Use an exact value.")
        }
        throw ControllerError.requestFailed("ACP runtime does not advertise model '\(requestedValue)'.")
    }

    private func canonicalSessionModeValue(
        _ requestedValue: String,
        in snapshot: SessionModeSnapshot
    ) throws -> String {
        if let exact = snapshot.availableValues.first(where: { $0 == requestedValue }) {
            return exact
        }
        let matches = snapshot.availableValues.filter { $0.caseInsensitiveCompare(requestedValue) == .orderedSame }
        if matches.count == 1, let canonical = matches.first {
            return canonical
        }
        if matches.count > 1 {
            throw ControllerError.requestFailed("ACP runtime advertises case-colliding session modes for '\(requestedValue)'. Use an exact value. Available modes: \(advertisedSessionModeDescription(snapshot)).")
        }
        throw ControllerError.requestFailed("ACP runtime does not advertise session mode '\(requestedValue)'. Available modes: \(advertisedSessionModeDescription(snapshot)).")
    }

    private func advertisedSessionModeDescription(_ snapshot: SessionModeSnapshot) -> String {
        snapshot.availableValues.isEmpty ? "none" : snapshot.availableValues.joined(separator: ", ")
    }

    #if DEBUG
        func debugSuspendNextConfigurationMutationPostcheck() {
            debugShouldSuspendNextConfigurationMutationPostcheck = true
        }

        func debugIsConfigurationMutationPostcheckSuspended() -> Bool {
            debugConfigurationMutationPostcheckIsSuspended
        }

        func debugResumeConfigurationMutationPostcheck() {
            debugShouldSuspendNextConfigurationMutationPostcheck = false
            debugConfigurationMutationPostcheckIsSuspended = false
            let waiters = debugConfigurationMutationPostcheckResumeWaiters
            debugConfigurationMutationPostcheckResumeWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func debugSuspendConfigurationMutationPostcheckIfNeeded() async {
            guard debugShouldSuspendNextConfigurationMutationPostcheck else { return }
            debugShouldSuspendNextConfigurationMutationPostcheck = false
            debugConfigurationMutationPostcheckIsSuspended = true
            await withCheckedContinuation { continuation in
                debugConfigurationMutationPostcheckResumeWaiters.append(continuation)
            }
            debugConfigurationMutationPostcheckIsSuspended = false
        }
    #endif

    private func applyVerifiedConfigOptionsMutationResponse(
        _ response: RequestResponse,
        requiredModeValue: String?,
        requiredModelValue: String?,
        requiredSelectValue: (configID: String, value: String)? = nil
    ) async throws {
        if response.inboundSequence < lastAppliedConfigurationSequence {
            diagnose(.info("Ignoring stale session/set_config_option snapshot."))
            #if DEBUG
                await debugSuspendConfigurationMutationPostcheckIfNeeded()
            #endif
            try verifyCurrentConfigurationState(
                requiredModeValue: requiredModeValue,
                requiredModelValue: requiredModelValue,
                requiredSelectValue: requiredSelectValue
            )
            return
        }
        guard let configOptions = response.result["configOptions"] as? [[String: Any]] else {
            throw ControllerError.protocolViolation("session/set_config_option response missing complete configOptions snapshot")
        }
        let parsedMode = parseModernModeSnapshot(fromConfigOptions: configOptions)
        if requiredModeValue != nil || sessionModeSnapshot != nil {
            guard case let .valid(modeSnapshot) = parsedMode else {
                throw ControllerError.protocolViolation("session/set_config_option response missing a valid modern mode selector")
            }
            if let requiredModeValue, modeSnapshot.currentValue != requiredModeValue {
                throw ControllerError.protocolViolation("session/set_config_option response did not confirm requested mode '\(requiredModeValue)'")
            }
        } else if case let .malformed(reason) = parsedMode {
            throw ControllerError.protocolViolation("session/set_config_option response contained malformed mode metadata: \(reason)")
        }

        if let requiredSelectValue {
            switch parseSelectConfigOptionByID(requiredSelectValue.configID, from: configOptions) {
            case let .valid(option):
                guard option.currentValue == requiredSelectValue.value else {
                    throw ControllerError.protocolViolation("session/set_config_option response did not confirm requested value '\(requiredSelectValue.value)' for selector '\(requiredSelectValue.configID)'")
                }
            case .absent:
                throw ControllerError.protocolViolation("session/set_config_option response missing selector '\(requiredSelectValue.configID)'")
            case let .malformed(reason):
                throw ControllerError.protocolViolation("session/set_config_option response contained malformed selector '\(requiredSelectValue.configID)': \(reason)")
            }
        }

        let parsedModel = parseModernModelSnapshot(fromConfigOptions: configOptions)
        switch parsedModel {
        case let .valid(_, models):
            if let requiredModelValue, models.currentModelRaw != requiredModelValue {
                throw ControllerError.protocolViolation("session/set_config_option response did not confirm requested model '\(requiredModelValue)'")
            }
        case .absent:
            if requiredModelValue != nil || sessionModelConfigOptionID != nil {
                throw ControllerError.protocolViolation("session/set_config_option response missing model selector")
            }
        case let .malformed(reason):
            throw ControllerError.protocolViolation("session/set_config_option response contained malformed model metadata: \(reason)")
        }

        if response.inboundSequence >= lastAppliedConfigurationSequence {
            applyConfigOptionsSnapshot(
                configOptions,
                parsedMode: parsedMode,
                inboundSequence: response.inboundSequence
            )
        }
        #if DEBUG
            await debugSuspendConfigurationMutationPostcheckIfNeeded()
        #endif
        try verifyCurrentConfigurationState(
            requiredModeValue: requiredModeValue,
            requiredModelValue: requiredModelValue,
            requiredSelectValue: requiredSelectValue
        )
    }

    private func verifyCurrentConfigurationState(
        requiredModeValue: String?,
        requiredModelValue: String?,
        requiredSelectValue: (configID: String, value: String)?
    ) throws {
        if let requiredModeValue,
           sessionModeSnapshot?.currentValue != requiredModeValue
        {
            throw ControllerError.protocolViolation("newer ACP configuration state no longer confirms requested mode '\(requiredModeValue)'")
        }
        if let requiredModelValue,
           discoveredSessionModels?.currentModelRaw != requiredModelValue
        {
            throw ControllerError.protocolViolation("newer ACP configuration state no longer confirms requested model '\(requiredModelValue)'")
        }
        if let requiredSelectValue,
           auxiliarySelectors[requiredSelectValue.configID]?.currentValue != requiredSelectValue.value
        {
            throw ControllerError.protocolViolation("newer ACP configuration state no longer confirms requested value '\(requiredSelectValue.value)' for selector '\(requiredSelectValue.configID)'")
        }
    }

    private func handleConfigOptionUpdateNotification(
        paramsSessionID: String?,
        update: [String: Any],
        inboundSequence: UInt64
    ) {
        guard let notificationSessionID = normalizedConfigValue(paramsSessionID) else {
            diagnose(.info("Ignoring config_option_update without a sessionId."))
            return
        }
        guard let currentSessionID = sessionID else {
            guard state == .openingSession else {
                diagnose(.info("Ignoring config_option_update for unopened session \(notificationSessionID)."))
                return
            }
            bufferedConfigOptionUpdates.append(BufferedConfigOptionUpdate(
                sessionID: notificationSessionID,
                update: update,
                inboundSequence: inboundSequence
            ))
            if bufferedConfigOptionUpdates.count > 16 {
                bufferedConfigOptionUpdates.removeFirst(bufferedConfigOptionUpdates.count - 16)
            }
            diagnose(.info("Buffered config_option_update until session \(notificationSessionID) is established."))
            return
        }
        guard currentSessionID == notificationSessionID else {
            diagnose(.info("Ignoring config_option_update for non-current session \(notificationSessionID)."))
            return
        }
        applyConfigOptionUpdate(update, inboundSequence: inboundSequence)
    }

    private func applyConfigOptionUpdate(_ update: [String: Any], inboundSequence: UInt64) {
        guard let configOptions = update["configOptions"] as? [[String: Any]] else {
            diagnose(.info("Ignoring config_option_update without a complete configOptions snapshot."))
            return
        }
        guard inboundSequence >= lastAppliedConfigurationSequence else {
            diagnose(.info("Ignoring stale config_option_update snapshot."))
            return
        }
        let parsedMode = parseModernModeSnapshot(fromConfigOptions: configOptions)
        applyConfigOptionsSnapshot(
            configOptions,
            parsedMode: parsedMode,
            inboundSequence: inboundSequence
        )
        diagnose(.info("Processed authoritative config_option_update snapshot."))
    }

    private func applyConfigOptionsSnapshot(
        _ configOptions: [[String: Any]],
        parsedMode: ParsedModernModeSnapshot,
        inboundSequence: UInt64
    ) {
        guard inboundSequence >= lastAppliedConfigurationSequence else { return }
        switch parsedMode {
        case let .valid(snapshot):
            sessionModeSnapshot = snapshot
            sessionModeFailureReason = nil
        case .absent:
            sessionModeSnapshot = nil
            sessionModeFailureReason = nil
        case let .malformed(reason):
            sessionModeSnapshot = nil
            sessionModeFailureReason = reason
            diagnose(.info("Invalidated session mode authority after malformed modern snapshot: \(reason)"))
        }
        let response: [String: Any] = ["configOptions": configOptions]
        applyDiscoveredSessionModels(from: response)
        rebuildAuxiliarySelectors(from: configOptions)
        authoritativeConfigOptions = configOptions
        lastAppliedConfigurationSequence = inboundSequence
        publishOhMyPiThinkingCapabilityIfAvailable()
    }

    private func rebuildAuxiliarySelectors(from configOptions: [[String: Any]]) {
        let excludedIDs = Set([sessionModeSnapshot?.configID, sessionModelConfigOptionID].compactMap(\.self))
        var selectors: [String: AuxiliarySelectorSnapshot] = [:]
        var visitedIDs = Set<String>()
        for option in configOptions {
            guard let configID = normalizedConfigValue(option["id"] as? String),
                  visitedIDs.insert(configID).inserted,
                  !excludedIDs.contains(configID)
            else {
                continue
            }
            guard case let .valid(parsed) = parseSelectConfigOptionByID(configID, from: configOptions) else {
                continue
            }
            let values = deduplicatedExactValues(parsed.choices.compactMap {
                normalizedConfigValue($0["value"] as? String)
            })
            guard !values.isEmpty, values.contains(parsed.currentValue) else { continue }
            selectors[configID] = AuxiliarySelectorSnapshot(
                configID: configID,
                category: normalizedConfigValue(option["category"] as? String),
                currentValue: parsed.currentValue,
                values: values,
                displayNames: values
            )
        }
        auxiliarySelectors = selectors
    }

    private func resolvedOhMyPiThinkingSelector() throws -> AuxiliarySelectorSnapshot {
        let expectedID = ACPConfigOptionKey.ohMyPiThinking.configID
        let expectedCategory = ACPConfigOptionKey.ohMyPiThinking.category
        let categoryMatches = authoritativeConfigOptions.filter {
            normalizedConfigValue($0["category"] as? String) == expectedCategory
        }
        let idMatches = authoritativeConfigOptions.filter {
            normalizedConfigValue($0["id"] as? String) == expectedID
        }

        guard categoryMatches.count == 1 else {
            if categoryMatches.isEmpty {
                throw ControllerError.requestFailed(
                    "Oh My Pi does not advertise the required thinking selector category '\(expectedCategory)' for model '\(discoveredSessionModels?.currentModelRaw ?? "unknown")'."
                )
            }
            throw ControllerError.requestFailed(
                "Oh My Pi advertised multiple thinking selectors in category '\(expectedCategory)'; expected exactly one selector with id '\(expectedID)'."
            )
        }
        guard idMatches.count == 1 else {
            if idMatches.isEmpty {
                throw ControllerError.requestFailed(
                    "Oh My Pi thinking selector for model '\(discoveredSessionModels?.currentModelRaw ?? "unknown")' has an unexpected id; expected '\(expectedID)'."
                )
            }
            throw ControllerError.requestFailed(
                "Oh My Pi advertised multiple selectors with id '\(expectedID)'; thinking selection is ambiguous."
            )
        }
        guard normalizedConfigValue(categoryMatches[0]["id"] as? String) == expectedID,
              normalizedConfigValue(idMatches[0]["category"] as? String) == expectedCategory
        else {
            throw ControllerError.requestFailed(
                "Oh My Pi thinking selector must use id '\(expectedID)' and category '\(expectedCategory)'."
            )
        }
        guard case let .valid(parsed) = parseSelectConfigOptionByID(
            expectedID,
            from: authoritativeConfigOptions
        ) else {
            throw ControllerError.requestFailed(
                "Oh My Pi thinking selector '\(expectedID)' is malformed for model '\(discoveredSessionModels?.currentModelRaw ?? "unknown")'."
            )
        }
        let values = deduplicatedExactValues(parsed.choices.compactMap {
            normalizedConfigValue($0["value"] as? String)
        })
        guard !values.isEmpty, values.contains(parsed.currentValue) else {
            throw ControllerError.requestFailed(
                "Oh My Pi thinking selector '\(expectedID)' has no valid current choice for model '\(discoveredSessionModels?.currentModelRaw ?? "unknown")'."
            )
        }
        let displayNamesByValue = Dictionary(
            parsed.choices.compactMap { choice -> (String, String)? in
                guard let value = normalizedConfigValue(choice["value"] as? String) else { return nil }
                let name = normalizedConfigValue(choice["name"] as? String) ?? value
                return (value, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return AuxiliarySelectorSnapshot(
            configID: expectedID,
            category: expectedCategory,
            currentValue: parsed.currentValue,
            values: values,
            displayNames: values.map { displayNamesByValue[$0] ?? $0 }
        )
    }

    private func publishOhMyPiThinkingCapabilityIfAvailable() {
        guard provider.providerID == .ohMyPi,
              let modelID = discoveredSessionModels?.currentModelRaw,
              let selector = try? resolvedOhMyPiThinkingSelector()
        else {
            return
        }
        ohMyPiThinkingCapabilityPublisher(OhMyPiThinkingCapabilityRecord(
            modelID: modelID,
            configID: selector.configID,
            category: selector.category ?? ACPConfigOptionKey.ohMyPiThinking.category,
            orderedOptions: selector.values,
            optionDisplayNames: selector.displayNames
        ))
    }

    private func applyDiscoveredSessionModels(from response: [String: Any]) {
        let parsed: ACPDiscoveredSessionModels?
        switch parseModernModelSnapshot(from: response) {
        case let .valid(configID, models):
            sessionModelConfigOptionID = configID
            sessionModelFailureReason = nil
            parsed = models
            if response["models"] != nil {
                diagnose(.info("ACP session advertised both configOptions and legacy models; using authoritative configOptions model selector."))
            }
        case .absent:
            sessionModelConfigOptionID = nil
            sessionModelFailureReason = nil
            parsed = nil
            if response["models"] != nil {
                diagnose(.info("Ignoring legacy ACP models metadata because model discovery and selection require configOptions."))
            }
        case let .malformed(reason):
            sessionModelConfigOptionID = nil
            sessionModelFailureReason = reason
            parsed = nil
            diagnose(.info("ACP session advertised a malformed modern model config option; legacy fallback is disabled: \(reason)"))
        }

        discoveredSessionModels = parsed
        guard let parsed,
              dynamicModelPublicationPolicy == .standard
        else { return }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(parsed, for: provider.providerID)
    }

    private func parseModernModelSnapshot(from response: [String: Any]) -> ParsedModernModelSnapshot {
        guard let rawConfigOptions = response["configOptions"] else { return .absent }
        guard let configOptions = rawConfigOptions as? [[String: Any]] else {
            return .malformed("configOptions is not an array")
        }
        return parseModernModelSnapshot(fromConfigOptions: configOptions)
    }

    private func parseModernModelSnapshot(
        fromConfigOptions configOptions: [[String: Any]]
    ) -> ParsedModernModelSnapshot {
        switch parseSelectConfigOption(category: "model", from: configOptions) {
        case .absent:
            return .absent
        case let .malformed(reason):
            return .malformed(reason)
        case let .valid(option):
            let options = mergeModelOptions(option.choices.compactMap(parseDiscoveredConfigModelOption))
            let availableValues = options.map(\.rawValue)
            guard !availableValues.isEmpty else {
                return .malformed("model selector '\(option.id)' has no usable values")
            }
            guard let currentModelRaw = canonicalAdvertisedValue(option.currentValue, in: availableValues) else {
                return .malformed("model selector '\(option.id)' currentValue is not one of its advertised values")
            }
            return .valid(
                configID: option.id,
                models: ACPDiscoveredSessionModels(
                    options: options,
                    currentModelRaw: currentModelRaw
                )
            )
        }
    }

    private func mergeModelOptions(_ rawOptions: [AgentModelOption]) -> [AgentModelOption] {
        var options: [AgentModelOption] = []
        var seenModelIDs = Set<String>()
        for option in rawOptions {
            guard seenModelIDs.insert(option.rawValue).inserted else { continue }
            options.append(option)
        }
        return options
    }

    private func parseDiscoveredConfigModelOption(from rawOption: [String: Any]) -> AgentModelOption? {
        guard let rawValue = normalizedACPModelString(
            (rawOption["value"] as? String) ?? (rawOption["modelId"] as? String) ?? (rawOption["id"] as? String)
        ) else {
            return nil
        }
        let displayName = normalizedACPModelString(
            (rawOption["name"] as? String) ?? (rawOption["displayName"] as? String)
        ) ?? rawValue
        return AgentModelOption(
            rawValue: rawValue,
            displayName: displayName,
            description: normalizedACPModelString(rawOption["description"] as? String),
            isPlaceholderDefault: false,
            isProviderDefault: rawOption["isDefault"] as? Bool ?? false
        )
    }

    private func sessionModelConfigValue(forSelectedModel selectedModel: String) -> String? {
        guard provider.providerID == .cursor else { return selectedModel }
        let normalizedSelection = normalizedCursorModelAlias(selectedModel)
        guard !normalizedSelection.isEmpty else { return selectedModel }
        let snapshot = discoveredSessionModels ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)

        if normalizedSelection == AgentModel.cursorAuto.rawValue {
            guard let snapshot else { return nil }
            if snapshot.contains(rawModel: selectedModel) {
                return selectedModel
            }
            return snapshot.options.first(where: { isCursorAutoConfigOption($0) })?.rawValue
        }

        guard let snapshot else { return selectedModel }
        if snapshot.contains(rawModel: selectedModel) {
            return selectedModel
        }

        if let displayMatch = snapshot.options.first(where: { option in
            normalizedCursorModelAlias(option.displayName) == normalizedSelection
        }) {
            return displayMatch.rawValue
        }
        if let baseMatch = snapshot.options.first(where: { option in
            normalizedCursorModelAlias(option.rawValue) == normalizedSelection
        }) {
            return baseMatch.rawValue
        }
        return selectedModel
    }

    private func isCursorAutoConfigOption(_ option: AgentModelOption) -> Bool {
        normalizedCursorModelAlias(option.rawValue) == AgentModel.cursorAuto.rawValue
            || normalizedCursorModelAlias(option.displayName) == AgentModel.cursorAuto.rawValue
    }

    private func normalizedCursorModelAlias(_ value: String) -> String {
        CursorModelRegistryGate.normalizedAlias(value)
    }

    private static func responseErrorMessage(from error: [String: Any]) -> String {
        let message = trimmedNonEmptyString(error["message"])
        let data = error["data"]
        let detail = responseErrorDetail(from: data)
        let base = message ?? "Unknown ACP error"
        guard let detail, !detail.isEmpty, detail != base else { return base }
        return "\(base): \(detail)"
    }

    private static func responseErrorDetail(from data: Any?) -> String? {
        guard let data else { return nil }
        if let text = trimmedNonEmptyString(data) {
            return text
        }
        if let dictionary = data as? [String: Any] {
            for path in [["message"], ["error", "message"], ["details"], ["cause", "message"]] {
                if let text = nestedTrimmedString(in: dictionary, path: path) {
                    return text
                }
            }
            return compactJSONPreview(data)
        }
        if let array = data as? [Any] {
            return compactJSONPreview(array)
        }
        return nil
    }

    private static func nestedTrimmedString(in dictionary: [String: Any], path: [String]) -> String? {
        var value: Any? = dictionary
        for key in path {
            guard let nested = value as? [String: Any] else { return nil }
            value = nested[key]
        }
        return trimmedNonEmptyString(value)
    }

    private static func trimmedNonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compactJSONPreview(_ value: Any, limit: Int = 2000) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else {
            return nil
        }
        guard string.count > limit else { return string }
        return String(string.prefix(limit)) + "…"
    }

    private static func responseErrorCode(from error: [String: Any]) -> Int? {
        switch error["code"] {
        case let code as Int:
            code
        case let code as Int64:
            Int(code)
        case let code as NSNumber:
            code.intValue
        case let code as String:
            Int(code.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private func messageStopResult(
        from response: [String: Any],
        sessionID: String,
        stopReason: String?
    ) -> AIStreamResult {
        let usage = response["usage"] as? [String: Any]
        let inputTokens = intValue(usage?["inputTokens"])
        let outputTokens = intValue(usage?["outputTokens"])
        let cachedReadTokens = intValue(usage?["cachedReadTokens"])
        let cachedWriteTokens = intValue(usage?["cachedWriteTokens"])
        let hasContextBreakdown = inputTokens != nil || cachedReadTokens != nil || cachedWriteTokens != nil
        let contextUsedTokens = hasContextBreakdown
            ? max(0, inputTokens ?? 0) + max(0, cachedReadTokens ?? 0) + max(0, cachedWriteTokens ?? 0)
            : nil
        let providerSessionID = providerSessionIdentity.loadSessionID ?? sessionID
        return AIStreamResult(
            type: "message_stop",
            text: nil,
            promptTokens: inputTokens,
            completionTokens: outputTokens,
            providerSessionID: providerSessionID,
            stopReason: stopReason,
            contextUsedTokens: contextUsedTokens
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let int64 as Int64:
            Int(int64)
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private func normalizedACPModelString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func normalizedModelString(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let trimmed, !trimmed.isEmpty, trimmed != "default" else {
            return nil
        }
        return trimmed
    }

    private func effectiveModelString() -> String? {
        normalizedModelString(discoveredSessionModels?.preferredModelRaw ?? runRequest.modelString)
    }

    private func normalizedWorkspacePath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func parseJSONRPCID(_ rawValue: Any?) -> JSONRPCID? {
        switch rawValue {
        case let value as String:
            return .string(value)
        case let value as Int:
            return .int(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            let doubleValue = value.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(value.intValue)
            }
            return .double(doubleValue)
        case let value as Double:
            return .double(value)
        default:
            return nil
        }
    }

    private func candidateStorageKeys(for id: JSONRPCID) -> [String] {
        var keys = [id.storageKey]
        switch id {
        case let .string(value):
            if let intValue = Int(value) {
                keys.append(JSONRPCID.int(intValue).storageKey)
                keys.append(JSONRPCID.double(Double(intValue)).storageKey)
            }
            if let doubleValue = Double(value) {
                keys.append(JSONRPCID.double(doubleValue).storageKey)
                if floor(doubleValue) == doubleValue {
                    keys.append(JSONRPCID.int(Int(doubleValue)).storageKey)
                }
            }
        case let .int(value):
            keys.append(JSONRPCID.string(String(value)).storageKey)
            keys.append(JSONRPCID.double(Double(value)).storageKey)
        case let .double(value):
            keys.append(JSONRPCID.string(String(value)).storageKey)
            if floor(value) == value {
                keys.append(JSONRPCID.int(Int(value)).storageKey)
                keys.append(JSONRPCID.string(String(Int(value))).storageKey)
            }
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func authMethodIDs(from authMethods: [[String: Any]]) -> [String] {
        authMethods.compactMap { dictionary -> String? in
            let rawID = (dictionary["id"] as? String) ?? (dictionary["methodId"] as? String)
            let authMethodID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return authMethodID?.isEmpty == false ? authMethodID : nil
        }
    }

    private func cleanupLaunchArtifacts() async {
        await provider.cleanupLaunchArtifacts(for: launchConfiguration)
    }

    private func approvalKind(for toolKind: String?) -> AgentApprovalKind {
        switch toolKind {
        case "edit", "delete", "move":
            .fileChange
        default:
            .commandExecution
        }
    }

    private func approvalDetails(
        toolTitle: String?,
        toolKind: String?,
        rawInputJSON: String?,
        options: [[String: Any]]
    ) -> [AgentApprovalDetail] {
        var details: [AgentApprovalDetail] = []
        if let toolTitle, !toolTitle.isEmpty {
            details.append(AgentApprovalDetail(label: "Tool", value: toolTitle))
        }
        if let toolKind, !toolKind.isEmpty {
            details.append(AgentApprovalDetail(label: "Kind", value: toolKind))
        }
        if let rawInputJSON, !rawInputJSON.isEmpty {
            details.append(AgentApprovalDetail(label: "Input", value: rawInputJSON, isCode: true))
        }
        if !options.isEmpty,
           let optionsJSON = serializeJSON(options)
        {
            details.append(AgentApprovalDetail(label: "Options", value: optionsJSON, isCode: true))
        }
        return details
    }

    private func optionID(for options: [PermissionOption], preferredKinds: [String]) -> String {
        for kind in preferredKinds {
            guard let normalizedKind = normalizedPermissionOptionValue(kind) else { continue }
            if let option = options.first(where: { normalizedPermissionOptionValue($0.kind) == normalizedKind }) {
                return option.optionID
            }
        }
        return options.first?.optionID ?? ""
    }

    private func optionID(for options: [PermissionOption], preferences: [PermissionOptionPreference]) -> String? {
        for preference in preferences {
            switch preference {
            case let .optionID(preferredOptionID):
                guard let normalizedOptionID = normalizedPermissionOptionValue(preferredOptionID) else { continue }
                if let option = options.first(where: { normalizedPermissionOptionValue($0.optionID) == normalizedOptionID }) {
                    return option.optionID
                }
            case let .kind(preferredKind):
                guard let normalizedKind = normalizedPermissionOptionValue(preferredKind) else { continue }
                if let option = options.first(where: { normalizedPermissionOptionValue($0.kind) == normalizedKind }) {
                    return option.optionID
                }
            }
        }
        return nil
    }

    private func normalizedPermissionOptionValue(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func sendPermissionSelectionResponse(id: JSONRPCID, optionID: String) throws {
        try sendJSONLine([
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": [
                "outcome": [
                    "outcome": "selected",
                    "optionId": optionID
                ]
            ]
        ])
    }

    private func preferredAllowOptionID(for options: [PermissionOption], sessionScoped: Bool) -> String {
        let preferences: [PermissionOptionPreference] = switch provider.providerID {
        case .openCode, .cursor, .ohMyPi:
            genericAllowOptionPreferences(sessionScoped: sessionScoped)
        }
        return optionID(for: options, preferences: preferences) ?? options.first?.optionID ?? ""
    }

    private func preferredRejectOptionID(for options: [PermissionOption]) -> String? {
        optionID(for: options, preferences: [
            .optionID("reject_once"),
            .optionID("reject"),
            .kind("reject_once"),
            .kind("reject"),
            .optionID("reject_always"),
            .kind("reject_always"),
            .optionID("deny_once"),
            .optionID("deny"),
            .kind("deny_once"),
            .kind("deny"),
            .optionID("cancel"),
            .kind("cancel")
        ])
    }

    private func fullAccessAutoApprovalOptionID(for options: [PermissionOption]) -> String? {
        guard autoApproveAllToolPermissions else { return nil }
        switch provider.providerID {
        case .cursor:
            return optionID(for: options, preferences: genericAllowOptionPreferences(sessionScoped: true))
        case .openCode, .ohMyPi:
            return nil
        }
    }

    private func genericAllowOptionPreferences(sessionScoped: Bool) -> [PermissionOptionPreference] {
        if sessionScoped {
            return [
                .optionID("always"),
                .optionID("allow_always"),
                .kind("allow_always"),
                .optionID("once"),
                .optionID("allow_once"),
                .kind("allow_once")
            ]
        }
        return [
            .optionID("once"),
            .optionID("allow_once"),
            .kind("allow_once"),
            .optionID("always"),
            .optionID("allow_always"),
            .kind("allow_always")
        ]
    }

    private func autoApprovalSelection(
        requestToolName: String?,
        requestPayload: [String: Any],
        options: [PermissionOption]
    ) -> AutoApprovalSelection? {
        guard let match = Self.repoPromptScopedAutoApprovalMatch(
            providerID: provider.providerID,
            requestToolName: requestToolName,
            requestPayload: requestPayload
        ) else {
            return nil
        }

        let preferences: [PermissionOptionPreference] = switch provider.providerID {
        case .openCode, .cursor, .ohMyPi:
            [
                .optionID("always"),
                .optionID("allow_always"),
                .kind("allow_always"),
                .optionID("once"),
                .optionID("allow_once"),
                .kind("allow_once")
            ]
        }

        guard let optionID = optionID(for: options, preferences: preferences) else { return nil }
        return AutoApprovalSelection(optionID: optionID, match: match)
    }

    static func repoPromptScopedAutoApprovalMatch(
        providerID: ACPProviderID,
        requestToolName: String?,
        requestPayload: [String: Any]
    ) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
        // Keep this exhaustive switch as a forcing function: every new ACP provider must
        // explicitly opt into strict RepoPrompt-tool recognition before duplicate approval.
        switch providerID {
        case .openCode, .cursor, .ohMyPi:
            break
        }
        guard let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: requestToolName,
            requestPayload: requestPayload
        ), isStrictACPRepoPromptPermissionMatch(
            match,
            requestToolName: requestToolName
        ) else {
            return nil
        }
        return match
    }

    private static func repoPromptPermissionRequestToolName(
        toolCall: [String: Any],
        toolTitle: String?
    ) -> String? {
        ACPRuntimeEventParsing.repoPromptToolName(from: toolCall) ?? toolTitle
    }

    #if DEBUG
        static func testRepoPromptPermissionEntryPointMatch(
            providerID: ACPProviderID,
            params: [String: Any]
        ) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
            guard let toolCall = params["toolCall"] as? [String: Any] else { return nil }
            let toolTitle = (toolCall["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawInput = toolCall["rawInput"] as? [String: Any]
            let options = params["options"] as? [[String: Any]] ?? []
            let requestToolName = repoPromptPermissionRequestToolName(
                toolCall: toolCall,
                toolTitle: toolTitle
            )
            let payload = repoPromptPermissionAutoApprovalPayload(
                toolTitle: toolTitle,
                toolKind: (toolCall["kind"] as? String)?.lowercased(),
                toolCall: toolCall,
                rawInput: rawInput,
                options: options
            )
            return repoPromptScopedAutoApprovalMatch(
                providerID: providerID,
                requestToolName: requestToolName,
                requestPayload: payload
            )
        }
    #endif

    private static func isStrictACPRepoPromptPermissionMatch(
        _ match: MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch,
        requestToolName: String?
    ) -> Bool {
        // ACP permission payloads may contain model-controlled tool arguments. Only the
        // protocol-level request tool name may establish duplicate-approval identity.
        guard case .topLevelToolName = match.source,
              let requestToolName
        else {
            return false
        }
        return MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(requestToolName)
    }

    private static func repoPromptPermissionAutoApprovalPayload(
        toolTitle: String?,
        toolKind: String?,
        toolCall: [String: Any],
        rawInput: [String: Any]?,
        options: [[String: Any]]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "toolCall": toolCall,
            "options": options
        ]
        if let toolTitle, !toolTitle.isEmpty {
            payload["title"] = toolTitle
        }
        if let toolKind, !toolKind.isEmpty {
            payload["kind"] = toolKind
        }
        if let rawInputValue = toolCall["rawInput"] {
            payload["rawInput"] = rawInputValue
        } else if let rawInput {
            payload["rawInput"] = rawInput
        }
        return payload
    }

    private func serializeJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private func terminalState(for stopReason: String?) -> AgentSessionRunState {
        switch stopReason?.lowercased() {
        case "end_turn", "max_tokens", "max_turn_requests":
            .completed
        case "cancelled":
            .cancelled
        case "refusal":
            .failed
        default:
            .completed
        }
    }

    private func displayText(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .missingOllamaURL:
                return "Missing Ollama URL."
            case .missingAzureConfiguration:
                return "Missing Azure OpenAI configuration."
            case .missingAPIKey:
                return "Missing API key."
            case .missingURL:
                return "Missing provider URL."
            case .providerNotConfigured:
                return "Provider is not configured."
            case .invalidModel:
                return "Invalid model."
            case .invalidSystemPrompt:
                return "Invalid system prompt."
            case .messageCreationFailed:
                return "Failed to create provider message."
            case let .invalidResponse(detail), let .invalidConfiguration(detail):
                return detail
            case let .apiError(source), let .unknown(source):
                return source.map(displayText) ?? String(describing: providerError)
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty, description != "The operation couldn’t be completed." {
                return description
            }
        }
        return String(describing: error)
    }

    private func terminalErrorText(for stopReason: String?) -> String? {
        switch stopReason?.lowercased() {
        case "refusal":
            "\(runRequest.agentKind.displayName) ACP refused to continue this turn."
        default:
            nil
        }
    }

    private func emit(_ event: NormalizedAgentRuntimeEvent) {
        _ = eventsContinuation?.yield(event)
    }

    private func emitTerminal(state: AgentSessionRunState, errorText: String?) {
        guard !didEmitTerminal else { return }
        didEmitTerminal = true
        emit(.terminal(state: state, errorText: errorText))
    }

    private func finishEventsIfNeeded() {
        guard !eventStreamFinished else { return }
        eventStreamFinished = true
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    private func resetEventsStreamForNextTurn() {
        eventsContinuation?.finish()
        eventsContinuation = nil
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    private static func makeEventsStream() -> (
        stream: AsyncStream<NormalizedAgentRuntimeEvent>,
        continuation: AsyncStream<NormalizedAgentRuntimeEvent>.Continuation
    ) {
        var capturedContinuation: AsyncStream<NormalizedAgentRuntimeEvent>.Continuation?
        let stream = AsyncStream<NormalizedAgentRuntimeEvent> { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            fatalError("ACPAgentSessionController failed to create event stream continuation")
        }
        return (stream, capturedContinuation)
    }

    private func log(_ message: String) {
        diagnose(.info(message))
        guard launchConfiguration.enableDebugLogging else { return }
        print("\(logPrefix) \(message)")
    }

    #if DEBUG
        private static func resolveRawACPCaptureURL(for providerID: ACPProviderID) -> URL? {
            let env = ProcessInfo.processInfo.environment
            let providerSpecificKey: String? = switch providerID {
            case .cursor:
                "RP_CURSOR_RAW_CAPTURE_PATH"
            case .openCode:
                "RP_OPENCODE_ACP_RAW_CAPTURE_PATH"
            case .ohMyPi:
                "RP_OMP_ACP_RAW_CAPTURE_PATH"
            }
            let customPath = providerSpecificKey.flatMap { key in
                env[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? env["RP_ACP_RAW_CAPTURE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let customPath, !customPath.isEmpty else { return nil }
            return URL(fileURLWithPath: customPath)
        }
    #endif

    private func resetActivePromptTrace() {
        #if DEBUG
            activePromptSessionUpdateCounts = [:]
            activePromptNormalizedStreamCount = 0
        #endif
        activePromptOpenCodeStderrError = nil
        activePromptNormalizedContentCount = 0
        activePromptNormalizedReasoningCount = 0
    }

    #if DEBUG
        private static func captureLaunchConfigurationIfEnabled(
            rawACPCaptureURL: URL?,
            providerID: ACPProviderID,
            launchConfiguration: ACPLaunchConfiguration
        ) {
            guard let rawACPCaptureURL else { return }
            writeRawACPEvent(
                to: rawACPCaptureURL,
                kind: "launch.configuration",
                payload: launchConfigurationTracePayload(launchConfiguration),
                providerID: providerID,
                controllerState: State.idle.rawValue,
                hasActivePromptTurn: false,
                suppressSessionLoadReplayUpdates: false,
                sessionID: nil
            )
        }

        static func debugLaunchConfigurationTracePayloadForTesting(
            _ launchConfiguration: ACPLaunchConfiguration
        ) -> [String: Any] {
            launchConfigurationTracePayload(launchConfiguration)
        }

        static func debugSanitizedRawCapturePayloadForTesting(_ payload: [String: Any]) -> [String: Any] {
            sanitizeRawCaptureDictionary(payload)
        }

        static func debugWriteRawACPEventForTesting(to url: URL, payload: [String: Any]) {
            writeRawACPEvent(
                to: url,
                kind: "test",
                payload: payload,
                providerID: .cursor,
                controllerState: State.idle.rawValue,
                hasActivePromptTurn: false,
                suppressSessionLoadReplayUpdates: false,
                sessionID: nil
            )
        }

        private static func launchConfigurationTracePayload(_ launchConfiguration: ACPLaunchConfiguration) -> [String: Any] {
            var payload: [String: Any] = [
                "command": launchConfiguration.command,
                "arguments": redactedLaunchArguments(launchConfiguration.arguments),
                "workingDirectory": launchConfiguration.workingDirectory ?? "",
                "additionalPathHints": launchConfiguration.additionalPathHints,
                "enableDebugLogging": launchConfiguration.enableDebugLogging,
                "environmentKeys": Array(launchConfiguration.environment.keys).sorted()
            ]
            if let configContent = launchConfiguration.environment["OPENCODE_CONFIG_CONTENT"] {
                payload["opencodeConfigContentLength"] = configContent.count
                if let data = configContent.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    payload["opencodeConfigKeys"] = Array(parsed.keys).sorted()
                    if let servers = parsed["mcp"] as? [String: Any] {
                        payload["opencodeMCPServerNames"] = Array(servers.keys).sorted()
                    }
                } else {
                    payload["opencodeConfigContentParseError"] = true
                }
            }
            return payload
        }
    #endif

    private func openCodeEmptyPromptDiagnosticMessage(from response: [String: Any], stopReason: String?) -> String? {
        guard provider.providerID == .openCode,
              isSuccessfulEmptyPromptStopReason(stopReason),
              activePromptNormalizedContentCount == 0,
              activePromptNormalizedReasoningCount == 0,
              openCodePromptUsageIndicatesNoModelTokens(response)
        else {
            return nil
        }

        let usage = response["usage"] as? [String: Any]
        let inputTokens = intValue(usage?["inputTokens"]) ?? 0
        let outputTokens = intValue(usage?["outputTokens"]) ?? 0
        let totalTokens = intValue(usage?["totalTokens"]) ?? 0
        let stopDescription = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? stopReason! : "unknown"
        let stderrDescription = activePromptOpenCodeStderrError.map {
            " OpenCode stderr reported: \($0)."
        } ?? ""
        #if DEBUG
            let updateCounts = activePromptSessionUpdateCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            let updateDescription = updateCounts.isEmpty ? "none" : updateCounts
            return "OpenCode ACP completed with stopReason=\(stopDescription) but emitted no assistant content or reasoning chunks. Prompt usage was input=\(inputTokens), output=\(outputTokens), total=\(totalTokens); raw session updates during the prompt: \(updateDescription).\(stderrDescription) RepoPrompt did not receive model text to render."
        #else
            return "OpenCode ACP completed with stopReason=\(stopDescription) but emitted no assistant content or reasoning chunks. Prompt usage was input=\(inputTokens), output=\(outputTokens), total=\(totalTokens).\(stderrDescription) RepoPrompt did not receive model text to render."
        #endif
    }

    private func isSuccessfulEmptyPromptStopReason(_ stopReason: String?) -> Bool {
        guard let normalized = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else {
            return true
        }
        return ["end_turn", "stop", "completed", "complete"].contains(normalized)
    }

    private func openCodePromptUsageIndicatesNoModelTokens(_ response: [String: Any]) -> Bool {
        guard let usage = response["usage"] as? [String: Any] else { return false }
        let inputTokens = intValue(usage["inputTokens"])
        let outputTokens = intValue(usage["outputTokens"])
        let totalTokens = intValue(usage["totalTokens"])
        if let totalTokens {
            return totalTokens == 0
        }
        if inputTokens != nil || outputTokens != nil {
            return (inputTokens ?? 0) == 0 && (outputTokens ?? 0) == 0
        }
        return false
    }

    private func recordActivePromptTraceUpdate(
        sourceUpdate: [String: Any],
        normalizedEvents: [NormalizedAgentRuntimeEvent]
    ) {
        guard let activePromptTurnID else { return }
        #if DEBUG
            let sourceSessionUpdate = (sourceUpdate["sessionUpdate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = sourceSessionUpdate?.isEmpty == false ? sourceSessionUpdate! : "<missing>"
            activePromptSessionUpdateCounts[key, default: 0] += 1
        #endif
        for event in normalizedEvents {
            guard case let .stream(result) = event else { continue }
            #if DEBUG
                activePromptNormalizedStreamCount += 1
            #endif
            switch result.type {
            case "content":
                activePromptNormalizedContentCount += 1
                promptReceiptEvidenceByTurnID[activePromptTurnID]?.agentStreamed = true
            case "reasoning":
                activePromptNormalizedReasoningCount += 1
                promptReceiptEvidenceByTurnID[activePromptTurnID]?.agentStreamed = true
            default:
                break
            }
        }
    }

    private func recordActivePromptStderrLine(_ line: String) {
        guard activePromptTurnID != nil,
              provider.providerID == .openCode
        else {
            return
        }

        let lowercased = line.lowercased()
        guard lowercased.contains("level=error")
            || lowercased.contains("stream error")
            || lowercased.contains("ai_apicallerror")
        else {
            return
        }

        activePromptOpenCodeStderrError = Self.truncatedDiagnosticPreview(
            Self.openCodeProviderErrorSummary(from: line),
            limit: 360
        )
    }

    private static func openCodeProviderErrorSummary(from stderrLine: String) -> String {
        for key in ["error.error", "error"] {
            if let value = shellStyleKeyValue(key, in: stderrLine) {
                return cleanOpenCodeProviderError(value)
            }
        }
        return truncatedDiagnosticPreview(stderrLine, limit: 360)
    }

    private static func cleanOpenCodeProviderError(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "AI_APICallError:",
            "APICallError:"
        ]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            return trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func shellStyleKeyValue(_ key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: "\(key)=") else { return nil }
        var index = keyRange.upperBound
        guard index < line.endIndex else { return nil }
        if line[index] == "\"" {
            line.formIndex(after: &index)
            var value = ""
            var escaped = false
            while index < line.endIndex {
                let character = line[index]
                line.formIndex(after: &index)
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return value
                } else {
                    value.append(character)
                }
            }
            return value.isEmpty ? nil : value
        }

        let end = line[index...].firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
        let value = line[index ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    #if DEBUG
        private func promptTraceCountersPayload() -> [String: Any] {
            [
                "sessionUpdateCounts": activePromptSessionUpdateCounts,
                "normalizedStreamCount": activePromptNormalizedStreamCount,
                "normalizedContentCount": activePromptNormalizedContentCount,
                "normalizedReasoningCount": activePromptNormalizedReasoningCount
            ]
        }

        private func promptTraceSummary(for promptBlocks: [[String: Any]]) -> [String: Any] {
            let blockSummaries = promptBlocks.enumerated().map { index, block in
                promptBlockTraceSummary(index: index, block: block)
            }
            let totalTextLength = promptBlocks.reduce(0) { total, block in
                total + ((block["text"] as? String)?.count ?? 0)
            }
            return [
                "blockCount": promptBlocks.count,
                "totalTextLength": totalTextLength,
                "blocks": blockSummaries
            ]
        }

        private func promptBlockTraceSummary(index: Int, block: [String: Any]) -> [String: Any] {
            var summary: [String: Any] = [
                "index": index,
                "keys": Array(block.keys).sorted()
            ]
            if let type = block["type"] as? String {
                summary["type"] = type
            }
            if let text = block["text"] as? String {
                summary["textLength"] = text.count
                summary["textHeadPreview"] = Self.normalizedACPPreview(text)
                summary["textTailPreview"] = Self.normalizedACPTailPreview(text)
            }
            if let uri = block["uri"] as? String {
                summary["uri"] = uri
            }
            if let mimeType = block["mimeType"] as? String {
                summary["mimeType"] = mimeType
            }
            if let data = block["data"] as? String {
                summary["dataLength"] = data.count
            }
            return summary
        }

        private func capturePromptTraceEvent(kind: String, payload: [String: Any]) {
            captureRawACPEvent(kind: kind, payload: payload)
        }

        private var isRawACPCaptureEnabled: Bool {
            rawACPCaptureURL != nil
        }

        private var isACPFragmentDiagnosticsEnabled: Bool {
            isRawACPCaptureEnabled && Self.resolveACPFragmentDiagnosticsEnabled(for: provider.providerID)
        }

        private func captureNormalizedACPEvents(
            _ events: [NormalizedAgentRuntimeEvent],
            sessionID: String,
            sourceUpdate: [String: Any]
        ) {
            guard isRawACPCaptureEnabled else { return }
            var payload: [String: Any] = [
                "sessionId": sessionID,
                "normalizedEventCount": events.count,
                "events": events.map(normalizedACPEventSummary)
            ]
            if let sourceSessionUpdate = sourceUpdate["sessionUpdate"] as? String {
                payload["sourceSessionUpdate"] = sourceSessionUpdate
            }
            captureRawACPEvent(kind: "session.update.normalized", payload: payload)
        }

        private func captureFragmentDiagnosticsIfEnabled(
            _ events: [NormalizedAgentRuntimeEvent],
            sourceUpdate: [String: Any]
        ) {
            guard isACPFragmentDiagnosticsEnabled else { return }
            let sourceSessionUpdate = sourceUpdate["sessionUpdate"] as? String
            for event in events {
                guard case let .stream(result) = event else { continue }
                captureFragmentDiagnosticIfEnabled(
                    source: "normalized",
                    streamType: result.type,
                    sampleSource: result.text ?? result.reasoning,
                    plainLength: result.text?.count ?? 0,
                    thoughtLength: result.reasoning?.count ?? 0,
                    sourceSessionUpdate: sourceSessionUpdate
                )
            }
        }

        private func captureFragmentDiagnosticIfEnabled(
            source: String,
            streamType: String,
            sampleSource: String?,
            plainLength: Int,
            thoughtLength: Int,
            sourceSessionUpdate: String?
        ) {
            guard isACPFragmentDiagnosticsEnabled,
                  let payload = Self.fragmentDiagnosticPayload(
                      source: source,
                      streamType: streamType,
                      sampleSource: sampleSource,
                      plainLength: plainLength,
                      thoughtLength: thoughtLength,
                      sourceSessionUpdate: sourceSessionUpdate
                  )
            else { return }
            captureRawACPEvent(kind: "fragment.diagnostic", payload: payload)
        }

        private static func fragmentDiagnosticPayload(
            source: String,
            streamType: String,
            sampleSource: String?,
            plainLength: Int,
            thoughtLength: Int,
            sourceSessionUpdate: String?
        ) -> [String: Any]? {
            guard let sampleSource else { return nil }
            let sample = sampleSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty, sample.count <= 80 else { return nil }
            var payload: [String: Any] = [
                "source": source,
                "streamType": streamType,
                "plainLength": plainLength,
                "thoughtLength": thoughtLength,
                "sample": sample,
                "scalars": sample.unicodeScalars.map { String(format: "U+%04X", Int($0.value)) }
            ]
            if let sourceSessionUpdate, !sourceSessionUpdate.isEmpty {
                payload["sourceSessionUpdate"] = sourceSessionUpdate
            }
            return payload
        }

        private func normalizedACPEventSummary(_ event: NormalizedAgentRuntimeEvent) -> [String: Any] {
            switch event {
            case let .stream(result):
                var summary: [String: Any] = [
                    "kind": "stream",
                    "type": result.type,
                    "textLength": result.text?.count ?? 0,
                    "reasoningLength": result.reasoning?.count ?? 0,
                    "hasToolArgsJSON": result.toolArgsJSON != nil,
                    "hasToolResultJSON": result.toolResultJSON != nil
                ]
                if let textPreview = Self.normalizedACPPreview(result.text) {
                    summary["textPreview"] = textPreview
                }
                if let reasoningPreview = Self.normalizedACPPreview(result.reasoning) {
                    summary["reasoningPreview"] = reasoningPreview
                }
                if let toolName = result.toolName {
                    summary["toolName"] = toolName
                }
                if let toolInvocationID = result.toolInvocationID {
                    summary["toolInvocationID"] = toolInvocationID.uuidString
                }
                if let toolArgsJSONLength = result.toolArgsJSON?.count {
                    summary["toolArgsJSONLength"] = toolArgsJSONLength
                }
                if let toolResultJSONLength = result.toolResultJSON?.count {
                    summary["toolResultJSONLength"] = toolResultJSONLength
                }
                if let toolIsError = result.toolIsError {
                    summary["toolIsError"] = toolIsError
                }
                if let providerSessionID = result.providerSessionID {
                    summary["providerSessionID"] = providerSessionID
                }
                if let stopReason = result.stopReason {
                    summary["stopReason"] = stopReason
                }
                if let contextUsedTokens = result.contextUsedTokens {
                    summary["contextUsedTokens"] = contextUsedTokens
                }
                if let modelContextWindow = result.modelContextWindow {
                    summary["modelContextWindow"] = modelContextWindow
                }
                if let promptTokens = result.promptTokens {
                    summary["promptTokens"] = promptTokens
                }
                if let completionTokens = result.completionTokens {
                    summary["completionTokens"] = completionTokens
                }
                if let cost = result.cost {
                    summary["cost"] = cost
                }
                if let contentMessageID = result.contentMessageID {
                    summary["contentMessageID"] = contentMessageID
                }
                return summary
            case let .approvalRequested(request):
                return [
                    "kind": "approvalRequested",
                    "requestID": request.requestID.displayValue,
                    "method": request.method,
                    "approvalKind": String(describing: request.kind)
                ]
            case let .approvalCancelled(requestID):
                return [
                    "kind": "approvalCancelled",
                    "requestID": requestID.displayValue
                ]
            case let .terminal(state, errorText):
                var summary: [String: Any] = [
                    "kind": "terminal",
                    "state": state.rawValue
                ]
                if let errorTextPreview = Self.normalizedACPPreview(errorText) {
                    summary["errorTextPreview"] = errorTextPreview
                }
                return summary
            }
        }

        private static func normalizedACPPreview(_ text: String?, limit: Int = 200) -> String? {
            guard let text, !text.isEmpty else { return nil }
            if text.count <= limit {
                return text
            }
            return String(text.prefix(limit))
        }

        private static func normalizedACPTailPreview(_ text: String?, limit: Int = 200) -> String? {
            guard let text, !text.isEmpty else { return nil }
            if text.count <= limit {
                return text
            }
            return String(text.suffix(limit))
        }

        private static func resolveACPFragmentDiagnosticsEnabled(for providerID: ACPProviderID) -> Bool {
            let env = ProcessInfo.processInfo.environment
            if isTruthyEnvironmentFlag(env["RP_ACP_FRAGMENT_DIAGNOSTICS"]) {
                return true
            }
            let providerSpecificKey = switch providerID {
            case .cursor:
                "RP_CURSOR_ACP_FRAGMENT_DIAGNOSTICS"
            case .openCode:
                "RP_OPENCODE_ACP_FRAGMENT_DIAGNOSTICS"
            case .ohMyPi:
                "RP_OMP_ACP_FRAGMENT_DIAGNOSTICS"
            }
            return isTruthyEnvironmentFlag(env[providerSpecificKey])
        }

        private static func isTruthyEnvironmentFlag(_ rawValue: String?) -> Bool {
            guard let rawValue else { return false }
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            default:
                return false
            }
        }

        private func captureRawACPEvent(kind: String, payload: [String: Any]) {
            guard let url = rawACPCaptureURL else { return }
            Self.writeRawACPEvent(
                to: url,
                kind: kind,
                payload: payload,
                providerID: provider.providerID,
                controllerState: state.rawValue,
                hasActivePromptTurn: activePromptTurnID != nil,
                suppressSessionLoadReplayUpdates: suppressSessionLoadReplayUpdates,
                sessionID: sessionID
            )
        }

        private static let rawACPCaptureWriteLock = NSLock()

        private static func writeRawACPEvent(
            to url: URL,
            kind: String,
            payload: [String: Any],
            providerID: ACPProviderID,
            controllerState: String,
            hasActivePromptTurn: Bool,
            suppressSessionLoadReplayUpdates: Bool,
            sessionID: String?
        ) {
            var record: [String: Any] = [
                "capturedAt": ISO8601DateFormatter().string(from: Date()),
                "kind": kind,
                "payload": sanitizeRawCaptureDictionary(payload),
                "providerID": providerID.rawValue,
                "controllerState": controllerState,
                "hasActivePromptTurn": hasActivePromptTurn,
                "suppressSessionLoadReplayUpdates": suppressSessionLoadReplayUpdates
            ]
            if let sessionID, !sessionID.isEmpty {
                record["controllerSessionID"] = sessionID
            }
            guard JSONSerialization.isValidJSONObject(record),
                  var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            else {
                return
            }
            data.append(0x0A)

            let parent = url.deletingLastPathComponent()
            _ = try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

            rawACPCaptureWriteLock.lock()
            defer { rawACPCaptureWriteLock.unlock() }
            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { return }
            defer { _ = Darwin.close(descriptor) }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { return }
            try? FDWriteSupport.writeAll(data, to: descriptor)
        }

        private static func sanitizeRawCaptureDictionary(_ dictionary: [String: Any]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, sanitizeRawCaptureValue(value, key: key))
            })
        }

        private static func sanitizeRawCaptureValue(_ value: Any, key: String?) -> Any {
            if let key, isSensitiveRawCaptureKey(key) {
                return "<redacted>"
            }
            if let dictionary = value as? [String: Any] {
                return sanitizeRawCaptureDictionary(dictionary)
            }
            if let array = value as? [Any] {
                return array.map { sanitizeRawCaptureValue($0, key: nil) }
            }
            if let string = value as? String, looksSensitiveRawCaptureString(string) {
                return "<redacted>"
            }
            return value
        }

        private static func isSensitiveRawCaptureKey(_ key: String) -> Bool {
            let normalized = key.lowercased().filter(\.isLetter)
            return [
                "argument", "authorization", "command", "content", "cookie", "credential",
                "cwd", "data", "diagnostic", "environment", "error", "key", "output",
                "password", "path", "prompt", "rawinput", "reasoning", "response", "result",
                "secret", "text", "token", "uri", "value", "workingdirectory"
            ].contains { normalized.contains($0) }
        }

        private static func looksSensitiveRawCaptureString(_ value: String) -> Bool {
            let normalized = value.lowercased()
            return normalized.contains("bearer ")
                || normalized.contains("api_key=")
                || normalized.contains("apikey=")
                || normalized.contains("access_token=")
                || normalized.contains("password=")
                || normalized.contains("secret=")
        }
    #endif

    private func diagnose(_ event: DiagnosticEvent) {
        diagnosticSink?(event)
    }
}
