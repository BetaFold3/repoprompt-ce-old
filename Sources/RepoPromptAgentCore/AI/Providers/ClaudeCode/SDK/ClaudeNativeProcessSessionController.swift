import Darwin
import Foundation
import os
import OSLog
import RepoPromptPlatform
import RepoPromptShared
import RepoPromptWorkspace

package final actor ClaudeNativeProcessSessionController {
    enum CommandProvenance: String, Equatable {
        case configuredOverride
        case automaticResolved
        case programmaticOverride
    }

    struct ResolvedLaunchCommand: Equatable {
        let command: String
        let provenance: CommandProvenance
    }

    private static let processLogger = Logger(
        subsystem: "com.repoprompt.agents",
        category: "ClaudeNativeProcess"
    )
    private static let rawEventLogFilePathKey = "claudeRawEventLogFilePath"
    private static let lastRawEventLogFilePathKey = "claudeLastRawEventLogFilePath"
    private static let rawEventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    package enum TurnStatus {
        case completed
        case cancelled
        case failed
    }

    /// Step 12: where a turn completion came from. Only a completion emitted on the CLI's own
    /// boundary for this FIFO position is provider evidence for the turn.
    package enum TurnCompletionOrigin: Equatable {
        /// Emitted on the CLI's own `result` for this turn: immediately, or (deferred mode) at the
        /// CLI's own `idle` that follows it. The status is `determineTurnStatus`'s classification
        /// of that result; the evidence is what the result itself and the FIFO showed when it was
        /// processed.
        case providerResult(ProviderResultEvidence)
        /// Emitted by the controller rather than on a CLI boundary: stdout EOF (process exit), a
        /// protocol failure, the deferred-completion idle-fallback timer, or the shutdown/EOF flush
        /// of deferred completions. The last two carry a status classified from a CLI result, but
        /// the controller timed the completion, so it is never provider-result evidence.
        case controllerSynthesized

        /// What a CLI `result` showed about the turn it was FIFO-credited to.
        package struct ProviderResultEvidence: Equatable {
            /// When the result was processed, this turn was the controller's only written turn
            /// without a result, and no earlier result was still waiting for `idle`. Attribution is
            /// FIFO, so a message the CLI skipped (no result) shifts later results one turn early;
            /// with no other turn outstanding, no skipped message can sit ahead of this one.
            package var soleOutstandingTurn: Bool
            /// The result payload itself reports an aborted or interrupted turn (its `subtype` is
            /// `error_during_execution`, or its `subtype`, `stop_reason`, `terminal_reason` or
            /// `errors` name a cancellation), independent of the controller's interrupt marker. A
            /// `success` result never does.
            package var reportsInterruption: Bool
            /// The result's own consumed-user attribution (`user_message_uuid(s)`) against the
            /// outbound UUID this controller wrote for the credited turn.
            package var messageIdentity: MessageIdentity

            package init(
                soleOutstandingTurn: Bool,
                reportsInterruption: Bool,
                messageIdentity: MessageIdentity
            ) {
                self.soleOutstandingTurn = soleOutstandingTurn
                self.reportsInterruption = reportsInterruption
                self.messageIdentity = messageIdentity
            }
        }

        package enum MessageIdentity: Equatable {
            /// The result carries no (non-null) `user_message_uuid` / `user_message_uuids`.
            case notReported
            /// Every attribution the result carries names exactly the credited turn's outbound UUID
            /// (`user_message_uuids` exactly that singleton).
            case namesTurn
            /// The result names another message, more than one, or a turn written without an
            /// outbound UUID: it is not this turn's result.
            case contradictsTurn
        }

        /// The CLI's own interrupted-turn result, attributed while no other written turn was
        /// outstanding, and affirmatively attributed by the CLI to exactly this turn's outbound
        /// message. Unattributed results never qualify: an unrelated interrupted or failed result
        /// (for example an aborted background continuation) carries no consumed user message, and
        /// a turn written without an outbound UUID can never be named, so it stays uncertain.
        package var isExclusiveInterruptedResult: Bool {
            guard case let .providerResult(evidence) = self else { return false }
            return evidence.soleOutstandingTurn
                && evidence.reportsInterruption
                && evidence.messageIdentity == .namesTurn
        }
    }

    /// RepoPrompt MCP health of the current launch. Transient and launch-scoped: every spawn starts
    /// `unknown`; fresh evidence (a `system/init` or `mcp_status` report of `connected`) makes it
    /// `connected`; an app-initiated loss of this launch's connection makes it `unhealthy` for the
    /// rest of the launch, and no later evidence on that launch restores `connected`.
    package enum RepoPromptMCPHealth: Equatable {
        case unknown
        case connected
        case unhealthy(reason: String)

        var isUnhealthy: Bool {
            if case .unhealthy = self { true } else { false }
        }
    }

    /// Outcome of waiting for fresh RepoPrompt MCP connected evidence on the current launch.
    package enum RepoPromptMCPConnectionProbeOutcome: Equatable {
        case connected
        case notConnected(String)
    }

    package struct RuntimeInitStatus: Equatable {
        struct InitializeResponseSnapshot: Equatable {
            struct Command: Equatable {
                let name: String
                let description: String
                let argumentHint: String
            }

            struct Agent: Equatable {
                let name: String
                let description: String
                let model: String?
            }

            struct Account: Equatable {
                let email: String?
                let organization: String?
                let subscriptionType: String?
                let tokenSource: String?
                let apiKeySource: String?
                let apiProvider: String?
            }

            let commands: [Command]
            let agents: [Agent]
            let outputStyle: String?
            let availableOutputStyles: [String]
            let account: Account?
            let pid: Int?
            let modelsJSON: String?
            let fastModeStateJSON: String?
        }

        let sessionID: String?
        let tools: [String]
        /// Reported statuses with the launch's authoritative RepoPrompt health overlaid: an
        /// unhealthy launch reports RepoPrompt as `disconnected` whatever the runtime last said.
        let mcpServerStatuses: [String: String]
        let initializeResponse: InitializeResponseSnapshot?
        var repoPromptMCPHealth: RepoPromptMCPHealth = .unknown

        var repoPromptServerStatus: String? {
            mcpServerStatuses.first {
                $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
            }?.value
        }

        var isRepoPromptServerFailed: Bool {
            guard let status = repoPromptServerStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return status == "failed"
        }
    }

    package enum Event {
        case stream(AIStreamResult)
        case runtimeInit(RuntimeInitStatus)
        case approvalRequest(AgentApprovalRequest)
        case approvalCancelled(requestID: String)
        case turnCompleted(turnID: UUID, status: TurnStatus, origin: TurnCompletionOrigin = .controllerSynthesized)
        case error(String)
        /// In-band position marker requested by the consumer (`emitEventMarker`); carries no
        /// provider output.
        case marker(UUID)
    }

    // MARK: - Usage accounting ownership (plan §3.2)

    /// Immutable identity of one successfully spawned provider process. Accounting executions
    /// are keyed by `token`; a controller instance is reusable and therefore not an execution.
    package struct ProcessLaunchIdentity: Equatable {
        enum LaunchMode: Equatable {
            case freshSession
            case resumedSession(String)
        }

        let token: UUID
        let pid: Int32
        let launchMode: LaunchMode
        let commandProvenance: CommandProvenance
        let runtimeVariant: ClaudeCodeRuntimeVariant
        /// Command actually handed to the spawner (may be a PATH wrapper or symlink).
        let executablePath: String
        /// `executablePath` with symlinks resolved; the value a contract must match exactly.
        let executableRealPath: String
        /// Effective backend of the launch environment (first-party or a compatible backend).
        let backend: ClaudeCodeLaunchEnvironment.Backend
        /// Backend-routing evidence derived from the final environment handed to the spawner: every
        /// resolver override/removed key plus every backend-routing key present in the child
        /// environment whatever its origin (inherited login shell, configured override or resolver).
        /// Keys only — values, which may be secrets, never enter the identity. Any entry means the
        /// launch may not be talking to the first-party backend in the qualified shape.
        let environmentOverrideKeys: [String]
        /// Keys of the app's own configured process overrides (`config.processEnvironmentOverrides`)
        /// applied to this launch, regardless of classification. Diagnostic provenance only.
        let configuredEnvironmentOverrideKeys: [String]
        let spawnedAt: Date

        init(
            token: UUID,
            pid: Int32,
            launchMode: LaunchMode,
            commandProvenance: CommandProvenance,
            runtimeVariant: ClaudeCodeRuntimeVariant,
            executablePath: String,
            executableRealPath: String,
            backend: ClaudeCodeLaunchEnvironment.Backend,
            environmentOverrideKeys: [String],
            configuredEnvironmentOverrideKeys: [String] = [],
            spawnedAt: Date
        ) {
            self.token = token
            self.pid = pid
            self.launchMode = launchMode
            self.commandProvenance = commandProvenance
            self.runtimeVariant = runtimeVariant
            self.executablePath = executablePath
            self.executableRealPath = executableRealPath
            self.backend = backend
            self.environmentOverrideKeys = environmentOverrideKeys
            self.configuredEnvironmentOverrideKeys = configuredEnvironmentOverrideKeys
            self.spawnedAt = spawnedAt
        }
    }

    /// Runtime-reported provenance for one launch: the initialize account category plus the first
    /// `system/init` fields. Category strings only, bound to the launch token; recorded as
    /// diagnostics and never used to gate reported figures.
    package struct RuntimeBinding: Equatable {
        let runtimeVersion: String
        let apiProvider: String?
        let apiKeySource: String?
        let model: String?
        let permissionMode: String?
    }

    /// Launch-environment evidence bound into `ProcessLaunchIdentity` (plan §2.10). It is derived
    /// from the exact dictionary handed to `ProcessLauncher.spawn`, never from resolver intent
    /// alone, so a redirect that reaches the child only through the inherited login shell or a
    /// configured override is still evidence.
    struct LaunchEnvironmentEvidence: Equatable {
        let environmentOverrideKeys: [String]
        let configuredEnvironmentOverrideKeys: [String]
    }

    /// Environment keys that change which backend, account or credential a launch talks to.
    /// Recorded on the launch identity as key names only (diagnostic provenance); they do not
    /// gate the runtime's reported figures.
    static let backendRoutingEnvironmentKeyPrefixes: [String] = ["ANTHROPIC_", "CLAUDE_CODE_USE_"]
    static let backendRoutingEnvironmentKeys: Set<String> = ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"]

    static func isBackendRoutingEnvironmentKey(_ key: String) -> Bool {
        backendRoutingEnvironmentKeys.contains(key)
            || backendRoutingEnvironmentKeyPrefixes.contains { key.hasPrefix($0) }
    }

    static func launchEnvironmentEvidence(
        finalEnvironment: [String: String],
        resolverOverrides: [String: String],
        resolverRemovedKeys: Set<String>,
        configuredOverrides: [String: String]
    ) -> LaunchEnvironmentEvidence {
        var routingKeys = Set(resolverOverrides.keys)
        routingKeys.formUnion(resolverRemovedKeys)
        routingKeys.formUnion(finalEnvironment.keys.filter(isBackendRoutingEnvironmentKey))
        routingKeys.formUnion(configuredOverrides.keys.filter(isBackendRoutingEnvironmentKey))
        return LaunchEnvironmentEvidence(
            environmentOverrideKeys: routingKeys.sorted(),
            configuredEnvironmentOverrideKeys: configuredOverrides.keys.sorted()
        )
    }

    /// Why the controller stopped attributing results on a launch. Typed so core can map it to
    /// an execution block reason without parsing text.
    package enum UsageAttributionBlock: Equatable {
        case missingRuntimeVersion
        case runtimeVersionConflict
        case providerSessionIdentityChanged
        case desynchronized(String)

        var description: String {
            switch self {
            case .missingRuntimeVersion: "system/init without claude_code_version"
            case .runtimeVersionConflict: "claude_code_version changed within one process"
            case .providerSessionIdentityChanged: "provider session identity changed within one process"
            case let .desynchronized(detail): detail
            }
        }
    }

    /// A raw `result` positively attributed to the dispatch it answers, on the current launch.
    package struct UsageResultAttribution: Equatable {
        let launchToken: UUID
        let turnID: UUID
        let dispatchOrdinal: Int
        let resultIndex: Int
        let queuedTurnCount: Int?
        let runtimeVersion: String
        let providerSessionID: String
        let observation: AgentProviderUsageObservation
        let reportedCost: Double?
        let turnStatus: TurnStatus
        /// Native child (subagent) activity was observed for this turn: an `Agent`/`Task` tool use
        /// on the main line since the previous result, or `subagent_stats.spawned > 0` on the
        /// result. Evidence only; core decides the token-scope consequence.
        let childActivityObserved: Bool

        init(
            launchToken: UUID,
            turnID: UUID,
            dispatchOrdinal: Int,
            resultIndex: Int,
            queuedTurnCount: Int?,
            runtimeVersion: String,
            providerSessionID: String,
            observation: AgentProviderUsageObservation,
            reportedCost: Double?,
            turnStatus: TurnStatus,
            childActivityObserved: Bool = false
        ) {
            self.launchToken = launchToken
            self.turnID = turnID
            self.dispatchOrdinal = dispatchOrdinal
            self.resultIndex = resultIndex
            self.queuedTurnCount = queuedTurnCount
            self.runtimeVersion = runtimeVersion
            self.providerSessionID = providerSessionID
            self.observation = observation
            self.reportedCost = reportedCost
            self.turnStatus = turnStatus
            self.childActivityObserved = childActivityObserved
        }
    }

    /// One main-line Claude assistant API request observed while a dispatch is outstanding. The
    /// Anthropic message ID deduplicates repeated assistant chunks; a missing observation is still
    /// emitted so a newer request without usage clears the previous latest-request value.
    package struct UsageRequestAttribution: Equatable {
        let launchToken: UUID
        let turnID: UUID
        let requestID: String?
        let observation: AgentProviderUsageObservation?
    }

    /// Ordered accounting events delivered on a dedicated stream, independent of transcript
    /// delivery and of any run attempt's consumer. Ownership decisions (contract, baseline,
    /// queue policy, counter boundaries) are made by core; the controller reports evidence and
    /// proves launch/dispatch/result correlation plus live main-line request scope.
    package enum UsageAccountingEvent: Equatable {
        case launched(ProcessLaunchIdentity)
        case runtimeEvidence(launchToken: UUID, runtimeVersion: String, providerSessionID: String?)
        /// Runtime provenance observed on the first `system/init` (after `runtimeEvidence`);
        /// repeated initializations never re-emit it. Diagnostic only.
        case runtimeBinding(launchToken: UUID, binding: RuntimeBinding)
        case dispatched(launchToken: UUID, turnID: UUID, ordinal: Int)
        case counterBoundaryObserved(launchToken: UUID, kind: String)
        /// Live-only presentation evidence. It is never retained in the resubscription replay.
        case mainRequestUsageAttributed(UsageRequestAttribution)
        case resultAttributed(UsageResultAttribution)
        /// Completion-lifecycle closure of a dispatched turn, emitted on this same ordered stream
        /// after any attribution decision for that turn so closure can never race a result.
        case turnClosed(launchToken: UUID, turnID: UUID, status: TurnStatus)
        case blocked(launchToken: UUID, reason: UsageAttributionBlock)
        case launchEnded(launchToken: UUID)
    }

    /// Outcome of attributing one raw `result` payload on the current launch.
    private enum UsageResultDisposition: Equatable {
        /// No active launch, or the launch is already blocked: legacy completion bookkeeping only.
        case notEvaluated
        case attributed
        /// Same uuid with identical accounting fields as an already attributed result. It is a
        /// re-delivery, not a second turn boundary, so it must not advance completion bookkeeping
        /// either; otherwise the FIFO would retire the next dispatched turn before its own result.
        case exactDuplicate
        case blocked
    }

    private struct UsageResultFingerprint: Equatable {
        let resultIndex: Int?
        let reportedCost: Double?
        let observation: AgentProviderUsageObservation
    }

    private struct UsageLaunchState {
        let identity: ProcessLaunchIdentity
        var nextDispatchOrdinal = 0
        var turnIDByDispatchOrdinal: [Int: UUID] = [:]
        var nextResultOrdinal = 0
        var runtimeVersion: String?
        var providerSessionID: String?
        var blockedReason: UsageAttributionBlock?
        var attributedResultFingerprints: [String: UsageResultFingerprint] = [:]
        var binding: RuntimeBinding?
        /// A main-line `Agent`/`Task` tool use was observed since the last attributed result.
        var childToolObservedSinceLastResult = false
    }

    package struct SessionRef {
        var sessionID: String?
        var configuredContextWindow: Int?
        var promptCacheRetention: MCPTimeoutPolicy.AgentLifecycleParentPromptCacheRetention = .standard
        var initializationGeneration: UInt64 = 0
        var initializedDuringCall: Bool = false
    }

    /// Outcome of an interrupt control request, used by the coordinator to decide
    /// whether it is safe to proceed with a superseding user turn.
    package enum InterruptOutcome: Equatable {
        /// Claude acknowledged the interrupt via control_response success.
        case acknowledged
        /// No turn was in flight; the turn likely completed naturally before the interrupt.
        case noTurnInFlight
        /// The interrupt control request timed out without an acknowledgement.
        case timedOut
        /// The interrupt request failed (e.g. process not running or write error).
        case failed
    }

    struct PermissionStageError: Error, LocalizedError {
        let requestedMode: String
        let underlyingError: Error

        var errorDescription: String? {
            "Claude rejected permission mode '\(requestedMode)' during initialization: \(underlyingError.localizedDescription)"
        }
    }

    struct AutoPermissionLiveMutationError: Error, LocalizedError, Equatable {
        enum Reason: Equatable {
            case initializationIncomplete
            case turnInFlight
        }

        let reason: Reason

        var errorDescription: String? {
            switch reason {
            case .initializationIncomplete:
                "Claude Auto settings cannot change before initialization completes."
            case .turnInFlight:
                "Claude Auto settings cannot change while a turn is active."
            }
        }
    }

    enum ControllerError: Error, LocalizedError {
        case processNotRunning
        case initializationFailed(String)
        case invalidControlResponse(String)
        case inputWriteFailed(String)
        case controlRequestTimedOut(requestID: String, detail: String?)
        case liveModelSwitchRequiresRestart
        /// The launch's RepoPrompt MCP connection was lost; it must be restarted (resuming its
        /// conversation) before it can take another turn. Thrown before any write.
        case repoPromptMCPRecoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                "Claude process is not running."
            case let .initializationFailed(message):
                "Claude initialization failed: \(message)"
            case let .invalidControlResponse(message):
                "Claude control response failed: \(message)"
            case let .inputWriteFailed(message):
                "Failed writing to Claude process stdin: \(message)"
            case let .controlRequestTimedOut(requestID, detail):
                if let detail {
                    "Claude control request timed out: \(requestID); \(detail)"
                } else {
                    "Claude control request timed out: \(requestID)"
                }
            case .liveModelSwitchRequiresRestart:
                "Changing to the selected model requires restarting Claude because its launch environment changes."
            case let .repoPromptMCPRecoveryRequired(reason):
                "RepoPrompt MCP is disconnected from this Claude process (\(reason)); Claude must restart and resume this conversation before the next turn."
            }
        }
    }

    private struct PendingPermissionRequest {
        let requestID: String
        let request: [String: Any]
        /// R6: the runtime launch whose transport issued the request (`nil` while registration is
        /// off). Its reply goes only to that transport, never to a replacement.
        let issuingLaunch: AgentRuntimeLaunch?
    }

    private struct LaunchEnvironmentSignature: Equatable {
        let environmentOverrides: [String: String]
        let removedEnvironmentKeys: Set<String>
        let backend: ClaudeCodeLaunchEnvironment.Backend

        init(_ launchEnvironment: ClaudeCodeLaunchEnvironment) {
            environmentOverrides = launchEnvironment.environmentOverrides
            removedEnvironmentKeys = launchEnvironment.removedEnvironmentKeys
            backend = launchEnvironment.backend
        }
    }

    private let runID: UUID
    private let tabID: UUID
    private let windowID: Int
    private let workspacePath: String?
    private let config: ClaudeCodeAgentConfig
    private let commandSelection: CLICommandSelection
    private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
    private let managedSettingsURL: URL?
    private let mcpHost: any AgentMCPHosting
    private let configService = MCPConfigExportService.shared
    private let rawEventFileLoggingEnabled: Bool
    private var rawEventLogFileURL: URL?
    private var rawEventLogFileSessionID: String?
    private var hasWrittenRawEventLogHeader = false

    private var process: SpawnedProcess?
    /// Runtime ownership of `process` (spec R6); `nil` while Phase 3 registration is off.
    private var runtimeLaunch: AgentRuntimeLaunch?
    /// Whether the current transport was spawned under a runtime launch; every stdin write then
    /// requires `runtimeLaunch` to be that committed launch (synchronous transport-owner check).
    private var runtimeManagedTransport = false
    private var runtimeCommittedLaunch: AgentRuntimeLaunch?
    /// R6: the native conversation durably associated with the current launch. Authorize-only
    /// writes (replies, interrupts, settings) are checked against it, never against an observed
    /// but not yet associated session ID.
    private var runtimeAssociatedConversationID: String?
    /// R6: the owner scope of the latest owner write on the current launch: the operation whose
    /// output reports a fresh session ID owns that conversation's association.
    private var runtimeLastOwnerScope: AgentRuntimeSessionScope?
    /// R6: owned exact-root reaps of registered launches (one per pid), joined by shutdown and
    /// before a successor launch reserves. Never populated while registration is off.
    private var pendingRootReaps: [pid_t: Task<Void, Never>] = [:]
    /// R6 (managed transports): an automatic reply (auto-approval or unsupported-request error),
    /// bound to the launch whose transport delivered its request.
    private struct QueuedAutomaticReply {
        let receivingLaunch: AgentRuntimeLaunch?
        let requestID: String
        let encoded: Data
        let failureMessage: String
    }

    /// R6: automatic replies awaiting the authorize-only fence. They are written in order after the
    /// inbound line that produced them, only to their receiving transport.
    private var queuedAutomaticReplies: [QueuedAutomaticReply] = []
    private let launchAuthority: AgentRuntimeLaunchAuthority
    /// R6: this controller's one launch pair (native standard, or the compatible backend's actual
    /// variant), derived once from its immutable config and used for every launch decision.
    private nonisolated let launchFamily: AgentRuntimeFamily
    private nonisolated let launchProvider: AgentRuntimeProvider
    /// R6 subset activation: whether that pair registers its launches.
    private nonisolated let registersLaunches: Bool
    private var registeredExpectedAgentPID: pid_t?
    private var stdoutFramer = LineFramer()
    private var stderrTail = Data()
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var configLease: MCPConfigLease?
    private var configURL: URL? {
        configLease?.url
    }

    private var initialFlagSettingsRequest: [String: Any]?
    private var activeFlagSettingsBaseModel: String?
    private var latestFlagSettingsIntentGeneration: UInt64 = 0
    private var activeLaunchEnvironmentSignature: LaunchEnvironmentSignature?
    private var flagSettingsRequestGeneration: UInt64 = 0
    private var hasCompletedInitialFlagSettings = false
    private var isInitialized = false
    private var initializationGeneration: UInt64 = 0
    private var isShuttingDown = false
    private var nextControlRequestID = 1
    private var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingControlRequestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingPermissionRequests: [String: PendingPermissionRequest] = [:]
    private var translator: ClaudeSDKNDJSONTranslator
    private var sessionID: String?
    private var configuredContextWindow: Int?
    private var promptCacheRetention: MCPTimeoutPolicy.AgentLifecycleParentPromptCacheRetention = .standard
    private var lastSpawnedCommand: String?
    private var turnInFlight: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    /// FIFO queue of turn IDs (head-pointer deque to avoid O(n) removeFirst).
    private var pendingTurnIDBuffer: ContiguousArray<UUID> = []
    private var pendingTurnIDHead: Int = 0
    private var turnWasInterrupted = false
    /// O49: snapshot of `startedTurnID`, readable without an actor hop (Stop and quit mark the
    /// started turn synchronously, before the run detaches). Written only on this actor.
    private nonisolated let startedTurnIDSnapshot = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    /// O49: the written turn that model output, reasoning, or a tool call was last attributed to,
    /// while it is still queued here. Attribution is this controller's own FIFO: output belongs to
    /// the first turn whose `result` has not arrived. Cleared when that turn is dequeued and
    /// whenever the queue is cleared, so a queued turn the CLI has not begun is never reported.
    package nonisolated var startedTurnID: UUID? {
        startedTurnIDSnapshot.withLock { $0 }
    }

    // MARK: - Authoritative lifecycle (session_state_changed)

    /// True once the provider has emitted at least one `session_state_changed` event in this
    /// controller's lifetime.  When true, turn completion defers until `idle` (or a fallback
    /// timeout) rather than completing immediately on `result/message_stop`.
    private var observedSessionStateChangedEvents = false

    /// A result-derived completion waiting for `idle`, with the origin fixed when its result was
    /// processed (Step 12).
    private struct DeferredTurnCompletion {
        let status: TurnStatus
        let origin: TurnCompletionOrigin
    }

    /// Step 12: the outbound user-message UUID each still-queued turn was written with, when its
    /// frame carried one (identity-eligible launches only). Compared with a result's own
    /// `user_message_uuid(s)`; cleared with the FIFO entry.
    private var outboundUserMessageUUIDByTurnID: [UUID: UUID] = [:]

    /// FIFO queue of result-derived turn completions waiting for an `idle` signal.
    /// Turn IDs remain in `pendingTurnIDBuffer` until the deferred completion fires
    /// so that `turnInFlight` stays true during the result→idle window.
    private var pendingAuthoritativeTurnCompletions: [DeferredTurnCompletion] = []

    /// Fallback task that fires when `idle` does not arrive within the expected window.
    private var authoritativeIdleFallbackTask: Task<Void, Never>?

    /// Generation token for the active fallback task. Stale tasks compare their token
    /// against this and no-op if they don't match (prevents race between cancel + reschedule).
    private var authoritativeIdleFallbackGeneration: UInt64 = 0

    /// Timeout before falling back to completing a turn without `idle`.
    private let authoritativeTurnIdleFallbackSeconds: TimeInterval

    // MARK: - Runtime init aggregation

    /// Parsed initialize response snapshot, stored after `initializeIfNeeded` succeeds.
    private var initializeResponseSnapshot: RuntimeInitStatus.InitializeResponseSnapshot?

    /// Tools list from the most recent `system/init` stream payload.
    private var latestRuntimeInitTools: [String] = []

    /// MCP server statuses from the most recent `system/init` stream payload.
    private var latestRuntimeInitMcpServerStatuses: [String: String] = [:]

    /// The last emitted runtime init status, used to deduplicate emissions.
    private var lastEmittedRuntimeInitStatus: RuntimeInitStatus?

    // MARK: - RepoPrompt MCP health (launch-scoped)

    private var repoPromptMCPHealth: RepoPromptMCPHealth = .unknown
    /// `async` to match `NativeAgentRuntimeControlling` exactly, so the protocol default never
    /// becomes the witness.
    package var currentRepoPromptMCPHealth: RepoPromptMCPHealth {
        get async { repoPromptMCPHealth }
    }

    /// The spawned process's PID bound to the current launch token (`currentLaunchAgentPID`) while
    /// the launch is initialized, healthy and not shutting down. It may not be registered as the
    /// run's expected agent yet. `async` to match `NativeAgentRuntimeControlling` exactly (see
    /// `currentRepoPromptMCPHealth`).
    package var repoPromptMCPLaunchAgentPID: pid_t? {
        get async {
            guard process != nil, isInitialized, !isShuttingDown,
                  !repoPromptMCPHealth.isUnhealthy
            else { return nil }
            return currentLaunchAgentPID
        }
    }

    /// The agent PID bound to the current launch token: the spawned process's PID installed
    /// together with `repoPromptMCPLaunchToken` (`installSpawnLaunchTokens`), while that token is
    /// still the current one and that process is still attached. Independent of the loss-observer
    /// registration. `registeredExpectedAgentPID` is not reset at a spawn (only at shutdown or a
    /// failed registration), so right after a respawn it still names the previous process until
    /// the new registration; this never does. The manager still fails closed for this PID until
    /// it is registered with a readable identity.
    private var currentLaunchAgentPID: pid_t? {
        guard let token = repoPromptMCPLaunchToken,
              let launch = spawnedLaunchAgent,
              launch.token == token,
              process?.pid == launch.pid
        else { return nil }
        return launch.pid
    }

    /// The spawned process's PID, installed with its launch token in one synchronous step.
    private var spawnedLaunchAgent: (token: UUID, pid: pid_t)?

    /// Connection IDs whose loss this launch already applied (duplicate deliveries are ignored).
    private var repoPromptMCPLostConnectionIDs: Set<UUID> = []
    private var runConnectionLossObserverToken: UUID?
    /// The launch identity the current loss observer is registered for.
    private var runConnectionLossObserverLaunch: AgentMCPRunLaunchIdentity?
    /// Unique per spawned process; set at spawn, cleared at shutdown. A loss is applied only when
    /// it is addressed to this token and proves ownership by the registered launch identity.
    private var repoPromptMCPLaunchToken: UUID?
    #if DEBUG
        /// Every loss decision (connection ID, `applied` or the ignore reason), in delivery order.
        private var debugRepoPromptMCPLossDecisions: [(connectionID: UUID, decision: String)] = []
    #endif

    #if DEBUG
        private var decodeSkippedWarningCount = 0
        /// Test-only suspension at R6 fence checkpoints (`launchCaptured` before the first await,
        /// `associated`, `authorized`), so fixtures can replace the transport inside a write's awaits.
        private var testRuntimeFenceCheckpoint: (@Sendable (String) async -> Void)?
        /// Test-only: records a protocol failure instead of shutting the (pipe-only) fixture
        /// transport down, so no placeholder PID is ever signalled.
        private var testProtocolFailureInterceptor: (@Sendable (String) -> Void)?
    #endif

    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var eventsStream: AsyncStream<Event>
    /// Incremented whenever `eventsStream` is replaced.
    private var eventsStreamGeneration: UInt64 = 0
    package var events: AsyncStream<Event> {
        eventsStream
    }

    /// Launch-local accounting ownership state; `nil` when no process is running.
    private var usageLaunchState: UsageLaunchState?
    /// Identity of the process whose stdout reader is current. Stale-launch discard of stdout
    /// bytes/EOF is keyed on this token, never on accounting state (`usageLaunchState`), so
    /// transcript and control delivery cannot depend on the usage feature (OracleB P1#4).
    private var activeStdoutLaunchToken: UUID?
    /// The launch whose stdout reached EOF. Its RepoPrompt MCP loss events are ignored: the
    /// launch is already ending, and `process` stays set through the EOF handler's awaited tail.
    private var repoPromptMCPStdoutRetiredLaunchToken: UUID?
    /// Step 4d3b (inactive): injected live-identity qualification; `false` by default and set by no
    /// production caller.
    private let liveTranscriptQualificationEnabled: Bool
    /// Step 4d3b: the current stdout producer's monotonic qualification state. Created only where an
    /// actual stdout launch token is installed (never by a consumer reset, turn, `system/init` or
    /// router change) and read only while its token is still current; `nil` when disabled.
    private var liveTranscriptQualification: ClaudeLiveTranscriptProducerState?
    /// Step 4d3b: the launch whose buffered stdout tail `handleStdoutEOF` is draining (only during
    /// that drain, after the stdout token was cleared).
    private var liveTranscriptEOFDrainLaunchToken: UUID?
    /// Lives for the controller's lifetime: a reusable controller keeps one stream across
    /// shutdown/relaunch cycles, so `shutdown()` only reports `launchEnded`. The stream is
    /// finished explicitly in `deinit` cleanup (after a final `launchEnded` if a launch was still
    /// active); dropping the continuation alone would not finish it.
    private var usageEventsContinuation: AsyncStream<UsageAccountingEvent>.Continuation?
    private var usageEventsStream: AsyncStream<UsageAccountingEvent>
    private var usageEventsStreamHandedOut = false
    /// Every usage event emitted for the current launch, from its `launched` up to (excluding)
    /// its `launchEnded`; cleared when the launch ends. A later subscriber is bootstrapped with
    /// it so evidence emitted between the previous subscriber finishing and the new subscription
    /// (typically the next `launched`, whose identity every later dispatch and result needs) is
    /// never lost (review R2, OracleA P1#3). Ended launches are never replayed.
    private var currentLaunchUsageEvents: [UsageAccountingEvent] = []
    /// The first subscriber receives the lifetime stream (with every event buffered since init).
    /// `AsyncStream` is single-consumer and ends for good once its iterator is cancelled, so a
    /// later subscriber (the same controller re-attached after its forwarder terminated, or a
    /// session change) receives a fresh stream: the previous one is finished, and the fresh one
    /// starts with the current launch's already-emitted evidence (nothing from ended launches).
    /// Core keeps continuity for a launch it already holds (a re-delivered `launched` is ignored
    /// there) and rejects disposed executions (OracleB P1#3, review R2).
    package var usageAccountingEvents: AsyncStream<UsageAccountingEvent> {
        guard usageEventsStreamHandedOut else {
            usageEventsStreamHandedOut = true
            return usageEventsStream
        }
        usageEventsContinuation?.finish()
        var continuation: AsyncStream<UsageAccountingEvent>.Continuation?
        let stream = AsyncStream<UsageAccountingEvent> { continuation = $0 }
        usageEventsStream = stream
        usageEventsContinuation = continuation
        for event in currentLaunchUsageEvents {
            continuation?.yield(event)
        }
        writeRawEventLogRecord(kind: "usage.stream.resubscribed", payload: [
            "launchToken": usageLaunchState?.identity.token.uuidString ?? NSNull(),
            "replayedCurrentLaunchEventCount": currentLaunchUsageEvents.count
        ] as [String: Any])
        return stream
    }

    package var hasActiveSession: Bool {
        process != nil
    }

    package var requiresReplacementAfterTerminalStartupFailure: Bool {
        if case .configuredExactPath = commandSelection {
            true
        } else {
            false
        }
    }

    deinit {
        performSynchronousDeinitCleanup()
    }

    /// Last-resort process cleanup for controller deallocation.
    ///
    /// Normal owners must call async `shutdown()`, which can reap the process and
    /// clear expected PID registrations. `deinit` cannot await that path, so this
    /// method releases file-handle callbacks, closes stdin, sends SIGTERM to the
    /// child process family, schedules group-aware termination/reaping, and schedules
    /// expected-PID cleanup on the MCP actor.
    ///
    /// The non-blocking `waitpid(WNOHANG)` here will usually return before the
    /// child exits, leaving a zombie. A detached `Task` is scheduled to reap the
    /// process asynchronously via `ProcessTermination.terminateAndReap`, which
    /// sends a follow-up SIGTERM (harmless if the child already exited) and
    /// waits for exit so the zombie is collected.
    private func performSynchronousDeinitCleanup() {
        closeOutputChannelsAndInput()
        activeStdoutLaunchToken = nil
        endUsageLaunch()
        usageEventsContinuation?.finish()
        usageEventsContinuation = nil

        if let process {
            let pid = process.pid
            let processGroupID = process.processGroupID
            ProcessTermination.signalProcessGroupOrPID(
                pid: pid,
                processGroupID: processGroupID,
                signal: SIGTERM
            )
            var status: Int32 = 0
            _ = Darwin.waitpid(pid, &status, WNOHANG)
            // Schedule an async reap so the child is collected even if the
            // non-blocking waitpid above did not reap it. The detached task is
            // cancellation-shielded by design — the actor is already gone.
            Task.detached(priority: .utility) {
                _ = await ProcessTermination.terminateAndReap(pid: pid, processGroupID: processGroupID)
            }
        }

        scheduleExpectedAgentPIDDeinitClearIfNeeded()
    }

    private func closeOutputChannelsAndInput() {
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()

        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil

        if let process {
            process.stdout.readabilityHandler = nil
            process.stderr.readabilityHandler = nil
            process.stdin?.closeFile()
        }
    }

    /// Clears MCP expected-agent PID registration when async `shutdown()` did not run.
    private func scheduleExpectedAgentPIDDeinitClearIfNeeded() {
        guard config.toolContext == .agentRun,
              let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        let pid = registeredExpectedAgentPID
        let runID = runID
        let mcpHost = mcpHost
        let lossObserverToken = runConnectionLossObserverToken
        Task {
            await mcpHost.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            if let lossObserverToken {
                await mcpHost.unregisterRunConnectionLossObserver(for: runID, token: lossObserverToken)
            }
        }
    }

    package var hasTurnInFlight: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Controller] run=\(runID.uuidString) tab=\(tabID.uuidString) \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func reasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    init(
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        workspacePath: String?,
        config: ClaudeCodeAgentConfig,
        mcpHost: any AgentMCPHosting,
        commandSelection: CLICommandSelection? = nil,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
        managedSettingsURL: URL? = ClaudePromptCacheRetentionResolver.defaultManagedSettingsURL,
        authoritativeTurnIdleFallbackSeconds: TimeInterval = 1.0,
        launchAuthority: AgentRuntimeLaunchAuthority = .production,
        liveTranscriptQualificationEnabled: Bool = false
    ) {
        self.launchAuthority = launchAuthority
        launchFamily = Self.runtimeFamily(config.runtimeVariant)
        launchProvider = .claude(config.runtimeVariant)
        registersLaunches = launchAuthority.isRegistrationActive(family: launchFamily, provider: launchProvider)
        self.liveTranscriptQualificationEnabled = liveTranscriptQualificationEnabled
        self.runID = runID
        self.tabID = tabID
        self.windowID = windowID
        self.workspacePath = workspacePath
        self.config = config
        self.mcpHost = mcpHost
        self.commandSelection = commandSelection ?? config.commandSelection
        self.environmentResolver = environmentResolver
        self.managedSettingsURL = managedSettingsURL
        self.authoritativeTurnIdleFallbackSeconds = authoritativeTurnIdleFallbackSeconds
        rawEventFileLoggingEnabled = Self.isRawEventFileLoggingEnabled()
        rawEventLogFileURL = nil
        rawEventLogFileSessionID = nil
        translator = ClaudeSDKNDJSONTranslator(enableDebugLogging: config.enableDebugLogging)
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
        var usageContinuation: AsyncStream<UsageAccountingEvent>.Continuation?
        usageEventsStream = AsyncStream { usageContinuation = $0 }
        usageEventsContinuation = usageContinuation
    }

    package func ensureEventsStreamReady() {
        guard eventsContinuation == nil else { return }
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
        eventsStreamGeneration &+= 1
    }

    package func eventsSubscription() -> NativeAgentRuntimeEventsSubscription {
        ensureEventsStreamReady()
        return NativeAgentRuntimeEventsSubscription(events: eventsStream, generation: eventsStreamGeneration)
    }

    package func emitEventMarker(_ id: UUID) -> UInt64? {
        guard let eventsContinuation else { return nil }
        eventsContinuation.yield(.marker(id))
        return eventsStreamGeneration
    }

    /// Finish the old events stream and create a fresh one.  Call this when starting a new
    /// run after a previous run was cancelled, to discard any buffered stale events and to
    /// avoid reusing an AsyncStream whose iterator may have been poisoned by task cancellation.
    package func resetEventsStreamForNewRun() {
        eventsContinuation?.finish()
        eventsContinuation = nil
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
        eventsStreamGeneration &+= 1
    }

    package func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: ClaudeCodeEffortLevel? = nil,
        systemPromptOverride: String? = nil
    ) async throws -> SessionRef {
        let initializationGenerationAtEntry = initializationGeneration
        if process != nil, isInitialized {
            // An unhealthy launch is never silently reused: the owner restarts it (resuming the
            // conversation) at a turn boundary.
            if case let .unhealthy(reason) = repoPromptMCPHealth {
                writeRawEventLogRecord(kind: "session.startOrResume.mcpRecoveryRequired", payload: ["reason": reason])
                throw ControllerError.repoPromptMCPRecoveryRequired(reason)
            }
            return SessionRef(
                sessionID: sessionID,
                configuredContextWindow: configuredContextWindow,
                promptCacheRetention: promptCacheRetention,
                initializationGeneration: initializationGeneration,
                initializedDuringCall: initializationGeneration != initializationGenerationAtEntry
            )
        }

        ensureEventsStreamReady()
        isShuttingDown = false
        ensureRawEventLogFileReadyIfNeeded(sessionIDHint: existingSessionID ?? sessionID)
        writeRawEventLogRecord(
            kind: "session.startOrResume",
            payload: [
                "existingSessionID": existingSessionID ?? NSNull(),
                "model": model ?? NSNull(),
                "effortLevel": effortLevel?.rawValue ?? NSNull(),
                "hasSystemPromptOverride": systemPromptOverride != nil
            ] as [String: Any]
        )
        do {
            try await prepareRuntimeIfNeeded()
            try await startProcessIfNeeded(existingSessionID: existingSessionID, model: model, effortLevel: effortLevel)
            try await initializeIfNeeded(systemPromptOverride: systemPromptOverride)
            return SessionRef(
                sessionID: sessionID,
                configuredContextWindow: configuredContextWindow,
                promptCacheRetention: promptCacheRetention,
                initializationGeneration: initializationGeneration,
                initializedDuringCall: initializationGeneration != initializationGenerationAtEntry
            )
        } catch {
            if process != nil || configURL != nil {
                await shutdown()
            }
            throw error
        }
    }

    package func currentSessionRef() async -> SessionRef {
        SessionRef(
            sessionID: sessionID,
            configuredContextWindow: configuredContextWindow,
            promptCacheRetention: promptCacheRetention,
            initializationGeneration: initializationGeneration,
            initializedDuringCall: false
        )
    }

    package func applyModelAndEffort(model: String?, effortLevel: ClaudeCodeEffortLevel?) async throws {
        guard process != nil else { return }
        let autoPermissionRequested = isAutoPermissionRequested
        if autoPermissionRequested {
            guard isInitialized else {
                throw AutoPermissionLiveMutationError(reason: .initializationIncomplete)
            }
            guard !turnInFlight else {
                throw AutoPermissionLiveMutationError(reason: .turnInFlight)
            }
        }

        latestFlagSettingsIntentGeneration &+= 1
        let intentGeneration = latestFlagSettingsIntentGeneration
        let resolved = try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel)
        guard intentGeneration == latestFlagSettingsIntentGeneration else { return }
        guard process != nil else {
            if autoPermissionRequested {
                throw ControllerError.processNotRunning
            }
            return
        }
        if autoPermissionRequested {
            guard isInitialized else {
                throw AutoPermissionLiveMutationError(reason: .initializationIncomplete)
            }
            guard !turnInFlight else {
                throw AutoPermissionLiveMutationError(reason: .turnInFlight)
            }
        }
        if liveFlagSettingsRequiresProcessRestart(for: resolved.launchEnvironment) {
            writeRawEventLogRecord(kind: "session.flagSettingsDeferred", payload: [
                "reason": "launch_environment_changed",
                "model": model ?? NSNull()
            ] as [String: Any])
            throw ControllerError.liveModelSwitchRequiresRestart
        }
        let previousBaseModel = activeFlagSettingsBaseModel
        let nextBaseModel = Self.flagSettingsBaseModel(from: resolved.request)
        if autoPermissionRequested, previousBaseModel != nextBaseModel {
            writeRawEventLogRecord(kind: "session.flagSettingsDeferred", payload: [
                "reason": "auto_base_model_changed",
                "model": model ?? NSNull()
            ] as [String: Any])
            throw ControllerError.liveModelSwitchRequiresRestart
        }
        storeFlagSettingsRequest(resolved.request)

        guard isInitialized || hasCompletedInitialFlagSettings else {
            writeRawEventLogRecord(kind: "session.flagSettingsPending", payload: [
                "settings": resolved.request?["settings"] ?? NSNull()
            ] as [String: Any])
            return
        }
        guard let request = resolved.request else { return }

        let flagSettingsResult = try await sendControlRequest(request: request, timeoutSeconds: 5.0)
        writeRawEventLogRecord(kind: "session.flagSettingsApplied", payload: [
            "settings": request["settings"] ?? NSNull(),
            "response": flagSettingsResult,
            "source": "live_update"
        ] as [String: Any])
        if previousBaseModel != nextBaseModel {
            translator.resetMainModelTracking()
        }
        activeFlagSettingsBaseModel = nextBaseModel
    }

    /// Whether the current launch may carry an outbound user-message `uuid`: an automatically
    /// resolved command, or a configured exact path (owner decision 2026-10-29, e.g. a
    /// pass-through wrapper the owner controls, such as the rotator shim), on the first-party
    /// backend with no backend-routing environment keys. A wrapper that drops or rewrites the
    /// frame's `uuid` leaves the native entry under another ID, so the claim never matches and
    /// Reconcile refuses safely. Programmatic overrides and compatible backends never qualify.
    /// Neither provenance proves an authenticated binary; capture stays gated OFF.
    private var outboundUserMessageIdentityEligible: Bool {
        guard let identity = usageLaunchState?.identity else { return false }
        return [.automaticResolved, .configuredOverride].contains(identity.commandProvenance)
            && identity.backend == .defaultClaude
            && identity.environmentOverrideKeys.isEmpty
    }

    /// The permission configuration a launch or `set_permission_mode` request asks for.
    private static func runtimePermission(mode: String?) -> AgentRuntimePermissionSnapshot {
        let trimmed = mode?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .claude(permissionMode: trimmed?.isEmpty == false ? trimmed : nil)
    }

    @discardableResult
    package func sendUserMessage(_ text: String) async throws -> UUID {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        if case let .unhealthy(reason) = repoPromptMCPHealth {
            throw ControllerError.repoPromptMCPRecoveryRequired(reason)
        }
        guard isInitialized else {
            throw ControllerError.initializationFailed(
                "Cannot send a user message before initialization completes."
            )
        }
        // R6 owner operation: the user turn associates with the scope its owner captured.
        let writeOwner = try await fenceRuntimeWrite(association: .owner(AgentRuntimeOperationOwner.current))
        // Omitted unless this write's own admission newly committed a baseline claiming it.
        var outboundUserMessageUUID: UUID?
        if writeOwner != nil {
            // The fence suspended: a cancelled operation or a superseded owner writes nothing
            // (reported as a proven non-write).
            guard !Task.isCancelled else { throw ControllerError.processNotRunning }
            if let admission = AgentRuntimeOperationOwner.writeAdmission {
                // Decided from this transport's own launch before the await; a replacement launch
                // during it gets zero bytes from `sendLine`'s owner check.
                let identityEligible = outboundUserMessageIdentityEligible
                guard case let .admitted(admittedUUID) = await admission(identityEligible) else {
                    throw ControllerError.processNotRunning
                }
                // The admission check suspended too: cancellation during it also writes nothing.
                guard !Task.isCancelled else { throw ControllerError.processNotRunning }
                outboundUserMessageUUID = identityEligible ? admittedUUID : nil
            }
        }
        guard isInitialized else {
            throw ControllerError.processNotRunning
        }
        let payload = try ClaudeSDKProtocolCodec.encodeUserMessage(
            text: text,
            sessionID: sessionID,
            messageUUID: outboundUserMessageUUID
        )
        try sendLine(payload, writeOwner: writeOwner)
        // The write succeeded: register the turn and its launch-local dispatch ordinal in this
        // same non-suspending actor step so no result can interleave between write and ordinal.
        let turnID = beginTurnTracking(outboundUserMessageUUID: outboundUserMessageUUID)
        registerUsageDispatch(turnID: turnID)
        noteLiveTranscriptOutbound(uuid: outboundUserMessageUUID, text: text)
        return turnID
    }

    package func interruptTurn(reason: String) async -> InterruptOutcome {
        guard process != nil else { return .failed }
        guard turnInFlight else { return .noTurnInFlight }
        // An interrupted turn's original result may still carry owned usage; it is attributed with
        // its cancelled status and finalized as interrupted by core (plan §4).
        do {
            // Wait for interrupt control-response ACK to confirm Claude received the interrupt.
            _ = try await sendControlRequest(
                request: ["subtype": "interrupt", "reason": reason],
                timeoutSeconds: 1.5
            )
            turnWasInterrupted = true
            writeRawEventLogRecord(kind: "turn.interrupted", payload: [
                "reason": reason
            ] as [String: Any])
            return .acknowledged
        } catch let controllerError as ControllerError {
            if case .controlRequestTimedOut = controllerError {
                writeRawEventLogRecord(kind: "turn.interrupt.timedOut", payload: [
                    "reason": reason
                ] as [String: Any])
                return .timedOut
            }
            writeRawEventLogRecord(kind: "turn.interrupt.failed", payload: [
                "reason": reason,
                "error": controllerError.localizedDescription
            ] as [String: Any])
            return .failed
        } catch {
            writeRawEventLogRecord(kind: "turn.interrupt.failed", payload: [
                "reason": reason,
                "error": error.localizedDescription
            ] as [String: Any])
            return .failed
        }
    }

    package func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        guard let pending = pendingPermissionRequests.removeValue(forKey: id) else {
            return
        }
        let issuingLaunch = pending.issuingLaunch
        do {
            // A reply to the CLI's own request creates no ownership: authorize only, and only on
            // the transport that issued the request.
            let writeOwner = try await fenceRuntimeWrite(association: nil)
            guard writeOwner === issuingLaunch else { throw ControllerError.processNotRunning }
            let response = permissionResponsePayload(decision: decision, pendingRequest: pending.request)
            writeRawEventLogRecord(kind: "approval.response.sent", payload: [
                "requestID": id,
                "decision": String(describing: decision),
                "response": response
            ] as [String: Any])
            let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                requestID: id,
                response: response
            )
            try sendLine(encoded, shutdownOnFailure: false, writeOwner: writeOwner)
        } catch {
            // R6: the issuing transport was replaced (before or during the fence); the stale reply
            // is dropped and never shuts down the replacement.
            guard runtimeLaunch === issuingLaunch else {
                writeRawEventLogRecord(kind: "approval.response.dropped", payload: [
                    "requestID": id,
                    "reason": "issuing transport replaced"
                ] as [String: Any])
                return
            }
            await failProtocolAndShutdown(
                message: "Failed to submit Claude approval decision: \(error.localizedDescription)"
            )
        }
    }

    package func shutdown() async {
        guard !isShuttingDown else {
            // A concurrent caller still waits for the owned reaps (and their post-reap discovery)
            // so it never returns while this launch's ownership is unresolved.
            await joinPendingRootReaps()
            return
        }
        isShuttingDown = true
        writeRawEventLogRecord(kind: "session.shutdown")

        failPendingControlRequests(with: ControllerError.processNotRunning)
        pendingPermissionRequests.removeAll()
        queuedAutomaticReplies.removeAll()
        // Flush observed deferred completions before clearing the queue. The flush inside
        // cancelAuthoritativeLifecycleState() is gated on `hasPendingTurnIDs`, so clearing
        // first made it dead code and silently dropped turns whose result had already been
        // observed but whose authoritative `idle` had not yet arrived.
        cancelAuthoritativeLifecycleState()
        clearTurnIDQueue()
        // Never carry an interrupt marker into the next session on this reusable controller:
        // determineTurnStatus() is what consumes it, and a trailing result that misses the
        // pending-turn-ID guard never reaches that consumption point.
        turnWasInterrupted = false
        activeStdoutLaunchToken = nil
        endUsageLaunch()

        closeOutputChannelsAndInput()

        let launch = runtimeLaunch
        runtimeLaunch = nil
        if let process {
            let pid = process.pid
            if let launch {
                // R6: one owned reap per exact root, visible to concurrent shutdown callers.
                await ownedRootReap(
                    launch: launch,
                    pid: pid,
                    processGroupID: process.processGroupID,
                    waitBeforeTerminating: nil
                ).value
            } else {
                _ = await ProcessTermination.terminateAndReap(
                    pid: pid,
                    processGroupID: process.processGroupID,
                    logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : { _ in }
                )
            }
        }
        // Includes an EOF-path reap of an earlier root of this controller.
        await joinPendingRootReaps()
        await clearExpectedAgentPIDIfNeeded()
        await unregisterRunConnectionLossObserverIfNeeded()
        resetRepoPromptMCPHealthForLaunch()
        repoPromptMCPLaunchToken = nil
        spawnedLaunchAgent = nil
        process = nil
        configuredContextWindow = nil
        promptCacheRetention = .standard
        activeLaunchEnvironmentSignature = nil
        activeFlagSettingsBaseModel = nil
        isInitialized = false
        hasCompletedInitialFlagSettings = false
        stdoutFramer = LineFramer()

        if let configLease {
            configLease.release()
            self.configLease = nil
        }
        rawEventLogFileURL = nil
        rawEventLogFileSessionID = nil
        hasWrittenRawEventLogHeader = false
        finishEventsStreamIfNeeded()
    }

    private func resolvePromptCacheRetentionForProcessLaunch(
        launchEnvironment: [String: String],
        workingDirectory: String?
    ) {
        promptCacheRetention = ClaudePromptCacheRetentionResolver.resolve(
            launchEnvironment: launchEnvironment,
            workingDirectory: workingDirectory,
            managedSettingsURL: managedSettingsURL
        )
    }

    static func resolveCommandForLaunch(
        selection: CLICommandSelection,
        environment: [String: String],
        additionalPaths: [String],
        logger: ((String) -> Void)? = nil
    ) throws -> ResolvedLaunchCommand {
        if let configuredCommand = try validatedConfiguredCommandForLaunch(selection: selection) {
            return configuredCommand
        }
        switch selection {
        case .configuredExactPath:
            preconditionFailure("Configured command validation must return a launch command")
        case let .automatic(command):
            return ResolvedLaunchCommand(
                command: CommandPathResolver.resolve(
                    command,
                    environment: environment,
                    additionalPaths: additionalPaths,
                    logger: logger,
                    preferredBasenames: [command],
                    shellLookupMode: .preferShell
                ),
                provenance: .automaticResolved
            )
        case let .programmaticOverride(command):
            return ResolvedLaunchCommand(
                command: CommandPathResolver.resolve(
                    command,
                    environment: environment,
                    additionalPaths: additionalPaths,
                    logger: logger,
                    preferredBasenames: [command],
                    shellLookupMode: .preferShell
                ),
                provenance: .programmaticOverride
            )
        }
    }

    private static func validatedConfiguredCommandForLaunch(
        selection: CLICommandSelection
    ) throws -> ResolvedLaunchCommand? {
        guard case let .configuredExactPath(path) = selection else { return nil }
        do {
            let validatedPath = try CLIExecutableOverrideStore.validateForLaunch(
                path,
                commandName: CLILaunchProfiles.claudeCode.commandName
            )
            return ResolvedLaunchCommand(command: validatedPath, provenance: .configuredOverride)
        } catch let reason as CLIExecutableOverrideError {
            throw AIProviderError.invalidConfiguration(
                detail: "The configured Claude executable path '\(path)' is not launchable. "
                    + "\(reason.localizedDescription) Fix the path in Settings or use Automatic."
            )
        }
    }

    private static func processSpawnedPayload(
        command: String,
        provenance: CommandProvenance,
        arguments: [String],
        workingDirectory: String
    ) -> [String: Any] {
        [
            "command": command,
            "commandProvenance": provenance.rawValue,
            "arguments": arguments,
            "workingDirectory": workingDirectory
        ]
    }

    static func connectTimeoutHint(for selection: CLICommandSelection) -> String? {
        guard case let .configuredExactPath(path) = selection else { return nil }
        return "a custom Claude executable path is configured: \(path) — wrappers must exec and keep stdin/stdout stream-json-transparent"
    }

    private var configuredCommandConnectTimeoutHint: String? {
        Self.connectTimeoutHint(for: commandSelection)
    }

    private func prepareRuntimeIfNeeded() async throws {
        if configURL != nil {
            return
        }

        let isRunning = await mcpHost.isRunning()
        guard isRunning else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        configLease = try await configService.prepareLaunchConfig()
    }

    private func startProcessIfNeeded(
        existingSessionID: String?,
        model: String?,
        effortLevel: ClaudeCodeEffortLevel?
    ) async throws {
        guard process == nil else { return }

        latestFlagSettingsIntentGeneration = 0
        flagSettingsRequestGeneration = 0
        hasCompletedInitialFlagSettings = false

        // Strict paths must fail before environment composition can consult the login shell.
        let configuredLaunchCommand = try Self.validatedConfiguredCommandForLaunch(
            selection: commandSelection
        )
        let resolvedFlags = try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel)
        let launchEnvironment = resolvedFlags.launchEnvironment
        let environment = await resolvedLaunchEnvironment(
            resolverOverrides: launchEnvironment.environmentOverrides,
            resolverRemovedKeys: launchEnvironment.removedEnvironmentKeys
        )
        let resolvedLaunchCommand = try configuredLaunchCommand ?? Self.resolveCommandForLaunch(
            selection: commandSelection,
            environment: environment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints),
            logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : nil
        )
        let resolvedCommand = resolvedLaunchCommand.command
        storeFlagSettingsRequest(resolvedFlags.request)
        activeFlagSettingsBaseModel = Self.flagSettingsBaseModel(from: resolvedFlags.request)
        activeLaunchEnvironmentSignature = LaunchEnvironmentSignature(launchEnvironment)
        let requestedSessionID = existingSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resumeSessionID = (requestedSessionID?.isEmpty == false) ? requestedSessionID : nil
        let family = launchFamily
        // Fresh `--session-id` is its own qualified gate and never combined with `--resume`.
        let provider = launchProvider
        let freshSessionID = resumeSessionID == nil && launchAuthority.allowsFreshSessionID(family, provider: provider)
            ? UUID().uuidString.lowercased()
            : nil
        let launch: AgentRuntimeLaunch? = if registersLaunches {
            launchAuthority.makeLaunch(AgentRuntimeLaunchContext(
                family: family,
                provider: provider,
                // R6: the starting operation's owner-captured scope (fails closed when none).
                session: AgentRuntimeOperationOwner.current,
                worktreePath: workspacePath,
                conversationID: resumeSessionID ?? freshSessionID,
                permission: Self.runtimePermission(mode: config.permissionMode)
            ))
        } else {
            nil
        }
        let arguments = buildArguments(
            existingSessionID: existingSessionID,
            model: nil,
            freshSessionID: freshSessionID
        )

        // R6: the previous registered root's owned reap and post-reap discovery finish before this
        // launch reserves, so a successor never races the app's own just-ended launch.
        if launch != nil {
            await joinPendingRootReaps()
            guard process == nil else { return }
        }
        let workingDirectory = resolvedWorkingDirectory()
        configuredContextWindow = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: environment,
            workingDirectory: workingDirectory
        )
        resolvePromptCacheRetentionForProcessLaunch(
            launchEnvironment: environment,
            workingDirectory: workingDirectory
        )
        let launchToken = UUID()
        // R6: reservation immediately before the spawn; a refusal spawns nothing and never falls
        // back to an unregistered launch.
        guard case let .proceed(runtimeID) = try await reserveSpawn(launch: launch) else { return }
        let spawned: SpawnedProcess
        do {
            spawned = try ProcessLauncher.spawn(
                command: resolvedCommand,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                runtimeID: runtimeID
            )
        } catch {
            await launch?.spawnFailed()
            throw error
        }
        if let lastSpawnedCommand, lastSpawnedCommand != resolvedCommand {
            Self.processLogger.notice(
                "Claude executable changed between controller spawns from \(lastSpawnedCommand, privacy: .private) to \(resolvedCommand, privacy: .private)"
            )
        }
        lastSpawnedCommand = resolvedCommand
        writeRawEventLogRecord(
            kind: "process.spawned",
            payload: Self.processSpawnedPayload(
                command: resolvedCommand,
                provenance: resolvedLaunchCommand.provenance,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
        translator.resetMainModelTracking()
        stdoutFramer = LineFramer()
        stderrTail.removeAll(keepingCapacity: false)
        // Reset authoritative lifecycle state for the new transport instance so we
        // don't inherit the previous process's capability negotiation.
        observedSessionStateChangedEvents = false
        cancelAuthoritativeLifecycleState()
        turnWasInterrupted = false
        // Reset runtime init aggregation state so stale metadata doesn't leak across runs.
        initializeResponseSnapshot = nil
        latestRuntimeInitTools = []
        latestRuntimeInitMcpServerStatuses = [:]
        lastEmittedRuntimeInitStatus = nil
        resetRepoPromptMCPHealthForLaunch()
        installSpawnLaunchTokens(launchToken, agentPID: spawned.pid)
        process = spawned
        runtimeLaunch = launch
        runtimeManagedTransport = launch != nil
        runtimeCommittedLaunch = nil
        // The reservation associated the requested conversation (resume or fresh preallocation).
        runtimeAssociatedConversationID = launch == nil ? nil : (resumeSessionID ?? freshSessionID)
        runtimeLastOwnerScope = launch?.context.session
        installLiveTranscriptQualification(launchToken: launchToken)
        do {
            try startStdoutReader(handle: spawned.stdout, launchToken: launchToken)
            try startStderrReader(handle: spawned.stderr)
            // R6: the birth identity is committed before initialization or any stdin write.
            try await launch?.commitSpawn(pid: spawned.pid, processGroupID: spawned.processGroupID)
            guard process?.pid == spawned.pid, runtimeLaunch === launch else {
                throw ControllerError.processNotRunning
            }
            runtimeCommittedLaunch = launch
        } catch {
            spawned.stdout.readabilityHandler = nil
            spawned.stderr.readabilityHandler = nil
            spawned.stdin?.closeFile()
            if process?.pid == spawned.pid {
                process = nil
                activeStdoutLaunchToken = nil
            }
            if runtimeLaunch === launch {
                runtimeLaunch = nil
            }
            if let launch {
                // R6: never a second reap of the same child. If the EOF path already owns this
                // root's reap, join it; otherwise this path is the single owned reap.
                let reap = pendingRootReaps[spawned.pid] ?? ownedRootReap(
                    launch: launch,
                    pid: spawned.pid,
                    processGroupID: spawned.processGroupID,
                    waitBeforeTerminating: nil
                )
                await reap.value
            } else {
                _ = await ProcessTermination.terminateAndReap(
                    pid: spawned.pid,
                    processGroupID: spawned.processGroupID,
                    logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : { _ in }
                )
            }
            if error is AgentProcessRegistryError {
                throw error
            }
            throw ControllerError.initializationFailed("Failed to start Claude process readers: \(error.localizedDescription)")
        }
        let resumedSessionID = existingSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Evidence comes from `environment`, the exact dictionary the child was spawned with.
        let environmentEvidence = Self.launchEnvironmentEvidence(
            finalEnvironment: environment,
            resolverOverrides: launchEnvironment.environmentOverrides,
            resolverRemovedKeys: launchEnvironment.removedEnvironmentKeys,
            configuredOverrides: config.processEnvironmentOverrides
        )
        beginUsageLaunch(ProcessLaunchIdentity(
            token: launchToken,
            pid: spawned.pid,
            launchMode: (resumedSessionID?.isEmpty == false) ? .resumedSession(resumedSessionID!) : .freshSession,
            commandProvenance: resolvedLaunchCommand.provenance,
            runtimeVariant: config.runtimeVariant,
            executablePath: resolvedCommand,
            executableRealPath: URL(fileURLWithPath: resolvedCommand).resolvingSymlinksInPath().path,
            backend: launchEnvironment.backend,
            environmentOverrideKeys: environmentEvidence.environmentOverrideKeys,
            configuredEnvironmentOverrideKeys: environmentEvidence.configuredEnvironmentOverrideKeys,
            spawnedAt: Date()
        ))
        resolveLiveTranscriptEligibility(launchToken: launchToken)
        await registerExpectedAgentPIDIfNeeded(spawned.pid)
    }

    private func initializeIfNeeded(systemPromptOverride: String?) async throws {
        guard !isInitialized else { return }

        let request = Self.buildInitializeRequest(systemPromptOverride: systemPromptOverride)

        let initializingLaunch = runtimeLaunch
        let initializeResult = try await sendControlRequest(request: request)
        if let returnedSessionID = (initializeResult["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !returnedSessionID.isEmpty
        {
            recordObservedSessionID(returnedSessionID)
            await associateObservedConversationIfNeeded(originLaunch: initializingLaunch)
        }

        let snapshot = Self.parseInitializeResponseSnapshot(from: initializeResult)
        initializeResponseSnapshot = snapshot

        if config.enableDebugLogging {
            print("[ClaudeNativeSession] initialize response keys: \(initializeResult.keys.sorted())")
            if let account = snapshot.account {
                print("[ClaudeNativeSession] account: \(account.email ?? "none"), org: \(account.organization ?? "none"), sub: \(account.subscriptionType ?? "none")")
            }
        }
        writeRawEventLogRecord(kind: "session.initialized", payload: initializeResult)
        try await applyInitialFlagSettingsIfNeeded()
        try await applyInitialPermissionModeIfNeeded()
        completeInitialization()

        publishRuntimeInitIfChanged()
    }

    private func completeInitialization() {
        initializationGeneration &+= 1
        isInitialized = true
    }

    private func resolveLaunchFlagSettings(
        model: String?,
        effortLevel suppliedEffortLevel: ClaudeCodeEffortLevel?
    ) async throws -> (launchEnvironment: ClaudeCodeLaunchEnvironment, request: [String: Any]?) {
        let modelSpecifier = model.map { ClaudeModelSpecifier(raw: $0) }
        let requestedModel = modelSpecifier != nil
            ? model
            : config.modelString
        let effectiveEffortLevel = modelSpecifier?.explicitEffortLevel
            ?? suppliedEffortLevel
            ?? config.effortLevel
        let launchEnvironment = try await environmentResolver.resolve(
            variant: config.runtimeVariant,
            requestedModel: requestedModel
        )
        try validateResolvedAutoPermissionMode(
            launchEnvironment: launchEnvironment
        )
        let requestEffortLevel = Self.shouldSuppressEffortSettings(for: launchEnvironment)
            ? nil
            : effectiveEffortLevel
        let request = Self.buildApplyFlagSettingsRequest(
            model: launchEnvironment.effectiveModel,
            effortLevel: requestEffortLevel
        )
        return (launchEnvironment, request)
    }

    private var isAutoPermissionRequested: Bool {
        config.permissionMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode) == .orderedSame
    }

    private func validateResolvedAutoPermissionMode(
        launchEnvironment: ClaudeCodeLaunchEnvironment
    ) throws {
        guard isAutoPermissionRequested else { return }
        switch launchEnvironment.backend {
        case .defaultClaude:
            break
        case let .compatible(backendID):
            let agentKind: AgentProviderKind = switch backendID {
            case .glmZAI:
                .claudeCodeGLM
            case .kimi:
                .kimiCode
            case .custom:
                .customClaudeCompatible
            }
            throw ClaudeAgentToolPreferences.AutoPermissionModeBlockedError(
                candidacy: .compatibleBackend(agentKind)
            )
        }

        let candidacy = ClaudeAgentToolPreferences.autoPermissionCandidacy(
            agentKind: .claudeCode,
            selectedModelRaw: launchEnvironment.effectiveModel
        )
        guard candidacy == .eligible else {
            throw ClaudeAgentToolPreferences.AutoPermissionModeBlockedError(
                candidacy: candidacy
            )
        }
    }

    private func liveFlagSettingsRequiresProcessRestart(for launchEnvironment: ClaudeCodeLaunchEnvironment) -> Bool {
        guard let activeLaunchEnvironmentSignature else {
            return false
        }
        return activeLaunchEnvironmentSignature != LaunchEnvironmentSignature(launchEnvironment)
    }

    private func storeFlagSettingsRequest(_ request: [String: Any]?) {
        flagSettingsRequestGeneration &+= 1
        initialFlagSettingsRequest = request
    }

    private func applyInitialFlagSettingsIfNeeded() async throws {
        while true {
            let requestGeneration = flagSettingsRequestGeneration
            guard let request = initialFlagSettingsRequest else {
                hasCompletedInitialFlagSettings = true
                return
            }
            let flagSettingsResult = try await sendControlRequest(request: request)
            writeRawEventLogRecord(kind: "session.flagSettingsApplied", payload: [
                "settings": request["settings"] ?? NSNull(),
                "response": flagSettingsResult
            ] as [String: Any])
            activeFlagSettingsBaseModel = Self.flagSettingsBaseModel(from: request)
            guard flagSettingsRequestGeneration != requestGeneration else {
                hasCompletedInitialFlagSettings = true
                return
            }
        }
    }

    private func applyInitialPermissionModeIfNeeded() async throws {
        guard let request = Self.buildSetPermissionModeRequest(permissionMode: config.permissionMode) else { return }
        do {
            let permissionModeResult = try await sendControlRequest(request: request)
            writeRawEventLogRecord(kind: "session.permissionModeInitialized", payload: [
                "requestedMode": request["mode"] ?? NSNull(),
                "response": permissionModeResult
            ] as [String: Any])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PermissionStageError(
                requestedMode: config.permissionMode,
                underlyingError: error
            )
        }
    }

    private static func buildInitializeRequest(systemPromptOverride: String?) -> [String: Any] {
        var request: [String: Any] = ["subtype": "initialize"]
        if let systemPromptOverride {
            request["systemPrompt"] = systemPromptOverride
        }
        return request
    }

    private static func shouldSuppressEffortSettings(for launchEnvironment: ClaudeCodeLaunchEnvironment) -> Bool {
        launchEnvironment.suppressesEffortSettings
    }

    private static func buildApplyFlagSettingsRequest(model: String?, effortLevel: ClaudeCodeEffortLevel?) -> [String: Any]? {
        var settings: [String: Any] = [:]
        if let model = normalizedFlagSettingsModel(model) {
            settings["model"] = model
        }
        if let effortLevel {
            settings["effortLevel"] = effortLevel.rawValue
        }
        guard !settings.isEmpty else { return nil }
        return [
            "subtype": "apply_flag_settings",
            "settings": settings
        ]
    }

    private static func normalizedFlagSettingsModel(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else { return nil }
        return trimmed
    }

    private static func flagSettingsBaseModel(from request: [String: Any]?) -> String? {
        guard let settings = request?["settings"] as? [String: Any],
              let rawModel = settings["model"] as? String
        else { return nil }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        let baseModel = specifier.baseModel ?? rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModel.isEmpty else { return nil }
        return baseModel.lowercased()
    }

    private static func buildSetPermissionModeRequest(permissionMode: String) -> [String: Any]? {
        let trimmed = permissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return [
            "subtype": "set_permission_mode",
            "mode": trimmed
        ]
    }

    /// How a fenced write relates to ownership: an owner operation associates the scope its owner
    /// captured (and any permission it requests); `nil` (callbacks, replies, interrupts, live
    /// settings) only authorizes on the already-associated conversation.
    private enum RuntimeWriteAssociation {
        case owner(AgentRuntimeSessionScope, permission: AgentRuntimePermissionSnapshot? = nil)
    }

    /// R6 fence before an awaited outgoing write. The committed launch is captured before the first
    /// suspension; an owner write associates its owner-captured session and run attempt, the known
    /// conversation and any requested permission change (two-writer check; persisted before the
    /// request that changes the permission); every write then authorizes, and the captured launch
    /// is rechecked after each suspension. Returns that launch: the final synchronous `sendLine`
    /// writes only while it still owns the transport, so a replacement made during any await
    /// receives zero bytes. A missing owner scope fails an owner write. No-op (nil) while
    /// registration is off.
    private func fenceRuntimeWrite(association: RuntimeWriteAssociation?) async throws -> AgentRuntimeLaunch? {
        guard runtimeManagedTransport else { return nil }
        guard let launch = runtimeLaunch, runtimeCommittedLaunch === launch else {
            throw ControllerError.processNotRunning
        }
        let conversationID = sessionID
        #if DEBUG
            if let checkpoint = testRuntimeFenceCheckpoint { await checkpoint("launchCaptured") }
        #endif
        // Authorize-only writes are checked against the durably associated conversation; an owner
        // write associates the known one first and is then checked against it.
        var authorizedConversationID = runtimeAssociatedConversationID
        if case let .owner(session, permission) = association {
            try await launch.associate(session: session, conversationID: conversationID, permission: permission)
            #if DEBUG
                if let checkpoint = testRuntimeFenceCheckpoint { await checkpoint("associated") }
            #endif
            guard process != nil, runtimeLaunch === launch, runtimeCommittedLaunch === launch else {
                throw ControllerError.processNotRunning
            }
            runtimeLastOwnerScope = session
            if let conversationID {
                runtimeAssociatedConversationID = conversationID
            }
            authorizedConversationID = conversationID
        }
        try await launch.authorizeWrite(conversationID: authorizedConversationID)
        #if DEBUG
            if let checkpoint = testRuntimeFenceCheckpoint { await checkpoint("authorized") }
        #endif
        guard process != nil, runtimeLaunch === launch, runtimeCommittedLaunch === launch else {
            throw ControllerError.processNotRunning
        }
        return launch
    }

    private func sendControlRequest(
        request: [String: Any],
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        // R6: a permission change is an owner write (persisted before the request, for the scope
        // its owner captured); other control requests (initialize, flag settings, interrupt)
        // create no ownership and only authorize.
        let association: RuntimeWriteAssociation? = if request["subtype"] as? String == "set_permission_mode" {
            .owner(
                AgentRuntimeOperationOwner.current,
                permission: Self.runtimePermission(mode: request["mode"] as? String)
            )
        } else {
            nil
        }
        let writeOwner = try await fenceRuntimeWrite(association: association)
        if writeOwner != nil, request["subtype"] as? String != "interrupt" {
            // The fence suspended: a cancelled operation writes nothing. An interrupt is exempt:
            // it is how cancel and stop paths (often already cancelled) end the turn.
            try Task.checkCancellation()
        }
        let requestID = makeControlRequestID()
        let payload = try ClaudeSDKProtocolCodec.encodeControlRequest(requestID: requestID, request: request)
        writeRawEventLogRecord(
            kind: "control.request.sent",
            payload: [
                "requestID": requestID,
                "request": request,
                "expectsResponse": true
            ] as [String: Any]
        )
        // Register the continuation and optional timeout BEFORE writing to stdin.
        // This avoids a race where Claude replies before the continuation is stored,
        // which would silently lose the ACK.
        return try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            if let timeoutSeconds, timeoutSeconds > 0 {
                let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
                pendingControlRequestTimeoutTasks[requestID] = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        await self?.handleControlRequestTimeout(requestID: requestID)
                    } catch {
                        return
                    }
                }
            }
            do {
                try sendLine(payload, writeOwner: writeOwner)
            } catch {
                // Writing failed — clean up the continuation and timeout, then resume with error.
                pendingControlRequests.removeValue(forKey: requestID)
                pendingControlRequestTimeoutTasks[requestID]?.cancel()
                pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendControlRequestWithoutResponse(request: [String: Any]) throws {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        let requestID = makeControlRequestID()
        let payload = try ClaudeSDKProtocolCodec.encodeControlRequest(requestID: requestID, request: request)
        writeRawEventLogRecord(
            kind: "control.request.sent",
            payload: [
                "requestID": requestID,
                "request": request,
                "expectsResponse": false
            ] as [String: Any]
        )
        try sendLine(payload)
    }

    /// `writeOwner`: the launch a preceding fence captured and authorized; the write goes only to
    /// the transport that launch still owns.
    private func sendLine(
        _ lineData: Data,
        shutdownOnFailure: Bool = true,
        writeOwner: AgentRuntimeLaunch? = nil
    ) throws {
        guard let process else {
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
        writeRawEventLogRecord(kind: "protocol.outbound.raw", payload: lineRecordPayload(from: lineData))
        do {
            // A missing stdin handle is a failed write, never a silent success: dispatch
            // registration below this call must only follow bytes actually delivered.
            guard let stdin = process.stdin else {
                throw ControllerError.inputWriteFailed("Claude stdin is not available")
            }
            // Combine JSON body and newline into a single write to ensure atomic
            // delivery to the CLI's stdin pipe. Two separate writes could theoretically
            // be split if the pipe reader consumes data between them.
            var frame = lineData
            frame.append(0x0A)
            try stdin.write(contentsOf: frame)
        } catch {
            // Stdin is broken — the process is dead or dying. Schedule teardown so the
            // child process doesn't linger (mirrors Codex's terminateTransport behavior).
            // shutdown() is idempotent (guards on isShuttingDown).  Control-response
            // callers can disable this so they can emit failed turn completion before
            // shutdown clears the active MCP-controlled turn context.
            if shutdownOnFailure {
                Task { await self.shutdown() }
            }
            throw ControllerError.inputWriteFailed(error.localizedDescription)
        }
    }

    private func startStdoutReader(handle: FileHandle, launchToken: UUID) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Claude stdout")
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
        // The consumer carries the launch token of the process whose stdout it reads, so a
        // straggler chunk or EOF from an already-replaced process is discarded before framing
        // and can neither reach the current translator nor accounting.
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk, launchToken: launchToken)
            }
            // Stream ended (EOF or finish() called)
            guard let self else { return }
            await handleStdoutEOF(launchToken: launchToken)
        }
    }

    private func startStderrReader(handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Claude stderr")
        let channel = FileHandleChunkChannel()
        stderrChunkChannel = channel
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
                guard let self else { break }
                await handleStderrChunk(chunk)
            }
        }
    }

    private func handleStderrChunk(_ data: Data) {
        appendTail(&stderrTail, chunk: data, limit: 256 * 1024)
        writeRawEventLogRecord(kind: "process.stderr", payload: lineRecordPayload(from: data))
        if config.enableDebugLogging,
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty
        {
            print("[ClaudeNativeSession][stderr] \(text)")
        }
    }

    private func handleStdoutChunk(_ data: Data, launchToken: UUID) async {
        guard isCurrentStdoutLaunch(launchToken) else {
            writeRawEventLogRecord(kind: "protocol.inbound.staleLaunchDiscarded", payload: [
                "launchToken": launchToken.uuidString,
                "byteCount": data.count
            ] as [String: Any])
            return
        }
        var lines: [Data] = []
        stdoutFramer.feed(data, onDiagnostic: { [self] diagnostic in
            switch diagnostic {
            case let .overflow(droppedBytes, retainedBytes):
                writeRawEventLogRecord(kind: "framer.overflow", payload: [
                    "droppedBytes": droppedBytes,
                    "retainedBytes": retainedBytes
                ] as [String: Any])
                if config.enableDebugLogging {
                    print("[ClaudeNativeSession] LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes")
                }
            case .nonJSONCandidateQuoteStateReset:
                writeRawEventLogRecord(kind: "framer.nonJSONCandidateReset")
            }
        }) { line in
            lines.append(line)
        }
        // R6: the chunk belongs to the transport (stdout reader and launch) that delivered it. Every
        // line is handled only while that transport is still current, so output buffered from a
        // transport replaced during an earlier line's awaits never reaches its replacement.
        let originLaunch = runtimeLaunch
        for line in lines {
            guard isCurrentStdoutLaunch(launchToken), runtimeLaunch === originLaunch else {
                writeRawEventLogRecord(kind: "protocol.inbound.replacedTransportDiscarded", payload: [
                    "launchToken": launchToken.uuidString
                ] as [String: Any])
                return
            }
            await handleLine(line)
            // R6: a newly observed conversation is durably associated before the next line (a
            // permission request, for example) can depend on it.
            await associateObservedConversationIfNeeded(originLaunch: originLaunch)
            await flushQueuedAutomaticReplies()
        }
    }

    /// R6: writes queued automatic replies in order, each only to the transport that delivered its
    /// request, after the authorize-only registry fence (on the associated conversation) and the
    /// final synchronous transport check. A reply whose transport was replaced is dropped; a
    /// refused reply on the still-current transport shuts it down, as a failed reply always has.
    private func flushQueuedAutomaticReplies() async {
        while !queuedAutomaticReplies.isEmpty {
            let reply = queuedAutomaticReplies.removeFirst()
            do {
                guard let receivingLaunch = reply.receivingLaunch, runtimeLaunch === receivingLaunch else {
                    throw ControllerError.processNotRunning
                }
                let writeOwner = try await fenceRuntimeWrite(association: nil)
                guard writeOwner === receivingLaunch else { throw ControllerError.processNotRunning }
                try sendLine(reply.encoded, shutdownOnFailure: false, writeOwner: receivingLaunch)
            } catch {
                guard let receivingLaunch = reply.receivingLaunch, runtimeLaunch === receivingLaunch, !isShuttingDown else {
                    writeRawEventLogRecord(kind: "control.autoReply.dropped", payload: [
                        "requestID": reply.requestID,
                        "reason": "receiving transport replaced"
                    ] as [String: Any])
                    continue
                }
                queuedAutomaticReplies.removeAll()
                await failProtocolAndShutdown(message: "\(reply.failureMessage): \(error.localizedDescription)")
                return
            }
        }
    }

    /// An automatic reply to a runtime-initiated request. Unmanaged transports write it at once
    /// (unchanged); a managed transport queues it for `flushQueuedAutomaticReplies`.
    private func sendAutomaticReply(
        _ encoded: Data,
        requestID: String,
        receivingLaunch: AgentRuntimeLaunch?,
        failureMessage: String
    ) {
        guard runtimeManagedTransport else {
            do {
                try sendLine(encoded, shutdownOnFailure: false, writeOwner: receivingLaunch)
            } catch {
                failProtocolAndShutdownSoon(message: "\(failureMessage): \(error.localizedDescription)")
            }
            return
        }
        queuedAutomaticReplies.append(QueuedAutomaticReply(
            receivingLaunch: receivingLaunch,
            requestID: requestID,
            encoded: encoded,
            failureMessage: failureMessage
        ))
    }

    /// R6 (managed transports only): durably associates a newly observed native conversation with
    /// the launch whose transport reported it, for the owner whose operation produced it (the
    /// latest owner write, else the launch's own scope). A failure shuts the transport down rather
    /// than letting replies or interrupts target an unowned conversation.
    private func associateObservedConversationIfNeeded(originLaunch: AgentRuntimeLaunch?) async {
        guard runtimeManagedTransport, !isShuttingDown, let launch = originLaunch, runtimeLaunch === launch,
              runtimeCommittedLaunch === launch,
              let observed = sessionID, observed != runtimeAssociatedConversationID
        else { return }
        let scope = runtimeLastOwnerScope ?? launch.context.session
        do {
            #if DEBUG
                if let checkpoint = testRuntimeFenceCheckpoint { await checkpoint("observedAssociating") }
            #endif
            try await launch.associate(session: scope, conversationID: observed)
            guard runtimeLaunch === launch else { return }
            runtimeAssociatedConversationID = observed
        } catch {
            guard runtimeLaunch === launch, !isShuttingDown else { return }
            await failProtocolAndShutdown(
                message: "Claude conversation could not be associated with its runtime: \(error.localizedDescription)"
            )
        }
    }

    /// R6: the single owned reap of a registered launch's exact root, registered for joining.
    /// `waitBeforeTerminating` lets an exited root (stdout EOF) exit on its own for a bounded time
    /// before escalation; `nil` terminates now. Always bounded; reports the reap (confirmed only when
    /// this wait reaped the root) and its post-reap discovery before completing.
    private func ownedRootReap(
        launch: AgentRuntimeLaunch,
        pid: pid_t,
        processGroupID: pid_t?,
        waitBeforeTerminating: TimeInterval?
    ) -> Task<Void, Never> {
        if let existing = pendingRootReaps[pid] { return existing }
        let debugLogging = config.enableDebugLogging
        let reap = Task { [weak self] in
            let logger: (String) -> Void = { message in
                if debugLogging { print("[ClaudeNativeSession] \(message)") }
            }
            var confirmed = false
            if let waitBeforeTerminating {
                do {
                    let result = try await ProcessTermination.waitForTerminationReportingRoot(
                        pid: pid,
                        processGroupID: processGroupID,
                        timeout: waitBeforeTerminating,
                        logger: logger
                    )
                    confirmed = result.rootReaped
                } catch {
                    confirmed = false
                }
            } else {
                let result = await ProcessTermination.terminateAndReapReportingRoot(
                    pid: pid,
                    processGroupID: processGroupID,
                    logger: logger
                )
                confirmed = result.rootReaped
            }
            await launch.rootReaped(pid: pid, confirmed: confirmed)
            await self?.finishOwnedRootReap(pid: pid)
        }
        pendingRootReaps[pid] = reap
        return reap
    }

    private func finishOwnedRootReap(pid: pid_t) {
        pendingRootReaps[pid] = nil
    }

    private func joinPendingRootReaps() async {
        while let entry = pendingRootReaps.first {
            await entry.value.value
            pendingRootReaps[entry.key] = nil
        }
    }

    private enum SpawnReservation {
        case proceed(runtimeID: UUID?)
        case alreadyRunning
    }

    /// R6: reserves `launch` (when registered) immediately before the spawn. A start that lost the
    /// slot, or whose task was cancelled by the time the reservation returned, releases it
    /// (`spawnFailed`) and spawns nothing.
    private func reserveSpawn(launch: AgentRuntimeLaunch?) async throws -> SpawnReservation {
        let runtimeID = try await launch?.prepareSpawn()
        guard process == nil else {
            // Another start installed a process while the reservation was awaited.
            await launch?.spawnFailed()
            return .alreadyRunning
        }
        if let launch, Task.isCancelled {
            await launch.spawnFailed()
            throw CancellationError()
        }
        return .proceed(runtimeID: runtimeID)
    }

    /// R6: registered launches join the tab's retained runtime retirements before a start.
    package nonisolated var joinsRetirementBeforeSuccessor: Bool {
        registersLaunches
    }

    /// The launch family of a Claude runtime variant: native for standard, compatible otherwise.
    private static func runtimeFamily(_ variant: ClaudeCodeRuntimeVariant) -> AgentRuntimeFamily {
        variant == .standard ? .claudeNative : .claudeCompatible
    }

    private func handleLine(_ lineData: Data) async {
        writeRawEventLogRecord(kind: "protocol.inbound.raw", payload: lineRecordPayload(from: lineData))
        do {
            guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(lineData) else { return }
            routeInboundMessage(inbound)
        } catch let codecError as ClaudeSDKProtocolCodec.CodecError {
            // Step 4d3b: an undecodable line (whatever recovery follows) ends live qualification.
            disqualifyLiveTranscript(.malformedLine)
            if case .invalidJSON = codecError {
                if recoverConcatenatedInboundMessagesIfNeeded(from: lineData)
                    || recoverEmbeddedInboundTailIfNeeded(from: lineData)
                    || recoverInvalidJSONStringControlCharsIfNeeded(from: lineData)
                    || recoverPlaintextAssistantDeltaIfNeeded(from: lineData)
                {
                    return
                }
            }
            let preview = String(data: lineData.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            writeRawEventLogRecord(kind: "protocol.decode.skipped", payload: [
                "preview": preview,
                "codecError": String(describing: codecError)
            ])
            emitDebugDecodeSkippedNotice(codecError: codecError, preview: preview)
            if config.enableDebugLogging {
                print("[ClaudeNativeSession] skipping undecodable protocol line: \(preview) | codecError=\(codecError)")
            }
            // Be tolerant of malformed/non-JSON protocol lines so one bad payload
            // doesn't kill an otherwise healthy Claude run.
            return
        } catch {
            let preview = String(data: lineData.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            writeRawEventLogRecord(kind: "protocol.decode.failed", payload: [
                "preview": preview,
                "error": error.localizedDescription
            ])
            if config.enableDebugLogging {
                print("[ClaudeNativeSession] failed decoding line: \(preview) | error=\(error)")
            }
            // Step 4d3b: refused (and its owner told) before the shutdown suspends.
            disqualifyLiveTranscript(.malformedLine)
            await failProtocolAndShutdown(message: "Claude protocol decode failure: \(preview)")
        }
    }

    private func routeInboundMessage(_ inbound: ClaudeSDKProtocolCodec.InboundMessage) {
        switch inbound {
        case let .streamPayload(payload):
            writeRawEventLogRecord(kind: "protocol.inbound.streamPayload", payload: payload)
            handleStreamPayload(payload)
        case let .controlRequest(request):
            writeRawEventLogRecord(kind: "protocol.inbound.controlRequest", payload: [
                "requestID": request.requestID,
                "subtype": request.subtype,
                "request": request.request
            ] as [String: Any])
            handleControlRequest(request)
        case let .controlResponse(response):
            writeRawEventLogRecord(kind: "protocol.inbound.controlResponse", payload: [
                "requestID": response.requestID,
                "subtype": response.subtype,
                "response": response.response ?? NSNull(),
                "error": response.error ?? NSNull(),
                "pendingPermissionRequestsCount": response.pendingPermissionRequests.count
            ] as [String: Any])
            handleControlResponse(response)
        case let .controlCancelRequest(requestID):
            writeRawEventLogRecord(kind: "protocol.inbound.controlCancelRequest", payload: ["requestID": requestID])
            handleControlCancelRequest(requestID: requestID)
        case .keepAlive:
            writeRawEventLogRecord(kind: "protocol.inbound.keepAlive")
        }
    }

    /// Maximum line size (in bytes) for which we attempt concatenated-segment recovery.
    /// Beyond this threshold the String conversion + brace-depth scan is too expensive.
    private static let maxConcatenatedRecoveryBytes = 2 * 1024 * 1024 // 2 MB

    private func recoverConcatenatedInboundMessagesIfNeeded(from lineData: Data) -> Bool {
        // Skip expensive String conversion + brace-depth scan for very large payloads.
        guard lineData.count <= Self.maxConcatenatedRecoveryBytes else {
            writeRawEventLogRecord(kind: "protocol.decode.concatenatedRecoverySkipped", payload: [
                "byteCount": lineData.count,
                "threshold": Self.maxConcatenatedRecoveryBytes
            ])
            return false
        }
        let segments = Self.splitConcatenatedJSONObjectPayloads(lineData)
        guard segments.count > 1 else { return false }

        var recoveredCount = 0
        for segment in segments {
            do {
                guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(segment) else { continue }
                recoveredCount += 1
                writeRawEventLogRecord(kind: "protocol.inbound.recoveredSegment", payload: lineRecordPayload(from: segment))
                routeInboundMessage(inbound)
            } catch {
                let preview = String(data: segment.prefix(256), encoding: .utf8) ?? "<non-utf8>"
                writeRawEventLogRecord(kind: "protocol.decode.recoveredSegmentSkipped", payload: [
                    "preview": preview,
                    "error": error.localizedDescription
                ])
            }
        }

        if recoveredCount > 0 {
            writeRawEventLogRecord(kind: "protocol.decode.recovered", payload: [
                "segments": segments.count,
                "recoveredSegments": recoveredCount
            ])
            return true
        }
        return false
    }

    /// Maximum number of trailing bytes to scan when attempting tail recovery.
    /// Prevents huge String allocations for multi-megabyte corrupted lines.
    private static let maxTailRecoveryScanBytes = 256 * 1024 // 256 KB

    private func recoverEmbeddedInboundTailIfNeeded(from lineData: Data) -> Bool {
        guard !lineData.isEmpty else { return false }

        // Only scan the last N bytes to limit worst-case cost.
        let scanWindow: Data
        let scanOffset: Int
        if lineData.count > Self.maxTailRecoveryScanBytes {
            scanOffset = lineData.count - Self.maxTailRecoveryScanBytes
            scanWindow = lineData.suffix(Self.maxTailRecoveryScanBytes)
        } else {
            scanOffset = 0
            scanWindow = lineData
        }

        // Search for the marker bytes in Data directly (avoid converting the entire payload to String).
        let markerOffsets = Self.jsonObjectStartOffsetsInData(scanWindow)
        guard !markerOffsets.isEmpty else { return false }

        // Skip the first offset if it points to the very start of the original lineData
        // (that's the same parse that already failed upstream).
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
            do {
                guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(suffixData) else { continue }
                let preview = makeUTF8Sample(from: suffixData, limit: 180)?.0 ?? "<non-utf8>"
                writeRawEventLogRecord(kind: "protocol.inbound.recoveredTail", payload: [
                    "startOffset": absoluteOffset,
                    "byteCount": suffixData.count,
                    "preview": preview
                ])
                routeInboundMessage(inbound)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// Finds byte offsets of the NDJSON marker `{"type":"` in raw Data, without String conversion.
    private static let jsonObjectMarkerBytes: [UInt8] = Array("{\"type\":\"".utf8)

    private static func jsonObjectStartOffsetsInData(_ data: Data) -> [Int] {
        guard data.count >= jsonObjectMarkerBytes.count else { return [] }
        var offsets: [Int] = []
        let markerLength = jsonObjectMarkerBytes.count
        let searchLimit = data.count - markerLength
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0 ... searchLimit {
                var matches = true
                for j in 0 ..< markerLength {
                    if baseAddress[i + j] != jsonObjectMarkerBytes[j] {
                        matches = false
                        break
                    }
                }
                if matches {
                    offsets.append(i)
                }
            }
        }
        return offsets
    }

    private func recoverInvalidJSONStringControlCharsIfNeeded(from lineData: Data) -> Bool {
        guard let repaired = repairJSONStringControlCharacters(lineData) else { return false }
        do {
            guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(repaired) else { return false }
            writeRawEventLogRecord(kind: "protocol.decode.recoveredJSONStringControlChars", payload: lineRecordPayload(from: repaired))
            routeInboundMessage(inbound)
            return true
        } catch {
            return false
        }
    }

    private func recoverPlaintextAssistantDeltaIfNeeded(from lineData: Data) -> Bool {
        guard turnInFlight else { return false }
        guard let text = Self.recoverablePlaintextAssistantFragment(from: lineData) else {
            return false
        }
        writeRawEventLogRecord(kind: "protocol.decode.recoveredPlaintext", payload: [
            "preview": String(text.prefix(200)),
            "length": text.count
        ] as [String: Any])
        emit(.stream(AIStreamResult(type: "content", text: text)))
        return true
    }

    private func emitDebugDecodeSkippedNotice(
        codecError: ClaudeSDKProtocolCodec.CodecError,
        preview: String
    ) {
        #if DEBUG
            decodeSkippedWarningCount += 1
            let compactPreview = preview
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = compactPreview.isEmpty ? "<empty>" : String(compactPreview.prefix(140))
            let warning = "⚠️ DEBUG: Claude skipped undecodable stream line #\(decodeSkippedWarningCount) (\(codecError)): \(snippet)"
            emit(.stream(AIStreamResult(type: "system", text: warning)))
        #endif
    }

    static func recoverablePlaintextAssistantFragment(from lineData: Data) -> String? {
        guard let rawText = String(data: lineData, encoding: .utf8) else {
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count >= 40,
              !text.contains("\t"),
              !text.hasPrefix("{"),
              !text.hasPrefix("["),
              !text.contains("{\"type\":\"")
        else {
            return nil
        }

        let letters = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if CharacterSet.letters.contains(scalar) {
                partialResult += 1
            }
        }
        guard letters >= 24 else { return nil }

        let longWordCount = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .count(where: { $0.count >= 4 })

        guard longWordCount >= 4 else { return nil }

        let braceSymbolCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if "{}[];".unicodeScalars.contains(scalar) {
                partialResult += 1
            }
        }
        guard braceSymbolCount <= 8 else { return nil }

        if text.hasPrefix(".") || text.hasPrefix("/") {
            return nil
        }
        return text
    }

    private static func splitConcatenatedJSONObjectPayloads(_ data: Data) -> [Data] {
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

    private func handleStreamPayload(_ payload: [String: Any]) {
        recordObservedSessionID(Self.firstSessionIdentifier(in: payload))
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled {
                let debugPayloadType = (payload["type"] as? String) ?? "<missing>"
                if debugPayloadType == "stream_event" || debugPayloadType == "assistant" || debugPayloadType == "message" || debugPayloadType == "result" {
                    let event = payload["event"] as? [String: Any]
                    let eventType = event?["type"] as? String
                    let delta = event?["delta"] as? [String: Any]
                    let deltaType = delta?["type"] as? String
                    reasoningDebug("payload type=\(debugPayloadType) eventType=\(eventType ?? "nil") deltaType=\(deltaType ?? "nil") keys=\(payload.keys.sorted())")
                }
            }
        #endif
        if let (tools, mcpStatuses) = Self.parseSystemInitFields(from: payload) {
            latestRuntimeInitTools = tools
            latestRuntimeInitMcpServerStatuses = mcpStatuses
            if Self.repoPromptStatus(in: mcpStatuses)?.lowercased() == "connected" {
                noteRepoPromptMCPConnectedEvidence(source: "system_init")
            }
            writeRawEventLogRecord(kind: "runtime.init.stream", payload: [
                "sessionID": sessionID ?? "",
                "tools": tools,
                "mcpServerStatuses": mcpStatuses
            ] as [String: Any])
            publishRuntimeInitIfChanged()
            noteUsageRuntimeEvidence(
                version: payload["claude_code_version"] as? String,
                providerSessionID: Self.firstSessionIdentifier(in: payload)
            )
            noteUsageRuntimeBinding(payload)
        } else if (payload["type"] as? String) == "system",
                  let subtype = (payload["subtype"] as? String)?.lowercased(),
                  subtype.contains("compact")
        {
            noteUsageCounterBoundary(kind: subtype)
        } else if let boundary = Self.usageCompactionStatusBoundary(in: payload) {
            // Installed 2.1.268 reports compaction through `system/status` (`compacting`,
            // `compact_result`/`compact_error`), not only `compact_boundary`.
            noteUsageCounterBoundary(kind: boundary)
        } else if Self.usageChildToolInvocation(in: payload) != nil {
            noteUsageChildToolObserved()
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            disqualifyLiveTranscript(.malformedPayload)
            return
        }
        var streamResults = translator.parseNDJSONLine(data)
        // Step 4d3b: the raw payload (the exact bytes the translator read) is classified before any
        // translated result is filtered or suppressed below.
        let liveTranscriptCarrier = classifyLiveTranscriptPayload(envelope: data, streamResults: &streamResults)
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled {
                let debugPayloadType = (payload["type"] as? String) ?? "<missing>"
                if streamResults.isEmpty {
                    let event = payload["event"] as? [String: Any]
                    let eventType = event?["type"] as? String
                    let delta = event?["delta"] as? [String: Any]
                    let deltaType = delta?["type"] as? String
                    if debugPayloadType == "stream_event" || deltaType?.contains("thinking") == true {
                        reasoningDebug("translator produced no results for payload type=\(debugPayloadType) eventType=\(eventType ?? "nil") deltaType=\(deltaType ?? "nil") deltaKeys=\(delta?.keys.sorted() ?? [])")
                    }
                } else if streamResults.contains(where: { $0.type == "reasoning" }) {
                    let summaries = streamResults.map { result in
                        "\(result.type):text=\(result.text?.count ?? 0):reasoning=\(result.reasoning?.count ?? 0)"
                    }.joined(separator: ",")
                    reasoningDebug("translator results include reasoning count=\(streamResults.count) summaries=\(summaries)")
                }
            }
        #endif
        if let translatorSessionID = translator.cliSessionID,
           !translatorSessionID.isEmpty
        {
            recordObservedSessionID(translatorSessionID)
        }

        // Only complete a turn when the original payload is a "result" type — the
        // authoritative turn-boundary signal from the SDK.  Forwarded stream events
        // (message_delta with stop_reason, message_stop) can also produce translated
        // "message_stop" results, but they are NOT turn boundaries; using them would
        // cause pendingTurnIDs to desynchronize when multiple message_stop results
        // arrive per turn.
        let payloadType = (payload["type"] as? String) ?? ""
        let isResultPayload = payloadType == "result"
        // O49: only the model's own live output starts a turn. A `result` payload closes a turn,
        // so text it carries is never credited (it may be processed after the finishing turn left
        // the FIFO head, which would credit the queued turn behind it).
        let creditsStartedTurn = payloadType == "assistant" || payloadType == "stream_event"
        if payloadType == "assistant" {
            emitMainRequestUsageIfOwned(payload: payload, streamResults: streamResults)
        }
        if let liveTranscriptCarrier {
            // Metadata only: no text, no usage, never a turn boundary; it reaches the owner before
            // this payload's own results, even when they are empty or suppressed.
            emit(.stream(liveTranscriptCarrier))
        }

        for result in streamResults {
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                    let text = result.reasoning ?? result.text ?? ""
                    reasoningDebug("emitting reasoning stream result len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                }
            #endif
            if let providerSessionID = result.providerSessionID,
               !providerSessionID.isEmpty
            {
                recordObservedSessionID(providerSessionID)
            }
            let logPayload = streamResultLogPayload(result)

            // Track session_state_changed events for authoritative lifecycle gating.
            if result.type == "session_state_changed" {
                observedSessionStateChangedEvents = true
                writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
                emit(.stream(result))
                if result.text?.lowercased() == "idle" {
                    completeNextDeferredTurnIfPending()
                }
                continue
            }

            // task_progress events flow through as run-state updates, not transcript rows
            if result.type == "task_progress" {
                writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
                emit(.stream(result))
                continue
            }

            if Self.shouldSuppressUserFacingStreamResult(result) {
                writeRawEventLogRecord(kind: "translator.streamResultSuppressed", payload: logPayload)
                continue
            }
            writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
            if creditsStartedTurn, AgentProviderHandoff.streamResultProvesProviderAcceptance(result) {
                noteOutputAttributedToProducingTurn()
            }
            emit(.stream(result))
            if isResultPayload, result.type == "message_stop" {
                // Accounting ownership is decided against launch-local dispatch ordinals, not the
                // completion FIFO below, so deferred `idle` completion never skews attribution.
                let disposition = evaluateUsageResultAttribution(result: result, payload: payload)
                if disposition == .exactDuplicate {
                    // A re-delivered result is not a second turn boundary. Consuming the FIFO
                    // here would retire the next dispatched turn (transcript and accounting)
                    // before its own authoritative result arrives.
                    writeRawEventLogRecord(kind: "turn.duplicateResultIgnored", payload: [
                        "resultIndex": result.usageObservation?.resultIndex ?? NSNull(),
                        "pendingTurnIDCount": pendingTurnIDBuffer.count - pendingTurnIDHead
                    ] as [String: Any])
                    continue
                }
                guard hasPendingTurnIDs else {
                    noteMissingPendingTurnID(context: "result message_stop")
                    continue
                }
                let status = determineTurnStatus(from: payload, stopReasonHint: result.stopReason)
                // Step 12: fixed now, against the FIFO as this result finds it (a later write must
                // not make an earlier result look exclusive, nor the reverse). The credited turn is
                // the first queued one whose result has not arrived.
                // (Surplus results can outnumber queued turns in deferred mode: no credited turn.)
                let creditedIndex = pendingTurnIDHead + pendingAuthoritativeTurnCompletions.count
                let creditedTurnID = creditedIndex < pendingTurnIDBuffer.count ? pendingTurnIDBuffer[creditedIndex] : nil
                let origin = TurnCompletionOrigin.providerResult(.init(
                    soleOutstandingTurn: pendingTurnIDBuffer.count - pendingTurnIDHead == 1
                        && pendingAuthoritativeTurnCompletions.isEmpty,
                    reportsInterruption: Self.resultPayloadReportsInterruption(payload),
                    messageIdentity: Self.resultMessageIdentity(
                        payload,
                        outbound: creditedTurnID.flatMap { outboundUserMessageUUIDByTurnID[$0] }
                    )
                ))
                if observedSessionStateChangedEvents {
                    // Defer completion until `idle` arrives or fallback timer fires.
                    // Do NOT dequeue the turn ID yet — keep turnInFlight == true so
                    // callers (e.g. coordinator steering) don't send a new user message
                    // before the authoritative idle boundary.
                    pendingAuthoritativeTurnCompletions.append(DeferredTurnCompletion(status: status, origin: origin))
                    scheduleAuthoritativeIdleFallbackIfNeeded()
                } else {
                    // Legacy mode: complete immediately on result/message_stop.
                    let completedTurnID = dequeueTurnID()
                    emitTurnCompleted(turnID: completedTurnID, status: status, origin: origin)
                }
            }
        }
    }

    /// Completes the next deferred turn waiting for `idle`, if any, and reschedules/cancels
    /// the fallback timer as needed. Dequeues the turn ID from `pendingTurnIDBuffer` at
    /// this point so `turnInFlight` transitions to false.
    private func completeNextDeferredTurnIfPending() {
        guard !pendingAuthoritativeTurnCompletions.isEmpty else { return }
        let completion = pendingAuthoritativeTurnCompletions.removeFirst()
        authoritativeIdleFallbackTask?.cancel()
        authoritativeIdleFallbackTask = nil
        guard hasPendingTurnIDs else {
            noteMissingPendingTurnID(context: "deferred idle completion")
            return
        }
        let turnID = dequeueTurnID()
        // The CLI's own `idle` boundary: the result's origin stands.
        emitTurnCompleted(turnID: turnID, status: completion.status, origin: completion.origin)
        // If more deferred completions remain, schedule a new fallback.
        scheduleAuthoritativeIdleFallbackIfNeeded()
    }

    /// Schedules a fallback timer for the head of the deferred completion queue.
    /// If `idle` does not arrive within `authoritativeTurnIdleFallbackSeconds`,
    /// the turn completes anyway. Each task carries a generation token so stale
    /// tasks that wake after cancellation are safely ignored.
    private func scheduleAuthoritativeIdleFallbackIfNeeded() {
        guard !pendingAuthoritativeTurnCompletions.isEmpty else {
            authoritativeIdleFallbackTask?.cancel()
            authoritativeIdleFallbackTask = nil
            return
        }
        // Only schedule if there is no active fallback task.
        guard authoritativeIdleFallbackTask == nil else { return }
        authoritativeIdleFallbackGeneration &+= 1
        let currentGeneration = authoritativeIdleFallbackGeneration
        let timeout = authoritativeTurnIdleFallbackSeconds
        authoritativeIdleFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleAuthoritativeIdleFallbackFired(generation: currentGeneration)
        }
    }

    private func handleAuthoritativeIdleFallbackFired(generation: UInt64) {
        // Ignore stale firings from superseded tasks.
        guard generation == authoritativeIdleFallbackGeneration else { return }
        authoritativeIdleFallbackTask = nil
        guard !pendingAuthoritativeTurnCompletions.isEmpty else { return }
        let status = pendingAuthoritativeTurnCompletions.removeFirst().status
        guard hasPendingTurnIDs else {
            noteMissingPendingTurnID(context: "idle fallback")
            return
        }
        let turnID = dequeueTurnID()
        writeRawEventLogRecord(kind: "lifecycle.idleFallback", payload: [
            "turnID": turnID.uuidString,
            "status": String(describing: status)
        ] as [String: Any])
        // Step 12: timed by the controller's fallback, not by the CLI.
        emitTurnCompleted(turnID: turnID, status: status, origin: .controllerSynthesized)
        scheduleAuthoritativeIdleFallbackIfNeeded()
    }

    /// Cancels and clears all authoritative lifecycle state. Called during shutdown/EOF.
    /// Preserves the stored turn status (e.g. `.completed`) rather than overwriting it
    /// with `.failed`, since the result was already observed.
    private func cancelAuthoritativeLifecycleState() {
        authoritativeIdleFallbackTask?.cancel()
        authoritativeIdleFallbackTask = nil
        // Emit deferred completions with their original status — the result/message_stop
        // already established the correct turn outcome; only idle was missing.
        for completion in pendingAuthoritativeTurnCompletions {
            guard hasPendingTurnIDs else { break }
            let turnID = dequeueTurnID()
            // Step 12: a shutdown/EOF flush, timed by the controller.
            emitTurnCompleted(turnID: turnID, status: completion.status, origin: .controllerSynthesized)
        }
        pendingAuthoritativeTurnCompletions.removeAll()
    }

    /// Records a turn-completion signal that arrived with no pending turn ID.
    ///
    /// This is an observed-benign signal on at least three routes, so it is a logged
    /// diagnostic rather than a DEBUG trap:
    /// - Teardown: `shutdown()`/`failProtocolAndShutdown()` clear the turn-ID queue
    ///   synchronously while the stdout consumer already holds a framed line, so the
    ///   subprocess's trailing `result` (a normal interrupt side effect) lands after
    ///   the queue was cleared.
    /// - Straggler lines: cancellation is cooperative and the consume path performs no
    ///   cancellation check, so a line from an old process can be processed after
    ///   `startOrResume` reset `isShuttingDown`.
    /// - Resume replay (crash 2026-07-27 19:28, `isShuttingDown == false`): reattaching
    ///   an existing CLI session can replay the final `result`/`message_stop` of a turn
    ///   this process instance never started, killing the debug host mid-session when
    ///   this was an `assertionFailure`.
    /// Callers keep their existing recovery path; the raw-event record preserves the
    /// diagnostic trail for genuine protocol drift.
    private func noteMissingPendingTurnID(context: String) {
        writeRawEventLogRecord(kind: "turn.pendingIDMissing", payload: [
            "context": context,
            "isShuttingDown": isShuttingDown,
            "turnWasInterrupted": turnWasInterrupted,
            "pendingAuthoritativeStatusCount": pendingAuthoritativeTurnCompletions.count
        ] as [String: Any])
        if config.enableDebugLogging {
            print("[ClaudeNativeSession] \(context) with no pending turn IDs — recovered (shutting_down=\(isShuttingDown))")
        }
    }

    static func shouldSuppressUserFacingStreamResult(_ result: AIStreamResult) -> Bool {
        // Reasoning is forwarded to Agent Mode as runtime-only status preview data.
        // Transcript suppression belongs in the view-model layer, not at this transport boundary.
        // Suppress Claude background task lifecycle notifications (task_started /
        // task_notification).  These are infrastructure-level events that Claude
        // processes internally; surfacing them in the transcript prematurely ends
        // the active assistant streaming segment (via endActiveAssistantSegment)
        // which makes the UI appear as if the turn completed while it is still
        // running.
        if result.type == "system", let text = result.text,
           text.hasPrefix("Task started") || text.hasPrefix("Task update")
        {
            return true
        }
        guard result.type == "error",
              let text = result.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(text)
    }

    /// Extracts tools and MCP server statuses from a `system/init` stream payload.
    /// Returns `nil` if the payload is not a `system/init` event.
    private static func parseSystemInitFields(from payload: [String: Any]) -> (tools: [String], mcpStatuses: [String: String])? {
        guard (payload["type"] as? String) == "system",
              ((payload["subtype"] as? String)?.lowercased() == "init")
        else {
            return nil
        }

        let tools = (payload["tools"] as? [String]) ?? []
        var mcpStatuses: [String: String] = [:]
        if let mcpServers = payload["mcp_servers"] as? [[String: Any]] {
            for server in mcpServers {
                guard let name = server["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                let status = (server["status"] as? String) ?? ""
                mcpStatuses[name] = status
            }
        }
        return (tools: tools, mcpStatuses: mcpStatuses)
    }

    // MARK: - RepoPrompt MCP health helpers

    static let repoPromptMCPDisconnectedStatus = "disconnected"

    /// The reported statuses as published: an unhealthy launch reports RepoPrompt `disconnected`
    /// (never `connected`, and never `failed`, which ends the run as a startup failure).
    static func overlayingRepoPromptMCPHealth(
        _ health: RepoPromptMCPHealth,
        on statuses: [String: String]
    ) -> [String: String] {
        guard health.isUnhealthy else { return statuses }
        var overlaid = statuses
        let key = statuses.keys.first {
            $0.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        } ?? MCPIntegrationHelper.repoPromptMCPServerName
        overlaid[key] = repoPromptMCPDisconnectedStatus
        return overlaid
    }

    static func repoPromptStatus(in statuses: [String: String]) -> String? {
        statuses.first {
            $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The RepoPrompt entry of an `mcp_status` control response (`{"mcpServers": [{name, status}]}`).
    static func repoPromptStatus(inMCPStatusResponse response: [String: Any]) -> String? {
        guard let servers = response["mcpServers"] as? [[String: Any]] else { return nil }
        var statuses: [String: String] = [:]
        for server in servers {
            guard let name = server["name"] as? String else { continue }
            statuses[name] = (server["status"] as? String) ?? ""
        }
        return repoPromptStatus(in: statuses)
    }

    static func repoPromptMCPDisconnectedMessage(toolName: String) -> String {
        "RepoPrompt MCP disconnected from Claude: tool '\(toolName)' did not stop after its deadline, so RepoPrompt closed the connection. RepoPrompt tools are unavailable for the rest of this turn; Claude restarts and resumes this conversation before your next message."
    }

    /// The non-terminal transcript error for a loss, worded by its reason in plain words. The raw
    /// close code stays in the `mcp.health.unhealthy` log payload only.
    static func repoPromptMCPDisconnectedMessage(for loss: AgentMCPRunConnectionLoss) -> String {
        let consequence = "RepoPrompt tools are unavailable for the rest of this turn; before your next message is sent, Claude restarts and resumes this conversation to reconnect them."
        switch loss.reason {
        case .toolExecutionWatchdog:
            return repoPromptMCPDisconnectedMessage(toolName: loss.toolName ?? "unknown")
        case .helperExited:
            let cause = repoPromptMCPAppSideCloseDescription(loss.closeReason)
                .map { "\($0), and the RepoPrompt MCP helper process exited" }
                ?? "the RepoPrompt MCP helper process exited"
            return "RepoPrompt MCP disconnected from Claude: \(cause). \(consequence)"
        case .routeNotRestored:
            let cause = repoPromptMCPAppSideCloseDescription(loss.closeReason)
                ?? "the RepoPrompt MCP helper lost its connection to RepoPrompt"
            return "RepoPrompt MCP disconnected from Claude: \(cause), and the helper has not reconnected. \(consequence)"
        }
    }

    /// Plain words for a close RepoPrompt itself initiated or detected as a transport failure;
    /// `nil` when the helper side closed (or the code is unknown), which the caller words as a
    /// helper-side close.
    static func repoPromptMCPAppSideCloseDescription(_ closeReason: String) -> String? {
        switch closeReason {
        case "idle_timeout":
            "RepoPrompt closed the idle connection"
        case "user_boot_from_dashboard":
            "RepoPrompt disconnected it from the dashboard"
        case "approval_denied":
            "RepoPrompt denied the connection"
        case "local_disconnect":
            "RepoPrompt closed the connection"
        case "read_error", "write_failure", "write_stall", "write_hangup", "receive_buffer_overflow":
            "the connection to RepoPrompt failed"
        default:
            nil
        }
    }

    private func resetRepoPromptMCPHealthForLaunch() {
        repoPromptMCPHealth = .unknown
        repoPromptMCPLostConnectionIDs.removeAll()
    }

    /// The single place a spawn installs its launch token: the stdout reader generation and the
    /// RepoPrompt MCP loss gate always share it, so `handleStdoutEOF`'s retirement (keyed on the
    /// stdout token) is compared with the same value in `noteRepoPromptMCPConnectionLost`.
    private func installSpawnLaunchTokens(_ launchToken: UUID, agentPID: pid_t) {
        repoPromptMCPLaunchToken = launchToken
        activeStdoutLaunchToken = launchToken
        spawnedLaunchAgent = (launchToken, agentPID)
    }

    /// Retires the current stdout reader generation. `handleStdoutEOF` does this before its
    /// awaited tail, while `process` is still set, so the launch is marked retired for loss
    /// handling at the same synchronous point.
    private func retireActiveStdoutLaunch(_ launchToken: UUID) {
        activeStdoutLaunchToken = nil
        repoPromptMCPStdoutRetiredLaunchToken = launchToken
    }

    private func noteRepoPromptMCPConnectedEvidence(source: String) {
        // Evidence on an unhealthy launch is retained raw but never restores `connected`.
        guard repoPromptMCPHealth == .unknown else { return }
        repoPromptMCPHealth = .connected
        writeRawEventLogRecord(kind: "mcp.health.connected", payload: ["source": source])
    }

    /// Applies an app-initiated loss of a RepoPrompt MCP connection. Only a loss of this
    /// controller's run that proves ownership by its current registered launch counts: it must be
    /// addressed to the current launch token, and either carry that launch's registered agent PID
    /// (proven ancestry) or concern a connection admitted after that launch registered. Another
    /// run, an earlier or later launch, no running launch, an unproven pre-existing connection,
    /// and repeated deliveries are ignored. Never blocks: it only updates state and publishes the
    /// degraded status.
    package func noteRepoPromptMCPConnectionLost(_ loss: AgentMCPRunConnectionLoss) {
        func ignore(_ why: String) {
            #if DEBUG
                debugRepoPromptMCPLossDecisions.append((loss.connectionID, why))
            #endif
            writeRawEventLogRecord(kind: "mcp.health.lossIgnored", payload: [
                "reason": why,
                "connectionID": loss.connectionID.uuidString,
                "lossRunID": loss.runID.uuidString,
                "lossLaunchToken": loss.launchToken.uuidString,
                "lossReason": loss.reason.rawValue,
                "closeReason": loss.closeReason
            ])
        }
        guard loss.runID == runID else { return ignore("run_mismatch") }
        guard process != nil, !isShuttingDown else { return ignore("no_current_launch") }
        // stdout EOF retires the launch before its awaited tail, while `process` is still set.
        if let retired = repoPromptMCPStdoutRetiredLaunchToken, retired == repoPromptMCPLaunchToken {
            return ignore("stdout_retired")
        }
        guard let currentToken = repoPromptMCPLaunchToken,
              let launch = runConnectionLossObserverLaunch,
              launch.token == currentToken,
              loss.launchToken == currentToken
        else {
            return ignore("stale_launch")
        }
        guard loss.provesOwnership(by: launch) else {
            return ignore(loss.agentProcessID == nil ? "unproven_predates_launch" : "agent_pid_mismatch")
        }
        guard repoPromptMCPLostConnectionIDs.insert(loss.connectionID).inserted else {
            return ignore("duplicate")
        }
        guard !repoPromptMCPHealth.isUnhealthy else { return ignore("already_unhealthy") }
        #if DEBUG
            debugRepoPromptMCPLossDecisions.append((loss.connectionID, "applied"))
        #endif
        repoPromptMCPHealth = .unhealthy(reason: loss.reason.rawValue)
        var payload: [String: Any] = [
            "reason": loss.reason.rawValue,
            "closeReason": loss.closeReason,
            "connectionID": loss.connectionID.uuidString,
            "agentProcessIDProven": loss.agentProcessID != nil,
            "reportedMcpServerStatuses": latestRuntimeInitMcpServerStatuses
        ]
        if let toolName = loss.toolName {
            payload["toolName"] = toolName
        }
        writeRawEventLogRecord(kind: "mcp.health.unhealthy", payload: payload)
        emit(.error(Self.repoPromptMCPDisconnectedMessage(for: loss)))
        publishRuntimeInitIfChanged()
    }

    static let repoPromptMCPProbeSupersededReason = "Claude restarted while waiting for RepoPrompt MCP"

    /// Waits (bounded) for fresh evidence that this launch's RepoPrompt MCP server is connected,
    /// before a turn is submitted on it. Polls `mcp_status` (a read-only control request); a CLI
    /// that rejects it or never answers it falls back to the app's authoritative live run route for
    /// this run. A missing RepoPrompt entry or `pending` keeps waiting until the deadline; only an
    /// explicit `failed` / `needs-auth` ends the wait early.
    ///
    /// The evidence is bound to the launch current at entry: after every suspension the probe
    /// re-checks that launch, and if it was replaced it reports not connected and records nothing,
    /// so one launch's evidence can never mark its successor connected.
    package func awaitRepoPromptMCPConnectedEvidence(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval = 0.25
    ) async -> RepoPromptMCPConnectionProbeOutcome {
        guard let probeLaunchToken = repoPromptMCPLaunchToken else {
            return .notConnected("Claude process is not running")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(max(0, timeoutSeconds) * 1000)))
        var lastStatus = "unreported"
        var useAppRoute = false
        /// The probed launch is no longer the current one (shut down or replaced).
        func launchReplaced() -> Bool {
            repoPromptMCPLaunchToken != probeLaunchToken
        }
        func superseded() -> RepoPromptMCPConnectionProbeOutcome {
            writeRawEventLogRecord(kind: "mcp.health.probeSuperseded", payload: [
                "probeLaunchToken": probeLaunchToken.uuidString
            ])
            return .notConnected(Self.repoPromptMCPProbeSupersededReason)
        }
        while true {
            guard !launchReplaced() else { return superseded() }
            guard process != nil, isInitialized, !isShuttingDown else {
                return .notConnected("Claude process is not running")
            }
            if case let .unhealthy(reason) = repoPromptMCPHealth {
                return .notConnected(reason)
            }
            if repoPromptMCPHealth == .connected {
                return .connected
            }
            if useAppRoute {
                let hasRoute: Bool = if let clientName = config.runtimeVariant.agentKind.mcpClientNameHint,
                                        let agentPID = currentLaunchAgentPID
                {
                    // The run's route must belong to this launch's own agent instance (the PID it
                    // registered, at the start time read then): a helper route retained across
                    // turns from an earlier launch never certifies a restart. The launch-token
                    // checks before and after this call bracket it.
                    await mcpHost.hasAuthoritativeLiveRunRoute(
                        runID: runID,
                        expectedClientName: clientName,
                        requiredAgentPID: agentPID
                    )
                } else {
                    false
                }
                guard !launchReplaced() else { return superseded() }
                if hasRoute {
                    noteRepoPromptMCPConnectedEvidence(source: "app_run_route")
                    continue
                }
                lastStatus = "no live run route"
            } else {
                let remaining = clock.now.duration(to: deadline)
                let requestTimeout = max(0.5, min(5.0, Double(remaining.components.seconds) + 0.5))
                let response: [String: Any]
                do {
                    response = try await sendControlRequest(
                        request: ["subtype": "mcp_status"],
                        timeoutSeconds: requestTimeout
                    )
                } catch ControllerError.invalidControlResponse {
                    guard !launchReplaced() else { return superseded() }
                    // An older CLI without `mcp_status`: use the app-side admission evidence.
                    useAppRoute = true
                    continue
                } catch ControllerError.controlRequestTimedOut {
                    guard !launchReplaced() else { return superseded() }
                    // A CLI that ignores unknown control requests: same fallback.
                    lastStatus = "mcp_status unanswered"
                    useAppRoute = true
                    continue
                } catch {
                    guard !launchReplaced() else { return superseded() }
                    return .notConnected("mcp_status failed: \(error.localizedDescription)")
                }
                guard !launchReplaced() else { return superseded() }
                let status = Self.repoPromptStatus(inMCPStatusResponse: response)
                lastStatus = status ?? "absent"
                switch status?.lowercased() {
                case "connected":
                    noteRepoPromptMCPConnectedEvidence(source: "mcp_status")
                    continue
                case "failed", "needs-auth", "needs_auth":
                    return .notConnected("RepoPrompt MCP status \(lastStatus)")
                default:
                    // `pending`, not yet listed, or not yet reported: keep waiting.
                    break
                }
            }
            guard clock.now < deadline else {
                return .notConnected("timed out waiting for RepoPrompt MCP (last status: \(lastStatus))")
            }
            do {
                try await Task.sleep(for: .milliseconds(Int64(max(0.01, pollIntervalSeconds) * 1000)))
            } catch {
                return .notConnected("cancelled")
            }
        }
    }

    /// Registers the loss observer for the current launch (token + the PID registered as the
    /// run's expected agent process). A registration for an earlier launch is replaced.
    private func registerRunConnectionLossObserverIfNeeded(expectedAgentPID pid: pid_t) async {
        // Only Agent Mode run launches (owned by the Claude Agent Mode coordinator, which has the
        // recovery path) observe connection loss.
        guard config.toolContext == .agentRun, let launchToken = repoPromptMCPLaunchToken else { return }
        let launch = AgentMCPRunLaunchIdentity(token: launchToken, agentProcessID: pid)
        guard runConnectionLossObserverLaunch != launch else { return }
        await unregisterRunConnectionLossObserverIfNeeded()
        let token = await mcpHost.registerRunConnectionLossObserver(for: runID, launch: launch) { [weak self] loss in
            await self?.noteRepoPromptMCPConnectionLost(loss)
        }
        // The launch may have been replaced, or another registration won, across the await.
        guard runConnectionLossObserverToken == nil, repoPromptMCPLaunchToken == launchToken else {
            await mcpHost.unregisterRunConnectionLossObserver(for: runID, token: token)
            return
        }
        runConnectionLossObserverToken = token
        runConnectionLossObserverLaunch = launch
    }

    private func unregisterRunConnectionLossObserverIfNeeded() async {
        guard let token = runConnectionLossObserverToken else { return }
        runConnectionLossObserverToken = nil
        runConnectionLossObserverLaunch = nil
        await mcpHost.unregisterRunConnectionLossObserver(for: runID, token: token)
    }

    // MARK: - Runtime init aggregation helpers

    /// Builds and emits a merged `RuntimeInitStatus` from all available sources.
    /// Deduplicates against the last emitted status.
    private func publishRuntimeInitIfChanged() {
        let status = RuntimeInitStatus(
            sessionID: sessionID,
            tools: latestRuntimeInitTools,
            mcpServerStatuses: Self.overlayingRepoPromptMCPHealth(
                repoPromptMCPHealth,
                on: latestRuntimeInitMcpServerStatuses
            ),
            initializeResponse: initializeResponseSnapshot,
            repoPromptMCPHealth: repoPromptMCPHealth
        )
        guard status != lastEmittedRuntimeInitStatus else { return }
        lastEmittedRuntimeInitStatus = status
        emit(.runtimeInit(status))
    }

    /// Best-effort parser for the initialize control response.
    /// Malformed entries are skipped; missing fields become nil/empty.
    static func parseInitializeResponseSnapshot(
        from response: [String: Any]
    ) -> RuntimeInitStatus.InitializeResponseSnapshot {
        let commands: [RuntimeInitStatus.InitializeResponseSnapshot.Command] = if let rawCommands = response["commands"] as? [[String: Any]] {
            rawCommands.compactMap { cmd in
                guard let name = cmd["name"] as? String, !name.isEmpty else { return nil }
                return .init(
                    name: name,
                    description: (cmd["description"] as? String) ?? "",
                    argumentHint: (cmd["argumentHint"] as? String) ?? ""
                )
            }
        } else {
            []
        }

        let agents: [RuntimeInitStatus.InitializeResponseSnapshot.Agent] = if let rawAgents = response["agents"] as? [[String: Any]] {
            rawAgents.compactMap { agent in
                guard let name = agent["name"] as? String, !name.isEmpty else { return nil }
                return .init(
                    name: name,
                    description: (agent["description"] as? String) ?? "",
                    model: agent["model"] as? String
                )
            }
        } else {
            []
        }

        let account: RuntimeInitStatus.InitializeResponseSnapshot.Account? = if let rawAccount = response["account"] as? [String: Any] {
            .init(
                email: rawAccount["email"] as? String,
                organization: rawAccount["organization"] as? String,
                subscriptionType: rawAccount["subscriptionType"] as? String,
                tokenSource: rawAccount["tokenSource"] as? String,
                apiKeySource: rawAccount["apiKeySource"] as? String,
                apiProvider: rawAccount["apiProvider"] as? String
            )
        } else {
            nil
        }

        return .init(
            commands: commands,
            agents: agents,
            outputStyle: response["output_style"] as? String,
            availableOutputStyles: (response["available_output_styles"] as? [String]) ?? [],
            account: account,
            pid: response["pid"] as? Int,
            modelsJSON: Self.canonicalJSONString(from: response["models"]),
            fastModeStateJSON: Self.canonicalJSONString(from: response["fast_mode_state"])
        )
    }

    /// Returns a stable canonical JSON string for a value, or nil if the value is nil/not serializable.
    private static func canonicalJSONString(from value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard JSONSerialization.isValidJSONObject(["v": value]) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstSessionIdentifier(in payload: [String: Any]) -> String? {
        if let sessionID = payload["session_id"] as? String {
            return sessionID
        }
        if let sessionID = payload["sessionId"] as? String {
            return sessionID
        }
        return nil
    }

    private func determineTurnStatus(
        from payload: [String: Any],
        stopReasonHint: String? = nil,
        consumeInterruptMarker: Bool = true
    ) -> TurnStatus {
        let subtype = ((payload["subtype"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stopReason = ((payload["stop_reason"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // If we recently sent an interrupt control request for this turn,
        // any error_during_execution result is an abort side effect, not a real failure.
        if turnWasInterrupted {
            if consumeInterruptMarker {
                turnWasInterrupted = false
            }
            return .cancelled
        }

        if Self.isCancelledTurnSignal(subtype)
            || Self.isCancelledTurnSignal(stopReason)
            || Self.isCancelledTurnSignal(stopReasonHint)
        {
            return .cancelled
        }
        if let streamEvent = payload["event"] as? [String: Any],
           let delta = streamEvent["delta"] as? [String: Any],
           let nestedStopReason = (delta["stop_reason"] as? String),
           Self.isCancelledTurnSignal(nestedStopReason)
        {
            return .cancelled
        }

        let resultErrors = Self.extractResultErrors(from: payload)
        if resultErrors.contains(where: { Self.isCancelledTurnSignal($0) }) {
            return .cancelled
        }

        if (payload["is_error"] as? Bool) == true
            || subtype.contains("error")
            || !resultErrors.isEmpty
        {
            return .failed
        }
        return .completed
    }

    #if DEBUG
        static func test_isRawEventFileLoggingEnabled() -> Bool {
            isRawEventFileLoggingEnabled()
        }

        func test_determineTurnStatus(payload: [String: Any], stopReasonHint: String? = nil) -> TurnStatus {
            determineTurnStatus(from: payload, stopReasonHint: stopReasonHint)
        }

        func test_setTurnWasInterrupted(_ value: Bool) {
            turnWasInterrupted = value
        }

        func test_handleStreamPayload(_ payload: [String: Any]) {
            handleStreamPayload(payload)
        }

        /// R6: launch arguments for a resume or a (gated) fresh `--session-id` start.
        func test_buildArguments(existingSessionID: String?, freshSessionID: String?) -> [String] {
            buildArguments(existingSessionID: existingSessionID, model: nil, freshSessionID: freshSessionID)
        }

        func test_resolveCapturedCommandForLaunch(
            environment: [String: String],
            additionalPaths: [String] = []
        ) throws -> ResolvedLaunchCommand {
            try Self.resolveCommandForLaunch(
                selection: commandSelection,
                environment: environment,
                additionalPaths: additionalPaths
            )
        }

        static func test_processSpawnedPayload(
            command: String,
            provenance: CommandProvenance,
            arguments: [String] = [],
            workingDirectory: String = "/tmp"
        ) -> [String: Any] {
            processSpawnedPayload(
                command: command,
                provenance: provenance,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }

        func test_effectiveLaunchEnvironment(
            base: [String: String],
            resolverOverrides: [String: String] = [:],
            resolverRemovedKeys: Set<String> = []
        ) -> [String: String] {
            effectiveLaunchEnvironment(
                base: base,
                resolverOverrides: resolverOverrides,
                resolverRemovedKeys: resolverRemovedKeys
            )
        }

        func test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: ClaudeCodeLaunchEnvironment,
            nextLaunchEnvironment: ClaudeCodeLaunchEnvironment
        ) -> Bool {
            activeLaunchEnvironmentSignature = LaunchEnvironmentSignature(activeLaunchEnvironment)
            return liveFlagSettingsRequiresProcessRestart(for: nextLaunchEnvironment)
        }

        func test_resolvePromptCacheRetentionForLaunch(
            launchEnvironment: [String: String],
            workingDirectory: String?
        ) {
            resolvePromptCacheRetentionForProcessLaunch(
                launchEnvironment: launchEnvironment,
                workingDirectory: workingDirectory
            )
        }

        /// Build the initialize control request payload for testing.
        func test_buildInitializeRequest(systemPromptOverride: String? = nil) -> [String: Any] {
            Self.buildInitializeRequest(systemPromptOverride: systemPromptOverride)
        }

        /// Build the initial flag-settings control request payload for testing.
        func test_buildApplyFlagSettingsRequest(
            model: String? = nil,
            effortLevel: ClaudeCodeEffortLevel? = nil
        ) -> [String: Any]? {
            Self.buildApplyFlagSettingsRequest(model: model, effortLevel: effortLevel)
        }

        func test_resolveApplyFlagSettingsRequest(
            model: String? = nil,
            effortLevel: ClaudeCodeEffortLevel? = nil
        ) async throws -> [String: Any]? {
            try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel).request
        }

        /// Build the initial permission-mode control request payload for testing.
        func test_buildSetPermissionModeRequest(permissionMode: String? = nil) -> [String: Any]? {
            Self.buildSetPermissionModeRequest(permissionMode: permissionMode ?? config.permissionMode)
        }

        /// Build CLI arguments for testing (verifies prompt flags are absent).
        func test_buildArguments(
            existingSessionID: String?,
            model: String?
        ) -> [String] {
            buildArguments(existingSessionID: existingSessionID, model: model)
        }

        @discardableResult
        func test_beginTurnTracking(outboundUserMessageUUID: UUID? = nil) -> UUID {
            beginTurnTracking(outboundUserMessageUUID: outboundUserMessageUUID)
        }

        /// The production stdout-EOF path (process loss) for the given launch's reader.
        func test_handleStdoutEOF(launchToken: UUID) async {
            await handleStdoutEOF(launchToken: launchToken)
        }

        /// Installs a synthetic process launch (no subprocess) so attribution can be exercised
        /// through the production `handleStreamPayload` path.
        @discardableResult
        func test_beginSyntheticUsageLaunch(
            launchMode: ProcessLaunchIdentity.LaunchMode = .freshSession,
            commandProvenance: CommandProvenance = .automaticResolved,
            pid: Int32 = 0,
            executableRealPath: String = "/synthetic/claude",
            backend: ClaudeCodeLaunchEnvironment.Backend = .defaultClaude,
            environmentOverrideKeys: [String] = [],
            configuredEnvironmentOverrideKeys: [String] = []
        ) -> ProcessLaunchIdentity {
            let identity = ProcessLaunchIdentity(
                token: UUID(),
                pid: pid,
                launchMode: launchMode,
                commandProvenance: commandProvenance,
                runtimeVariant: config.runtimeVariant,
                executablePath: executableRealPath,
                executableRealPath: executableRealPath,
                backend: backend,
                environmentOverrideKeys: environmentOverrideKeys,
                configuredEnvironmentOverrideKeys: configuredEnvironmentOverrideKeys,
                spawnedAt: Date()
            )
            // A synthetic launch stands in for a spawn: the stdout reader generation is that launch.
            activeStdoutLaunchToken = identity.token
            installLiveTranscriptQualification(launchToken: identity.token)
            beginUsageLaunch(identity)
            resolveLiveTranscriptEligibility(launchToken: identity.token)
            return identity
        }

        /// Seeds the initialize control response (account category evidence) for binding tests.
        func test_setInitializeResponse(_ response: [String: Any]) {
            initializeResponseSnapshot = Self.parseInitializeResponseSnapshot(from: response)
        }

        /// Runs the production environment composition (`effectiveLaunchEnvironment`, which applies
        /// this controller's configured overrides, the resolver overrides/removals and child
        /// sanitization) and derives launch-identity evidence from that final dictionary exactly
        /// as `startProcessIfNeeded` does before `ProcessLauncher.spawn`.
        func test_launchEnvironmentEvidence(
            base: [String: String],
            resolverOverrides: [String: String] = [:],
            resolverRemovedKeys: Set<String> = []
        ) -> LaunchEnvironmentEvidence {
            let finalEnvironment = effectiveLaunchEnvironment(
                base: base,
                resolverOverrides: resolverOverrides,
                resolverRemovedKeys: resolverRemovedKeys
            )
            return Self.launchEnvironmentEvidence(
                finalEnvironment: finalEnvironment,
                resolverOverrides: resolverOverrides,
                resolverRemovedKeys: resolverRemovedKeys,
                configuredOverrides: config.processEnvironmentOverrides
            )
        }

        /// Mirrors a successful user-message write: turn tracking plus dispatch registration.
        @discardableResult
        func test_registerSyntheticDispatch() -> UUID {
            let turnID = beginTurnTracking()
            registerUsageDispatch(turnID: turnID)
            return turnID
        }

        func test_endSyntheticUsageLaunch() {
            endUsageLaunch()
        }

        /// Step 4d3b: the outbound step `sendUserMessage` performs after a successful write.
        func test_noteLiveTranscriptOutbound(uuid: UUID?, text: String) {
            noteLiveTranscriptOutbound(uuid: uuid, text: text)
        }

        func test_liveTranscriptQualification() -> ClaudeLiveTranscriptProducerState? {
            liveTranscriptQualification
        }

        /// Step 4d3b: routes one raw line through the production `handleLine` path (decode failures
        /// included).
        func test_handleLine(_ lineData: Data) async {
            await handleLine(lineData)
        }

        /// Attaches an already-spawned harmless child (for example `/bin/cat`) as the controller's
        /// process so `sendUserMessage` performs its production stdin write against a real pipe.
        /// Readers are not started; `shutdown()` terminates the child normally.
        func test_attachSpawnedProcess(
            _ spawned: SpawnedProcess,
            initialized: Bool = true
        ) {
            // As at a production spawn: a new launch starts with fresh health and a new token.
            resetRepoPromptMCPHealthForLaunch()
            process = spawned
            installSpawnLaunchTokens(UUID(), agentPID: spawned.pid)
            if initialized {
                completeInitialization()
            } else {
                isInitialized = false
            }
            isShuttingDown = false
        }

        func test_currentRepoPromptMCPLaunchToken() -> UUID? {
            repoPromptMCPLaunchToken
        }

        /// The synchronous first step of `handleStdoutEOF` for the attached launch: the stdout
        /// generation is retired while `process` is still set (the EOF tail has not run yet).
        func test_retireActiveStdoutLaunchForCurrentLaunch() {
            guard let token = repoPromptMCPLaunchToken else { return }
            retireActiveStdoutLaunch(token)
        }

        func test_currentRunConnectionLossObserverLaunch() -> AgentMCPRunLaunchIdentity? {
            runConnectionLossObserverLaunch
        }

        func test_repoPromptMCPLossDecisions() -> [(connectionID: UUID, decision: String)] {
            debugRepoPromptMCPLossDecisions
        }

        /// Runs the production expected-PID + loss-observer registration for the attached launch.
        func test_registerExpectedAgentPID(_ pid: pid_t) async {
            await registerExpectedAgentPIDIfNeeded(pid)
        }

        func test_currentUsageLaunchToken() -> UUID? {
            usageLaunchState?.identity.token
        }

        func test_handleStdoutChunk(_ data: Data, launchToken: UUID) async {
            await handleStdoutChunk(data, launchToken: launchToken)
        }

        /// Stores a pending permission request as if the current transport had issued it.
        func test_storePendingPermissionRequest(id: String, request: [String: Any]) {
            pendingPermissionRequests[id] = PendingPermissionRequest(requestID: id, request: request, issuingLaunch: runtimeLaunch)
        }

        /// Attaches a fixture runtime launch to the current (test-attached) transport, committed or
        /// not, as a registered spawn would, so the production fences run without a real spawn.
        func test_installRuntimeLaunch(_ launch: AgentRuntimeLaunch, committed: Bool) {
            runtimeLaunch = launch
            runtimeManagedTransport = true
            runtimeCommittedLaunch = committed ? launch : nil
        }

        func test_setRuntimeFenceCheckpoint(_ checkpoint: (@Sendable (String) async -> Void)?) {
            testRuntimeFenceCheckpoint = checkpoint
        }

        func test_setProtocolFailureInterceptor(_ interceptor: (@Sendable (String) -> Void)?) {
            testProtocolFailureInterceptor = interceptor
        }

        /// Forgets a fixture transport that has no child process (pipes only), so neither `deinit`
        /// nor `shutdown()` signals or reaps its placeholder PID.
        func test_detachFixtureTransport() {
            process = nil
            runtimeLaunch = nil
            runtimeManagedTransport = false
            runtimeCommittedLaunch = nil
        }

        /// The production initial permission-mode request (`set_permission_mode` owner write).
        func test_applyInitialPermissionMode() async throws {
            try await applyInitialPermissionModeIfNeeded()
        }

        func test_handleControlRequest(
            requestID: String,
            subtype: String,
            request: [String: Any]
        ) async {
            handleControlRequest(
                ClaudeSDKProtocolCodec.ControlRequest(
                    requestID: requestID,
                    request: request,
                    subtype: subtype
                )
            )
            // As after an inbound line: queued automatic replies pass their fence and are written.
            await flushQueuedAutomaticReplies()
        }

        /// The production launch reservation step (cancellation and slot rechecks included).
        /// Returns whether the start would go on to spawn.
        func test_reserveSpawn(launch: AgentRuntimeLaunch) async throws -> Bool {
            guard case .proceed = try await reserveSpawn(launch: launch) else { return false }
            return true
        }
    #endif

    private static func extractResultErrors(from payload: [String: Any]) -> [String] {
        guard let errors = payload["errors"] as? [Any] else { return [] }
        return errors.compactMap { entry in
            switch entry {
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let object as [String: Any]:
                let message = (object["message"] as? String) ?? (object["error"] as? String)
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            default:
                return nil
            }
        }
    }

    /// Step 12 (P1-A): whether a result payload itself reports an aborted or interrupted turn,
    /// independent of the sticky `turnWasInterrupted` marker (which classifies whatever result comes
    /// next). The CLI's subtype for an aborted turn is `error_during_execution` (SDK: "API failure OR
    /// cancelled request"; observed on interrupts with `aborted_streaming`). A `success` result, the
    /// shape of an ordinary or background-continuation turn, never qualifies.
    private static func resultPayloadReportsInterruption(_ payload: [String: Any]) -> Bool {
        guard (payload["type"] as? String) == "result" else { return false }
        let subtype = ((payload["subtype"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard subtype != "success" else { return false }
        if subtype == "error_during_execution" { return true }
        return isCancelledTurnSignal(subtype)
            || isCancelledTurnSignal(payload["stop_reason"] as? String)
            || isCancelledTurnSignal(payload["terminal_reason"] as? String)
            || extractResultErrors(from: payload).contains(where: { isCancelledTurnSignal($0) })
    }

    /// Step 12 (P1-A): a result's consumed-user attribution against `outbound`, the UUID the credited
    /// turn's frame was written with (nil when written without one). JSON `null` counts as absent.
    private static func resultMessageIdentity(
        _ payload: [String: Any],
        outbound: UUID?
    ) -> TurnCompletionOrigin.MessageIdentity {
        let single = payload["user_message_uuid"].flatMap { $0 is NSNull ? nil : $0 }
        let list = payload["user_message_uuids"].flatMap { $0 is NSNull ? nil : $0 }
        guard single != nil || list != nil else { return .notReported }
        guard let outbound else { return .contradictsTurn }
        if let single {
            guard let value = single as? String, UUID(uuidString: value) == outbound else { return .contradictsTurn }
        }
        if let list {
            guard let values = list as? [Any], values.count == 1, let value = values[0] as? String,
                  UUID(uuidString: value) == outbound
            else { return .contradictsTurn }
        }
        return .namesTurn
    }

    private static func isCancelledTurnSignal(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return false
        }
        return value.contains("interrupt")
            || value.contains("cancel")
            || value.contains("aborted")
            || value.contains("request was aborted")
    }

    private func handleControlRequest(_ request: ClaudeSDKProtocolCodec.ControlRequest) {
        // R6: replies go only to the launch whose transport delivered this request.
        let receivingLaunch = runtimeLaunch
        writeRawEventLogRecord(kind: "control.request.received", payload: [
            "requestID": request.requestID,
            "subtype": request.subtype,
            "request": request.request
        ] as [String: Any])
        switch request.subtype {
        case "can_use_tool":
            let payload = request.request
            let toolName = (payload["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let input = payload["input"] as? [String: Any] ?? [:]
            if let repoPromptMatch = Self.repoPromptPermissionAutoApprovalMatch(toolName: toolName, requestPayload: payload) {
                do {
                    let allowResponse = Self.allowPermissionResponsePayload(
                        pendingRequest: payload,
                        includeUpdatedPermissions: false
                    )
                    writeRawEventLogRecord(kind: "approval.autoApprove.repoPrompt", payload: [
                        "requestID": request.requestID,
                        "toolName": toolName,
                        "matchSource": repoPromptMatch.source.rawValue,
                        "normalizedToolName": repoPromptMatch.normalizedToolName ?? NSNull(),
                        "serverIdentifier": repoPromptMatch.serverIdentifier ?? NSNull(),
                        "response": allowResponse
                    ] as [String: Any])
                    let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                        requestID: request.requestID,
                        response: allowResponse
                    )
                    sendAutomaticReply(
                        encoded,
                        requestID: request.requestID,
                        receivingLaunch: receivingLaunch,
                        failureMessage: "Failed auto-approving RepoPrompt Claude permission request"
                    )
                } catch {
                    failProtocolAndShutdownSoon(
                        message: "Failed auto-approving RepoPrompt Claude permission request: \(error.localizedDescription)"
                    )
                }
                return
            }
            if let approval = buildApprovalRequest(from: request) {
                pendingPermissionRequests[request.requestID] = PendingPermissionRequest(
                    requestID: request.requestID,
                    request: payload,
                    issuingLaunch: runtimeLaunch
                )
                writeRawEventLogRecord(kind: "approval.request.emitted", payload: [
                    "requestID": request.requestID,
                    "toolName": toolName,
                    "kind": String(describing: approval.kind)
                ] as [String: Any])
                emit(.approvalRequest(approval))
            } else {
                do {
                    let allowResponse = Self.allowPermissionResponsePayload(
                        pendingRequest: payload,
                        includeUpdatedPermissions: false
                    )
                    writeRawEventLogRecord(kind: "approval.autoApprove.fallback", payload: [
                        "requestID": request.requestID,
                        "toolName": toolName,
                        "response": allowResponse
                    ] as [String: Any])
                    let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                        requestID: request.requestID,
                        response: allowResponse
                    )
                    sendAutomaticReply(
                        encoded,
                        requestID: request.requestID,
                        receivingLaunch: receivingLaunch,
                        failureMessage: "Failed auto-approving Claude permission request"
                    )
                } catch {
                    failProtocolAndShutdownSoon(
                        message: "Failed auto-approving Claude permission request: \(error.localizedDescription)"
                    )
                }
            }
        default:
            do {
                let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseError(
                    requestID: request.requestID,
                    error: "Unsupported control request subtype: \(request.subtype)"
                )
                sendAutomaticReply(
                    encoded,
                    requestID: request.requestID,
                    receivingLaunch: receivingLaunch,
                    failureMessage: "Failed replying to unsupported Claude control request (\(request.subtype))"
                )
            } catch {
                failProtocolAndShutdownSoon(
                    message: "Failed replying to unsupported Claude control request (\(request.subtype)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleControlCancelRequest(requestID: String) {
        writeRawEventLogRecord(kind: "control.request.cancelled", payload: ["requestID": requestID])
        if pendingPermissionRequests.removeValue(forKey: requestID) != nil {
            emit(.approvalCancelled(requestID: requestID))
        }
    }

    private func handleControlResponse(_ response: ClaudeSDKProtocolCodec.ControlResponse) {
        guard let continuation = pendingControlRequests.removeValue(forKey: response.requestID) else {
            return
        }
        if let timeoutTask = pendingControlRequestTimeoutTasks.removeValue(forKey: response.requestID) {
            timeoutTask.cancel()
        }
        writeRawEventLogRecord(kind: "control.response.received", payload: [
            "requestID": response.requestID,
            "subtype": response.subtype,
            "error": response.error ?? NSNull(),
            "pendingPermissionRequestsCount": response.pendingPermissionRequests.count
        ] as [String: Any])
        switch response.subtype {
        case "success":
            continuation.resume(returning: response.response ?? [:])
        case "error":
            let message = response.error ?? "Unknown Claude control error"
            continuation.resume(throwing: ControllerError.invalidControlResponse(message))
            for pending in response.pendingPermissionRequests {
                guard let requestID = pending["request_id"] as? String,
                      let request = pending["request"] as? [String: Any]
                else {
                    continue
                }
                let synthesized = ClaudeSDKProtocolCodec.ControlRequest(
                    requestID: requestID,
                    request: request,
                    subtype: (request["subtype"] as? String) ?? ""
                )
                handleControlRequest(synthesized)
            }
        default:
            continuation.resume(throwing: ControllerError.invalidControlResponse("Unsupported subtype: \(response.subtype)"))
        }
    }

    /// How long an EOF'd registered root may take to exit on its own before its owned reap escalates.
    private static let exitedRootReapWait: TimeInterval = 2.0

    /// Turns failed by an unexpected stdout EOF (process loss), oldest first; bounded.
    private var processLostTurnIDs: [UUID] = []
    private static let processLostTurnIDLimit = 64

    /// `async` to match `NativeAgentRuntimeControlling` exactly: a synchronous signature lets the
    /// protocol extension's `false` default win both as the witness and in direct `await` calls.
    package func turnEndedByProcessLoss(_ turnID: UUID) async -> Bool {
        guard let index = processLostTurnIDs.firstIndex(of: turnID) else { return false }
        processLostTurnIDs.remove(at: index)
        return true
    }

    private func handleStdoutEOF(launchToken: UUID) async {
        guard !isShuttingDown else { return }
        // An EOF from an already-replaced process must not tear down the current launch.
        guard isCurrentStdoutLaunch(launchToken) else {
            writeRawEventLogRecord(kind: "process.stdoutEOF.staleLaunchIgnored", payload: [
                "launchToken": launchToken.uuidString
            ])
            return
        }
        retireActiveStdoutLaunch(launchToken)
        writeRawEventLogRecord(kind: "process.stdoutEOF")
        var remainingLines: [Data] = []
        stdoutFramer.flush { line in
            remainingLines.append(line)
        }
        // Step 4d3b: the exiting launch's producer classifies its own buffered tail (scoped to this
        // drain; the stdout token stays cleared), then retires.
        liveTranscriptEOFDrainLaunchToken = launchToken
        for line in remainingLines {
            await handleLine(line)
        }
        liveTranscriptEOFDrainLaunchToken = nil
        retireLiveTranscriptQualification(launchToken: launchToken)
        // The transport is gone: automatic replies queued for it are never written.
        queuedAutomaticReplies.removeAll()
        failPendingControlRequests(with: ControllerError.processNotRunning)
        cancelAuthoritativeLifecycleState()
        if let launch = runtimeLaunch, let exited = process {
            // R6: the captured launch owns one bounded reap of its exact root (it closed stdout, so
            // it normally exits on its own; escalation only after the bounded wait) and reports it
            // (root-lifetime evidence only). The reap is retained and joined by shutdown and by the
            // next launch's reservation. Only registered launches change reaping behavior.
            runtimeLaunch = nil
            _ = ownedRootReap(
                launch: launch,
                pid: exited.pid,
                processGroupID: exited.processGroupID,
                waitBeforeTerminating: Self.exitedRootReapWait
            )
        }
        process = nil
        isInitialized = false
        hasCompletedInitialFlagSettings = false
        let staleIDs = drainAllTurnIDs()
        if !staleIDs.isEmpty {
            // Review A F06: these turns failed by provider-process loss (not a requested shutdown);
            // recorded before their completions so the run's finalizer can type its cause. Bounded.
            processLostTurnIDs.append(contentsOf: staleIDs)
            if processLostTurnIDs.count > Self.processLostTurnIDLimit {
                processLostTurnIDs.removeFirst(processLostTurnIDs.count - Self.processLostTurnIDLimit)
            }
            emit(.error("Claude process exited unexpectedly."))
            for id in staleIDs {
                emitTurnCompleted(turnID: id, status: .failed, origin: .controllerSynthesized)
            }
        }
        endUsageLaunch()
        finishEventsStreamIfNeeded()
    }

    /// Every completion-lifecycle exit emits the transcript event and, when a launch is active,
    /// the ordered accounting closure on the usage stream (after any attribution for the turn).
    private func emitTurnCompleted(turnID: UUID, status: TurnStatus, origin: TurnCompletionOrigin) {
        emit(.turnCompleted(turnID: turnID, status: status, origin: origin))
        if let state = usageLaunchState {
            emitUsage(.turnClosed(launchToken: state.identity.token, turnID: turnID, status: status))
        }
    }

    // MARK: - Usage accounting ownership helpers

    /// Process/reader generation check for stdout bytes and EOF; independent of accounting state.
    private func isCurrentStdoutLaunch(_ token: UUID) -> Bool {
        activeStdoutLaunchToken == token
    }

    private func emitUsage(_ event: UsageAccountingEvent) {
        switch event {
        case .launched:
            currentLaunchUsageEvents = [event]
        case .launchEnded:
            currentLaunchUsageEvents.removeAll()
        default:
            currentLaunchUsageEvents.append(event)
        }
        usageEventsContinuation?.yield(event)
    }

    /// Latest-request evidence is intentionally not added to currentLaunchUsageEvents. Replaying
    /// it to a replacement subscriber could make a prior request look current after restore.
    private func emitTransientUsage(_ event: UsageAccountingEvent) {
        usageEventsContinuation?.yield(event)
    }

    private func beginUsageLaunch(_ identity: ProcessLaunchIdentity) {
        var state = UsageLaunchState(identity: identity)
        if case let .resumedSession(sessionID) = identity.launchMode {
            state.providerSessionID = sessionID
        }
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.launch.began", payload: [
            "launchToken": identity.token.uuidString,
            "pid": Int(identity.pid),
            "launchMode": Self.launchModeDescription(identity.launchMode),
            "commandProvenance": identity.commandProvenance.rawValue,
            "runtimeVariant": identity.runtimeVariant.rawValue,
            "environmentOverrideKeys": identity.environmentOverrideKeys,
            "configuredEnvironmentOverrideKeys": identity.configuredEnvironmentOverrideKeys
        ] as [String: Any])
        emitUsage(.launched(identity))
    }

    private func endUsageLaunch() {
        guard let state = usageLaunchState else { return }
        usageLaunchState = nil
        writeRawEventLogRecord(kind: "usage.launch.ended", payload: [
            "launchToken": state.identity.token.uuidString,
            "dispatchCount": state.nextDispatchOrdinal,
            "attributedResultCount": state.nextResultOrdinal,
            "blockedReason": state.blockedReason?.description ?? NSNull()
        ] as [String: Any])
        emitUsage(.launchEnded(launchToken: state.identity.token))
    }

    private static func launchModeDescription(_ mode: ProcessLaunchIdentity.LaunchMode) -> String {
        switch mode {
        case .freshSession: "freshSession"
        case .resumedSession: "resumedSession"
        }
    }

    private func registerUsageDispatch(turnID: UUID) {
        guard var state = usageLaunchState else { return }
        let ordinal = state.nextDispatchOrdinal
        state.nextDispatchOrdinal += 1
        state.turnIDByDispatchOrdinal[ordinal] = turnID
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.dispatch.registered", payload: [
            "launchToken": state.identity.token.uuidString,
            "turnID": turnID.uuidString,
            "ordinal": ordinal
        ] as [String: Any])
        emitUsage(.dispatched(launchToken: state.identity.token, turnID: turnID, ordinal: ordinal))
    }

    /// Terminal for the launch: no later result on this process can be attributed.
    private func blockUsageAttribution(_ reason: UsageAttributionBlock) {
        guard var state = usageLaunchState, state.blockedReason == nil else { return }
        state.blockedReason = reason
        state.turnIDByDispatchOrdinal.removeAll()
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.attribution.blocked", payload: [
            "launchToken": state.identity.token.uuidString,
            "reason": reason.description
        ] as [String: Any])
        emitUsage(.blocked(launchToken: state.identity.token, reason: reason))
    }

    private func blockUsageAttribution(reason: String) {
        blockUsageAttribution(.desynchronized(reason))
    }

    private func noteUsageRuntimeEvidence(version: String?, providerSessionID: String?) {
        guard var state = usageLaunchState, state.blockedReason == nil else { return }
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedVersion.isEmpty else {
            blockUsageAttribution(.missingRuntimeVersion)
            return
        }
        if let known = state.runtimeVersion {
            guard known == trimmedVersion else {
                blockUsageAttribution(.runtimeVersionConflict)
                return
            }
        }
        let trimmedSession = providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let known = state.providerSessionID {
            guard trimmedSession.isEmpty || known == trimmedSession else {
                blockUsageAttribution(.providerSessionIdentityChanged)
                return
            }
        } else if !trimmedSession.isEmpty {
            state.providerSessionID = trimmedSession
        }
        let isFirstEvidence = state.runtimeVersion == nil
        state.runtimeVersion = trimmedVersion
        usageLaunchState = state
        if isFirstEvidence {
            writeRawEventLogRecord(kind: "usage.runtime.evidence", payload: [
                "launchToken": state.identity.token.uuidString,
                "claudeCodeVersion": trimmedVersion,
                "hasProviderSessionID": !trimmedSession.isEmpty
            ] as [String: Any])
            emitUsage(.runtimeEvidence(
                launchToken: state.identity.token,
                runtimeVersion: trimmedVersion,
                providerSessionID: state.providerSessionID
            ))
        }
    }

    /// Emits only a current-launch, main-line assistant request while the dispatch that owns the
    /// next result is still outstanding. Sidechain assistant messages and session mismatches are
    /// ignored; they can never replace the main readout. A missing usage object is still evidence
    /// that a newer main request occurred, so it clears the earlier value downstream.
    private func emitMainRequestUsageIfOwned(
        payload: [String: Any],
        streamResults: [AIStreamResult]
    ) {
        guard let state = usageLaunchState,
              state.blockedReason == nil,
              payload["parent_tool_use_id"] == nil || payload["parent_tool_use_id"] is NSNull,
              let providerSessionID = state.providerSessionID,
              Self.firstSessionIdentifier(in: payload)?
              .trimmingCharacters(in: .whitespacesAndNewlines) == providerSessionID,
              let turnID = state.turnIDByDispatchOrdinal[state.nextResultOrdinal]
        else { return }

        let message = payload["message"] as? [String: Any]
        let trimmedRequestID = (message?["id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = trimmedRequestID.flatMap { $0.isEmpty ? nil : $0 }
        let observation = streamResults
            .compactMap(\.usageObservation)
            .first(where: { $0.source == .assistant && $0.parentToolUseID == nil })

        emitTransientUsage(.mainRequestUsageAttributed(.init(
            launchToken: state.identity.token,
            turnID: turnID,
            requestID: requestID,
            observation: observation
        )))
    }

    // MARK: Step 4d3b live transcript qualification (inactive)

    /// A fresh state for a newly installed stdout producer; called only where an actual stdout launch
    /// token is installed. Disabled: none.
    private func installLiveTranscriptQualification(launchToken: UUID) {
        guard liveTranscriptQualificationEnabled else {
            liveTranscriptQualification = nil
            return
        }
        var state = ClaudeLiveTranscriptProducerState(launchToken: launchToken)
        // Installed across an earlier launch's EOF drain (only its fatal-path shutdown suspends): its
        // payloads during that drain are never classified, so it never qualifies.
        if liveTranscriptEOFDrainLaunchToken != nil { state.disqualify(.launchDuringDrain) }
        liveTranscriptQualification = state
    }

    /// Once the launch identity is recorded, only a launch eligible for an outbound user-message
    /// identity (automatic or configured command, default backend, no routing overrides) keeps its state; an
    /// ineligible producer drops it and never emits evidence. Eligibility is not installed-profile
    /// qualification.
    private func resolveLiveTranscriptEligibility(launchToken: UUID) {
        guard var state = currentLiveTranscriptQualification(), state.launchToken == launchToken else { return }
        guard outboundUserMessageIdentityEligible, usageLaunchState?.identity.token == launchToken else {
            liveTranscriptQualification = nil
            return
        }
        state.markEligible()
        liveTranscriptQualification = state
    }

    /// The state of the producer whose stdout is current; a stale producer's state is never read.
    /// While an EOF drain is active, only the exiting launch whose buffered tail it drains is ever
    /// selected, never a replacement installed across the drain's (fatal-path) suspension.
    private func currentLiveTranscriptQualification() -> ClaudeLiveTranscriptProducerState? {
        guard let state = liveTranscriptQualification,
              state.launchToken == (liveTranscriptEOFDrainLaunchToken ?? activeStdoutLaunchToken)
        else {
            return nil
        }
        return state
    }

    private func noteLiveTranscriptOutbound(uuid: UUID?, text: String) {
        guard var state = currentLiveTranscriptQualification() else { return }
        let wasQualifying = state.disqualification == nil
        state.noteOutbound(uuid: uuid, text: text)
        liveTranscriptQualification = state
        emitDirectLiveTranscriptDisqualification(state, wasQualifying: wasQualifying)
    }

    private func disqualifyLiveTranscript(_ reason: ClaudeLiveTranscriptDisqualification) {
        guard var state = currentLiveTranscriptQualification() else { return }
        let wasQualifying = state.disqualification == nil
        state.disqualify(reason)
        liveTranscriptQualification = state
        emitDirectLiveTranscriptDisqualification(state, wasQualifying: wasQualifying)
    }

    /// A producer disqualified outside payload classification (an undecodable line or payload, an
    /// unidentified or overlapping outbound write) tells its owner at once with one metadata-only
    /// carrier, so its owner invalidates proofs even when no later payload arrives; later payloads
    /// still repeat it. Nothing for a disabled, ineligible or already disqualified producer.
    private func emitDirectLiveTranscriptDisqualification(
        _ state: ClaudeLiveTranscriptProducerState,
        wasQualifying: Bool
    ) {
        guard wasQualifying, state.eligibility == .eligible, let reason = state.disqualification else { return }
        emit(.stream(.claudeLiveTranscriptEvidenceCarrier(
            ClaudeLiveTranscriptEvidence(producerLaunchToken: state.launchToken, kind: .disqualified(reason))
        )))
    }

    /// After its stdout EOF drained the buffered tail, the exited launch's producer is retired (a
    /// replacement launch installed meanwhile keeps its own).
    private func retireLiveTranscriptQualification(launchToken: UUID) {
        if liveTranscriptQualification?.launchToken == launchToken {
            liveTranscriptQualification = nil
        }
    }

    /// Classifies one raw payload of the current producer: complete-text and Step 4d5 Read row
    /// evidence is attached to its one translated `content`/`tool_call`/`tool_result` result; any
    /// other evidence is returned as a metadata-only carrier.
    /// Nothing while disabled, stale or not (yet) eligible.
    private func classifyLiveTranscriptPayload(
        envelope: Data,
        streamResults: inout [AIStreamResult]
    ) -> AIStreamResult? {
        guard var state = currentLiveTranscriptQualification() else { return nil }
        let outcome = state.classify(envelope: envelope, translated: streamResults, turnInFlight: turnInFlight)
        liveTranscriptQualification = state
        guard state.eligibility == .eligible else { return nil }
        switch outcome {
        case .benign:
            return nil
        case let .attach(index, evidence):
            // Step 4d5: evidence never rides on a result suppression would drop silently.
            guard !Self.shouldSuppressUserFacingStreamResult(streamResults[index]) else {
                state.disqualify(.attachmentSuppressed)
                liveTranscriptQualification = state
                return .claudeLiveTranscriptEvidenceCarrier(ClaudeLiveTranscriptEvidence(
                    producerLaunchToken: state.launchToken,
                    kind: .disqualified(state.disqualification ?? .attachmentSuppressed)
                ))
            }
            streamResults[index].claudeLiveTranscriptEvidence = evidence
            return nil
        case let .standalone(evidence):
            return .claudeLiveTranscriptEvidenceCarrier(evidence)
        }
    }

    // MARK: Runtime provenance and child-activity evidence

    /// Records the first `system/init` provenance for the launch (diagnostic only). Repeated
    /// initializations never reset baseline, index or totals and never re-emit it; a changed model
    /// or key source is not a reason to stop counting the runtime's reported figures.
    private func noteUsageRuntimeBinding(_ payload: [String: Any]) {
        guard var state = usageLaunchState, state.blockedReason == nil, let version = state.runtimeVersion else { return }
        let observed = RuntimeBinding(
            runtimeVersion: version,
            apiProvider: initializeResponseSnapshot?.account?.apiProvider,
            apiKeySource: payload["apiKeySource"] as? String,
            model: payload["model"] as? String,
            permissionMode: payload["permissionMode"] as? String
        )
        guard state.binding == nil else { return }
        state.binding = observed
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.runtime.binding", payload: [
            "launchToken": state.identity.token.uuidString,
            "apiProvider": observed.apiProvider ?? NSNull(),
            "apiKeySource": observed.apiKeySource ?? NSNull(),
            "model": observed.model ?? NSNull(),
            "permissionMode": observed.permissionMode ?? NSNull()
        ] as [String: Any])
        emitUsage(.runtimeBinding(launchToken: state.identity.token, binding: observed))
    }

    /// `system/status` compaction activity on installed 2.1.268 (`status: compacting`,
    /// `compact_result`/`compact_error`/`compact_metadata`).
    static func usageCompactionStatusBoundary(in payload: [String: Any]) -> String? {
        guard (payload["type"] as? String) == "system", (payload["subtype"] as? String) == "status" else { return nil }
        if (payload["status"] as? String)?.lowercased().contains("compact") == true { return "status:compacting" }
        for key in ["compact_result", "compact_error", "compact_metadata"] where payload[key] != nil {
            return "status:\(key)"
        }
        return nil
    }

    /// Name of a native child tool invoked in a main-line assistant message (`Agent` or its alias
    /// `Task`). Sidechain messages (non-null `parent_tool_use_id`) are not main-line evidence.
    static func usageChildToolInvocation(in payload: [String: Any]) -> String? {
        guard (payload["type"] as? String) == "assistant",
              payload["parent_tool_use_id"] == nil || payload["parent_tool_use_id"] is NSNull,
              let message = payload["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        for block in content where (block["type"] as? String) == "tool_use" {
            if let name = block["name"] as? String, name == "Agent" || name == "Task" {
                return name
            }
        }
        return nil
    }

    private func noteUsageChildToolObserved() {
        guard var state = usageLaunchState, state.blockedReason == nil, !state.childToolObservedSinceLastResult else { return }
        state.childToolObservedSinceLastResult = true
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.childTool.observed", payload: [
            "launchToken": state.identity.token.uuidString
        ] as [String: Any])
    }

    /// Whether a result reports spawned native children (`subagent_stats.spawned > 0`). The field
    /// is present with zeros on every 2.1.268 result, so presence alone is never child evidence.
    static func usageResultReportsSpawnedChildren(in payload: [String: Any]) -> Bool {
        guard let stats = payload["subagent_stats"] as? [String: Any],
              let spawned = stats["spawned"] as? NSNumber,
              CFGetTypeID(spawned) != CFBooleanGetTypeID()
        else { return false }
        return spawned.doubleValue > 0
    }

    private func noteUsageCounterBoundary(kind: String) {
        guard let state = usageLaunchState, state.blockedReason == nil else { return }
        writeRawEventLogRecord(kind: "usage.counterBoundary.observed", payload: [
            "launchToken": state.identity.token.uuidString,
            "kind": kind
        ] as [String: Any])
        emitUsage(.counterBoundaryObserved(launchToken: state.identity.token, kind: kind))
    }

    /// Attributes a raw `result` to exactly the dispatch it answers. Every failure is fail-closed:
    /// an exact duplicate is a no-op (no ordinal advance, and the caller must not treat it as a
    /// turn boundary), a reused uuid with different fields, a reused/skipped/reordered index, a
    /// missing dispatch, missing version or session evidence all block the remaining launch.
    /// Indices are never skipped to resynchronize.
    @discardableResult
    private func evaluateUsageResultAttribution(result: AIStreamResult, payload: [String: Any]) -> UsageResultDisposition {
        guard var state = usageLaunchState, state.blockedReason == nil else { return .notEvaluated }
        guard let observation = result.usageObservation else {
            blockUsageAttribution(reason: "result carried no usage observation")
            return .blocked
        }
        guard let resultID = observation.envelopeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resultID.isEmpty
        else {
            blockUsageAttribution(reason: "result without uuid")
            return .blocked
        }
        // Bind the cumulative cost from the originally decoded payload: the translator input is a
        // JSONSerialization re-serialisation of this dictionary (17-significant-digit doubles) and
        // the parser turns such literals into decimal numbers, so `result.cost` can carry ±1e-18
        // noise (0.008242 → 0.008242000000000001) while the decoded value is the exact nearest double.
        // The plugin codec already parses long decimal literals to the correctly rounded double
        // (`ClaudeProviderJSONValue(any:)`), so this is the nearest double of the wire lexeme.
        let cumulativeCost = (payload["total_cost_usd"] as? NSNumber).map(\.doubleValue) ?? result.cost
        let fingerprint = UsageResultFingerprint(
            resultIndex: observation.resultIndex,
            reportedCost: cumulativeCost,
            observation: observation
        )
        if let seen = state.attributedResultFingerprints[resultID] {
            if seen == fingerprint {
                writeRawEventLogRecord(kind: "usage.result.duplicateIgnored", payload: [
                    "launchToken": state.identity.token.uuidString,
                    "resultIndex": observation.resultIndex ?? NSNull()
                ] as [String: Any])
                return .exactDuplicate
            }
            blockUsageAttribution(reason: "result uuid reused with conflicting accounting fields")
            return .blocked
        }
        guard let runtimeVersion = state.runtimeVersion else {
            blockUsageAttribution(reason: "result before runtime version evidence")
            return .blocked
        }
        let resultSessionID = Self.firstSessionIdentifier(in: payload)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let providerSessionID = state.providerSessionID, !resultSessionID.isEmpty,
              resultSessionID == providerSessionID
        else {
            blockUsageAttribution(reason: "result provider session identity mismatch")
            return .blocked
        }
        guard let resultIndex = observation.resultIndex else {
            blockUsageAttribution(reason: "result_index missing or invalid")
            return .blocked
        }
        guard resultIndex == state.nextResultOrdinal else {
            blockUsageAttribution(reason: "result_index \(resultIndex) but next expected ordinal is \(state.nextResultOrdinal)")
            return .blocked
        }
        guard let turnID = state.turnIDByDispatchOrdinal[resultIndex] else {
            blockUsageAttribution(reason: "no dispatched turn for result_index \(resultIndex)")
            return .blocked
        }
        // Outcome, local commands, child scope and cumulative-cost monotonicity are not ownership
        // questions: the result is attributed with its status and child evidence, and core decides
        // finalization, token-scope coverage and checkpoint acceptance (plan §4).
        let status = determineTurnStatus(from: payload, stopReasonHint: result.stopReason, consumeInterruptMarker: false)
        let childActivityObserved = state.childToolObservedSinceLastResult || Self.usageResultReportsSpawnedChildren(in: payload)
        state.turnIDByDispatchOrdinal.removeValue(forKey: resultIndex)
        state.nextResultOrdinal += 1
        state.attributedResultFingerprints[resultID] = fingerprint
        state.childToolObservedSinceLastResult = false
        usageLaunchState = state
        writeRawEventLogRecord(kind: "usage.result.attributed", payload: [
            "launchToken": state.identity.token.uuidString,
            "turnID": turnID.uuidString,
            "resultIndex": resultIndex,
            "queuedTurnCount": observation.queuedTurnCount ?? NSNull(),
            "status": String(describing: status),
            "childActivityObserved": childActivityObserved
        ] as [String: Any])
        emitUsage(.resultAttributed(UsageResultAttribution(
            launchToken: state.identity.token,
            turnID: turnID,
            dispatchOrdinal: resultIndex,
            resultIndex: resultIndex,
            queuedTurnCount: observation.queuedTurnCount,
            runtimeVersion: runtimeVersion,
            providerSessionID: providerSessionID,
            observation: observation,
            reportedCost: cumulativeCost,
            turnStatus: status,
            childActivityObserved: childActivityObserved
        )))
        return .attributed
    }

    private func failPendingControlRequests(with error: Error) {
        let pending = pendingControlRequests
        pendingControlRequests.removeAll()
        let timeoutTasks = pendingControlRequestTimeoutTasks
        pendingControlRequestTimeoutTasks.removeAll()
        for timeoutTask in timeoutTasks.values {
            timeoutTask.cancel()
        }
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func handleControlRequestTimeout(requestID: String) {
        guard let continuation = pendingControlRequests.removeValue(forKey: requestID) else {
            pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            return
        }
        pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: ControllerError.controlRequestTimedOut(
            requestID: requestID,
            detail: isInitialized ? nil : configuredCommandConnectTimeoutHint
        ))
    }

    private func finishEventsStreamIfNeeded() {
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    /// Unbounded buffering is required: consumers rely on every event, including `.marker`
    /// run boundaries, being delivered in order without drops.
    private static func makeEventsStream() -> (stream: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation) {
        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            fatalError("Failed to initialize Claude events stream continuation")
        }
        return (stream, continuation)
    }

    /// Non-empty system-prompt suffix that makes the CLI emit its interactive `You are Claude Code…`
    /// identity preamble instead of the Agent SDK `You are a Claude agent…` form. z.ai (GLM)
    /// selectively rejects the Agent SDK self-identification under peak load with a misleading 529
    /// `overloaded` that exhausts the CLI's retry budget and fails the run; the interactive form is
    /// never shed. Empty/whitespace-only values are ignored by the CLI, so this must be a real token,
    /// and it deliberately avoids the trigger words ("Claude"/"Anthropic"/"agent"/"SDK") so it cannot
    /// reintroduce the shedding. See https://github.com/repoprompt/repoprompt-ce/issues/295.
    private static let glmZAIAppendSystemPrompt = "Running within RepoPrompt CE."

    private func buildArguments(
        existingSessionID: String?,
        model: String?,
        freshSessionID: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json"
        ]

        args.append(contentsOf: ["--permission-prompt-tool", "stdio"])

        // GLM/z.ai sheds requests carrying the Agent SDK identity preamble under load (see #295).
        // Any non-empty --append-system-prompt flips the CLI onto the never-shed "Claude Code" preamble.
        if config.runtimeVariant == .glm {
            args.append(contentsOf: ["--append-system-prompt", Self.glmZAIAppendSystemPrompt])
        }

        if let existingSessionID, !existingSessionID.isEmpty {
            args.append(contentsOf: ["--resume", existingSessionID])
            // RepoPrompt instructions are delivered in provider-bound user messages,
            // so CLI prompt flags remain unused on both fresh starts and resumes.
        } else if let freshSessionID, !freshSessionID.isEmpty {
            // Qualified fresh preallocation only (R6); never combined with `--resume`.
            args.append(contentsOf: ["--session-id", freshSessionID])
        }

        if config.permissionMode.caseInsensitiveCompare("bypassPermissions") == .orderedSame {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let configURL {
            args.append(contentsOf: ["--mcp-config", configURL.path])
            if config.mcpStrictMode {
                args.append("--strict-mcp-config")
            }
        }
        if !config.disallowedBuiltInTools.isEmpty {
            args.append(contentsOf: ["--disallowedTools", config.disallowedBuiltInTools.joined(separator: ",")])
        }
        return args
    }

    private func buildApprovalRequest(from request: ClaudeSDKProtocolCodec.ControlRequest) -> AgentApprovalRequest? {
        let payload = request.request
        let toolName = (payload["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
        let input = payload["input"] as? [String: Any] ?? [:]
        let blockedPath = payload["blocked_path"] as? String
        let decisionReason = payload["decision_reason"] as? String
        let description = payload["description"] as? String
        let toolUseID = (payload["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTool = toolName.lowercased()
        let kind: AgentApprovalKind = normalizedTool.contains("bash") || normalizedTool.contains("shell")
            ? .commandExecution
            : .fileChange

        let threadID = sessionID ?? "claude:\(tabID.uuidString.lowercased())"
        let turnID = "turn:\(runID.uuidString.lowercased())"
        let itemID = (toolUseID?.isEmpty == false ? toolUseID! : request.requestID)

        let approvalID = AgentApprovalRequest.stableID(
            requestID: .claudeControl(request.requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        let detailSeed = approvalID.uuidString
        var details: [AgentApprovalDetail] = []
        var detailIndex = 0
        func appendDetail(label: String, value: String, isCode: Bool = false) {
            details.append(
                AgentApprovalDetail(
                    id: AgentApprovalDetail.stableID(
                        requestSeed: detailSeed,
                        index: detailIndex,
                        label: label,
                        value: value,
                        isCode: isCode
                    ),
                    label: label,
                    value: value,
                    isCode: isCode
                )
            )
            detailIndex += 1
        }
        appendDetail(label: "Tool", value: toolName, isCode: true)
        if let command, !command.isEmpty {
            appendDetail(label: "Command", value: command, isCode: true)
        }
        if let blockedPath, !blockedPath.isEmpty {
            appendDetail(label: "Blocked Path", value: blockedPath, isCode: true)
        }
        if let decisionReason, !decisionReason.isEmpty {
            appendDetail(label: "Reason", value: decisionReason)
        }
        if let description, !description.isEmpty {
            appendDetail(label: "Description", value: description)
        }

        return AgentApprovalRequest(
            id: approvalID,
            requestID: .claudeControl(request.requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: decisionReason,
            command: command,
            cwd: workspacePath,
            grantRoot: blockedPath,
            details: details
        )
    }

    private func permissionResponsePayload(
        decision: AgentApprovalDecision,
        pendingRequest: [String: Any]
    ) -> [String: Any] {
        switch decision {
        case .accept:
            Self.allowPermissionResponsePayload(
                pendingRequest: pendingRequest,
                includeUpdatedPermissions: false
            )
        case .acceptForSession, .acceptWithExecpolicyAmendment:
            Self.allowPermissionResponsePayload(
                pendingRequest: pendingRequest,
                includeUpdatedPermissions: true
            )
        case .decline:
            [
                "behavior": "deny",
                "message": "Permission denied by user."
            ]
        case .cancel:
            [
                "behavior": "deny",
                "message": "Permission cancelled by user.",
                "interrupt": true
            ]
        }
    }

    nonisolated static func allowPermissionResponsePayload(
        pendingRequest: [String: Any],
        includeUpdatedPermissions: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "allow"]
        payload["updatedInput"] = pendingRequest["input"] as? [String: Any] ?? [:]
        if includeUpdatedPermissions,
           let suggestions = pendingRequest["permission_suggestions"] as? [[String: Any]],
           !suggestions.isEmpty
        {
            payload["updatedPermissions"] = suggestions
        }
        if let toolUseID = (pendingRequest["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolUseID.isEmpty
        {
            payload["toolUseID"] = toolUseID
        }
        return payload
    }

    nonisolated static func shouldAutoApproveRepoPromptPermissionRequest(
        toolName: String,
        input: [String: Any]
    ) -> Bool {
        repoPromptPermissionAutoApprovalMatch(toolName: toolName, requestPayload: input) != nil
    }

    nonisolated static func repoPromptPermissionAutoApprovalMatch(
        toolName: String,
        requestPayload: [String: Any]
    ) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
        MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: toolName,
            requestPayload: requestPayload
        )
    }

    private func resolvedWorkingDirectory() -> String {
        let trimmedWorkspace = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWorkspace, !trimmedWorkspace.isEmpty {
            return trimmedWorkspace
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func registerExpectedAgentPIDIfNeeded(_ pid: pid_t) async {
        guard config.toolContext == .agentRun,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        let previousPID = registeredExpectedAgentPID.flatMap { $0 == pid ? nil : $0 }
        registeredExpectedAgentPID = pid
        #if DEBUG
            // Both launch paths (runtime-managed or not) register the spawned process installed
            // with the current launch token; a different PID means the early-release proof would
            // ask about a process the host never registered for this launch.
            if let token = repoPromptMCPLaunchToken,
               let launch = spawnedLaunchAgent,
               launch.token == token,
               launch.pid != pid
            {
                print("[ClaudeNativeSession] DEBUG expected-PID mismatch: registering pid=\(pid) but launch token=\(token.uuidString) spawned pid=\(launch.pid) runID=\(runID.uuidString)")
            }
        #endif
        // The loss observer registers first, in the first manager call after spawn: this launch's
        // helper only connects once Claude has booted and started it, so its connection is not
        // recorded as predating this launch's observer (no extra hop for it to slip into).
        await registerRunConnectionLossObserverIfNeeded(expectedAgentPID: pid)
        // A same-controller respawn (after an unexpected stdout EOF, which never clears it) still
        // has the previous process's PID registered. Clear it first, after the previous launch's
        // loss observer was replaced above: the clear releases that instance, unrouting its
        // dependents, and closes the window in which a reused PID passes the PID-only admission gate.
        if let previousPID {
            await mcpHost.clearExpectedAgentPID(previousPID, for: clientName, runID: runID)
        }
        await mcpHost.registerExpectedAgentPID(
            pid,
            for: clientName,
            runID: runID,
            expectedProcessExecutablePath: nil,
            expectedProcessExecutableIdentity: nil
        )
        if isShuttingDown {
            await unregisterRunConnectionLossObserverIfNeeded()
            await mcpHost.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            if registeredExpectedAgentPID == pid {
                registeredExpectedAgentPID = nil
            }
            return
        }
        if config.enableDebugLogging {
            print("[ClaudeNativeSession] Registered expected MCP parent PID \(pid) for \(clientName) runID=\(runID.uuidString)")
        }
    }

    private func clearExpectedAgentPIDIfNeeded() async {
        guard let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        await mcpHost.clearExpectedAgentPID(registeredExpectedAgentPID, for: clientName, runID: runID)
        self.registeredExpectedAgentPID = nil
        if config.enableDebugLogging {
            print("[ClaudeNativeSession] Cleared expected MCP parent PID for \(clientName) runID=\(runID.uuidString)")
        }
    }

    private func failProtocolAndShutdownSoon(message: String) {
        Task { await self.failProtocolAndShutdown(message: message) }
    }

    private func failProtocolAndShutdown(message: String) async {
        guard !isShuttingDown else { return }
        #if DEBUG
            if let testProtocolFailureInterceptor {
                testProtocolFailureInterceptor(message)
                return
            }
        #endif
        writeRawEventLogRecord(kind: "session.failProtocol", payload: ["message": message])
        emit(.error(message))
        let staleIDs = drainAllTurnIDs()
        if !staleIDs.isEmpty {
            for id in staleIDs {
                emitTurnCompleted(turnID: id, status: .failed, origin: .controllerSynthesized)
            }
        }
        await shutdown()
    }

    private func resolvedLaunchEnvironment(
        resolverOverrides: [String: String],
        resolverRemovedKeys: Set<String>
    ) async -> [String: String] {
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .claudeNative,
                additionalRemovedKeys: ["NODE_OPTIONS"],
                enableDebugLogging: config.enableDebugLogging
            )
        )
        return effectiveLaunchEnvironment(
            base: result.environment,
            resolverOverrides: resolverOverrides,
            resolverRemovedKeys: resolverRemovedKeys
        )
    }

    private func effectiveLaunchEnvironment(
        base: [String: String],
        resolverOverrides: [String: String],
        resolverRemovedKeys: Set<String> = []
    ) -> [String: String] {
        var env = base
        if env["CLAUDE_CODE_ENTRYPOINT"].map({ !$0.isEmpty }) != true {
            env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"
        }
        // Disable claude.ai web connector MCP servers unconditionally unless a Claude-specific override says otherwise.
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        // Disable ToolSearch unless explicitly opted in.
        if !config.toolSearchEnabled {
            env["ENABLE_TOOL_SEARCH"] = "false"
        }
        for (key, value) in config.processEnvironmentOverrides {
            env[key] = value
        }
        for (key, value) in resolverOverrides {
            env[key] = value
        }
        // Managed launch boundary: an inherited runtime marker never reaches the child; a
        // registered launch sets its own explicitly at spawn.
        return ProcessEnvironmentSanitizer.sanitizedForChildLaunch(
            env,
            additionalRemovedKeys: Set(["NODE_OPTIONS", ProcessLauncher.runtimeMarkerEnvironmentKey]).union(resolverRemovedKeys)
        )
    }

    private func recordObservedSessionID(_ candidate: String?) {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else {
            return
        }
        let changed = (sessionID != candidate)
        sessionID = candidate
        ensureRawEventLogFileReadyIfNeeded(sessionIDHint: candidate)
        if changed {
            publishRuntimeInitIfChanged()
        }
    }

    private static let rawEventLoggingEnabledKey = "claudeRawEventLoggingEnabled"

    private static func isRawEventFileLoggingEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
            defaults.bool(forKey: rawEventLoggingEnabledKey)
        #else
            false
        #endif
    }

    #if DEBUG
        static func test_isRawEventFileLoggingEnabled(defaults: UserDefaults) -> Bool {
            isRawEventFileLoggingEnabled(defaults: defaults)
        }
    #endif

    private static func normalizedSessionIdentifier(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "unknown-session" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let normalized = String(scalars)
        return normalized.isEmpty ? "unknown-session" : normalized
    }

    private static func makeRawEventLogFileURL(
        workspacePath: String?,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        let overridePath = defaults.string(forKey: rawEventLogFilePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDirectory: URL = {
            if let overridePath, !overridePath.isEmpty {
                let expanded = NSString(string: overridePath).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            return MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent("ClaudeRawEvents", isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = "claude-session-\(sessionID)-\(timestamp).jsonl"
        return baseDirectory.appendingPathComponent(fileName)
    }

    #if DEBUG
        static func test_makeRawEventLogFileURL(
            workspacePath: String?,
            sessionID: String,
            defaults: UserDefaults
        ) -> URL? {
            makeRawEventLogFileURL(workspacePath: workspacePath, sessionID: sessionID, defaults: defaults)
        }
    #endif

    private func ensureRawEventLogFileReadyIfNeeded(sessionIDHint: String?) {
        guard rawEventFileLoggingEnabled else { return }
        let effectiveSessionID = Self.normalizedSessionIdentifier(sessionIDHint ?? sessionID ?? tabID.uuidString)
        if rawEventLogFileURL != nil, rawEventLogFileSessionID == effectiveSessionID {
            return
        }
        guard let fileURL = Self.makeRawEventLogFileURL(workspacePath: workspacePath, sessionID: effectiveSessionID) else {
            return
        }
        rawEventLogFileURL = fileURL
        rawEventLogFileSessionID = effectiveSessionID
        hasWrittenRawEventLogHeader = false
        UserDefaults.standard.set(fileURL.path, forKey: Self.lastRawEventLogFilePathKey)
    }

    private func appendRawEventLogRecord(_ record: [String: Any]) {
        guard rawEventFileLoggingEnabled else { return }
        guard let rawEventLogFileURL else { return }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        if !FileManager.default.fileExists(atPath: rawEventLogFileURL.path) {
            _ = FileManager.default.createFile(atPath: rawEventLogFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: rawEventLogFileURL) else { return }
        do {
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    @inline(__always)
    private func writeRawEventLogRecord(kind: String, payload: @autoclosure () -> Any? = nil) {
        #if DEBUG
            guard rawEventFileLoggingEnabled else { return }
            let sessionHint = sessionID ?? rawEventLogFileSessionID
            ensureRawEventLogFileReadyIfNeeded(sessionIDHint: sessionHint)
            guard rawEventLogFileURL != nil else { return }
            let loggedSessionID = sessionID ?? rawEventLogFileSessionID ?? ""
            if !hasWrittenRawEventLogHeader {
                hasWrittenRawEventLogHeader = true
                appendRawEventLogRecord([
                    "kind": "session.header",
                    "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
                    "runID": runID.uuidString,
                    "tabID": tabID.uuidString,
                    "windowID": windowID,
                    "workspacePath": workspacePath ?? "",
                    "sessionID": loggedSessionID
                ])
            }
            var record: [String: Any] = [
                "kind": kind,
                "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
                "runID": runID.uuidString,
                "tabID": tabID.uuidString,
                "windowID": windowID,
                "sessionID": loggedSessionID
            ]
            if let payload = payload() {
                if JSONSerialization.isValidJSONObject(payload) {
                    record["payload"] = payload
                } else {
                    record["payloadDebugDescription"] = String(describing: payload)
                }
            }
            appendRawEventLogRecord(record)
        #endif
    }

    /// Maximum bytes to include verbatim in raw event log records.
    /// Larger payloads are sampled (prefix only) to avoid bloating log files and memory.
    private static let maxLogRecordTextBytes = 64 * 1024 // 64 KB

    private func lineRecordPayload(from data: Data) -> [String: Any] {
        let effectiveData = data.count <= Self.maxLogRecordTextBytes ? data : data.prefix(Self.maxLogRecordTextBytes)
        let truncated = data.count > Self.maxLogRecordTextBytes
        if let text = String(data: effectiveData, encoding: .utf8) {
            var result: [String: Any] = [
                "encoding": "utf8",
                "byteCount": data.count,
                "text": text
            ]
            if truncated { result["truncated"] = true }
            return result
        }
        return [
            "encoding": "base64",
            "byteCount": data.count,
            "base64": effectiveData.base64EncodedString(),
            "truncated": truncated
        ]
    }

    private func streamResultLogPayload(_ result: AIStreamResult) -> [String: Any] {
        var payload: [String: Any] = [
            "type": result.type,
            "text": result.text ?? NSNull(),
            "reasoning": result.reasoning ?? NSNull(),
            "toolName": result.toolName ?? NSNull(),
            "toolInvocationID": result.toolInvocationID?.uuidString ?? NSNull(),
            "toolIsError": result.toolIsError ?? NSNull(),
            "promptTokens": result.promptTokens ?? NSNull(),
            "completionTokens": result.completionTokens ?? NSNull(),
            "contextUsedTokens": result.contextUsedTokens ?? NSNull(),
            "providerSessionID": result.providerSessionID ?? NSNull(),
            "stopReason": result.stopReason ?? NSNull()
        ]
        if let toolArgsJSON = result.toolArgsJSON {
            payload["toolArgsJSON"] = toolArgsJSON
        }
        if let toolResultJSON = result.toolResultJSON {
            payload["toolResultJSON"] = toolResultJSON
        }
        return payload
    }

    private func makeControlRequestID() -> String {
        let value = nextControlRequestID
        nextControlRequestID += 1
        return "rp-claude-\(value)"
    }

    @discardableResult
    private func beginTurnTracking(outboundUserMessageUUID: UUID? = nil) -> UUID {
        let id = UUID()
        pendingTurnIDBuffer.append(id)
        if let outboundUserMessageUUID {
            outboundUserMessageUUIDByTurnID[id] = outboundUserMessageUUID
        }
        return id
    }

    // MARK: - Pending turn ID deque helpers

    /// O(1) check whether the FIFO queue has entries.
    private var hasPendingTurnIDs: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    /// O(1) dequeue from the front.  Compacts the buffer when half is consumed.
    private func dequeueTurnID() -> UUID {
        let id = pendingTurnIDBuffer[pendingTurnIDHead]
        pendingTurnIDHead += 1
        outboundUserMessageUUIDByTurnID.removeValue(forKey: id)
        compactTurnIDBufferIfNeeded()
        startedTurnIDSnapshot.withLock { started in
            if started == id { started = nil }
        }
        return id
    }

    /// O49: the producing turn is the first queued turn whose `result` has not arrived (in deferred
    /// mode, turns with a result awaiting `idle` are still queued ahead of it). No queued turn: the
    /// output is attributed to nothing.
    private func noteOutputAttributedToProducingTurn() {
        let index = pendingTurnIDHead + pendingAuthoritativeTurnCompletions.count
        guard index < pendingTurnIDBuffer.count else { return }
        let id = pendingTurnIDBuffer[index]
        startedTurnIDSnapshot.withLock { $0 = id }
    }

    /// Drain all remaining IDs and reset.
    private func drainAllTurnIDs() -> [UUID] {
        guard hasPendingTurnIDs else { return [] }
        let remaining = Array(pendingTurnIDBuffer[pendingTurnIDHead...])
        clearTurnIDQueue()
        return remaining
    }

    /// Reset the queue to empty.
    private func clearTurnIDQueue() {
        pendingTurnIDBuffer.removeAll(keepingCapacity: false)
        pendingTurnIDHead = 0
        outboundUserMessageUUIDByTurnID.removeAll()
        startedTurnIDSnapshot.withLock { $0 = nil }
    }

    private func compactTurnIDBufferIfNeeded() {
        // Compact when more than half is consumed and at least 4 slots are wasted.
        if pendingTurnIDHead > 4, pendingTurnIDHead >= pendingTurnIDBuffer.count / 2 {
            pendingTurnIDBuffer.removeFirst(pendingTurnIDHead)
            pendingTurnIDHead = 0
        }
    }

    private func emit(_ event: Event) {
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled,
               case let .stream(result) = event,
               result.type == "reasoning"
            {
                let text = result.reasoning ?? result.text ?? ""
                reasoningDebug("yield event=.stream(reasoning) len=\(text.count) continuationPresent=\(eventsContinuation != nil)")
            }
        #endif
        eventsContinuation?.yield(event)
    }
}
