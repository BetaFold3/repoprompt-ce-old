import Foundation
import MCP
import RepoPromptAgentCore
import RepoPromptShared
import RepoPromptWorkspace

struct OracleExportFile: Equatable {
    let path: String
    let instruction: String
}

struct OracleExportDestination: Equatable, @unchecked Sendable {
    let workspaceID: UUID
    let windowID: Int
    let tabID: UUID?
    /// Logical/canonical primary root returned to the bound child.
    let primaryRootPath: String
    /// Frozen logical-to-physical scope used for disk I/O and read-back verification.
    let lookupContext: WorkspaceLookupContext

    init(
        workspaceID: UUID,
        windowID: Int,
        tabID: UUID?,
        primaryRootPath: String,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) {
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.tabID = tabID
        self.primaryRootPath = primaryRootPath
        self.lookupContext = lookupContext
    }
}

struct OracleExportRequest {
    let sourceTool: String
    let mode: String
    let message: String
    let chatID: String?
    let response: String?
    let destination: OracleExportDestination?

    init(
        sourceTool: String,
        mode: String,
        message: String,
        chatID: String?,
        response: String?,
        destination: OracleExportDestination? = nil
    ) {
        self.sourceTool = sourceTool
        self.mode = mode
        self.message = message
        self.chatID = chatID
        self.response = response
        self.destination = destination
    }
}

enum AgentOracleExport {
    static func instruction(path: String) -> String {
        let pathLiteral = jsonStringLiteral(path)
        return """
        Read the Oracle export with `read_file` using `{"path": \(pathLiteral)}`. Use this exact absolute `path` value verbatim without shortening or rewriting it, and use the file as planning context for this task.
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return literal
    }

    static func oracleMarkdown(request: OracleExportRequest, exportedAt _: Date = Date()) -> String {
        let title = switch request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plan":
            "# Oracle Plan"
        case "review":
            "# Oracle Review"
        default:
            "# Oracle Response"
        }
        let response: String = if let responseText = request.response,
                                  !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            responseText
        } else {
            "_No response text was returned._"
        }
        return "\(title)\n\n\(response)"
    }
}

struct AgentRunWaitScopeCompletion: Equatable {
    enum Reason: String, Equatable {
        case snapshotReady = "snapshot_ready"
        case timedOut = "timed_out"
        case startupPending = "startup_pending"
        case statusUpdate = "status_update"
        case delegatedQuestionPending = "delegated_question_pending"
        case expired
        case superseded
        case cancelled
        case error
    }

    let reason: Reason
    let result: String?
    let winnerSessionID: UUID?
    let pendingSessionIDs: Set<UUID>
    let errorDescription: String?
}

private enum MultiWaitDisposition {
    case actionable(AgentRunMCPSnapshot)
    case steeringInterrupted(AgentRunMCPSnapshot)
    case delegatedQuestionInterrupted(AgentRunMCPSnapshot)
    case superseded(AgentRunMCPSnapshot)
    case statusUpdate(AgentRunMCPSnapshot)
    case terminalPublicationRejected(String)
    case timedOut
    case expired
    case cancelled
}

private struct WaitAnyResult {
    let sessionID: UUID
    let disposition: MultiWaitDisposition
}

private struct SteerControlIdentity {
    let sessionID: UUID
    let activationID: UUID
    let registration: AgentRunSessionStore.Registration
}

private struct SteerControlResolution {
    let session: AgentTabSession
    let reactivatedTarget: AgentModeViewModel.MCPSessionTarget?
    let reactivatedControlIdentity: SteerControlIdentity?
}

private struct TimestampedWaitAnyResult {
    let result: WaitAnyResult
    let completedAt: ContinuousClock.Instant
}

private struct CancelledSingleWaitResolution {
    let rawValue: Value
    let completion: AgentRunWaitScopeCompletion
}

private final class WaitScopeCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletion: AgentRunWaitScopeCompletion?

    func set(_ completion: AgentRunWaitScopeCompletion) {
        lock.lock()
        storedCompletion = completion
        lock.unlock()
    }

    func get() -> AgentRunWaitScopeCompletion? {
        lock.lock()
        let completion = storedCompletion
        lock.unlock()
        return completion
    }
}

private let agentRunDelegatedQuestionWakeNote = "Woken early: another child agent is waiting for your answer; see delegated_question_notices."
private let agentRunSteeringWakeNote = "Steering interrupted this wait; the agent run has not completed. After responding to the user, call agent_run.wait for this session again to resume waiting."
private let agentRunExpiredHandleRecoveryNote = [
    "This run/control/wait handle has expired.",
    "If the session still exists in the active workspace, you can usually continue it with `agent_run` using `op: \"steer\"`,",
    "the same `session_id`, and a new `message`.",
    "Use `op: \"start\"` only when you want a new session."
].joined(separator: " ")

@MainActor
struct AgentRunMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias HeartbeatOperation = @Sendable () async throws -> Value
    typealias StartRun = @MainActor (
        _ target: AgentModeViewModel.MCPSessionTarget,
        _ message: String,
        _ metadata: RequestMetadata,
        _ bindCurrentRequestToTab: @escaping AgentExternalMCPRunStarter.BindCurrentRequestToTab,
        _ agentModeVM: AgentModeViewModel,
        _ agentRaw: String?,
        _ modelRaw: String?,
        _ reasoningEffortRaw: String?,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ roleOhMyPiThinkingSelections: OhMyPiThinkingSelections,
        _ workflow: AgentWorkflowDefinition?,
        _ expectedParentSessionID: UUID?,
        _ oracleReviewSource: AgentRunOracleReviewSource?
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome
    typealias ResolveOracleReviewLaunchSource = @MainActor (
        _ metadata: RequestMetadata,
        _ targetWindow: WindowState
    ) async throws -> ResolvedAgentRunOracleReviewLaunchSource

    /// Compatibility alias for the unresolved-parent automatic wait, retained for existing test and
    /// downstream source compatibility only. No lifecycle path reads it: start, wait, multi-wait and
    /// steer-with-wait resolve the frozen parent family through `AgentMCPWaitPolicy`.
    static let defaultWaitTimeoutSeconds = MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
    static let defaultStartTaskLabelKind: AgentModelCatalog.TaskLabelKind = .pair
    nonisolated static let statusUpdateSliceSeconds: TimeInterval = 2
    /// Sampling interval for waits on live sessions that have no MCP control registration
    /// (desktop roots observed through the phone app link). They have no wait cursor, so the
    /// session store cannot signal a change; the wait samples the truthful live snapshot instead.
    nonisolated static let liveUnregisteredWaitPollSeconds: TimeInterval = 1
    #if DEBUG
        static let ompQualificationAuthorizationCleanupDeadlineNanoseconds: UInt64 = 5_000_000_000
        static let ompQualificationAuthorizationMinimumSeconds: TimeInterval = 5
        static let ompQualificationAuthorizationMaximumSeconds: TimeInterval = 30
        nonisolated(unsafe) static var ompQualificationAuthorizationDeadlineNanosecondsOverride: UInt64?

        static func ompQualificationAuthorizationDeadlineNanoseconds(
            requestTimeoutSeconds: TimeInterval
        ) -> UInt64 {
            if let override = ompQualificationAuthorizationDeadlineNanosecondsOverride {
                return max(1, override)
            }
            let clamped = min(
                max(requestTimeoutSeconds, ompQualificationAuthorizationMinimumSeconds),
                ompQualificationAuthorizationMaximumSeconds
            )
            return UInt64(clamped * 1_000_000_000)
        }

        /// Arithmetic only: the caller supplies `now` from the start's single authorization clock.
        static func ompQualificationAuthorizationRemainingNanoseconds(
            deadlineUptimeNanoseconds: UInt64?,
            nowUptimeNanoseconds: UInt64
        ) -> UInt64 {
            guard let deadlineUptimeNanoseconds else {
                return ompQualificationAuthorizationCleanupDeadlineNanoseconds
            }
            return deadlineUptimeNanoseconds > nowUptimeNanoseconds
                ? deadlineUptimeNanoseconds - nowUptimeNanoseconds
                : 0
        }

        /// Process-global DEBUG seams for fast, deterministic status-update tests; reset in tearDown.
        /// Safe under serial XCTest execution only — would race if wait suites ever
        /// run parallel in-process.
        nonisolated(unsafe) static var statusUpdateSliceSecondsOverride: TimeInterval?
        nonisolated(unsafe) static var waitClockNowOverride: (@Sendable () -> ContinuousClock.Instant)?
        nonisolated(unsafe) static var liveUnregisteredWaitPollSecondsOverride: TimeInterval?
    #endif

    nonisolated static func normalizedStatusTextKey(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func shouldReturnStatusUpdate(
        baselineKey: String?,
        latest: AgentRunMCPSnapshot?
    ) -> Bool {
        guard let latest, latest.status == .running,
              let latestKey = normalizedStatusTextKey(latest.statusText)
        else {
            return false
        }
        return latestKey != baselineKey
    }

    private nonisolated static var resolvedStatusUpdateSliceSeconds: TimeInterval {
        #if DEBUG
            if let override = statusUpdateSliceSecondsOverride {
                return max(0.001, override)
            }
        #endif
        return statusUpdateSliceSeconds
    }

    private nonisolated static var resolvedLiveUnregisteredWaitPollSeconds: TimeInterval {
        #if DEBUG
            if let override = liveUnregisteredWaitPollSecondsOverride {
                return max(0.001, override)
            }
        #endif
        return liveUnregisteredWaitPollSeconds
    }

    private nonisolated static func resolvedWaitClockNow(_ clock: ContinuousClock) -> ContinuousClock.Instant {
        #if DEBUG
            if let override = waitClockNowOverride {
                return override()
            }
        #endif
        return clock.now
    }

    /// Plan §6.1/§6.4: omission is automatic for the frozen parent family, explicit `0` is a poll,
    /// and explicit values above the shared maximum are rejected without clamping.
    static func resolvedStartWaitSelection(
        _ value: Value?,
        parentFamily: AgentMCPWaitPolicy.ParentFamily,
        promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention
    ) throws -> AgentMCPWaitPolicy.Selection {
        try AgentMCPWaitPolicy.selection(
            rawTimeout: value,
            parentFamily: parentFamily,
            promptCacheRetention: promptCacheRetention
        )
    }

    static func resolvedWaitSelection(
        _ value: Value?,
        parentFamily: AgentMCPWaitPolicy.ParentFamily,
        promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention
    ) throws -> AgentMCPWaitPolicy.Selection {
        try AgentMCPWaitPolicy.selection(
            rawTimeout: value,
            parentFamily: parentFamily,
            promptCacheRetention: promptCacheRetention
        )
    }

    static func resolvedSteerWaitSelection(
        _ value: Value?,
        parentFamily: AgentMCPWaitPolicy.ParentFamily,
        promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention
    ) throws -> AgentMCPWaitPolicy.Selection {
        try AgentMCPWaitPolicy.selection(
            rawTimeout: value,
            parentFamily: parentFamily,
            promptCacheRetention: promptCacheRetention
        )
    }

    private nonisolated static func agentRunExpiredSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot.expired(
            sessionID: sessionID,
            statusText: agentRunExpiredHandleRecoveryNote
        )
    }

    static func defaultTaskLabelForStart(
        resolvedTabID: UUID?,
        workflow _: AgentWorkflowDefinition? = nil
    ) -> AgentModelCatalog.TaskLabelKind? {
        // `agent_run.start` creates a new session by default; when callers omit
        // `model_id`, resolve through the global Pair role default. Workflows do
        // not override that default. If a caller explicitly targets an existing
        // tab, leave that tab's current selection alone.
        resolvedTabID == nil ? defaultStartTaskLabelKind : nil
    }

    let toolName: String
    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveRequestedTabID: (_ args: [String: Value]) throws -> UUID?
    let resolveSpawnParentSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
    var resolveOracleReviewLaunchSource: ResolveOracleReviewLaunchSource = { _, _ in
        throw MCPError.internalError("agent_run.start Oracle launch-source resolution is not configured.")
    }

    var validateSpawnRouting: (_ metadata: RequestMetadata, _ sourceTabID: UUID?, _ operation: String) async throws -> Void = { _, _, _ in }
    let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
    var resolveSpawnParentSessionIDFromSourceTabID: ((_ sourceTabID: UUID, _ targetWindow: WindowState) async -> UUID?)?
    let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping HeartbeatOperation) async throws -> Value
    var beginAgentRunWait: (_ metadata: RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil }
    var endAgentRunWait: (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in }
    var hasDeliverableDelegatedQuestionNotices: @MainActor @Sendable (_ waitToken: UUID, _ childSessionIDs: Set<UUID>) -> Bool = { _, _ in false }
    /// Plan §6.3: freezes the effective parent family for one lifecycle call from the authenticated
    /// run binding. The default treats the parent as unresolved; the server view model injects the
    /// authoritative resolver. Invoked once at the outer entry, before any mutation or delegation.
    var resolveWaitPolicyContext: (_ metadata: RequestMetadata) async -> AgentMCPWaitPolicy.RequestContext = {
        AgentMCPWaitPolicy.RequestContext.unresolved(metadata: $0)
    }

    /// Session profile of the calling connection's enforced tool policy. The default treats the
    /// caller as standard; the server view model injects the connection manager's value. A
    /// Knowledge caller is also recognized from its live routed source session.
    var resolveConnectionSessionProfile: (_ metadata: RequestMetadata) async -> AgentSessionProfile = { _ in .standard }
    /// K5 web gate input: whether Codex's built-in Search tool is enabled. Injectable so tests never
    /// read or write real settings.
    var codexWebSearchEnabled: @MainActor () -> Bool = { CodexAgentToolPreferences.searchToolEnabled() }

    let startRun: StartRun
    var currentSnapshotProvider: (@Sendable (_ sessionID: UUID, _ agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot?)?
    #if DEBUG
        /// Monotonic uptime read for OMP qualification authorization admission and accounting only:
        /// deadline arming, every remaining-budget calculation, and the start receipt. Configure
        /// before `execute`; each start snapshots it once. Lease expiry and real waits keep real time.
        var ompQualificationMonotonicNowNanoseconds: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }

        var testAgentModeViewModel: AgentModeViewModel?
        var testAfterOMPQualificationInitialSnapshot: (() async -> Void)?
        var testBeforeOMPQualificationConsume: (() async -> Void)?
        var testBeforeExplicitTabWorktreeValidation: (() -> Void)?
        var testWorktreePreparationFailure: Error?
        var testBeforeWorktreePreparationFailureCleanup: ((AgentTabSession) async -> Void)?
        var testBeforeOMPQualificationProviderDispatch: (() async -> Void)?
        var testBeforeOMPQualificationContextIdentityCheck: ((
            OhMyPiAgentModeSmokeGate.StartContext,
            AgentTabSession
        ) async -> Void)?
        var testAfterOMPQualificationPreDispatchIdentityCheck: (() async -> Void)?
        var testBeforeOMPQualificationTargetDiscardCAS: ((AgentTabSession?) async -> Void)?
        var testBeforeProviderAvailabilityPreflight: (() -> Void)?
        var testBeforeProviderDispatch: (() async -> Void)?
        var testAfterProviderStartBeforeBookkeeping: (() async -> Void)?
        var testOMPQualificationTerminalCategory: ((String) -> Void)?
        /// Observes a consumed qualification start at rollback-cleanup entry, before any
        /// remaining-time or authorization wait computation. The terminal-category hook runs only
        /// after rollback and target discard, so it cannot show whether the first deadline had
        /// already resolved the receipt before cleanup began.
        var testBeforeOMPQualificationRollbackCleanup: ((OhMyPiAgentModeSmokeGate.StartContext?) -> Void)?
        var testOMPQualificationOwnerVerifier: ((
            _ connectionID: UUID,
            _ ownerProcessID: Int32,
            _ ownerStartSeconds: Int64,
            _ ownerStartMicroseconds: Int32
        ) async -> Bool)?
        var testDispatchSteerInstruction: ((
            _ sessionID: UUID,
            _ text: String,
            _ workflow: AgentWorkflowDefinition?,
            _ agentModeVM: AgentModeViewModel
        ) async throws -> AgentModeViewModel.MCPInstructionDispatch)?
        /// Replaces the remote attention-root send (`remoteRootDispatchInstruction`) only; gating,
        /// targeting, and snapshot projection still run.
        var testDispatchRemoteRootInstruction: ((
            _ sessionID: UUID,
            _ text: String,
            _ workflow: AgentWorkflowDefinition?,
            _ agentModeVM: AgentModeViewModel
        ) async throws -> AgentModeViewModel.MCPInstructionDispatch)?
        /// Runs at the `request_id` registry lookup's suspension point, after the lookup returned and
        /// before its decision is acted on.
        var testDuringIdempotencyLookup: (() async -> Void)?
    #endif
    var vcsService: VCSService = .shared
    var gitTargetResolver: GitRepoTargetResolver = .init()
    /// App-side request_id idempotency (plan §6.1). Injectable for tests.
    var idempotencyRegistry: MCPRequestIdempotencyRegistry = .shared

    private var startWorktreeCoordinator: AgentMCPStartWorktreeCoordinator {
        AgentMCPStartWorktreeCoordinator(
            operationName: "agent_run.start",
            vcsService: vcsService,
            gitTargetResolver: gitTargetResolver
        )
    }

    func execute(args: [String: Value]) async throws -> Value {
        let op = normalizedString(args["op"])?.lowercased() ?? "wait"
        #if DEBUG
            if op != "start", args["_worktree_startup_benchmark_token"] != nil {
                throw MCPError.invalidParams("The worktree startup benchmark token is only supported with agent_run op=start.")
            }
            if op != "start", args["_omp_qualification_lease_id"] != nil {
                throw MCPError.invalidParams("The OMP qualification lease parameter is only supported with agent_run op=start.")
            }
            if op != "start", args["_omp_qualification_apply_edits_review"] != nil {
                throw MCPError.invalidParams("The OMP qualification apply_edits review parameter is only supported with agent_run op=start.")
            }
        #endif
        if op != "start", startWorktreeCoordinator.containsArguments(args) {
            throw MCPError.invalidParams("agent_run worktree arguments are only supported with op=start.")
        }
        let knowledgeCaller = try await admitKnowledgeCaller(op: op, args: args)
        switch op {
        case "start", "steer", "respond":
            if let requestID = normalizedString(args["request_id"]) {
                return try await executeIdempotentMutation(
                    op: op,
                    requestID: requestID,
                    args: args,
                    knowledgeCaller: knowledgeCaller
                )
            }
            return try await executeMutationCore(op: op, args: args, knowledgeCaller: knowledgeCaller)
        case "poll":
            return try await executeWait(args: args, forcePoll: true, knowledgeCaller: knowledgeCaller)
        case "wait":
            return try await executeWait(args: args, knowledgeCaller: knowledgeCaller)
        case "cancel":
            return try await executeCancel(args: args, knowledgeCaller: knowledgeCaller)
        default:
            throw MCPError.invalidParams("Unsupported agent_run op '\(op)'. Use start, poll, wait, cancel, steer, or respond.")
        }
    }

    private func executeMutationCore(
        op: String,
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        switch op {
        case "start":
            return try await executeStart(args: args, knowledgeCaller: knowledgeCaller)
        case "steer":
            return try await executeSteer(args: args, knowledgeCaller: knowledgeCaller)
        case "respond":
            return try await executeRespond(args: args, knowledgeCaller: knowledgeCaller)
        default:
            throw MCPError.invalidParams("Unsupported agent_run mutating op '\(op)'.")
        }
    }

    /// Optional app-side idempotency (plan §6.1): a `request_id` on start/steer/
    /// respond makes duplicate calls return the recorded outcome instead of
    /// re-executing. `mcpResolvePendingInteraction` fencing is untouched — a
    /// duplicate respond is absorbed here before it can reach the view model.
    private func executeIdempotentMutation(
        op: String,
        requestID: String,
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller?
    ) async throws -> Value {
        let metadata = await captureRequestMetadata()
        let clientID = MCPClientIdentity.storageKey(metadata.clientName)
            ?? metadata.connectionID?.uuidString
            ?? "unknown-client"
        // KW-02: authorize the frozen Knowledge caller (and its own-child target) before this
        // request_id is looked up; nil for every other caller.
        let knowledgeAuthorization = try await authorizeKnowledgeIdempotentRequest(
            op: op,
            args: args,
            knowledgeCaller: knowledgeCaller
        )
        let key = MCPRequestIdempotencyRegistry.Key(
            clientID: Self.idempotencyClientID(clientID, knowledgeCaller: knowledgeCaller),
            requestID: requestID
        )
        let fingerprint = MCPRequestIdempotencyRegistry.Fingerprint(
            operation: op,
            payloadHashSHA256: MCPRequestIdempotencyRegistry.payloadHashHex(
                args: args,
                excluding: ["request_id", "response_mode"]
            )
        )
        let decision = await idempotencyRegistry.begin(key: key, fingerprint: fingerprint)
        #if DEBUG
            await testDuringIdempotencyLookup?()
        #endif
        // KW-02: the lookup suspended since authorization. Every branch that discloses a recorded
        // outcome, an in-flight marker, or a conflict first re-checks the frozen Knowledge caller and
        // target synchronously, with no suspension before the disclosure. A new request is left to
        // the operation's own admission and boundary rechecks, which record any failure.
        switch decision {
        case .new:
            break
        case let .duplicate(outcome):
            try revalidateKnowledgeIdempotentRequest(knowledgeAuthorization)
            switch outcome {
            case let .success(value):
                return Self.idempotentReplayValue(value, requestID: requestID)
            case let .failure(code, message):
                throw MCPError.invalidParams(
                    "request_id '\(requestID)' already failed (\(code)): \(message)"
                )
            }
        case .inFlight:
            try revalidateKnowledgeIdempotentRequest(knowledgeAuthorization)
            throw MCPError.invalidParams(
                "request_id '\(requestID)' is still in flight; poll for state instead of retrying."
            )
        case let .conflict(existing):
            try revalidateKnowledgeIdempotentRequest(knowledgeAuthorization)
            throw MCPError.invalidParams(
                "request_id_conflict: request_id '\(requestID)' was already used for a different \(existing.operation) payload."
            )
        }
        do {
            let value = try await executeMutationCore(op: op, args: args, knowledgeCaller: knowledgeCaller)
            await idempotencyRegistry.complete(key: key, outcome: .success(value))
            return value
        } catch {
            let code = if error is CancellationError {
                "cancelled"
            } else if case MCPError.invalidParams = error {
                "invalid_params"
            } else {
                "internal_error"
            }
            await idempotencyRegistry.complete(key: key, outcome: .failure(
                code: code,
                message: String(describing: error)
            ))
            throw error
        }
    }

    /// KW-02: a Knowledge caller's request_ids live in a namespace keyed by its admitted durable
    /// identity, so they never replay another session's outcome (a standard session's or another
    /// Knowledge root's), and identical requests from separate roots never collapse into one
    /// worker. Standard client keys are lowercased (`MCPClientIdentity.storageKey`), a bare
    /// connection UUID (hex digits and dashes), or `unknown-client`, so the prefix cannot collide
    /// with them. External and standard callers keep their existing key.
    static func idempotencyClientID(_ clientID: String, knowledgeCaller: KnowledgeCaller?) -> String {
        guard let knowledgeCaller else { return clientID }
        return "KNOWLEDGE-CALLER:\(knowledgeCaller.admittedCallerSessionID.uuidString)|\(clientID)"
    }

    /// Frozen authorization of one Knowledge `request_id`: the caller and the target resolved for it.
    private struct KnowledgeIdempotencyAuthorization {
        let op: String
        let knowledgeCaller: KnowledgeCaller
        let targetSessionID: UUID?
        let agentModeVM: AgentModeViewModel
    }

    /// KW-02: before a Knowledge request_id is looked up, the frozen caller must still hold its tab
    /// as a hydrated, eligible Knowledge root and, for steer and respond, the target must still be
    /// its own Knowledge research worker. Returns nil for every other caller.
    private func authorizeKnowledgeIdempotentRequest(
        op: String,
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller?
    ) async throws -> KnowledgeIdempotencyAuthorization? {
        guard let knowledgeCaller else { return nil }
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let targetSessionID: UUID? = if op == "start" {
            nil
        } else {
            try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        }
        let authorization = KnowledgeIdempotencyAuthorization(
            op: op,
            knowledgeCaller: knowledgeCaller,
            targetSessionID: targetSessionID,
            agentModeVM: agentModeVM
        )
        try revalidateKnowledgeIdempotentRequest(authorization)
        return authorization
    }

    /// Synchronous re-check of a frozen Knowledge `request_id` authorization: the caller's identity,
    /// hydrated Knowledge profile, and eligibility, and its own-child target. No-op for other callers.
    private func revalidateKnowledgeIdempotentRequest(_ authorization: KnowledgeIdempotencyAuthorization?) throws {
        guard let authorization else { return }
        try authorization.agentModeVM.mcpRevalidateDelegationCommit(
            sourceTabID: authorization.knowledgeCaller.sourceTabID,
            expectedCallerSessionID: authorization.knowledgeCaller.admittedCallerSessionID,
            targetSessionID: authorization.targetSessionID,
            operation: "agent_run.\(authorization.op)",
            expectedCallerProfile: .knowledge
        )
    }

    private nonisolated static func idempotentReplayValue(_ value: Value, requestID: String) -> Value {
        guard var object = value.objectValue else { return value }
        var meta = object["_meta"]?.objectValue ?? [:]
        meta["request_id_replay"] = .bool(true)
        meta["request_id"] = .string(requestID)
        object["_meta"] = .object(meta)
        return .object(object)
    }

    #if DEBUG
        private static func cancelQualificationRun(
            _ receipt: OhMyPiAgentModeSmokeGate.AuthorizedRunReceipt,
            targetTabID: UUID,
            agentModeVM: AgentModeViewModel
        ) async {
            guard let session = agentModeVM.session(for: targetTabID, createIfNeeded: false),
                  session.runID == receipt.runID
            else { return }
            let exactTarget = AgentRunCancelTarget(
                tabID: targetTabID,
                expectedRunID: receipt.runID,
                expectedActiveAgentSessionID: receipt.activeAgentSessionID,
                expectedRunAttemptID: receipt.runAttemptID,
                expectedPendingUserInputRequestID: nil
            )
            _ = await agentModeVM.cancelAgentRun(
                target: exactTarget,
                cause: .ordinary,
                completion: .terminalPublished
            )
        }
    #endif

    private func executeStart(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let metadata = await captureRequestMetadata()
        #if DEBUG
            var ompQualificationLease: OhMyPiAgentModeSmokeGate.Snapshot?
            var ompQualificationRollbackSnapshot: OhMyPiAgentModeSmokeGate.Snapshot?
            var ompQualificationStartTransaction: OhMyPiAgentModeSmokeGate.StartTransaction?
            var ompQualificationStartContext: OhMyPiAgentModeSmokeGate.StartContext?
            var ompQualificationInvocationContext: OhMyPiAgentModeSmokeGate.StartContext?
            var ompQualificationProviderDispatchStarted = false
            var ompQualificationTransactionSucceeded = false
            var ompQualificationAuthorizationDeadlineUptimeNanoseconds: UInt64?
            let ompQualificationNow = ompQualificationMonotonicNowNanoseconds
            let ompQualificationApplyEditsReviewRequested: Bool
            if let rawReviewRequest = args["_omp_qualification_apply_edits_review"] {
                guard rawReviewRequest.boolValue == true else {
                    throw MCPError.invalidParams("_omp_qualification_apply_edits_review must be true when present.")
                }
                ompQualificationApplyEditsReviewRequested = true
            } else {
                ompQualificationApplyEditsReviewRequested = false
            }
            if let suppliedLeaseID = args["_omp_qualification_lease_id"] {
                let rawLeaseID = suppliedLeaseID.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let rawLeaseID,
                      !rawLeaseID.isEmpty,
                      let leaseID = UUID(uuidString: rawLeaseID)
                else {
                    throw MCPError.invalidParams(
                        "The dedicated DEBUG OMP qualification lease parameter must be a nonblank UUID string."
                    )
                }
                let activeLease = OhMyPiAgentModeSmokeGate.shared.activeSnapshot()
                guard let activeLease,
                      activeLease.leaseID == leaseID,
                      let connectionID = metadata.connectionID
                else {
                    throw MCPError.invalidParams(
                        "The dedicated DEBUG OMP qualification lease parameter was invalid or its controller ownership could not be verified."
                    )
                }
                let ownerVerified: Bool = if let testOMPQualificationOwnerVerifier {
                    await testOMPQualificationOwnerVerifier(
                        connectionID,
                        activeLease.ownerProcessID,
                        activeLease.ownerProcessStartSeconds,
                        activeLease.ownerProcessStartMicroseconds
                    )
                } else {
                    await ServerNetworkManager.shared.debugQualificationOwnerIsAncestor(
                        connectionID: connectionID,
                        ownerProcessID: activeLease.ownerProcessID,
                        ownerStartSeconds: activeLease.ownerProcessStartSeconds,
                        ownerStartMicroseconds: activeLease.ownerProcessStartMicroseconds
                    )
                }
                guard ownerVerified else {
                    throw MCPError.invalidParams(
                        "The dedicated DEBUG OMP qualification lease parameter was invalid or its controller ownership could not be verified."
                    )
                }
                guard activeLease.sessionID == nil, activeLease.runID == nil else {
                    throw MCPError.invalidParams(
                        "The OMP qualification lease was already consumed by an earlier start."
                    )
                }
                ompQualificationLease = activeLease
                ompQualificationRollbackSnapshot = activeLease
                await testAfterOMPQualificationInitialSnapshot?()
            } else if ompQualificationApplyEditsReviewRequested {
                throw MCPError.invalidParams(
                    "Fresh OMP qualification starts require _omp_qualification_lease_id."
                )
            }
            // Rollback ownership begins only after the bound-lease guard above; hoisting this
            // defer would let a rejected replay release and cancel the earlier healthy run.
            defer {
                if !ompQualificationTransactionSucceeded {
                    if let ompQualificationStartTransaction {
                        _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                            ompQualificationStartTransaction
                        )
                    } else if let ompQualificationRollbackSnapshot {
                        _ = OhMyPiAgentModeSmokeGate.shared.rollbackStartTransaction(
                            ifCurrent: ompQualificationRollbackSnapshot
                        )
                    }
                }
            }
            let rollbackConsumedQualificationStart: (AgentModeViewModel, UUID, Bool) async -> Void = { agentModeVM, targetTabID, clearSessionContext in
                guard let transaction = ompQualificationStartTransaction else { return }
                ompQualificationStartTransaction = nil
                ompQualificationRollbackSnapshot = nil
                let context = ompQualificationStartContext
                ompQualificationStartContext = nil
                let dispatchStarted = ompQualificationProviderDispatchStarted
                let cleanup: @MainActor () async -> Void = {
                    testBeforeOMPQualificationRollbackCleanup?(context)
                    let authorizationOutcome: OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome?
                    if !dispatchStarted {
                        authorizationOutcome = context?.authorizationReceipt.resolve(.denied)
                    } else {
                        let remainingNanoseconds = Self.ompQualificationAuthorizationRemainingNanoseconds(
                            deadlineUptimeNanoseconds: ompQualificationAuthorizationDeadlineUptimeNanoseconds,
                            nowUptimeNanoseconds: ompQualificationNow()
                        )
                        let observedOutcome: OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome? = if let context,
                                                                                                              remainingNanoseconds > 0
                        {
                            await context.authorizationReceipt.wait(timeoutNanoseconds: remainingNanoseconds)
                        } else {
                            nil
                        }
                        // The first absolute deadline owns the outcome. Once it expires, denial
                        // wins immediately; cleanup must not open a second authorization window.
                        authorizationOutcome = context?.authorizationReceipt.resolve(
                            observedOutcome ?? .denied
                        )
                    }
                    let released = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                        transaction,
                        cancelBoundRun: false
                    )
                    if clearSessionContext,
                       let session = agentModeVM.session(for: targetTabID, createIfNeeded: false),
                       session.ompQualificationStartContext === context
                    {
                        session.ompQualificationStartContext = nil
                    }
                    if case let .authorized(receipt) = authorizationOutcome {
                        await Self.cancelQualificationRun(
                            receipt,
                            targetTabID: targetTabID,
                            agentModeVM: agentModeVM
                        )
                    } else if let runID = released?.runID {
                        await Self.cancelQualificationRun(
                            .init(
                                runID: runID,
                                activeAgentSessionID: nil,
                                runAttemptID: nil
                            ),
                            targetTabID: targetTabID,
                            agentModeVM: agentModeVM
                        )
                    }
                }
                if clearSessionContext {
                    let cleanupTask = Task { @MainActor in
                        await cleanup()
                    }
                    await cleanupTask.value
                } else {
                    await cleanup()
                }
            }
        #endif

        let message = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let worktreeStartRequest = try startWorktreeCoordinator.parseRequest(args: args)
        var worktreeStartupCorrelationID = UUID()
        var worktreeStartupFlags = WorktreeStartupFeatureFlags.current()
        var worktreeStartupServingControl = WorktreeStartupServingControl.automatic
        #if DEBUG
            var worktreeStartupBenchmarkToken: UUID?
        #endif
        // start always creates a new session — reject explicit session_id
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("agent_run.start always creates a new session. Use agent_run op=steer with session_id to continue an existing session.")
        }
        let detach = parseBool(args["detach"]) ?? false
        // Plan §6.3/§6.4: freeze the effective parent family and validate the wait selection before
        // any session target is created, bound or dispatched. An invalid explicit timeout therefore
        // never dispatches a mutation. Detached starts still validate the supplied value but report
        // no wait policy.
        let waitContext = await resolveWaitPolicyContext(metadata)
        let waitSelection = try Self.resolvedStartWaitSelection(
            args["timeout"],
            parentFamily: waitContext.parentFamily,
            promptCacheRetention: waitContext.parentPromptCacheRetention
        )
        let timeoutSeconds = waitSelection.timeoutSeconds
        #if DEBUG
            if ompQualificationLease != nil {
                let budget = Self.ompQualificationAuthorizationDeadlineNanoseconds(
                    requestTimeoutSeconds: timeoutSeconds
                )
                let now = ompQualificationNow()
                ompQualificationAuthorizationDeadlineUptimeNanoseconds = now.addingReportingOverflow(budget).overflow
                    ? UInt64.max
                    : now + budget
            }
        #endif

        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_run.start.")
        }
        guard workspace.isSystemWorkspace == false else {
            throw MCPError.invalidParams("Cannot start an agent run from the default system workspace. Open or select a project workspace and try again.")
        }
        // Plan §6.6: explicit workspace selector — validated against the resolved
        // target window's active workspace. A mismatch is a structured failure
        // (no fallback resolution) so remote callers re-target explicitly.
        #if DEBUG
            let requestedWorkspaceUUID: UUID?
        #endif
        if let requestedWorkspaceID = normalizedString(args["workspace_id"]) {
            guard let requestedUUID = UUID(uuidString: requestedWorkspaceID) else {
                throw MCPError.invalidParams("workspace_id must be a workspace UUID.")
            }
            guard workspace.id == requestedUUID else {
                throw MCPError.invalidParams(
                    "workspace_mismatch: the target window's active workspace is '\(workspace.name)' (\(workspace.id.uuidString)), not \(requestedUUID.uuidString). Pass the window_id of a window showing that workspace, or omit workspace_id."
                )
            }
            #if DEBUG
                requestedWorkspaceUUID = requestedUUID
            #endif
        } else {
            #if DEBUG
                requestedWorkspaceUUID = nil
            #endif
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let resolvedTabID = try resolveRequestedTabID(args)
        if knowledgeCaller != nil {
            // K3: a Knowledge start always creates a fresh Knowledge research worker.
            try validateKnowledgeStartArguments(
                args: args,
                resolvedTabID: resolvedTabID,
                workflow: workflow,
                worktreeStartRequest: worktreeStartRequest
            )
        }
        // A Knowledge start never falls back to a role default: an omitted model_id inherits the
        // admitted parent's frozen selection below (K4).
        let defaultTaskLabel = knowledgeCaller == nil
            ? Self.defaultTaskLabelForStart(resolvedTabID: resolvedTabID, workflow: workflow)
            : nil
        #if DEBUG
            testBeforeProviderAvailabilityPreflight?()
        #endif
        let agentAvailability = targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        var resolvedSelection = try AgentMCPSelectionResolver.resolve(
            modelID: normalizedString(args["model_id"]),
            defaultTaskLabel: defaultTaskLabel,
            availability: agentAvailability,
            workspaceID: workspace.id
        )
        var inheritedReasoningEffortRaw: String?
        var resolvedKnowledgeModelSource: String?
        if knowledgeCaller != nil, let explicitAgentRaw = resolvedSelection.agentRaw {
            // K4/K5: an explicit compound model must be Knowledge-supported and web-capable.
            try validateKnowledgeWorkerProvider(agentRaw: explicitAgentRaw)
            resolvedKnowledgeModelSource = "explicit"
        }
        #if DEBUG
            let existingRequestedAgent = resolvedTabID.flatMap {
                agentModeVM.session(for: $0, createIfNeeded: false)?.selectedAgent
            }
            let earlyEffectiveTargetIsOhMyPi = resolvedSelection.agentRaw == AgentProviderKind.ohMyPi.rawValue
                || (resolvedSelection.agentRaw == nil && existingRequestedAgent == .ohMyPi)
            if ompQualificationLease != nil, !earlyEffectiveTargetIsOhMyPi {
                throw MCPError.invalidParams(
                    "_omp_qualification_lease_id may only authorize an effective OMP target."
                )
            }
        #endif
        let parentSourceTabID = await resolveSpawnParentSourceTabID(metadata)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartResolvedSource", tabID: parentSourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "parentSourceTabID": parentSourceTabID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        try await validateSpawnRouting(metadata, parentSourceTabID, "agent_run.start")
        if let knowledgeCaller {
            guard let parentSourceTabID, parentSourceTabID == knowledgeCaller.sourceTabID else {
                throw MCPError.invalidParams(
                    "agent_run.start from a Knowledge session changed routing while it was being admitted. Refusing to create a research worker; retry after the session is active."
                )
            }
            // KW-01: the Knowledge root admitted at the outer gate must still hold the tab as a
            // hydrated, eligible Knowledge session before inner admission runs, so a replacement
            // (or a standard placeholder) in the same tab is never admitted in its place.
            try agentModeVM.mcpRevalidateDelegationCommit(
                sourceTabID: parentSourceTabID,
                expectedCallerSessionID: knowledgeCaller.admittedCallerSessionID,
                operation: "agent_run.start",
                expectedCallerProfile: .knowledge
            )
        }
        let innerAdmittedCallerSessionID = try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: parentSourceTabID)
        if let knowledgeCaller, innerAdmittedCallerSessionID != knowledgeCaller.admittedCallerSessionID {
            throw MCPError.invalidParams(
                "agent_run.start: the calling agent session changed while the request was in flight. Refusing to create a research worker; retry after the session is active."
            )
        }
        // A Knowledge start is always credited to the identity frozen by outer admission.
        let admittedCallerSessionID = knowledgeCaller?.admittedCallerSessionID ?? innerAdmittedCallerSessionID
        let admittedCallerProfile: AgentSessionProfile? = knowledgeCaller == nil ? nil : .knowledge
        let revalidateSpawnDelegation: () throws -> Void = { [weak agentModeVM] in
            guard let agentModeVM else {
                throw MCPError.invalidParams(
                    "agent_run.start: the agent window closed while the request was in flight. Nothing was started."
                )
            }
            try agentModeVM.mcpRevalidateDelegationCommit(
                sourceTabID: parentSourceTabID,
                expectedCallerSessionID: admittedCallerSessionID,
                targetSessionID: resolvedTabID.flatMap { agentModeVM.mcpExistingSessionID(forTabID: $0) },
                operation: "agent_run.start",
                expectedCallerProfile: admittedCallerProfile
            )
        }
        // Step 5b: freeze, synchronously with admission, this call's dispatcher invocation UUID, the
        // admitted parent, its active run attempt, and its recovery lane. Nil (unchanged) for an
        // independent caller or a parent without durable recovery admission.
        let delegatedChildLinkAdmission = try agentModeVM.mcpAdmitDelegatedChildLink(
            sourceTabID: parentSourceTabID,
            admittedCallerSessionID: admittedCallerSessionID,
            invocationID: metadata.toolInvocationID,
            operation: "agent_run.start",
            revalidateDelegation: revalidateSpawnDelegation
        )
        if let knowledgeCaller {
            if resolvedSelection.agentRaw == nil {
                // K4: freeze the admitted parent's live provider, model, and effort synchronously
                // with admission; never fall back to the window default.
                let inherited = try agentModeVM.mcpKnowledgeChildSelectionSnapshot(
                    sourceTabID: knowledgeCaller.sourceTabID,
                    expectedCallerSessionID: knowledgeCaller.admittedCallerSessionID
                )
                try validateKnowledgeWorkerProvider(agentRaw: inherited.agent.rawValue)
                guard AgentModelCatalog.isAgentAvailable(inherited.agent, availability: agentAvailability) else {
                    throw MCPError.invalidParams(
                        "agent_run.start cannot give the research worker this session's provider (\(inherited.agent.displayName)) because it is currently unavailable."
                    )
                }
                resolvedSelection = AgentMCPSelectionResolver.ResolvedSelection(
                    agentRaw: inherited.agent.rawValue,
                    modelRaw: inherited.modelRaw,
                    taskLabelKind: nil,
                    ohMyPiThinkingSelections: .empty
                )
                inheritedReasoningEffortRaw = inherited.reasoningEffortRaw
                resolvedKnowledgeModelSource = "inherited"
            }
        }
        let selection = resolvedSelection
        let selectionReasoningEffortRaw = inheritedReasoningEffortRaw
        let knowledgeWorkerModelSource = resolvedKnowledgeModelSource
        // An explicit tab may already hold a session; a delegated worker must not reactivate a
        // shallower one (including adopting a parentless root) through start.
        try agentModeVM.mcpValidateDelegationTarget(
            sourceTabID: parentSourceTabID,
            targetSessionID: resolvedTabID.flatMap { agentModeVM.mcpExistingSessionID(forTabID: $0) },
            operation: "agent_run.start",
            expectedCallerProfile: admittedCallerProfile
        )
        let spawnParentSessionID: UUID? = if let parentSourceTabID,
                                             let resolveSpawnParentSessionIDFromSourceTabID
        {
            await resolveSpawnParentSessionIDFromSourceTabID(parentSourceTabID, targetWindow)
        } else {
            await resolveSpawnParentSessionID(metadata, targetWindow)
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartParentResolved", tabID: parentSourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "parentSourceTabID": parentSourceTabID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "requestedTabID": resolvedTabID?.uuidString ?? "nil"
            ])
        #endif
        // A non-nil spawn source is only returned for a routed Agent Mode invocation.
        // Never degrade such a nested start into an orphan when its validated
        // parent Agent session has disappeared or cannot be recovered.
        if parentSourceTabID != nil, spawnParentSessionID == nil {
            throw MCPError.invalidParams("agent_run.start was routed from an Agent Mode run, but RepoPrompt could not resolve its parent Agent session. Refusing to create an unparented run; reconnect the agent MCP client or retry after the source session is active.")
        }
        try agentModeVM.mcpRequireAdmittedSpawnParent(
            sourceTabID: parentSourceTabID,
            admittedCallerSessionID: admittedCallerSessionID,
            resolvedParentSessionID: spawnParentSessionID,
            operation: "agent_run.start"
        )

        // Freeze the source before model validation or target creation. Later selection/worktree
        // mutations must not alter the child run's delegated review packaging.
        let oracleLaunchSource = try await resolveOracleReviewLaunchSource(metadata, targetWindow)
        if let parentSourceTabID {
            guard oracleLaunchSource.snapshot.tabID == parentSourceTabID,
                  oracleLaunchSource.source.sourceAgentSessionID == spawnParentSessionID
            else {
                throw MCPError.invalidParams(
                    "agent_run.start conversation-parent routing does not match its immutable Oracle packaging source. Refusing to create the child run."
                )
            }
        }

        #if DEBUG
            if let rawToken = normalizedString(args["_worktree_startup_benchmark_token"]) {
                guard let token = UUID(uuidString: rawToken) else {
                    throw MCPError.invalidParams("Invalid worktree startup benchmark token.")
                }
                do {
                    guard case .create = worktreeStartRequest.mode,
                          worktreeStartRequest.path == nil,
                          !worktreeStartRequest.allowExternalPath
                    else {
                        throw DebugWorktreeStartupBenchmarkError.startIdentityMismatch
                    }
                    let preflight = try WorktreeStartupBenchmarkDiagnostics.shared.preflight(token: token)
                    let scope = preflight.expectedStart.rootIdentity.scope
                    let actualContextID = metadata.tabContextHint?.tabID
                        ?? targetWindow.promptManager.activeComposeTabID
                    guard scope.windowID == targetWindow.windowID,
                          scope.workspaceID == workspace.id,
                          scope.contextID == actualContextID
                    else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
                    worktreeStartupBenchmarkToken = token
                    worktreeStartupCorrelationID = preflight.correlationID
                    worktreeStartupFlags = preflight.flags
                    worktreeStartupServingControl = preflight.servingControl
                } catch let error as DebugWorktreeStartupBenchmarkError {
                    throw MCPError.invalidParams("Worktree startup benchmark token rejected (\(error.code)).")
                }
            }
        #endif

        let sessionName = normalizedString(args["session_name"])
        let effectiveParentWorktreeInheritance = worktreeStartRequest.inheritParentWorktreeBindings
            && !worktreeStartRequest.hasExplicitWorktreeArgs
        let usesRoutedParentSource = parentSourceTabID != nil
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: resolvedTabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: sessionName,
            parentSessionID: spawnParentSessionID,
            inheritWorktreeBindings: usesRoutedParentSource
                ? false
                : effectiveParentWorktreeInheritance,
            delegationCommitCheck: {
                try revalidateSpawnDelegation()
                try agentModeVM.mcpRequireDelegatedChildLinkAdmissionCurrent(delegatedChildLinkAdmission)
            },
            childSessionProfile: knowledgeCaller == nil ? nil : .knowledge
        )
        guard let targetSessionID = target.sessionID else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.internalError("agent_run.start target did not resolve a session ID.")
        }
        #if DEBUG
            let mcpStartInvocationGenerationID = UUID()
            guard agentModeVM.mcpInstallStartInvocationGeneration(
                mcpStartInvocationGenerationID,
                for: target,
                expectedSessionID: targetSessionID
            ) else {
                throw MCPError.invalidParams(
                    "The agent_run.start target is already claimed by an earlier transaction cleanup."
                )
            }
            let discardUnconsumedTargetIfOwned: () async -> Void = {
                _ = await agentModeVM.mcpDiscardSessionTarget(
                    target,
                    ifOwnedByStartGeneration: mcpStartInvocationGenerationID,
                    expectedSessionID: targetSessionID,
                    requireNoRun: true
                )
            }
        #endif
        #if DEBUG
            let existingTargetAgent = agentModeVM.session(
                for: target.tabID,
                createIfNeeded: false
            )?.selectedAgent
            let effectiveTargetIsOhMyPi = selection.agentRaw == AgentProviderKind.ohMyPi.rawValue
                || (selection.agentRaw == nil && existingTargetAgent == .ohMyPi)
            if effectiveTargetIsOhMyPi, ompQualificationLease != nil {
                await testBeforeOMPQualificationConsume?()
                guard let requestedWorkspaceUUID else {
                    await discardUnconsumedTargetIfOwned()
                    throw MCPError.invalidParams(
                        "OMP qualification starts require an explicit workspace_id matching the fingerprinted workspace."
                    )
                }
                guard targetWindow.workspaceManager.activeWorkspace?.id == requestedWorkspaceUUID else {
                    await discardUnconsumedTargetIfOwned()
                    throw MCPError.invalidParams(
                        "workspace_mismatch: the fingerprinted OMP qualification workspace changed before lease consumption."
                    )
                }
                guard let ompQualificationLease,
                      let connectionID = metadata.connectionID
                else {
                    await discardUnconsumedTargetIfOwned()
                    throw MCPError.invalidParams(
                        "The effective OMP target requires _omp_qualification_lease_id, including when model_id is omitted."
                    )
                }
                let consumption: OhMyPiAgentModeSmokeGate.Consumption
                do {
                    consumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                        leaseID: ompQualificationLease.leaseID,
                        ownerConnectionID: connectionID,
                        ownerProcessID: ompQualificationLease.ownerProcessID,
                        sessionID: targetSessionID,
                        qualificationWorkspaceID: requestedWorkspaceUUID,
                        permitsApplyEditsReview: ompQualificationApplyEditsReviewRequested
                    )
                } catch {
                    await discardUnconsumedTargetIfOwned()
                    throw MCPError.invalidParams("The OMP qualification lease was expired, stolen, or already consumed.")
                }
                ompQualificationRollbackSnapshot = consumption.snapshot
                ompQualificationStartTransaction = consumption.transaction
                let context = OhMyPiAgentModeSmokeGate.StartContext(
                    transaction: consumption.transaction,
                    expectedWorkspaceID: requestedWorkspaceUUID,
                    authorizationDeadlineUptimeNanoseconds: ompQualificationAuthorizationDeadlineUptimeNanoseconds,
                    monotonicNowNanoseconds: ompQualificationNow
                )
                ompQualificationStartContext = context
                ompQualificationInvocationContext = context
                guard let targetSession = agentModeVM.session(
                    for: target.tabID,
                    createIfNeeded: false
                ) else {
                    await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
                    _ = await agentModeVM.mcpDiscardSessionTarget(
                        target,
                        ifOwnedByOMPQualification: context
                    )
                    throw MCPError.internalError(
                        "OMP qualification could not install its transaction context because the resolved target session is unavailable."
                    )
                }
                guard agentModeVM.mcpInstallStartInvocationGeneration(
                    context.generationID,
                    for: target,
                    expectedSessionID: targetSessionID
                ) else {
                    await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
                    throw MCPError.invalidParams(
                        "The OMP qualification target is already claimed by an earlier transaction cleanup."
                    )
                }
                targetSession.ompQualificationStartContext = context
            } else if ompQualificationLease != nil {
                await discardUnconsumedTargetIfOwned()
                throw MCPError.invalidParams(
                    "_omp_qualification_lease_id may only authorize an effective OMP target."
                )
            }
        #endif
        #if DEBUG
            let discardQualificationTargetIfOwned: (
                _ beforeDiscard: () -> Void
            ) async -> AgentModeViewModel.OMPQualificationTargetDiscardOutcome = { beforeDiscard in
                let liveTargetSession = agentModeVM.session(for: target.tabID, createIfNeeded: false)
                await testBeforeOMPQualificationTargetDiscardCAS?(liveTargetSession)
                if let context = ompQualificationInvocationContext {
                    return await agentModeVM.mcpDiscardSessionTarget(
                        target,
                        ifOwnedByOMPQualification: context,
                        beforeDiscard: beforeDiscard
                    )
                }
                return await agentModeVM.mcpDiscardSessionTarget(
                    target,
                    ifOwnedByStartGeneration: mcpStartInvocationGenerationID,
                    expectedSessionID: targetSessionID,
                    beforeDiscard: beforeDiscard
                )
            }
            let qualificationOwnershipCategory: (
                AgentModeViewModel.OMPQualificationTargetDiscardOutcome,
                String
            ) -> String = { outcome, fallback in
                switch outcome {
                case .contextReplaced:
                    "qualification_context_replaced"
                case .aborted, .superseded, .discarded, .ineligible:
                    fallback
                }
            }
        #endif
        #if DEBUG
            if worktreeStartupBenchmarkToken != nil {
                do {
                    let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
                    try diagnostics.registerRecoverableStartTarget(
                        correlationID: worktreeStartupCorrelationID,
                        agentSessionID: targetSessionID,
                        targetTabID: target.tabID,
                        targetOrigin: target.origin
                    )
                    try diagnostics.requireRecoverableStartNotAborted(
                        correlationID: worktreeStartupCorrelationID
                    )
                } catch {
                    await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
                    let discardOutcome = await discardQualificationTargetIfOwned {
                        try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                            correlationID: worktreeStartupCorrelationID,
                            phase: .discardRequested,
                            errorCategory: "target_registration"
                        )
                    }
                    if discardOutcome == .discarded {
                        try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                            correlationID: worktreeStartupCorrelationID,
                            phase: .discardCompleted,
                            providerRunActive: false
                        )
                    }
                    throw error
                }
            }
        #endif
        let worktreeStartupContext = WorktreeStartupContext(
            agentSessionID: targetSessionID,
            correlationID: worktreeStartupCorrelationID,
            flags: worktreeStartupFlags,
            servingControl: worktreeStartupServingControl
        )
        WorktreeStartupInstrumentation.record(.agentRunStarted, context: worktreeStartupContext)
        #if DEBUG
            let performTerminalQualificationCleanup: (
                _ category: String,
                _ recordInstrumentationFailure: Bool,
                _ fallback: WorkspaceRootSeedFallbackReason?
            ) async -> Void = { category, recordInstrumentationFailure, fallback in
                let cleanupTask = Task { @MainActor in
                    await rollbackConsumedQualificationStart(agentModeVM, target.tabID, false)
                    let discardOutcome = await discardQualificationTargetIfOwned {
                        if worktreeStartupBenchmarkToken != nil {
                            try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                                correlationID: worktreeStartupCorrelationID,
                                phase: .failed,
                                providerRunActive: false,
                                errorCategory: category
                            )
                            try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                                correlationID: worktreeStartupCorrelationID,
                                phase: .discardRequested
                            )
                        }
                    }
                    if let session = agentModeVM.session(for: target.tabID, createIfNeeded: false),
                       session.ompQualificationStartContext === ompQualificationInvocationContext
                    {
                        session.ompQualificationStartContext = nil
                    }
                    let effectiveCategory = qualificationOwnershipCategory(discardOutcome, category)
                    testOMPQualificationTerminalCategory?(effectiveCategory)
                    if recordInstrumentationFailure {
                        WorktreeStartupInstrumentation.record(
                            .failed,
                            context: worktreeStartupContext,
                            fallback: fallback
                        )
                    }
                    if worktreeStartupBenchmarkToken != nil {
                        if discardOutcome == .discarded {
                            try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                                correlationID: worktreeStartupCorrelationID,
                                phase: .discardCompleted,
                                providerRunActive: false
                            )
                        } else {
                            try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                                correlationID: worktreeStartupCorrelationID,
                                phase: .failed,
                                providerRunActive: false,
                                errorCategory: effectiveCategory
                            )
                        }
                    }
                }
                await cleanupTask.value
            }
        #endif
        var expectedRoutedWorktreeBindings: [AgentSessionWorktreeBinding]?
        var expectedExplicitTabWorktreeSource: (
            tabID: UUID,
            sessionID: UUID,
            bindings: [AgentSessionWorktreeBinding]
        )?
        do {
            #if DEBUG
                if let testWorktreePreparationFailure {
                    throw testWorktreePreparationFailure
                }
            #endif
            if effectiveParentWorktreeInheritance,
               let parentSourceTabID,
               let spawnParentSessionID
            {
                expectedRoutedWorktreeBindings = try agentModeVM.mcpReconcileRoutedSpawnWorktreeBindings(
                    sourceTabID: parentSourceTabID,
                    expectedParentSessionID: spawnParentSessionID,
                    target: target
                )
            } else if effectiveParentWorktreeInheritance,
                      parentSourceTabID == nil,
                      spawnParentSessionID == nil,
                      oracleLaunchSource.snapshot.route == .explicitTabContext,
                      let sourceAgentSessionID = oracleLaunchSource.snapshot.sourceAgentSessionID
            {
                guard case let .captured(capturedSource) = oracleLaunchSource.source else {
                    throw MCPError.invalidParams(
                        "agent_run.start cannot inherit the explicit-tab worktree because its frozen launch source is unavailable."
                    )
                }
                guard capturedSource.sourceTabID == oracleLaunchSource.snapshot.tabID,
                      capturedSource.sourceAgentSessionID == sourceAgentSessionID
                else {
                    throw MCPError.invalidParams(
                        "agent_run.start cannot inherit the explicit-tab worktree because its frozen launch source identity does not match the launch snapshot."
                    )
                }
                let capturedBindings = capturedSource.sourceWorktreeBindings
                try agentModeVM.mcpReconcileExplicitTabSpawnWorktreeBindings(
                    sourceTabID: oracleLaunchSource.snapshot.tabID,
                    expectedSourceSessionID: sourceAgentSessionID,
                    expectedBindings: capturedBindings,
                    target: target
                )
                expectedExplicitTabWorktreeSource = (
                    oracleLaunchSource.snapshot.tabID,
                    sourceAgentSessionID,
                    capturedBindings
                )
            }
            #if DEBUG
                if let worktreeStartupBenchmarkToken {
                    try await WorktreeStartupBenchmarkDiagnostics.$currentPendingStart.withValue(
                        DebugWorktreeStartupBenchmarkPendingStart(
                            token: worktreeStartupBenchmarkToken,
                            startAttemptID: UUID()
                        )
                    ) {
                        try await startWorktreeCoordinator.prepare(
                            request: worktreeStartRequest,
                            target: target,
                            targetWindow: targetWindow,
                            startupContext: worktreeStartupContext
                        )
                    }
                } else {
                    try await startWorktreeCoordinator.prepare(
                        request: worktreeStartRequest,
                        target: target,
                        targetWindow: targetWindow,
                        startupContext: worktreeStartupContext
                    )
                }
            #else
                try await startWorktreeCoordinator.prepare(
                    request: worktreeStartRequest,
                    target: target,
                    targetWindow: targetWindow,
                    startupContext: worktreeStartupContext
                )
            #endif
            if let expectedRoutedWorktreeBindings,
               let spawnParentSessionID
            {
                try agentModeVM.mcpRequireRoutedSpawnWorktreeBindings(
                    expectedRoutedWorktreeBindings,
                    expectedParentSessionID: spawnParentSessionID,
                    target: target
                )
            }
            #if DEBUG
                if expectedExplicitTabWorktreeSource != nil {
                    testBeforeExplicitTabWorktreeValidation?()
                }
            #endif
            if let expectedExplicitTabWorktreeSource {
                try agentModeVM.mcpRequireExplicitTabSpawnWorktreeBindings(
                    sourceTabID: expectedExplicitTabWorktreeSource.tabID,
                    expectedSourceSessionID: expectedExplicitTabWorktreeSource.sessionID,
                    expectedBindings: expectedExplicitTabWorktreeSource.bindings,
                    target: target
                )
            }
            // The parent admission must survive worktree preparation's awaits.
            try agentModeVM.mcpRequireDelegatedChildLinkAdmissionCurrent(delegatedChildLinkAdmission)
        } catch {
            WorktreeStartupInstrumentation.record(
                .failed,
                context: worktreeStartupContext,
                fallback: error is CancellationError ? .cancellation : nil
            )
            #if DEBUG
                if let targetSession = agentModeVM.session(for: target.tabID, createIfNeeded: false) {
                    await testBeforeWorktreePreparationFailureCleanup?(targetSession)
                }
                let category = error is CancellationError
                    ? "cancellation"
                    : (error as? DebugWorktreeStartupBenchmarkError) == .startAborted
                    ? "abort_requested"
                    : "worktree_preparation"
                await performTerminalQualificationCleanup(
                    category,
                    false,
                    error is CancellationError ? .cancellation : nil
                )
            #else
                await agentModeVM.mcpDiscardSessionTarget(target)
            #endif
            throw error
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartTargetResolved", tabID: target.tabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "targetSessionID": target.sessionID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "taskLabel": selection.taskLabelKind?.rawValue ?? "nil",
                "agent": selection.agentRaw ?? "nil",
                "model": selection.modelRaw ?? "nil",
                "targetOrigin": String(describing: target.origin)
            ])
        #endif
        #if DEBUG
            let terminalQualificationFailure: (_ message: String, _ category: String) async -> MCPError = { message, category in
                await performTerminalQualificationCleanup(category, true, nil)
                return MCPError.invalidParams(message)
            }

            await testBeforeOMPQualificationProviderDispatch?()
            if ompQualificationStartTransaction != nil {
                guard let requestedWorkspaceUUID,
                      targetWindow.workspaceManager.activeWorkspace?.id == requestedWorkspaceUUID
                else {
                    throw await terminalQualificationFailure(
                        "workspace_mismatch: the fingerprinted OMP qualification workspace changed before provider dispatch.",
                        "workspace_mismatch"
                    )
                }
                guard let context = ompQualificationStartContext,
                      Self.ompQualificationAuthorizationRemainingNanoseconds(
                          deadlineUptimeNanoseconds: ompQualificationAuthorizationDeadlineUptimeNanoseconds,
                          nowUptimeNanoseconds: ompQualificationNow()
                      ) > 0
                else {
                    ompQualificationStartContext?.authorizationReceipt.resolve(.denied)
                    throw await terminalQualificationFailure(
                        "The OMP qualification provider authorization deadline expired before provider dispatch.",
                        "qualification_authorization_timeout"
                    )
                }
                guard let liveSession = agentModeVM.session(for: target.tabID, createIfNeeded: false) else {
                    context.authorizationReceipt.resolve(.denied)
                    throw await terminalQualificationFailure(
                        "The OMP qualification transaction context was unavailable before provider dispatch.",
                        "qualification_context_missing"
                    )
                }
                await testBeforeOMPQualificationContextIdentityCheck?(context, liveSession)
                guard liveSession.mcpStartInvocationGenerationID == context.generationID,
                      liveSession.ompQualificationStartContext === context
                else {
                    context.authorizationReceipt.resolve(.denied)
                    throw await terminalQualificationFailure(
                        "The OMP qualification transaction context was replaced before provider dispatch.",
                        "qualification_context_replaced"
                    )
                }
                await testAfterOMPQualificationPreDispatchIdentityCheck?()
                guard liveSession.mcpStartInvocationGenerationID == context.generationID,
                      liveSession.ompQualificationStartContext === context
                else {
                    context.authorizationReceipt.resolve(.denied)
                    throw await terminalQualificationFailure(
                        "The OMP qualification transaction context was replaced before provider dispatch.",
                        "qualification_context_replaced"
                    )
                }
            }
        #endif
        if let delegatedChildLinkAdmission {
            // Step 5b: the child's covering save and the parent's link commit are acknowledged
            // before any child dispatch; a failure or cancellation here dispatches nothing.
            do {
                try await agentModeVM.mcpCommitDelegatedChildLink(
                    delegatedChildLinkAdmission,
                    childTabID: target.tabID,
                    childSessionID: targetSessionID
                )
                // Immediately before the start: a cancelled call starts nothing.
                try Task.checkCancellation()
            } catch {
                WorktreeStartupInstrumentation.record(
                    .failed,
                    context: worktreeStartupContext,
                    fallback: error is CancellationError ? .cancellation : nil
                )
                #if DEBUG
                    await performTerminalQualificationCleanup(
                        error is CancellationError ? "cancellation" : "delegated_child_link",
                        false,
                        error is CancellationError ? .cancellation : nil
                    )
                #else
                    await agentModeVM.mcpDiscardSessionTarget(target)
                #endif
                throw error
            }
        }
        let outcome: AgentExternalMCPRunStarter.StartOutcome
        do {
            WorktreeStartupInstrumentation.record(.providerStart, context: worktreeStartupContext)
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    await testBeforeProviderDispatch?()
                    try WorktreeStartupBenchmarkDiagnostics.shared.beginRecoverableProviderDispatch(
                        correlationID: worktreeStartupCorrelationID
                    )
                }
            #endif
            #if DEBUG
                ompQualificationProviderDispatchStarted = true
            #endif
            #if DEBUG
                outcome = try await OhMyPiAgentModeSmokeGate.$invocationStartContext.withValue(
                    ompQualificationStartContext
                ) {
                    try await MCPDelegatedChildDispatchFence.$current.withValue(delegatedChildLinkAdmission) {
                        // One-shot: inherited unstructured work never arms the fence after the start.
                        defer { delegatedChildLinkAdmission?.releaseDispatchFence() }
                        return try await startRun(
                            target,
                            message,
                            metadata,
                            bindCurrentRequestToTab,
                            agentModeVM,
                            selection.agentRaw,
                            selection.modelRaw,
                            selectionReasoningEffortRaw,
                            selection.taskLabelKind,
                            selection.ohMyPiThinkingSelections,
                            workflow,
                            spawnParentSessionID,
                            oracleLaunchSource.source
                        )
                    }
                }
            #else
                outcome = try await MCPDelegatedChildDispatchFence.$current.withValue(delegatedChildLinkAdmission) {
                    // One-shot: inherited unstructured work never arms the fence after the start.
                    defer { delegatedChildLinkAdmission?.releaseDispatchFence() }
                    return try await startRun(
                        target,
                        message,
                        metadata,
                        bindCurrentRequestToTab,
                        agentModeVM,
                        selection.agentRaw,
                        selection.modelRaw,
                        selectionReasoningEffortRaw,
                        selection.taskLabelKind,
                        selection.ohMyPiThinkingSelections,
                        workflow,
                        spawnParentSessionID,
                        oracleLaunchSource.source
                    )
                }
            #endif
            #if DEBUG
                if worktreeStartupBenchmarkToken != nil {
                    await testAfterProviderStartBeforeBookkeeping?()
                    if WorktreeStartupBenchmarkDiagnostics.shared.recoverableStartAbortRequested(
                        correlationID: worktreeStartupCorrelationID
                    ) == true {
                        if ompQualificationStartTransaction != nil {
                            await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
                        } else {
                            await agentModeVM.cancelAgentRun(
                                tabID: target.tabID,
                                cause: .ordinary,
                                completion: .terminalPublished
                            )
                        }
                        throw DebugWorktreeStartupBenchmarkError.startAborted
                    }
                }
            #endif
        } catch {
            WorktreeStartupInstrumentation.record(
                .failed,
                context: worktreeStartupContext,
                fallback: error is CancellationError ? .cancellation : nil
            )
            let decoratedError = startWorktreeCoordinator.providerStartError(
                error,
                targetSessionID: target.sessionID,
                agentModeVM: agentModeVM
            )
            #if DEBUG
                ompQualificationStartContext?.authorizationReceipt.resolve(.denied)
                let providerFailureCategory = if error is AgentExternalMCPRunStarter.OMPQualificationInvocationError {
                    "qualification_context_replaced"
                } else if error is CancellationError {
                    "cancellation"
                } else {
                    "provider_start"
                }
                await performTerminalQualificationCleanup(
                    providerFailureCategory,
                    false,
                    error is CancellationError ? .cancellation : nil
                )
            #else
                await agentModeVM.mcpDiscardSessionTarget(target)
            #endif
            throw decoratedError
        }
        #if DEBUG
            var effectiveSnapshot = outcome.snapshot
        #else
            let effectiveSnapshot = outcome.snapshot
        #endif
        #if DEBUG
            if let ompQualificationLease {
                guard let context = ompQualificationStartContext else {
                    throw await terminalQualificationFailure(
                        "The OMP qualification start lost its transaction context.",
                        "qualification_context"
                    )
                }
                let remainingNanoseconds = Self.ompQualificationAuthorizationRemainingNanoseconds(
                    deadlineUptimeNanoseconds: ompQualificationAuthorizationDeadlineUptimeNanoseconds,
                    nowUptimeNanoseconds: ompQualificationNow()
                )
                let observedAuthorizationOutcome = remainingNanoseconds > 0
                    ? await context.authorizationReceipt.wait(timeoutNanoseconds: remainingNanoseconds)
                    : nil
                let authorizationOutcome: OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome
                if let observedAuthorizationOutcome {
                    authorizationOutcome = observedAuthorizationOutcome
                } else {
                    let effectiveOutcome = context.authorizationReceipt.resolve(.denied)
                    guard case .authorized = effectiveOutcome else {
                        throw await terminalQualificationFailure(
                            "The OMP qualification provider authorization did not reach an actionable outcome before its deadline.",
                            "qualification_authorization_timeout"
                        )
                    }
                    // A prior authorization winner remains authoritative even if the
                    // waiting task observes it at the absolute deadline boundary.
                    authorizationOutcome = effectiveOutcome
                }
                guard case let .authorized(authorizedRun) = authorizationOutcome else {
                    let startupFailureSuffix = context.authorizationReceipt.resolvedStartupFailureReason.map {
                        " Underlying startup failure: \($0)"
                    } ?? ""
                    throw await terminalQualificationFailure(
                        "The OMP qualification provider start was not authorized for this transaction.\(startupFailureSuffix)",
                        "qualification_authorization"
                    )
                }
                if let dispatchedRunID = outcome.snapshot.runID,
                   dispatchedRunID != authorizedRun.runID
                {
                    throw await terminalQualificationFailure(
                        "The OMP qualification start returned a run identity that did not match the authorized run.",
                        "run_identity_mismatch"
                    )
                }
                let liveSnapshot = await currentSnapshot(
                    sessionID: outcome.snapshot.sessionID,
                    agentModeVM: agentModeVM,
                    unregisteredRunIdentity: false
                )
                guard let connectionID = metadata.connectionID,
                      let runID = liveSnapshot.runID
                else {
                    throw await terminalQualificationFailure(
                        "The OMP qualification start did not expose a bindable run identity.",
                        "run_identity_missing"
                    )
                }
                guard runID == authorizedRun.runID else {
                    throw await terminalQualificationFailure(
                        "The OMP qualification start returned a run identity that did not match the authorized run.",
                        "run_identity_mismatch"
                    )
                }
                do {
                    ompQualificationRollbackSnapshot = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                        leaseID: ompQualificationLease.leaseID,
                        ownerConnectionID: connectionID,
                        sessionID: liveSnapshot.sessionID,
                        runID: runID
                    )
                    effectiveSnapshot = liveSnapshot
                } catch {
                    throw await terminalQualificationFailure(
                        "The OMP qualification lease could not bind the created run.",
                        "run_binding"
                    )
                }
            }
            if worktreeStartupBenchmarkToken != nil {
                try? WorktreeStartupBenchmarkDiagnostics.shared.recordRecoverableStartPhase(
                    correlationID: worktreeStartupCorrelationID,
                    phase: .responsePrepared,
                    providerRunActive: effectiveSnapshot.status == .running
                )
            }
        #endif
        if detach || effectiveSnapshot.status != .running || timeoutSeconds <= 0 {
            #if DEBUG
                ompQualificationTransactionSucceeded = ompQualificationLease == nil
                    || Self.ompQualificationTransactionCommits(status: effectiveSnapshot.status)
                if !ompQualificationTransactionSucceeded {
                    await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
                } else if let session = agentModeVM.session(for: target.tabID, createIfNeeded: false),
                          session.ompQualificationStartContext === ompQualificationStartContext
                {
                    session.ompQualificationStartContext = nil
                }
            #endif
            let startedValue = Self.attachingKnowledgeWorkerReceipt(
                to: decoratedRunValue(snapshot: effectiveSnapshot, workflow: workflow, delivery: outcome.delivery),
                modelSource: knowledgeWorkerModelSource,
                agentRaw: selection.agentRaw,
                modelRaw: selection.modelRaw,
                reasoningEffortRaw: selectionReasoningEffortRaw
            )
            // Detached starts have no wait policy to report; every other start selected one.
            return detach ? startedValue : AgentMCPWaitPolicy.attaching(waitSelection, to: startedValue)
        }
        let waitedValue: Value
        do {
            waitedValue = try await waitForInterestingState(
                sessionID: effectiveSnapshot.sessionID,
                agentModeVM: agentModeVM,
                metadata: waitContext.metadata,
                timeoutSeconds: waitSelection.timeoutSeconds,
                stage: "starting",
                message: "Waiting for the started run to finish or request input...",
                workflow: workflow,
                initialDelivery: outcome.delivery
            )
        } catch {
            #if DEBUG
                await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
            #endif
            throw error
        }
        #if DEBUG
            let committedStatus = await currentSnapshot(
                sessionID: effectiveSnapshot.sessionID,
                agentModeVM: agentModeVM
            ).status
            ompQualificationTransactionSucceeded = ompQualificationLease == nil
                || Self.ompQualificationTransactionCommits(status: committedStatus)
            if !ompQualificationTransactionSucceeded {
                await rollbackConsumedQualificationStart(agentModeVM, target.tabID, true)
            } else if let session = agentModeVM.session(for: target.tabID, createIfNeeded: false),
                      session.ompQualificationStartContext === ompQualificationStartContext
            {
                session.ompQualificationStartContext = nil
            }
        #endif
        return AgentMCPWaitPolicy.attaching(
            waitSelection,
            to: Self.attachingKnowledgeWorkerReceipt(
                to: waitedValue,
                modelSource: knowledgeWorkerModelSource,
                agentRaw: selection.agentRaw,
                modelRaw: selection.modelRaw,
                reasoningEffortRaw: selectionReasoningEffortRaw
            )
        )
    }

    private func executeWait(
        args: [String: Value],
        forcePoll: Bool = false,
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        if args["session_ids"] != nil {
            if forcePoll {
                return try await executePollMany(args: args, knowledgeCaller: knowledgeCaller)
            }
            return try await executeWaitAny(args: args, knowledgeCaller: knowledgeCaller)
        }

        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let includeStatusUpdates = forcePoll ? false : (parseBool(args["include_status_updates"]) ?? false)
        let metadata = await captureRequestMetadata()
        let waitContext: AgentMCPWaitPolicy.RequestContext
        let waitSelection: AgentMCPWaitPolicy.Selection
        if forcePoll {
            // `op=poll` never waits, so it does not need the parent family.
            waitContext = AgentMCPWaitPolicy.RequestContext.unresolved(metadata: metadata)
            waitSelection = .poll
        } else {
            waitContext = await resolveWaitPolicyContext(metadata)
            waitSelection = try Self.resolvedWaitSelection(
                args["timeout"],
                parentFamily: waitContext.parentFamily,
                promptCacheRetention: waitContext.parentPromptCacheRetention
            )
        }
        try validateKnowledgeObservationTargets(
            [sessionID],
            knowledgeCaller: knowledgeCaller,
            agentModeVM: agentModeVM,
            operation: forcePoll ? "agent_run.poll" : "agent_run.wait"
        )
        return try await performSingleWait(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            context: waitContext,
            selection: waitSelection,
            includeStatusUpdates: includeStatusUpdates
        )
    }

    private func executeWaitAny(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let includeStatusUpdates = parseBool(args["include_status_updates"]) ?? false
        let metadata = await captureRequestMetadata()
        let waitContext = await resolveWaitPolicyContext(metadata)
        let waitSelection = try Self.resolvedWaitSelection(
            args["timeout"],
            parentFamily: waitContext.parentFamily,
            promptCacheRetention: waitContext.parentPromptCacheRetention
        )
        try validateKnowledgeObservationTargets(
            sessionIDs,
            knowledgeCaller: knowledgeCaller,
            agentModeVM: agentModeVM,
            operation: "agent_run.wait"
        )
        return try await performWait(
            sessionIDs: sessionIDs,
            agentModeVM: agentModeVM,
            context: waitContext,
            selection: waitSelection,
            includeStatusUpdates: includeStatusUpdates
        )
    }

    /// Delegated wait entry for callers that already froze the request context and wait
    /// selection at their own outer lifecycle entry (Explore start-to-wait and Explore wait).
    /// The frozen values are used as-is; nothing is recaptured or recomputed here.
    func executeFrozenWait(
        sessionIDs: [UUID],
        context: AgentMCPWaitPolicy.RequestContext,
        selection: AgentMCPWaitPolicy.Selection,
        includeStatusUpdates: Bool = false
    ) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        return try await performWait(
            sessionIDs: sessionIDs,
            agentModeVM: agentModeVM,
            context: context,
            selection: selection,
            includeStatusUpdates: includeStatusUpdates
        )
    }

    private func performWait(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        context: AgentMCPWaitPolicy.RequestContext,
        selection: AgentMCPWaitPolicy.Selection,
        includeStatusUpdates: Bool
    ) async throws -> Value {
        // Single-element waits preserve the single-session response shape while taking the same
        // frozen context/selection as a general multi-wait (no recapture of provider identity).
        if sessionIDs.count == 1 {
            return try await performSingleWait(
                sessionID: sessionIDs[0],
                agentModeVM: agentModeVM,
                context: context,
                selection: selection,
                includeStatusUpdates: includeStatusUpdates
            )
        }
        return try await performMultiWait(
            sessionIDs: sessionIDs,
            agentModeVM: agentModeVM,
            context: context,
            selection: selection,
            includeStatusUpdates: includeStatusUpdates
        )
    }

    private func performSingleWait(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        context: AgentMCPWaitPolicy.RequestContext,
        selection: AgentMCPWaitPolicy.Selection,
        includeStatusUpdates: Bool
    ) async throws -> Value {
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if initialSnapshot.isActionableForMCPWait || selection.timeoutSeconds <= 0 {
            return AgentMCPWaitPolicy.attaching(selection, to: decoratedRunValue(snapshot: initialSnapshot))
        }
        if isLiveUnregisteredWaitTarget(sessionID: sessionID, agentModeVM: agentModeVM) {
            let rawValue = try await sampleLiveUnregisteredWait(
                sessionIDs: [sessionID],
                shape: .single,
                agentModeVM: agentModeVM,
                metadata: context.metadata,
                timeoutSeconds: selection.timeoutSeconds,
                includeStatusUpdates: includeStatusUpdates,
                initialSnapshots: [initialSnapshot]
            )
            let value = await finalDecoratedSingleWaitValue(
                from: rawValue,
                sessionID: sessionID,
                agentModeVM: agentModeVM,
                workflow: nil,
                initialDelivery: nil
            )
            return AgentMCPWaitPolicy.attaching(selection, to: value)
        }
        let value = try await waitForInterestingState(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            metadata: context.metadata,
            timeoutSeconds: selection.timeoutSeconds,
            stage: "waiting",
            message: "Waiting for the agent run to finish or request input...",
            liveSnapshot: initialSnapshot,
            includeStatusUpdates: includeStatusUpdates
        )
        return AgentMCPWaitPolicy.attaching(selection, to: value)
    }

    private func performMultiWait(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        context: AgentMCPWaitPolicy.RequestContext,
        selection: AgentMCPWaitPolicy.Selection,
        includeStatusUpdates: Bool
    ) async throws -> Value {
        let metadata = context.metadata
        let timeoutSeconds = selection.timeoutSeconds
        let initialSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)

        if let ready = initialSnapshots.first(where: { isInterestingSnapshot($0) }) {
            return AgentMCPWaitPolicy.attaching(selection, to: decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: ready.status == .expired ? "expired" : "snapshot_ready",
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            ))
        }

        if timeoutSeconds <= 0 {
            return AgentMCPWaitPolicy.attaching(selection, to: decoratedMultiWaitValue(
                snapshot: initialSnapshots[0],
                sessionIDs: sessionIDs,
                result: "timed_out",
                snapshots: initialSnapshots,
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            ))
        }

        if sessionIDs.allSatisfy({ agentModeVM.mcpWaitCursor(sessionID: $0) == nil }),
           sessionIDs.contains(where: { isLiveUnregisteredWaitTarget(sessionID: $0, agentModeVM: agentModeVM) })
        {
            let value = try await sampleLiveUnregisteredWait(
                sessionIDs: sessionIDs,
                shape: .multi,
                agentModeVM: agentModeVM,
                metadata: metadata,
                timeoutSeconds: timeoutSeconds,
                includeStatusUpdates: includeStatusUpdates,
                initialSnapshots: initialSnapshots
            )
            return AgentMCPWaitPolicy.attaching(selection, to: value)
        }

        let waitScopeToken = await beginAgentRunWait(metadata, Set(sessionIDs), timeoutSeconds)
        if let waitScopeToken, hasDeliverableDelegatedQuestionNotices(waitScopeToken, Set(sessionIDs)) {
            let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
            let value = delegatedQuestionMultiWaitValue(
                sessionIDs: sessionIDs,
                triggeringSnapshot: snapshots.first ?? initialSnapshots[0],
                snapshots: snapshots
            )
            await endAgentRunWait(waitScopeToken, waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs))
            return AgentMCPWaitPolicy.attaching(selection, to: value)
        }
        do {
            let value = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                "waiting",
                "Waiting for the first agent run to finish or request input..."
            ) {
                try await waitForAnyInterestingState(
                    sessionIDs: sessionIDs,
                    agentModeVM: agentModeVM,
                    timeoutSeconds: timeoutSeconds,
                    initialSnapshots: initialSnapshots,
                    includeStatusUpdates: includeStatusUpdates,
                    hasDeliverableDelegatedQuestion: { [self] in
                        guard let waitScopeToken else { return false }
                        return await hasDeliverableDelegatedQuestionNotices(waitScopeToken, Set(sessionIDs))
                    }
                )
            }
            let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            return AgentMCPWaitPolicy.attaching(selection, to: value)
        } catch is CancellationError {
            if let value = await waitAnyCancellationValueIfActionable(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                fallbackSnapshots: initialSnapshots
            ) {
                let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, completion)
                }
                return AgentMCPWaitPolicy.attaching(selection, to: value)
            }
            let completion = AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: nil)
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw CancellationError()
        } catch {
            let completion = AgentRunWaitScopeCompletion(reason: .error, result: "error", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: String(describing: error))
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
    }

    private func resolvedAgentModeViewModel(_ targetWindow: WindowState) -> AgentModeViewModel {
        #if DEBUG
            if let testAgentModeViewModel {
                return testAgentModeViewModel
            }
        #endif
        return targetWindow.agentModeViewModel
    }

    private func executePollMany(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)
        try validateKnowledgeObservationTargets(
            sessionIDs,
            knowledgeCaller: knowledgeCaller,
            agentModeVM: agentModeVM,
            operation: "agent_run.poll"
        )
        let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        return AgentMCPWaitPolicy.attaching(.poll, to: decoratedMultiPollValue(sessionIDs: sessionIDs, snapshots: snapshots))
    }

    #if DEBUG
        static func ompQualificationTransactionCommits(status: AgentRunMCPSnapshot.Status) -> Bool {
            switch status {
            case .running, .waitingForInput, .completed:
                true
            case .failed, .cancelled, .expired:
                false
            }
        }
    #endif

    struct DelegatedControlAdmission {
        let sourceTabID: UUID?
        let callerSessionID: UUID?
        /// Profile the caller was admitted with; `.knowledge` keeps Knowledge rechecks at every
        /// boundary. Nil for standard and external callers, whose rechecks are unchanged.
        var callerProfile: AgentSessionProfile?
    }

    /// Routed Knowledge caller of one `agent_run` call, admitted at the outer entry. Every later
    /// admission, commit, dispatch, and replay check is made against this frozen caller, never
    /// against whichever session occupies the tab by then.
    struct KnowledgeCaller {
        let sourceTabID: UUID
        /// Durable identity frozen by admission; later checks require the tab to still hold it.
        let admittedCallerSessionID: UUID
    }

    static let knowledgeCodexWebSearchDisabledMessage = "Codex web search is turned off, so a Codex Knowledge research worker could not search the web. Turn on the Codex Search tool (Settings → CLI Providers → Codex → Core tools → Search, or the Codex tools menu in the Agent composer), or pass a Claude Code model_id. No research worker was created."

    /// K1/K2 admission for every `agent_run` operation. A caller is a Knowledge caller when its
    /// connection's enforced tool policy or the verified profile of its live routed source record
    /// is Knowledge. A Knowledge caller must use an allowlisted operation, resolve to a hydrated
    /// live Knowledge record, and be an eligible Knowledge root: placeholders, workers
    /// (`knowledgeLeaf`), and unverifiable lineage are denied. Research workers never run
    /// workflows, so workflow arguments are rejected for every Knowledge operation. The returned
    /// caller is carried through every later check of this call. Returns nil for every other
    /// caller, whose behavior is unchanged.
    private func admitKnowledgeCaller(op: String, args: [String: Value]) async throws -> KnowledgeCaller? {
        let metadata = await captureRequestMetadata()
        let connectionProfile = await resolveConnectionSessionProfile(metadata)
        let sourceTabID = await resolveSpawnParentSourceTabID(metadata)
        // Only a routed caller has a live source record to inspect. An unrouted caller (an external
        // client) never resolves the window here, so its operation keeps its own single resolution;
        // an unrouted Knowledge connection still fails closed below.
        let agentModeVM: AgentModeViewModel? = if sourceTabID != nil, let targetWindow = try? requireTargetWindow() {
            resolvedAgentModeViewModel(targetWindow)
        } else {
            nil
        }
        let callerResolution = sourceTabID.flatMap { agentModeVM?.mcpDelegationCallerProfileResolution(sourceTabID: $0) }
        // A live record whose verified profile is Knowledge (including an unhydrated placeholder
        // whose identity is indexed as Knowledge) makes this a Knowledge caller even when the
        // connection reports no profile; it then fails closed below unless it is hydrated.
        let liveClaimsKnowledge = if case .resolved(.knowledge, _) = callerResolution { true } else { false }
        guard connectionProfile == .knowledge || liveClaimsKnowledge else { return nil }
        guard KnowledgeSessionPolicy.allowedAgentRunOperations.contains(op) else {
            throw MCPError.invalidParams(
                "agent_run op '\(op)' is not available to Knowledge sessions. Use start, poll, wait, cancel, steer, or respond."
            )
        }
        guard let sourceTabID,
              let agentModeVM,
              callerResolution == .resolved(.knowledge, isHydrated: true),
              let admittedCallerSessionID = try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: sourceTabID)
        else {
            throw MCPError.invalidParams(
                "agent_run was called from a Knowledge session, but RepoPrompt could not resolve that session. Refusing to start or control research workers; retry after the session is active."
            )
        }
        if args["workflow_id"] != nil || args["workflow_name"] != nil {
            throw MCPError.invalidParams(
                "agent_run from a Knowledge session does not support workflows. Describe the research question in message instead."
            )
        }
        return KnowledgeCaller(sourceTabID: sourceTabID, admittedCallerSessionID: admittedCallerSessionID)
    }

    /// K3: a Knowledge start always creates a fresh Knowledge research worker, so existing-tab
    /// selectors, workflows, worktree arguments, and role-label `model_id`s are rejected before
    /// any model resolution or target creation.
    private func validateKnowledgeStartArguments(
        args: [String: Value],
        resolvedTabID: UUID?,
        workflow: AgentWorkflowDefinition?,
        worktreeStartRequest: AgentMCPStartWorktreeCoordinator.Request
    ) throws {
        // `session_id` is already rejected for every start by the general start guard.
        if resolvedTabID != nil || args["_tabID"] != nil || args["tab_id"] != nil {
            throw MCPError.invalidParams(
                "agent_run.start from a Knowledge session always creates a fresh research worker; tab_id and other existing-session selectors are not supported."
            )
        }
        if workflow != nil || args["workflow_id"] != nil || args["workflow_name"] != nil {
            throw MCPError.invalidParams(
                "agent_run.start from a Knowledge session does not support workflows. Describe the research question in message instead."
            )
        }
        if worktreeStartRequest.hasExplicitWorktreeArgs || startWorktreeCoordinator.containsArguments(args) {
            throw MCPError.invalidParams(
                "agent_run.start from a Knowledge session does not support worktree arguments; research workers do not edit code."
            )
        }
        if let modelID = normalizedString(args["model_id"]) {
            guard modelID.contains(":") else {
                throw MCPError.invalidParams(
                    "agent_run.start from a Knowledge session does not accept role labels such as '\(modelID)'. Omit model_id to use this session's provider and model, or pass an explicit Claude Code or Codex model_id (agent:model)."
                )
            }
            // K4/K5 before catalog resolution: an unsupported provider or a Codex worker without
            // web search is rejected deterministically, independent of catalog availability.
            if let parsed = AgentModelSelectionID.parse(modelID) {
                try validateKnowledgeWorkerProvider(agentRaw: parsed.agentRaw)
            }
        }
    }

    /// K4/K5: a Knowledge research worker runs only on a Knowledge-supported provider, and a Codex
    /// worker requires Codex's local Search tool toggle. Only that known local toggle is checked;
    /// remote web availability is never probed, and Claude has no RepoPrompt toggle to gate.
    private func validateKnowledgeWorkerProvider(agentRaw: String) throws {
        guard let agent = AgentProviderKind(rawValue: agentRaw),
              KnowledgeSessionPolicy.supportedProviders.contains(agent)
        else {
            let supported = KnowledgeSessionPolicy.supportedProvidersOrdered
                .map(\.displayName)
                .joined(separator: " or ")
            throw MCPError.invalidParams(
                "Knowledge research workers run only on \(supported); agent '\(agentRaw)' is not supported. Omit model_id to use this session's provider and model."
            )
        }
        if agent == .codexExec, !codexWebSearchEnabled() {
            throw MCPError.invalidParams(Self.knowledgeCodexWebSearchDisabledMessage)
        }
    }

    /// K6 for session-addressed `wait`/`poll`: a Knowledge caller may observe only its own
    /// Knowledge research workers. Runs synchronously after the session references and wait
    /// context resolved, re-checking the frozen caller identity and every target.
    private func validateKnowledgeObservationTargets(
        _ sessionIDs: [UUID],
        knowledgeCaller: KnowledgeCaller?,
        agentModeVM: AgentModeViewModel,
        operation: String
    ) throws {
        guard let knowledgeCaller else { return }
        for sessionID in sessionIDs {
            try agentModeVM.mcpRevalidateDelegationCommit(
                sourceTabID: knowledgeCaller.sourceTabID,
                expectedCallerSessionID: knowledgeCaller.admittedCallerSessionID,
                targetSessionID: sessionID,
                operation: operation,
                expectedCallerProfile: .knowledge
            )
        }
    }

    /// K4 start receipt: names the Knowledge research worker's resolved provider and model and
    /// whether they were inherited from the calling session or passed explicitly. Non-Knowledge
    /// starts (nil `modelSource`) are returned unchanged.
    static func attachingKnowledgeWorkerReceipt(
        to value: Value,
        modelSource: String?,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?
    ) -> Value {
        guard let modelSource, var object = value.objectValue else { return value }
        object["knowledge_worker"] = .object([
            "profile": .string(AgentSessionProfile.knowledge.rawValue),
            "model_source": .string(modelSource),
            "provider": agentRaw.map(Value.string) ?? .null,
            "model": modelRaw.map(Value.string) ?? .null,
            "reasoning_effort": reasoningEffortRaw.map(Value.string) ?? .null
        ])
        return .object(object)
    }

    /// Session-addressed control (cancel, respond) from a delegated worker is bounded like
    /// reactivation: a depth ≥ 1 caller may only act on sessions strictly deeper than itself, never
    /// itself, an ancestor, a sibling, or a root. External and depth-0 callers are unchanged. The
    /// returned admission freezes the caller identity for the mutation-boundary recheck.
    @discardableResult
    private func validateDelegatedControlTarget(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        operation: String,
        knowledgeCaller: KnowledgeCaller?
    ) async throws -> DelegatedControlAdmission {
        let metadata = await captureRequestMetadata()
        return try await admitDelegatedControl(
            metadata: metadata,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            operation: operation,
            knowledgeCaller: knowledgeCaller
        )
    }

    /// Control admission for one session-addressed call. Standard and external callers are admitted
    /// as before. A Knowledge caller is never re-admitted from whichever session now occupies its
    /// tab (KW-01): the routed tab must be unchanged, and the frozen identity must still be a
    /// hydrated, eligible Knowledge root whose target is its own Knowledge research worker.
    private func admitDelegatedControl(
        metadata: RequestMetadata,
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        operation: String,
        knowledgeCaller: KnowledgeCaller?
    ) async throws -> DelegatedControlAdmission {
        let sourceTabID = await resolveSpawnParentSourceTabID(metadata)
        try await validateSpawnRouting(metadata, sourceTabID, operation)
        if let knowledgeCaller {
            guard sourceTabID == knowledgeCaller.sourceTabID else {
                throw MCPError.invalidParams(
                    "\(operation) from a Knowledge session changed routing while it was being admitted. Refusing to control research workers; retry after the session is active."
                )
            }
            try agentModeVM.mcpRevalidateDelegationCommit(
                sourceTabID: knowledgeCaller.sourceTabID,
                expectedCallerSessionID: knowledgeCaller.admittedCallerSessionID,
                targetSessionID: sessionID,
                operation: operation,
                expectedCallerProfile: .knowledge
            )
            return DelegatedControlAdmission(
                sourceTabID: knowledgeCaller.sourceTabID,
                callerSessionID: knowledgeCaller.admittedCallerSessionID,
                callerProfile: .knowledge
            )
        }
        let callerSessionID = try agentModeVM.mcpAdmitDelegationControl(
            sourceTabID: sourceTabID,
            targetSessionID: sessionID,
            operation: operation
        )
        return DelegatedControlAdmission(sourceTabID: sourceTabID, callerSessionID: callerSessionID)
    }

    /// Cancellation mutation boundary: synchronously re-admits the frozen caller (identity,
    /// eligibility, target scope) and re-resolves the live cancel target, then enters
    /// `cancelAgentRun(target:)`, whose own guards also run before its first suspension.
    private func cancelAfterDelegationRevalidation(
        sessionID: UUID,
        expectedRunID: UUID?,
        admission: DelegatedControlAdmission,
        agentModeVM: AgentModeViewModel
    ) async throws {
        try agentModeVM.mcpRevalidateDelegationCommit(
            sourceTabID: admission.sourceTabID,
            expectedCallerSessionID: admission.callerSessionID,
            targetSessionID: sessionID,
            operation: "agent_run.cancel",
            expectedCallerProfile: admission.callerProfile
        )
        guard let session = agentModeVM.mcpControlledSession(sessionID: sessionID), session.runState.isActive else {
            throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
        }
        let cancelTarget = agentModeVM.makeRunCancelTarget(tabID: session.tabID, session: session)
        if let expectedRunID, cancelTarget.expectedRunID != expectedRunID {
            throw MCPError.invalidParams(
                "The requested run_id is not the current run for this session; refusing to cancel a different run."
            )
        }
        guard await agentModeVM.cancelAgentRun(
            target: cancelTarget,
            cause: .userCancel,
            completion: .terminalPublished
        ) else {
            throw MCPError.invalidParams(
                "The requested run is no longer current; refusing to cancel a different run."
            )
        }
    }

    private func executeCancel(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let controlAdmission = try await validateDelegatedControlTarget(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            operation: "agent_run.cancel",
            knowledgeCaller: knowledgeCaller
        )
        let metadata = await captureRequestMetadata()
        let expectedRunID = try parseCancelRunID(args)
        if isRemoteRootControl(
            metadata: metadata,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            knowledgeCaller: knowledgeCaller
        ) {
            return try await executeRemoteRootCancel(
                expectedRunID: expectedRunID,
                sessionID: sessionID,
                metadata: metadata,
                agentModeVM: agentModeVM
            )
        }
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if let expectedRunID, initialSnapshot.runID != expectedRunID {
            throw MCPError.invalidParams(
                "The requested run_id is not the current run for this session; refusing to cancel a different run."
            )
        }
        if initialSnapshot.status == .expired {
            throw MCPError.invalidParams(agentRunExpiredHandleRecoveryNote)
        }
        if initialSnapshot.status.isTerminal {
            throw MCPError.invalidParams("The run is not currently active (status: \(initialSnapshot.status.rawValue)) and cannot be cancelled.")
        }
        guard let controlledSession = agentModeVM.mcpControlledSession(sessionID: sessionID) else {
            // A live session outside MCP control (for example a desktop root) can report
            // `running` without being cancellable through this tool.
            throw MCPError.invalidParams(
                "This session is not under agent_run control, so agent_run cannot cancel it."
            )
        }
        guard controlledSession.runState.isActive else {
            throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
        }
        let cancelResult = try await withHeartbeat(
            metadata.connectionID,
            toolName,
            "cancelling",
            "Cancelling the agent run..."
        ) {
            try await cancelAfterDelegationRevalidation(
                sessionID: sessionID,
                expectedRunID: expectedRunID,
                admission: controlAdmission,
                agentModeVM: agentModeVM
            )
            await Task.yield()
            return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
        }
        if let parsed = cancelResult.objectValue.flatMap(Self.snapshot(from:)) {
            return decoratedRunValue(snapshot: parsed)
        }
        return cancelResult
    }

    private func executeSteer(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = resolvedAgentModeViewModel(targetWindow)
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let text = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let metadata = await captureRequestMetadata()

        // Steering starts or redirects work: an Agent Mode caller must still be allowed to delegate,
        // and a delegated worker may only steer sessions deeper than itself.
        let steerAdmission = try await admitDelegatedControl(
            metadata: metadata,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            operation: "agent_run.steer",
            knowledgeCaller: knowledgeCaller
        )

        // A verified paired device steering (running) or following up (idle) a desktop root uses
        // the normal send path without installing MCP control (plan Step 1).
        if isRemoteRootControl(
            metadata: metadata,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            knowledgeCaller: knowledgeCaller
        ) {
            return try await executeRemoteRootSteer(
                args: args,
                sessionID: sessionID,
                text: text,
                workflow: workflow,
                agentModeVM: agentModeVM
            )
        }

        // Plan §6.3/§6.4: resolve the frozen parent family and validate the active wait selection
        // before the steering mutation or any control-context reactivation, so an invalid explicit
        // timeout never dispatches. `wait=false` keeps ignoring a supplied timeout_seconds with the
        // existing warning and does not parse it.
        let shouldWait: Bool = {
            if let explicit = parseBool(args["wait"]) { return explicit }
            if args["timeout_seconds"] != nil { return true }
            return false
        }()
        let rawSteerTimeoutSeconds = args["timeout_seconds"]
        let ignoredTimeoutWarning: String?
        let steerWaitContext: AgentMCPWaitPolicy.RequestContext?
        let steerWaitSelection: AgentMCPWaitPolicy.Selection?
        if shouldWait {
            ignoredTimeoutWarning = nil
            let waitContext = await resolveWaitPolicyContext(metadata)
            steerWaitContext = waitContext
            steerWaitSelection = try Self.resolvedSteerWaitSelection(
                rawSteerTimeoutSeconds,
                parentFamily: waitContext.parentFamily,
                promptCacheRetention: waitContext.parentPromptCacheRetention
            )
        } else if rawSteerTimeoutSeconds != nil {
            ignoredTimeoutWarning = "Ignoring timeout_seconds because wait=false; the steering instruction was accepted without waiting."
            steerWaitContext = nil
            steerWaitSelection = nil
        } else {
            ignoredTimeoutWarning = nil
            steerWaitContext = nil
            steerWaitSelection = nil
        }

        let resolution = try await ensureSteerControlContext(
            sessionID: sessionID,
            targetWindow: targetWindow,
            agentModeVM: agentModeVM,
            metadata: metadata,
            // Only a Knowledge caller admitted for its own worker (K6) may reactivate a Knowledge
            // session; every other caller keeps the standard-only activation.
            expectedSessionProfile: steerAdmission.callerProfile == .knowledge ? .knowledge : .standard
        )
        let delivery: AgentModeViewModel.MCPInstructionDispatch
        let snapshot: AgentRunMCPSnapshot
        do {
            // Control-context resolution may have suspended since admission: re-admit the caller
            // and target synchronously before the steering instruction is dispatched.
            try agentModeVM.mcpRevalidateDelegationCommit(
                sourceTabID: steerAdmission.sourceTabID,
                expectedCallerSessionID: steerAdmission.callerSessionID,
                targetSessionID: sessionID,
                operation: "agent_run.steer",
                expectedCallerProfile: steerAdmission.callerProfile
            )
            if resolution.session.runState.isActive {
                delivery = try await dispatchSteerInstruction(
                    sessionID: sessionID,
                    text: text,
                    workflow: workflow,
                    agentModeVM: agentModeVM
                )
                await Task.yield()
                snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            } else {
                // Inactive steering starts a new epoch without replacing the session activation.
                agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, true)
                do {
                    delivery = try await agentModeVM.withMCPRunEpochTransition(
                        sessionID: sessionID,
                        kind: .steering
                    ) {
                        try await dispatchSteerInstruction(
                            sessionID: sessionID,
                            text: text,
                            workflow: workflow,
                            agentModeVM: agentModeVM
                        )
                    }
                } catch {
                    clearFollowUpPendingAfterSteerFailure(
                        sessionID: sessionID,
                        resolution: resolution,
                        agentModeVM: agentModeVM
                    )
                    throw error
                }
                await Task.yield()
                snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            }
        } catch {
            if let identity = resolution.reactivatedControlIdentity {
                await agentModeVM.mcpCleanupReactivatedControlContextIfCurrent(
                    sessionID: identity.sessionID,
                    activationID: identity.activationID,
                    registration: identity.registration,
                    reactivatedTarget: resolution.reactivatedTarget
                )
            }
            throw error
        }
        await Task.yield()

        // Steer-and-wait: optionally block until the agent reaches an interesting state using the
        // selection frozen before the mutation.
        let shouldBlockForSteeredOutput = delivery.isActiveRunDispatch
            ? snapshot.interaction == nil
            : (!snapshot.status.isTerminal && snapshot.interaction == nil)
        if let steerWaitContext, let steerWaitSelection,
           shouldBlockForSteeredOutput, steerWaitSelection.timeoutSeconds > 0
        {
            let waited = try await waitForInterestingState(
                sessionID: sessionID,
                agentModeVM: agentModeVM,
                metadata: steerWaitContext.metadata,
                timeoutSeconds: steerWaitSelection.timeoutSeconds,
                stage: "steering",
                message: "Waiting for the steered run to finish or request input...",
                workflow: workflow,
                initialDelivery: delivery,
                liveSnapshot: snapshot.status == .running ? snapshot : nil
            )
            return AgentMCPWaitPolicy.attaching(steerWaitSelection, to: waited)
        }
        let steeredValue = decoratedRunValue(
            snapshot: snapshot,
            workflow: workflow,
            delivery: delivery,
            warning: ignoredTimeoutWarning
        )
        // Non-waiting steers have no wait policy to report.
        guard let steerWaitSelection else { return steeredValue }
        return AgentMCPWaitPolicy.attaching(steerWaitSelection, to: steeredValue)
    }

    // MARK: - Remote attention-root control (paired gateway devices)

    /// One synchronous gate over already-captured request metadata: true only for a verified
    /// paired-device caller (`.gateway` principal plus its per-device app-link identity, never a
    /// client name alone) targeting a remote-controllable desktop root. Every other caller or
    /// session keeps the ordinary MCP control rules.
    private func isRemoteRootControl(
        metadata: RequestMetadata,
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        knowledgeCaller: KnowledgeCaller?
    ) -> Bool {
        knowledgeCaller == nil
            && metadata.gatewayRemoteDeviceID != nil
            && agentModeVM.remoteAttentionRootSession(sessionID: sessionID) != nil
    }

    private func parseCancelRunID(_ args: [String: Value]) throws -> UUID? {
        guard args["run_id"] != nil else { return nil }
        guard let raw = normalizedString(args["run_id"]), let runID = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("agent_run cancel run_id must be a non-empty UUID string when provided.")
        }
        return runID
    }

    private func executeRemoteRootCancel(
        expectedRunID: UUID?,
        sessionID: UUID,
        metadata: RequestMetadata,
        agentModeVM: AgentModeViewModel
    ) async throws -> Value {
        let cancelResult = try await withHeartbeat(
            metadata.connectionID,
            toolName,
            "cancelling",
            "Cancelling the agent run..."
        ) {
            // The view model re-resolves the root and its guarded cancel target synchronously.
            try await agentModeVM.remoteRootCancelRun(sessionID: sessionID, expectedRunID: expectedRunID)
            await Task.yield()
            return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
        }
        if let parsed = cancelResult.objectValue.flatMap(Self.snapshot(from:)) {
            return decoratedRunValue(snapshot: parsed)
        }
        return cancelResult
    }

    private func executeRemoteRootSteer(
        args: [String: Value],
        sessionID: UUID,
        text: String,
        workflow: AgentWorkflowDefinition?,
        agentModeVM: AgentModeViewModel
    ) async throws -> Value {
        // A desktop root has no MCP wait registration, so steer-and-wait is not offered; the
        // instruction is still delivered and the caller polls for updates.
        let waitRequested = parseBool(args["wait"]) == true
            || (parseBool(args["wait"]) == nil && args["timeout_seconds"] != nil)
        let warning: String? = waitRequested
            ? "Waiting is not available for remote control of a desktop session; the instruction was accepted without waiting. Poll for updates."
            : nil
        let delivery = try await dispatchRemoteRootInstruction(
            sessionID: sessionID,
            text: text,
            workflow: workflow,
            agentModeVM: agentModeVM
        )
        await Task.yield()
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        return decoratedRunValue(snapshot: snapshot, workflow: workflow, delivery: delivery, warning: warning)
    }

    private func dispatchRemoteRootInstruction(
        sessionID: UUID,
        text: String,
        workflow: AgentWorkflowDefinition?,
        agentModeVM: AgentModeViewModel
    ) async throws -> AgentModeViewModel.MCPInstructionDispatch {
        #if DEBUG
            if let testDispatchRemoteRootInstruction {
                return try await testDispatchRemoteRootInstruction(sessionID, text, workflow, agentModeVM)
            }
        #endif
        return try await agentModeVM.remoteRootDispatchInstruction(
            sessionID: sessionID,
            text: text,
            workflow: workflow
        )
    }

    private func clearFollowUpPendingAfterSteerFailure(
        sessionID: UUID,
        resolution: SteerControlResolution,
        agentModeVM: AgentModeViewModel
    ) {
        // The pending running mask is session-scoped rather than activation-scoped. A failed
        // inactive steer must always drop it so MCP snapshots stop reporting a queued run,
        // even if a concurrent replacement means destructive context cleanup must be skipped.
        agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, false)

        if let identity = resolution.reactivatedControlIdentity {
            guard let session = agentModeVM.mcpControlledSession(sessionID: identity.sessionID),
                  let context = session.mcpControlContext,
                  context.sessionID == identity.sessionID,
                  context.activationID == identity.activationID,
                  context.registration == identity.registration
            else {
                return
            }
        }
    }

    private func ensureSteerControlContext(
        sessionID: UUID,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel,
        metadata: RequestMetadata,
        expectedSessionProfile: AgentSessionProfile
    ) async throws -> SteerControlResolution {
        if let controlledSession = agentModeVM.mcpControlledSession(sessionID: sessionID) {
            return SteerControlResolution(
                session: controlledSession,
                reactivatedTarget: nil,
                reactivatedControlIdentity: nil
            )
        }
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available to resolve session_id '\(sessionID.uuidString)'.")
        }
        guard let resolvedSessionID = try await agentModeVM.mcpResolveSessionID(
            reference: sessionID.uuidString,
            workspace: workspace
        ), resolvedSessionID == sessionID else {
            throw MCPError.invalidParams("Session '\(sessionID.uuidString)' was not found in the active workspace.")
        }

        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            inheritWorktreeBindings: false
        )
        let session = try await agentModeVM.ensureSessionReady(tabID: target.tabID)
        guard session.activeAgentSessionID == sessionID else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        guard !session.runState.isActive else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.invalidParams(
                "The requested agent run is active but is not controlled by this MCP handle."
            )
        }

        do {
            try await agentModeVM.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: metadata.connectionID,
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true,
                expectedSessionProfile: expectedSessionProfile
            )
        } catch {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw error
        }
        guard let reactivatedSession = agentModeVM.mcpControlledSession(sessionID: sessionID),
              let context = reactivatedSession.mcpControlContext,
              context.sessionID == sessionID
        else {
            await agentModeVM.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.internalError("Failed to reactivate MCP control for the requested agent session.")
        }
        let identity = SteerControlIdentity(
            sessionID: context.sessionID,
            activationID: context.activationID,
            registration: context.registration
        )
        return SteerControlResolution(
            session: reactivatedSession,
            reactivatedTarget: target,
            reactivatedControlIdentity: identity
        )
    }

    private func dispatchSteerInstruction(
        sessionID: UUID,
        text: String,
        workflow: AgentWorkflowDefinition?,
        agentModeVM: AgentModeViewModel
    ) async throws -> AgentModeViewModel.MCPInstructionDispatch {
        #if DEBUG
            if let testDispatchSteerInstruction {
                return try await testDispatchSteerInstruction(sessionID, text, workflow, agentModeVM)
            }
        #endif
        return try await agentModeVM.mcpDispatchInstruction(
            sessionID: sessionID,
            text: text,
            allowStartingRun: true,
            workflow: workflow
        )
    }

    private func executeRespond(
        args: [String: Value],
        knowledgeCaller: KnowledgeCaller? = nil
    ) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let controlAdmission = try await validateDelegatedControlTarget(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            operation: "agent_run.respond",
            knowledgeCaller: knowledgeCaller
        )
        let interactionID = try requireUUID(args["interaction_id"], name: "interaction_id")
        let workflow = try resolveWorkflow(args: args)
        let payload = try parseResponsePayload(args: args)
        #if DEBUG
            let ompQualificationApplyEditsReviewDecision = agentModeVM
                .mcpOMPQualificationApplyEditsReviewDecisionMetadata(
                    sessionID: sessionID,
                    interactionID: interactionID,
                    rawDecision: payload.decisionRaw
                )
        #endif
        let metadata = await captureRequestMetadata()
        // A verified paired device answering a desktop root's pending question: exact question
        // only, attributed to the authenticated device, with no MCP control installed (plan Step 1).
        // The view model re-resolves the root and the exact interaction synchronously.
        if isRemoteRootControl(
            metadata: metadata,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            knowledgeCaller: knowledgeCaller
        ), let deviceID = metadata.gatewayRemoteDeviceID {
            let dispatch = try await agentModeVM.remoteRootResolvePendingQuestion(
                sessionID: sessionID,
                interactionID: interactionID,
                payload: payload,
                resolvedBy: deviceID
            )
            await Task.yield()
            return await decoratedRunValue(
                snapshot: currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM),
                workflow: workflow,
                delivery: dispatch
            )
        }
        // Attribute `resolved_by` to the resolving MCP client identity. Remote gateway
        // devices connect through per-device app links named `remote:<device8>`, so
        // their storage key already carries the remote namespace.
        let resolvedBy = MCPClientIdentity.storageKey(metadata.clientName) ?? "mcp"
        // Dispatch boundary (KW-03): re-admit the frozen caller (identity, eligibility, target
        // ceiling) after the awaits since admission, with no suspension before resolution. A
        // Knowledge caller also keeps its verified Knowledge profile and own-child rule. External
        // callers (no routed source) are unaffected.
        try agentModeVM.mcpRevalidateDelegationCommit(
            sourceTabID: controlAdmission.sourceTabID,
            expectedCallerSessionID: controlAdmission.callerSessionID,
            targetSessionID: sessionID,
            operation: "agent_run.respond",
            expectedCallerProfile: controlAdmission.callerProfile
        )
        let dispatch = try await agentModeVM.mcpResolvePendingInteraction(
            sessionID: sessionID,
            interactionID: interactionID,
            payload: payload,
            workflow: workflow,
            resolvedBy: resolvedBy
        )
        await Task.yield()
        let decorated = await decoratedRunValue(
            snapshot: currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM),
            workflow: workflow,
            delivery: dispatch
        )
        #if DEBUG
            guard let ompQualificationApplyEditsReviewDecision,
                  var object = decorated.objectValue
            else {
                return decorated
            }
            var responseMetadata = object["_meta"]?.objectValue ?? [:]
            responseMetadata["omp_qualification_apply_edits_review"] = .object([
                "decision": .string(ompQualificationApplyEditsReviewDecision),
                "interaction_id": .string(interactionID.uuidString)
            ])
            object["_meta"] = .object(responseMetadata)
            return .object(object)
        #else
            return decorated
        #endif
    }

    private func waitForInterestingState(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        metadata: RequestMetadata,
        timeoutSeconds: TimeInterval,
        stage: String,
        message: String,
        workflow: AgentWorkflowDefinition? = nil,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        liveSnapshot _: AgentRunMCPSnapshot? = nil,
        includeStatusUpdates: Bool = false
    ) async throws -> Value {
        guard let initialCursor = agentModeVM.mcpWaitCursor(sessionID: sessionID) else {
            throw MCPError.invalidParams(agentRunExpiredHandleRecoveryNote)
        }
        let clock = ContinuousClock()
        let deadline = Self.resolvedWaitClockNow(clock).advanced(by: .seconds(timeoutSeconds))
        // Accepted staleness window (plan §2/Q3): a status change landing between a
        // prior wait's return and this baseline capture is absorbed into the baseline
        // and only surfaces at the next change or the timeout sample. Deliberate —
        // sampling, not streaming.
        let baselineKey = await includeStatusUpdates
            ? Self.normalizedStatusTextKey((AgentRunSessionStore.snapshot(for: initialCursor))?.statusText)
            : nil
        let waitScopeToken = await beginAgentRunWait(metadata, [sessionID], timeoutSeconds)
        if let waitScopeToken, hasDeliverableDelegatedQuestionNotices(waitScopeToken, [sessionID]) {
            let current = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            let value = current.isActionableForMCPWait
                ? current.toValue()
                : Self.delegatedQuestionInterruptedSingleWaitValue(current)
            await endAgentRunWait(waitScopeToken, singleWaitScopeCompletion(from: value, sessionID: sessionID))
            return await finalDecoratedSingleWaitValue(
                from: value, sessionID: sessionID, agentModeVM: agentModeVM,
                workflow: workflow, initialDelivery: initialDelivery
            )
        }
        let completionBox = WaitScopeCompletionBox()
        let snapshot: Value
        do {
            snapshot = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                stage,
                message
            ) {
                var cursor = initialCursor
                while true {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let remaining = Self.timeInterval(from: Self.resolvedWaitClockNow(clock).duration(to: deadline))
                    guard remaining > 0 else {
                        let value = await timedOutWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                        let result = Self.waitResult(from: value) ?? "timed_out"
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: result == "startup_pending" ? .startupPending : .timedOut,
                            result: result,
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return value
                    }
                    let sliceTimeout = includeStatusUpdates
                        ? min(remaining, Self.resolvedStatusUpdateSliceSeconds)
                        : remaining
                    let disposition = await AgentRunSessionStore.waitUntilInteresting(
                        cursor: cursor,
                        timeoutSeconds: sliceTimeout
                    )
                    switch disposition {
                    case let .snapshotReady(triggeringSnapshot):
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: triggeringSnapshot.status == .expired ? .expired : .snapshotReady,
                            result: triggeringSnapshot.status == .expired ? "expired" : "snapshot_ready",
                            winnerSessionID: triggeringSnapshot.status == .expired ? nil : sessionID,
                            pendingSessionIDs: triggeringSnapshot.status == .expired ? [sessionID] : [],
                            errorDescription: nil
                        ))
                        return triggeringSnapshot.toValue()
                    case let .noteworthySnapshot(triggeringSnapshot, reason):
                        if triggeringSnapshot.isActionableForMCPWait {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .snapshotReady,
                                result: "snapshot_ready",
                                winnerSessionID: sessionID,
                                pendingSessionIDs: [],
                                errorDescription: nil
                            ))
                            return triggeringSnapshot.toValue()
                        }
                        if reason == .steeringRequested {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .cancelled,
                                result: "interrupted_by_steering",
                                winnerSessionID: nil,
                                pendingSessionIDs: [sessionID],
                                errorDescription: nil
                            ))
                            return Self.steeringInterruptedSingleWaitValue(triggeringSnapshot)
                        }
                        if reason == .delegatedQuestionPending,
                           let waitScopeToken,
                           await hasDeliverableDelegatedQuestionNotices(waitScopeToken, [sessionID])
                        {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .delegatedQuestionPending,
                                result: AgentDelegatedQuestionNoticeWire.agentRunWaitResult,
                                winnerSessionID: nil,
                                pendingSessionIDs: [sessionID],
                                errorDescription: nil
                            ))
                            return Self.delegatedQuestionInterruptedSingleWaitValue(triggeringSnapshot)
                        }
                        if reason == .interactionResolved {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .snapshotReady,
                                result: "interaction_resolved",
                                winnerSessionID: sessionID,
                                pendingSessionIDs: [],
                                errorDescription: nil
                            ))
                            return Self.interactionResolvedSingleWaitValue(triggeringSnapshot)
                        }
                        continue
                    case let .epochAdvanced(epoch, transitionKind):
                        if transitionKind == .unrelated {
                            completionBox.set(AgentRunWaitScopeCompletion(
                                reason: .superseded,
                                result: "superseded",
                                winnerSessionID: nil,
                                pendingSessionIDs: [sessionID],
                                errorDescription: nil
                            ))
                            return await supersededWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                        }
                        cursor = .init(registration: cursor.registration, epoch: epoch)
                    case let .terminalPublicationRejected(_, reason):
                        throw MCPError.internalError("The agent run terminal state could not be published: \(reason)")
                    case .timedOut:
                        let remainingAfterSlice = Self.timeInterval(
                            from: Self.resolvedWaitClockNow(clock).duration(to: deadline)
                        )
                        if includeStatusUpdates, remainingAfterSlice > 0 {
                            let latest = await AgentRunSessionStore.snapshot(for: cursor)
                            if Self.shouldReturnStatusUpdate(baselineKey: baselineKey, latest: latest) {
                                completionBox.set(AgentRunWaitScopeCompletion(
                                    reason: .statusUpdate,
                                    result: "status_update",
                                    winnerSessionID: sessionID,
                                    pendingSessionIDs: [],
                                    errorDescription: nil
                                ))
                                return await statusUpdateWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                            }
                            continue
                        }
                        let value = await timedOutWaitValue(sessionID: sessionID, agentModeVM: agentModeVM)
                        let result = Self.waitResult(from: value) ?? "timed_out"
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: result == "startup_pending" ? .startupPending : .timedOut,
                            result: result,
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return value
                    case .expired:
                        completionBox.set(AgentRunWaitScopeCompletion(
                            reason: .expired,
                            result: "expired",
                            winnerSessionID: nil,
                            pendingSessionIDs: [sessionID],
                            errorDescription: nil
                        ))
                        return Self.expiredWaitValue(sessionID: sessionID)
                    case .cancelled:
                        throw CancellationError()
                    }
                }
            }
        } catch {
            if error is CancellationError,
               let resolution = await cancelledSingleWaitResolutionIfActionable(
                   sessionID: sessionID,
                   agentModeVM: agentModeVM
               )
            {
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, resolution.completion)
                }
                return await finalDecoratedSingleWaitValue(
                    from: resolution.rawValue,
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    workflow: workflow,
                    initialDelivery: initialDelivery
                )
            }
            if let waitScopeToken {
                let completion = AgentRunWaitScopeCompletion(
                    reason: error is CancellationError ? .cancelled : .error,
                    result: error is CancellationError ? "cancelled" : "error",
                    winnerSessionID: nil,
                    pendingSessionIDs: [sessionID],
                    errorDescription: String(describing: error)
                )
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
        if let waitScopeToken {
            let completion = completionBox.get() ?? singleWaitScopeCompletion(from: snapshot, sessionID: sessionID)
            await endAgentRunWait(waitScopeToken, completion)
        }
        return await finalDecoratedSingleWaitValue(
            from: snapshot,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            workflow: workflow,
            initialDelivery: initialDelivery
        )
    }

    private enum LiveUnregisteredWaitShape {
        case single
        case multi
    }

    /// True for a live session with no MCP control registration at all (not merely no wait
    /// cursor), such as a desktop root the phone app link observes. The cursor-based wait would
    /// report an expired handle for it even though the session is alive and truthfully running;
    /// a registered session without a cursor keeps the ordinary expired-handle reporting.
    private func isLiveUnregisteredWaitTarget(sessionID: UUID, agentModeVM: AgentModeViewModel) -> Bool {
        guard agentModeVM.mcpWaitCursor(sessionID: sessionID) == nil,
              agentModeVM.mcpRegistration(sessionID: sessionID) == nil
        else { return false }
        return ((try? agentModeVM.authoritativeLiveSession(for: sessionID)) ?? nil) != nil
    }

    /// Mixed-wait lane for one live unregistered target: samples its truthful snapshot like
    /// `sampleLiveUnregisteredWait` and reports through the same first-result arbitration as the
    /// controlled targets' cursor lanes, so their wait scope and delegated-question handling stay
    /// unchanged while this target can still win.
    private nonisolated func sampleLiveUnregisteredWaitAnyLane(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        timeoutSeconds: TimeInterval,
        includeStatusUpdates: Bool,
        baselineKey: String?
    ) async -> WaitAnyResult {
        let clock = ContinuousClock()
        let deadline = Self.resolvedWaitClockNow(clock).advanced(by: .seconds(timeoutSeconds))
        let pollSeconds = Self.resolvedLiveUnregisteredWaitPollSeconds
        while true {
            let remaining = Self.timeInterval(from: Self.resolvedWaitClockNow(clock).duration(to: deadline))
            guard remaining > 0 else { return WaitAnyResult(sessionID: sessionID, disposition: .timedOut) }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(remaining, pollSeconds) * 1_000_000_000))
            } catch {
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
            let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            if isInterestingSnapshot(snapshot) {
                return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
            }
            if includeStatusUpdates, Self.shouldReturnStatusUpdate(baselineKey: baselineKey, latest: snapshot) {
                return WaitAnyResult(sessionID: sessionID, disposition: .statusUpdate(snapshot))
            }
        }
    }

    /// Bounded sampling wait for live unregistered sessions. It re-reads the truthful live
    /// snapshot every `liveUnregisteredWaitPollSeconds` until one session is actionable, a
    /// running session's status text changes (when status updates were requested), or the
    /// deadline passes. It never registers control or creates a wait scope.
    private func sampleLiveUnregisteredWait(
        sessionIDs: [UUID],
        shape: LiveUnregisteredWaitShape,
        agentModeVM: AgentModeViewModel,
        metadata: RequestMetadata,
        timeoutSeconds: TimeInterval,
        includeStatusUpdates: Bool,
        initialSnapshots: [AgentRunMCPSnapshot]
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = Self.resolvedWaitClockNow(clock).advanced(by: .seconds(timeoutSeconds))
        let pollSeconds = Self.resolvedLiveUnregisteredWaitPollSeconds
        let baselineKeys: [UUID: String?] = Dictionary(
            initialSnapshots.map { ($0.sessionID, Self.normalizedStatusTextKey($0.statusText)) },
            uniquingKeysWith: { first, _ in first }
        )
        return try await withHeartbeat(
            metadata.connectionID,
            toolName,
            "waiting",
            "Waiting for the agent run to finish or request input..."
        ) { [self] in
            var latest = initialSnapshots
            while true {
                try Task.checkCancellation()
                let remaining = Self.timeInterval(from: Self.resolvedWaitClockNow(clock).duration(to: deadline))
                guard remaining > 0 else {
                    let representative = latest.first(where: \.isStartupPendingForMCPWait) ?? latest[0]
                    let result = representative.isStartupPendingForMCPWait ? "startup_pending" : "timed_out"
                    return liveUnregisteredWaitValue(
                        shape: shape,
                        sessionIDs: sessionIDs,
                        trigger: representative,
                        result: result,
                        snapshots: latest
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(min(remaining, pollSeconds) * 1_000_000_000))
                latest = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
                if let ready = latest.first(where: { isInterestingSnapshot($0) }) {
                    return liveUnregisteredWaitValue(
                        shape: shape,
                        sessionIDs: sessionIDs,
                        trigger: ready,
                        result: ready.status == .expired ? "expired" : "snapshot_ready",
                        snapshots: latest
                    )
                }
                if includeStatusUpdates,
                   let updated = latest.first(where: {
                       Self.shouldReturnStatusUpdate(baselineKey: baselineKeys[$0.sessionID] ?? nil, latest: $0)
                   })
                {
                    return liveUnregisteredWaitValue(
                        shape: shape,
                        sessionIDs: sessionIDs,
                        trigger: updated,
                        result: "status_update",
                        snapshots: latest
                    )
                }
            }
        }
    }

    private nonisolated func liveUnregisteredWaitValue(
        shape: LiveUnregisteredWaitShape,
        sessionIDs: [UUID],
        trigger: AgentRunMCPSnapshot,
        result: String,
        snapshots: [AgentRunMCPSnapshot]
    ) -> Value {
        switch shape {
        case .single:
            guard result != "snapshot_ready" else { return trigger.toValue() }
            var object = trigger.asObject()
            object["_meta"] = .object(["wait_result": .string(result)])
            return .object(object)
        case .multi:
            return decoratedMultiWaitValue(
                snapshot: trigger,
                sessionIDs: sessionIDs,
                result: result,
                snapshots: snapshots,
                pendingSessionIDs: result == "status_update"
                    ? pendingSessionIDs(from: snapshots).filter { $0 != trigger.sessionID }
                    : pendingSessionIDs(from: snapshots)
            )
        }
    }

    private func timedOutWaitValue(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wait_result": .string(snapshot.isStartupPendingForMCPWait ? "startup_pending" : "timed_out")
        ])
        return .object(object)
    }

    private func statusUpdateWaitValue(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        var object = snapshot.asObject()
        object["_meta"] = .object(["wait_result": .string("status_update")])
        return .object(object)
    }

    private nonisolated static func waitResult(from value: Value) -> String? {
        value.objectValue?["_meta"]?.objectValue?["wait_result"]?.stringValue
    }

    private func supersededWaitValue(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wake_reason": .string("superseded_turn"),
            "wait_result": .string("superseded")
        ])
        return .object(object)
    }

    private nonisolated static func expiredWaitValue(sessionID: UUID) -> Value {
        var object = agentRunExpiredSnapshot(sessionID: sessionID).asObject()
        object["_meta"] = .object(["wait_result": .string("expired")])
        return .object(object)
    }

    private nonisolated static func delegatedQuestionInterruptedSingleWaitValue(
        _ snapshot: AgentRunMCPSnapshot
    ) -> Value {
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wake_reason": .string(AgentRunSessionStore.WakeReason.delegatedQuestionPending.rawValue),
            "wait_result": .string(AgentDelegatedQuestionNoticeWire.agentRunWaitResult)
        ])
        return .object(object)
    }

    private nonisolated static func steeringInterruptedSingleWaitValue(
        _ snapshot: AgentRunMCPSnapshot
    ) -> Value {
        var object = snapshot.asObject()
        object["_meta"] = .object([
            "wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
        ])
        return .object(object)
    }

    private nonisolated static func interactionResolvedSingleWaitValue(
        _ snapshot: AgentRunMCPSnapshot
    ) -> Value {
        var object = snapshot.asObject()
        var meta: [String: Value] = [
            "wake_reason": .string(AgentRunSessionStore.WakeReason.interactionResolved.rawValue)
        ]
        if let resolution = snapshot.lastInteractionResolution {
            meta["interaction_resolved"] = .object(resolution.asObject())
        }
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private func cancelledSingleWaitResolutionIfActionable(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> CancelledSingleWaitResolution? {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        guard snapshot.status != .expired, snapshot.isActionableForMCPWait else { return nil }
        let value = snapshot.toValue()
        return CancelledSingleWaitResolution(
            rawValue: value,
            completion: singleWaitScopeCompletion(from: value, sessionID: sessionID)
        )
    }

    private func finalDecoratedSingleWaitValue(
        from rawValue: Value,
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        workflow: AgentWorkflowDefinition?,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch?
    ) async -> Value {
        let resolvedSnapshot: AgentRunMCPSnapshot
        let wakeReason = rawValue.objectValue.flatMap(wakeReason(from:))
        if let parsedSnapshot = rawValue.objectValue.flatMap(Self.snapshot(from:)) {
            resolvedSnapshot = parsedSnapshot
        } else {
            resolvedSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        }
        let decorated = decoratedRunValue(
            snapshot: resolvedSnapshot,
            workflow: workflow,
            delivery: initialDelivery,
            wakeReason: wakeReason
        )
        guard var object = decorated.objectValue,
              let rawMeta = rawValue.objectValue?["_meta"]?.objectValue
        else {
            return decorated
        }
        var meta = object["_meta"]?.objectValue ?? [:]
        for (key, value) in rawMeta {
            meta[key] = value
        }
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private func waitAnyCancellationValueIfActionable(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        fallbackSnapshots: [AgentRunMCPSnapshot]
    ) async -> Value? {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        let snapshots = freshSnapshots.isEmpty ? fallbackSnapshots : freshSnapshots
        guard !snapshots.isEmpty else { return nil }

        if let ready = snapshots.first(where: { isInterestingSnapshot($0) && $0.status != .expired }) {
            return decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: "snapshot_ready",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
            )
        }

        return nil
    }

    private func waitAnySteeringInterruptValue(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        triggeringSnapshot: AgentRunMCPSnapshot,
        latestSnapshots: [AgentRunMCPSnapshot],
        wakeReason: AgentRunSessionStore.WakeReason = .steeringRequested
    ) async -> Value {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        var snapshots = freshSnapshots.isEmpty ? latestSnapshots : freshSnapshots
        if snapshots.isEmpty {
            snapshots = [triggeringSnapshot]
        } else if snapshots.contains(where: { $0.sessionID == triggeringSnapshot.sessionID }) == false {
            snapshots.append(triggeringSnapshot)
        }
        let pendingIDs = pendingSessionIDs(from: snapshots)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        return Self.decoratedMultiWaitInterruptValue(
            sessionIDs: sessionIDs,
            representativeSnapshot: triggeringSnapshot,
            snapshots: snapshots,
            pendingSessionIDs: pendingIDs.isEmpty && !runningIDs.isEmpty ? runningIDs : pendingIDs,
            interruptedSessionID: triggeringSnapshot.sessionID,
            wakeReason: wakeReason
        )
    }

    /// Multi-wait value for a delegated child-question wake (plan §6.2), arbitrated and rendered
    /// over exactly one snapshot collection: an actionable or terminal child in `snapshots` wins
    /// (`snapshot_ready`/`expired`); otherwise the interrupt renders this same set, so an
    /// `interrupted_by_child_question` result never carries an actionable child snapshot.
    private nonisolated func delegatedQuestionMultiWaitValue(
        sessionIDs: [UUID],
        triggeringSnapshot: AgentRunMCPSnapshot,
        snapshots: [AgentRunMCPSnapshot]
    ) -> Value {
        if let ready = snapshots.first(where: { isInterestingSnapshot($0) }) {
            return decoratedMultiWaitValue(
                snapshot: ready, sessionIDs: sessionIDs,
                result: ready.status == .expired ? "expired" : "snapshot_ready",
                snapshots: snapshots, pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        }
        var rendered = snapshots
        if rendered.isEmpty {
            rendered = [triggeringSnapshot]
        } else if !rendered.contains(where: { $0.sessionID == triggeringSnapshot.sessionID }) {
            rendered.append(triggeringSnapshot)
        }
        let representative = rendered.first { $0.sessionID == triggeringSnapshot.sessionID } ?? triggeringSnapshot
        let pendingIDs = pendingSessionIDs(from: rendered)
        let runningIDs = rendered.filter { $0.status == .running }.map(\.sessionID)
        return Self.decoratedMultiWaitInterruptValue(
            sessionIDs: sessionIDs,
            representativeSnapshot: representative,
            snapshots: rendered,
            pendingSessionIDs: pendingIDs.isEmpty && !runningIDs.isEmpty ? runningIDs : pendingIDs,
            interruptedSessionID: triggeringSnapshot.sessionID,
            wakeReason: .delegatedQuestionPending
        )
    }

    private nonisolated static func decoratedMultiWaitInterruptValue(
        sessionIDs: [UUID],
        representativeSnapshot: AgentRunMCPSnapshot,
        snapshots: [AgentRunMCPSnapshot],
        pendingSessionIDs: [UUID],
        interruptedSessionID: UUID,
        wakeReason: AgentRunSessionStore.WakeReason = .steeringRequested
    ) -> Value {
        let delegated = wakeReason == .delegatedQuestionPending
        let note = delegated ? agentRunDelegatedQuestionWakeNote : agentRunSteeringWakeNote
        var object = representativeSnapshot.asObject()
        object.removeValue(forKey: "assistant_text")
        object["status_text"] = .string(
            delegated
                ? agentRunDelegatedQuestionWakeNote
                : "Wait interrupted by a new steering instruction; the agent run is still running."
        )
        object["_meta"] = .object([
            "wake_reason": .string(wakeReason.rawValue),
            "note": .string(note)
        ])
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string(delegated ? AgentDelegatedQuestionNoticeWire.agentRunWaitResult : "interrupted_by_steering"),
            "winner_session_id": .null,
            "interrupted_session_id": .string(interruptedSessionID.uuidString),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(pendingSessionIDs.map { .string($0.uuidString) }),
            "instruction": .string(note)
        ])
        object["snapshots"] = .array(snapshots.map { snapshot in
            var snapshotObject = snapshot.asObject()
            if !snapshot.status.isTerminal {
                snapshotObject.removeValue(forKey: "assistant_text")
            }
            return .object(snapshotObject)
        })
        return .object(object)
    }

    private nonisolated func waitForAnyInterestingState(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        timeoutSeconds: TimeInterval,
        initialSnapshots: [AgentRunMCPSnapshot],
        includeStatusUpdates: Bool = false,
        hasDeliverableDelegatedQuestion: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> Value {
        let (cursors, liveUnregisteredIDs) = await MainActor.run {
            (
                sessionIDs.compactMap { agentModeVM.mcpWaitCursor(sessionID: $0) },
                sessionIDs.filter { isLiveUnregisteredWaitTarget(sessionID: $0, agentModeVM: agentModeVM) }
            )
        }
        guard !cursors.isEmpty else {
            return decoratedMultiWaitValue(
                snapshot: Self.agentRunExpiredSnapshot(sessionID: sessionIDs[0]),
                sessionIDs: sessionIDs,
                result: "expired",
                pendingSessionIDs: sessionIDs
            )
        }
        // A mixed wait (controlled plus live unregistered targets) adds one sampling lane per
        // unregistered target to the controlled cursor lanes, so either kind of target can win.
        let baselineKeys: [UUID: String?] = Dictionary(
            initialSnapshots.map { ($0.sessionID, Self.normalizedStatusTextKey($0.statusText)) },
            uniquingKeysWith: { first, _ in first }
        )
        let samplingLanes: [(UUID, @Sendable () async -> WaitAnyResult)] = liveUnregisteredIDs.map { sessionID in
            let baselineKey = baselineKeys[sessionID] ?? nil
            return (sessionID, { [self] in
                await sampleLiveUnregisteredWaitAnyLane(
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    timeoutSeconds: timeoutSeconds,
                    includeStatusUpdates: includeStatusUpdates,
                    baselineKey: baselineKey
                )
            })
        }
        let result = await Self.waitUntilFirstActionable(
            cursors: cursors,
            fallbackSessionID: sessionIDs[0],
            timeoutSeconds: timeoutSeconds,
            includeStatusUpdates: includeStatusUpdates,
            hasDeliverableDelegatedQuestion: hasDeliverableDelegatedQuestion,
            additionalLanes: samplingLanes
        )
        let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        switch result.disposition {
        case let .actionable(snapshot):
            return decoratedMultiWaitValue(
                snapshot: snapshot,
                sessionIDs: sessionIDs,
                result: snapshot.status == .expired ? "expired" : "snapshot_ready",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != snapshot.sessionID }
            )
        case let .steeringInterrupted(snapshot):
            return await waitAnySteeringInterruptValue(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                triggeringSnapshot: snapshot,
                latestSnapshots: snapshots
            )
        case let .delegatedQuestionInterrupted(snapshot):
            // Arbitrated and rendered over this single post-wake collection: an actionable or
            // terminal child in it always wins, and no second refresh can render an interrupt over
            // a completion that was never arbitrated.
            return delegatedQuestionMultiWaitValue(
                sessionIDs: sessionIDs,
                triggeringSnapshot: snapshot,
                snapshots: snapshots
            )
        case let .superseded(snapshot):
            return decoratedMultiWaitSupersededValue(
                snapshot: snapshot,
                sessionIDs: sessionIDs,
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case let .statusUpdate(snapshot):
            let representative = snapshots.first { $0.sessionID == snapshot.sessionID } ?? snapshot
            return decoratedMultiWaitValue(
                snapshot: representative,
                sessionIDs: sessionIDs,
                result: "status_update",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != snapshot.sessionID }
            )
        case let .terminalPublicationRejected(reason):
            throw MCPError.internalError("An agent run terminal state could not be published: \(reason)")
        case .timedOut:
            let representative = snapshots.first(where: \.isStartupPendingForMCPWait) ?? snapshots.first ?? initialSnapshots[0]
            return decoratedMultiWaitValue(
                snapshot: representative,
                sessionIDs: sessionIDs,
                result: representative.isStartupPendingForMCPWait ? "startup_pending" : "timed_out",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case .expired:
            return decoratedMultiWaitValue(
                snapshot: Self.agentRunExpiredSnapshot(sessionID: result.sessionID),
                sessionIDs: sessionIDs,
                result: "expired",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots)
            )
        case .cancelled:
            if let value = await waitAnyCancellationValueIfActionable(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                fallbackSnapshots: snapshots
            ) {
                return value
            }
            throw CancellationError()
        }
    }

    private nonisolated static func waitUntilFirstActionable(
        cursors: [AgentRunSessionStore.WaitCursor],
        fallbackSessionID: UUID,
        timeoutSeconds: TimeInterval,
        includeStatusUpdates: Bool = false,
        hasDeliverableDelegatedQuestion: @escaping @Sendable () async -> Bool = { false },
        additionalLanes: [(UUID, @Sendable () async -> WaitAnyResult)] = []
    ) async -> WaitAnyResult {
        var operations: [@Sendable () async -> WaitAnyResult] = cursors.map { cursor in
            { await Self.waitUntilActionable(
                cursor: cursor,
                timeoutSeconds: timeoutSeconds,
                includeStatusUpdates: includeStatusUpdates,
                hasDeliverableDelegatedQuestion: hasDeliverableDelegatedQuestion
            ) }
        }
        operations.append(contentsOf: additionalLanes.map { _, operation in operation })
        return await resolveFirstWaitAny(
            operations: operations,
            sessionOrder: cursors.map(\.registration.sessionID) + additionalLanes.map { sessionID, _ in sessionID },
            fallbackSessionID: fallbackSessionID
        )
    }

    private nonisolated static func resolveFirstWaitAny(
        operations: [@Sendable () async -> WaitAnyResult],
        sessionOrder: [UUID],
        fallbackSessionID: UUID,
        afterCancelAll: (@Sendable () async -> Void)? = nil
    ) async -> WaitAnyResult {
        let clock = ContinuousClock()
        return await withTaskGroup(of: TimestampedWaitAnyResult.self) { group in
            for operation in operations {
                group.addTask {
                    let result = await operation()
                    return TimestampedWaitAnyResult(result: result, completedAt: clock.now)
                }
            }
            guard let first = await group.next() else {
                return WaitAnyResult(sessionID: fallbackSessionID, disposition: .expired)
            }
            let cutoff = clock.now
            var resolvedResults = [first.result]
            group.cancelAll()
            await afterCancelAll?()
            while let candidate = await group.next() {
                guard candidate.completedAt <= cutoff else { continue }
                resolvedResults.append(candidate.result)
            }
            return Self.arbitrateWaitAnyResults(
                resolvedResults,
                sessionOrder: sessionOrder,
                fallbackSessionID: fallbackSessionID
            )
        }
    }

    private nonisolated static func waitUntilActionable(
        cursor initialCursor: AgentRunSessionStore.WaitCursor,
        timeoutSeconds: TimeInterval,
        includeStatusUpdates: Bool = false,
        hasDeliverableDelegatedQuestion: @escaping @Sendable () async -> Bool = { false }
    ) async -> WaitAnyResult {
        let sessionID = initialCursor.registration.sessionID
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        // Same accepted staleness window as the single-session wait: baseline is
        // captured once per call; changes racing the capture surface on the next
        // change or timeout sample.
        let baselineKey = await includeStatusUpdates
            ? normalizedStatusTextKey((AgentRunSessionStore.snapshot(for: initialCursor))?.statusText)
            : nil
        var cursor = initialCursor
        if !Task.isCancelled, await hasDeliverableDelegatedQuestion(),
           let snapshot = await AgentRunSessionStore.snapshot(for: cursor)
        {
            return WaitAnyResult(
                sessionID: sessionID,
                disposition: snapshot.isActionableForMCPWait ? .actionable(snapshot) : .delegatedQuestionInterrupted(snapshot)
            )
        }
        while true {
            if Task.isCancelled {
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
            let remaining = timeInterval(from: clock.now.duration(to: deadline))
            guard remaining > 0 else {
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            }
            let sliceTimeout = includeStatusUpdates
                ? min(remaining, resolvedStatusUpdateSliceSeconds)
                : remaining
            let disposition = await AgentRunSessionStore.waitUntilInteresting(
                cursor: cursor,
                timeoutSeconds: sliceTimeout
            )
            switch disposition {
            case let .snapshotReady(snapshot):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
            case let .noteworthySnapshot(snapshot, reason):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
                if reason == .steeringRequested {
                    return WaitAnyResult(sessionID: sessionID, disposition: .steeringInterrupted(snapshot))
                }
                if reason == .delegatedQuestionPending, await hasDeliverableDelegatedQuestion() {
                    return WaitAnyResult(sessionID: sessionID, disposition: .delegatedQuestionInterrupted(snapshot))
                }
            case let .epochAdvanced(epoch, transitionKind):
                if transitionKind == .unrelated {
                    let snapshot = await AgentRunSessionStore.snapshot(
                        for: .init(registration: cursor.registration, epoch: epoch)
                    ) ?? Self.agentRunExpiredSnapshot(sessionID: sessionID)
                    return WaitAnyResult(sessionID: sessionID, disposition: .superseded(snapshot))
                }
                cursor = .init(registration: cursor.registration, epoch: epoch)
            case let .terminalPublicationRejected(_, reason):
                return WaitAnyResult(sessionID: sessionID, disposition: .terminalPublicationRejected(reason))
            case .timedOut:
                let remainingAfterSlice = timeInterval(from: clock.now.duration(to: deadline))
                if includeStatusUpdates, remainingAfterSlice > 0 {
                    let latest = await AgentRunSessionStore.snapshot(for: cursor)
                    if shouldReturnStatusUpdate(baselineKey: baselineKey, latest: latest), let latest {
                        return WaitAnyResult(sessionID: sessionID, disposition: .statusUpdate(latest))
                    }
                    continue
                }
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            case .expired:
                return WaitAnyResult(sessionID: sessionID, disposition: .expired)
            case .cancelled:
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
        }
    }

    private nonisolated static func arbitrateWaitAnyResults(
        _ results: [WaitAnyResult],
        sessionOrder: [UUID],
        fallbackSessionID: UUID
    ) -> WaitAnyResult {
        guard !results.isEmpty else {
            return WaitAnyResult(sessionID: fallbackSessionID, disposition: .expired)
        }
        let order = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($1, $0) })
        return results.min { lhs, rhs in
            let lhsPriority = arbitrationPriority(lhs.disposition)
            let rhsPriority = arbitrationPriority(rhs.disposition)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return order[lhs.sessionID, default: Int.max] < order[rhs.sessionID, default: Int.max]
        } ?? results[0]
    }

    private nonisolated static func arbitrationPriority(_ disposition: MultiWaitDisposition) -> Int {
        switch disposition {
        case .terminalPublicationRejected:
            0
        case .steeringInterrupted:
            1
        case .actionable:
            2
        case .superseded:
            3
        case .expired:
            4
        case .delegatedQuestionInterrupted:
            5
        case .statusUpdate:
            6
        case .timedOut:
            7
        case .cancelled:
            8
        }
    }

    #if DEBUG
        static func test_decoratedMultiWaitInterruptValue(
            sessionIDs: [UUID],
            representativeSnapshot: AgentRunMCPSnapshot? = nil,
            snapshots: [AgentRunMCPSnapshot],
            pendingSessionIDs: [UUID],
            interruptedSessionID: UUID
        ) -> Value {
            decoratedMultiWaitInterruptValue(
                sessionIDs: sessionIDs,
                representativeSnapshot: representativeSnapshot
                    ?? snapshots.first { $0.sessionID == interruptedSessionID }
                    ?? agentRunExpiredSnapshot(sessionID: interruptedSessionID),
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs,
                interruptedSessionID: interruptedSessionID
            )
        }

        static func test_waitAnyCutoffExcludesPostCancellationSteering(
            actionableSessionID: UUID,
            steeringSessionID: UUID
        ) async -> (sessionID: UUID, disposition: String) {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let operations: [@Sendable () async -> WaitAnyResult] = [
                {
                    WaitAnyResult(
                        sessionID: actionableSessionID,
                        disposition: .actionable(Self.agentRunExpiredSnapshot(sessionID: actionableSessionID))
                    )
                },
                {
                    for await _ in stream {
                        break
                    }
                    return WaitAnyResult(
                        sessionID: steeringSessionID,
                        disposition: .steeringInterrupted(Self.agentRunExpiredSnapshot(sessionID: steeringSessionID))
                    )
                }
            ]
            let result = await resolveFirstWaitAny(
                operations: operations,
                sessionOrder: [actionableSessionID, steeringSessionID],
                fallbackSessionID: actionableSessionID,
                afterCancelAll: {
                    continuation.yield()
                    continuation.finish()
                }
            )
            let disposition = switch result.disposition {
            case .actionable: "actionable"
            case .steeringInterrupted: "steering_interrupted"
            case .delegatedQuestionInterrupted: "delegated_question_interrupted"
            default: "other"
            }
            return (result.sessionID, disposition)
        }

        static func test_expiredWaitValue(sessionID: UUID) -> Value {
            expiredWaitValue(sessionID: sessionID)
        }

        static func test_waitUntilActionableDisposition(
            sessionID: UUID,
            timeoutSeconds: TimeInterval,
            hasDeliverableDelegatedQuestion: @escaping @Sendable () async -> Bool = { false }
        ) async -> (disposition: String, wakeReason: String?, sessionID: UUID, snapshotStatus: String?) {
            guard let registration = await AgentRunSessionStore.currentRegistration(for: sessionID),
                  let cursor = await AgentRunSessionStore.currentCursor(for: registration)
            else {
                return ("expired", nil, sessionID, nil)
            }
            let result = await waitUntilActionable(cursor: cursor, timeoutSeconds: timeoutSeconds, hasDeliverableDelegatedQuestion: hasDeliverableDelegatedQuestion)
            switch result.disposition {
            case let .actionable(snapshot):
                return ("actionable", nil, result.sessionID, snapshot.status.rawValue)
            case let .steeringInterrupted(snapshot):
                return (
                    "steering_interrupted",
                    AgentRunSessionStore.WakeReason.steeringRequested.rawValue,
                    result.sessionID,
                    snapshot.status.rawValue
                )
            case let .delegatedQuestionInterrupted(snapshot):
                return (
                    "delegated_question_interrupted",
                    AgentRunSessionStore.WakeReason.delegatedQuestionPending.rawValue,
                    result.sessionID,
                    snapshot.status.rawValue
                )
            case let .superseded(snapshot):
                return ("superseded", "superseded_turn", result.sessionID, snapshot.status.rawValue)
            case let .statusUpdate(snapshot):
                return ("status_update", nil, result.sessionID, snapshot.status.rawValue)
            case .terminalPublicationRejected:
                return ("publication_rejected", nil, result.sessionID, nil)
            case .timedOut:
                return ("timed_out", nil, result.sessionID, nil)
            case .expired:
                return ("expired", nil, result.sessionID, nil)
            case .cancelled:
                return ("cancelled", nil, result.sessionID, nil)
            }
        }

        static func test_waitUntilFirstActionableDisposition(
            sessionIDs: [UUID],
            timeoutSeconds: TimeInterval,
            hasDeliverableDelegatedQuestion: @escaping @Sendable () async -> Bool = { false }
        ) async -> (sessionID: UUID, disposition: String) {
            var cursors: [AgentRunSessionStore.WaitCursor] = []
            for sessionID in sessionIDs {
                guard let registration = await AgentRunSessionStore.currentRegistration(for: sessionID),
                      let cursor = await AgentRunSessionStore.currentCursor(for: registration)
                else { continue }
                cursors.append(cursor)
            }
            let result = await waitUntilFirstActionable(
                cursors: cursors,
                fallbackSessionID: sessionIDs[0],
                timeoutSeconds: timeoutSeconds,
                hasDeliverableDelegatedQuestion: hasDeliverableDelegatedQuestion
            )
            let disposition = switch result.disposition {
            case .terminalPublicationRejected: "publication_rejected"
            case .steeringInterrupted: "steering_interrupted"
            case .delegatedQuestionInterrupted: "delegated_question_interrupted"
            case .actionable: "actionable"
            case .superseded: "superseded"
            case .expired: "expired"
            case .statusUpdate: "status_update"
            case .timedOut: "timed_out"
            case .cancelled: "cancelled"
            }
            return (result.sessionID, disposition)
        }

        static func test_arbitrateWaitAnyDisposition(
            sessionIDs: [UUID],
            candidates: [(sessionID: UUID, disposition: String)]
        ) -> (sessionID: UUID, disposition: String) {
            let results = candidates.compactMap { candidate -> WaitAnyResult? in
                let snapshot = Self.agentRunExpiredSnapshot(sessionID: candidate.sessionID)
                let disposition: MultiWaitDisposition
                switch candidate.disposition {
                case "publication_rejected":
                    disposition = .terminalPublicationRejected("test")
                case "steering_interrupted":
                    disposition = .steeringInterrupted(snapshot)
                case "delegated_question_interrupted":
                    disposition = .delegatedQuestionInterrupted(snapshot)
                case "actionable":
                    disposition = .actionable(snapshot)
                case "superseded":
                    disposition = .superseded(snapshot)
                case "expired":
                    disposition = .expired
                case "status_update":
                    disposition = .statusUpdate(snapshot)
                case "timed_out":
                    disposition = .timedOut
                case "cancelled":
                    disposition = .cancelled
                default:
                    return nil
                }
                return WaitAnyResult(sessionID: candidate.sessionID, disposition: disposition)
            }
            let fallbackSessionID = sessionIDs.first ?? candidates.first?.sessionID ?? UUID()
            let result = arbitrateWaitAnyResults(
                results,
                sessionOrder: sessionIDs,
                fallbackSessionID: fallbackSessionID
            )
            let disposition = switch result.disposition {
            case .terminalPublicationRejected: "publication_rejected"
            case .steeringInterrupted: "steering_interrupted"
            case .delegatedQuestionInterrupted: "delegated_question_interrupted"
            case .actionable: "actionable"
            case .superseded: "superseded"
            case .expired: "expired"
            case .statusUpdate: "status_update"
            case .timedOut: "timed_out"
            case .cancelled: "cancelled"
            }
            return (result.sessionID, disposition)
        }
    #endif

    private nonisolated static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private nonisolated func waitScopeCompletion(from value: Value, fallbackSessionIDs: [UUID]) -> AgentRunWaitScopeCompletion {
        let object = value.objectValue
        let wait = object?["wait"]?.objectValue
        let result = wait?["result"]?.stringValue
        let winnerSessionID = wait?["winner_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let pendingSessionIDs = Set(wait?["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? fallbackSessionIDs)
        let reason: AgentRunWaitScopeCompletion.Reason = switch result {
        case "timed_out": .timedOut
        case "startup_pending": .startupPending
        case "expired": .expired
        case "status_update": .statusUpdate
        case "superseded": .superseded
        case "cancelled", "interrupted_by_steering": .cancelled
        case AgentDelegatedQuestionNoticeWire.agentRunWaitResult: .delegatedQuestionPending
        case "error": .error
        default: .snapshotReady
        }
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: result,
            winnerSessionID: winnerSessionID,
            pendingSessionIDs: pendingSessionIDs,
            errorDescription: nil
        )
    }

    private nonisolated func singleWaitScopeCompletion(from value: Value, sessionID: UUID) -> AgentRunWaitScopeCompletion {
        let status = value.objectValue?["status"]?.stringValue.flatMap(AgentRunMCPSnapshot.Status.init(rawValue:))
        let waitResult = Self.waitResult(from: value)
        let reason: AgentRunWaitScopeCompletion.Reason = if waitResult == "startup_pending" {
            .startupPending
        } else if waitResult == "timed_out" {
            .timedOut
        } else if waitResult == AgentDelegatedQuestionNoticeWire.agentRunWaitResult {
            .delegatedQuestionPending
        } else if status == .expired {
            .expired
        } else {
            .snapshotReady
        }
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: waitResult ?? reason.rawValue,
            winnerSessionID: status == .expired || reason == .timedOut || reason == .startupPending || reason == .delegatedQuestionPending ? nil : sessionID,
            pendingSessionIDs: reason == .timedOut || reason == .startupPending || reason == .delegatedQuestionPending ? [sessionID] : [],
            errorDescription: nil
        )
    }

    private func decoratedRunValue(
        snapshot: AgentRunMCPSnapshot,
        workflow: AgentWorkflowDefinition? = nil,
        delivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        wakeReason: AgentRunSessionStore.WakeReason? = nil,
        warning: String? = nil
    ) -> Value {
        var object = snapshot.asObject()
        if let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty {
            object["warning"] = .string(warning)
        }
        if let workflow {
            object["workflow_id"] = .string(workflow.id)
            object["workflow_name"] = .string(workflow.displayName)
        }
        if let meta = metadataObject(for: snapshot, delivery: delivery, wakeReason: wakeReason) {
            object["_meta"] = .object(meta)
        }
        // After a steer dispatch into an active run, the assistant_text is from the
        // *previous* turn and would confuse the caller into thinking the steer produced
        // no new output.  Strip it so the caller sees a clean "instruction accepted" response.
        if !snapshot.status.isTerminal,
           delivery?.isActiveRunDispatch == true || wakeReason?.suppressesAssistantPreview == true
        {
            object.removeValue(forKey: "assistant_text")
        }
        if wakeReason == .steeringRequested {
            object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
            object["wait"] = .object([
                "result": .string("interrupted_by_steering"),
                "instruction": .string(agentRunSteeringWakeNote)
            ])
        }
        if wakeReason == .delegatedQuestionPending {
            object["status_text"] = .string(agentRunDelegatedQuestionWakeNote)
            object["wait"] = .object([
                "result": .string(AgentDelegatedQuestionNoticeWire.agentRunWaitResult),
                "instruction": .string(agentRunDelegatedQuestionWakeNote)
            ])
        }
        if wakeReason == .interactionResolved {
            object["wait"] = .object([
                "result": .string("interaction_resolved")
            ])
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiWaitValue(
        snapshot: AgentRunMCPSnapshot,
        sessionIDs: [UUID],
        result: String,
        snapshots: [AgentRunMCPSnapshot]? = nil,
        pendingSessionIDs: [UUID]? = nil
    ) -> Value {
        var object = snapshot.asObject()
        object["_meta"] = .object(["wait_result": .string(result)])
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string(result),
            "winner_session_id": result == "timed_out" || result == "startup_pending" || result == "expired" || result == "superseded"
                ? .null : .string(snapshot.sessionID.uuidString),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(
                (pendingSessionIDs ?? sessionIDs.filter { $0 != snapshot.sessionID }).map { .string($0.uuidString) }
            ),
            "instruction": .null
        ])
        if let snapshots {
            object["snapshots"] = .array(snapshots.map { .object(multiSnapshotObject($0)) })
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiWaitSupersededValue(
        snapshot: AgentRunMCPSnapshot,
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot],
        pendingSessionIDs: [UUID]
    ) -> Value {
        let value = decoratedMultiWaitValue(
            snapshot: snapshot,
            sessionIDs: sessionIDs,
            result: "superseded",
            snapshots: snapshots,
            pendingSessionIDs: pendingSessionIDs
        )
        guard var object = value.objectValue else { return value }
        var meta = object["_meta"]?.objectValue ?? [:]
        meta["wake_reason"] = .string("superseded_turn")
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private nonisolated func decoratedMultiPollValue(
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot]
    ) -> Value {
        let interestingIDs = snapshots.filter { isInterestingSnapshot($0) }.map(\.sessionID)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        let terminalIDs = snapshots.filter(\.status.isTerminal).map(\.sessionID)
        return .object([
            "poll": .object([
                "mode": .string("many"),
                "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
                "polled_count": .int(sessionIDs.count),
                "interesting_session_ids": .array(interestingIDs.map { .string($0.uuidString) }),
                "running_session_ids": .array(runningIDs.map { .string($0.uuidString) }),
                "terminal_session_ids": .array(terminalIDs.map { .string($0.uuidString) })
            ]),
            "snapshots": .array(snapshots.map { .object(multiSnapshotObject($0)) })
        ])
    }

    private nonisolated func multiSnapshotObject(_ snapshot: AgentRunMCPSnapshot) -> [String: Value] {
        var object = snapshot.asObject()
        if let resolution = snapshot.lastInteractionResolution {
            var metadata = object["_meta"]?.objectValue ?? [:]
            metadata["interaction_resolved"] = .object(resolution.asObject())
            object["_meta"] = .object(metadata)
        }
        return object
    }

    private func metadataObject(
        for snapshot: AgentRunMCPSnapshot,
        delivery: AgentModeViewModel.MCPInstructionDispatch?,
        wakeReason: AgentRunSessionStore.WakeReason?
    ) -> [String: Value]? {
        guard !snapshot.status.isTerminal else { return nil }
        var metadata: [String: Value] = [:]
        if let delivery {
            switch delivery {
            case .queuedFollowUp, .queuedClaudeInterrupt, .queuedACPInterrupt, .deliveredIntoWaitingContinuation, .dispatchedCodexTurn:
                metadata["delivery"] = .string(delivery.rawValue)
            case .startedRun:
                break
            }
        }
        if let resolution = snapshot.lastInteractionResolution {
            metadata["interaction_resolved"] = .object(resolution.asObject())
        }
        if let wakeReason {
            metadata["wake_reason"] = .string(wakeReason.rawValue)
            if wakeReason == .steeringRequested {
                metadata["note"] = .string(agentRunSteeringWakeNote)
            } else if wakeReason == .delegatedQuestionPending {
                metadata["note"] = .string(agentRunDelegatedQuestionWakeNote)
            }
        }
        return metadata.isEmpty ? nil : metadata
    }

    private func wakeReason(from object: [String: Value]) -> AgentRunSessionStore.WakeReason? {
        guard let raw = object["_meta"]?.objectValue?["wake_reason"]?.stringValue else { return nil }
        return AgentRunSessionStore.WakeReason(rawValue: raw)
    }

    /// Question snapshots already visible in an agent_run result acknowledge their notice
    /// at handoff without duplicating its text. Handles single, wait_any, and poll-many shapes.
    nonisolated static func coveredDelegatedQuestionNoticeKeys(in value: Value) -> Set<AgentDelegatedQuestionNoticeKey> {
        guard let object = value.objectValue else { return [] }
        let snapshots = [value] + (object["snapshots"]?.arrayValue ?? [])
        return Set(snapshots.compactMap { snapshot in
            guard let child = snapshot.objectValue,
                  let sessionID = child["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let interaction = child["interaction"]?.objectValue,
                  interaction["kind"]?.stringValue == "question",
                  let interactionID = interaction["id"]?.stringValue.flatMap(UUID.init(uuidString:))
            else { return nil }
            return AgentDelegatedQuestionNoticeKey(childSessionID: sessionID, interactionID: interactionID)
        })
    }

    static func snapshot(from object: [String: Value]) -> AgentRunMCPSnapshot? {
        guard let sessionIDRaw = object["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: sessionIDRaw),
              let statusRaw = object["status"]?.stringValue,
              let status = AgentRunMCPSnapshot.Status(rawValue: statusRaw)
        else {
            return nil
        }
        let session = object["session"]?.objectValue
        let agent = object["agent"]?.objectValue
        let runID = object["run_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let interaction = object["interaction"]?.objectValue.flatMap(Self.interaction(from:))
        let updatedAt = object["updated_at"]?.stringValue.flatMap(Self.timestampFormatter.date(from:)) ?? Date()
        let tabID = (session?["context_id"] ?? session?["tab_id"])?.stringValue.flatMap(UUID.init(uuidString:))
        let parentSessionID = session?["parent_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let failureReason = object["failure_reason"]?.stringValue.flatMap(AgentRunMCPSnapshot.FailureReason.init(rawValue:))
        let worktreeBindings = Self.worktreeBindings(from: object)
        let activeWorktreeMerges = Self.activeWorktreeMerges(from: object)
        return AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: runID,
            tabID: tabID,
            sessionName: session?["name"]?.stringValue,
            agentRaw: agent?["id"]?.stringValue,
            agentDisplayName: agent?["name"]?.stringValue,
            modelRaw: agent?["model"]?.stringValue,
            reasoningEffortRaw: agent?["reasoning_effort"]?.stringValue,
            status: status,
            statusText: object["status_text"]?.stringValue,
            latestAssistantPreview: object["assistant_text"]?.stringValue,
            interaction: interaction,
            transcriptItemCount: object["transcript_item_count"]?.intValue ?? 0,
            updatedAt: updatedAt,
            parentSessionID: parentSessionID,
            failureReason: failureReason,
            followUpPending: object["followup_pending"]?.boolValue ?? false,
            worktreeBindings: worktreeBindings,
            activeWorktreeMerges: activeWorktreeMerges
        )
    }

    private static func activeWorktreeMerges(from object: [String: Value]) -> [AgentSessionWorktreeMergeSummary] {
        guard let values = object["active_worktree_merges"]?.arrayValue else { return [] }
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let statusRaw = object["status"]?.stringValue,
                  let status = AgentSessionWorktreeMergeOperation.Status(rawValue: statusRaw),
                  let repositoryID = object["repository_id"]?.stringValue,
                  let repoKey = object["repo_key"]?.stringValue,
                  let sourceWorktreeID = object["source_worktree_id"]?.stringValue,
                  let sourceLabel = object["source_label"]?.stringValue,
                  let sourcePath = object["source_path"]?.stringValue,
                  let targetWorktreeID = object["target_worktree_id"]?.stringValue,
                  let targetLabel = object["target_label"]?.stringValue,
                  let targetPath = object["target_path"]?.stringValue,
                  let updatedAtRaw = object["updated_at"]?.stringValue,
                  let updatedAt = Self.timestampFormatter.date(from: updatedAtRaw)
            else { return nil }
            return AgentSessionWorktreeMergeSummary(
                id: id,
                status: status,
                sourceWorktreeID: sourceWorktreeID,
                sourceLabel: sourceLabel,
                sourceBranch: object["source_branch"]?.stringValue,
                sourcePath: sourcePath,
                targetWorktreeID: targetWorktreeID,
                targetLabel: targetLabel,
                targetBranch: object["target_branch"]?.stringValue,
                targetPath: targetPath,
                repositoryID: repositoryID,
                repoKey: repoKey,
                conflictFileCount: object["conflict_file_count"]?.intValue ?? 0,
                updatedAt: updatedAt
            )
        }
    }

    private static func worktreeBindings(from object: [String: Value]) -> [AgentRunMCPSnapshot.WorktreeBinding] {
        if let values = object["worktree_bindings"]?.arrayValue {
            return values.compactMap { value in
                guard let object = value.objectValue else { return nil }
                return worktreeBinding(from: object)
            }
        }
        if let object = object["worktree"]?.objectValue,
           let binding = Self.worktreeBinding(from: object)
        {
            return [binding]
        }
        return []
    }

    private static func worktreeBinding(from object: [String: Value]) -> AgentRunMCPSnapshot.WorktreeBinding? {
        guard let id = object["id"]?.stringValue,
              let repositoryID = object["repository_id"]?.stringValue,
              let repoKey = object["repo_key"]?.stringValue,
              let logicalRootPath = object["logical_root_path"]?.stringValue,
              let worktreeID = object["worktree_id"]?.stringValue,
              let worktreeRootPath = object["worktree_root_path"]?.stringValue,
              let boundAtRaw = object["bound_at"]?.stringValue,
              let boundAt = timestampFormatter.date(from: boundAtRaw),
              let source = object["source"]?.stringValue
        else {
            return nil
        }
        return AgentRunMCPSnapshot.WorktreeBinding(
            id: id,
            repositoryID: repositoryID,
            repoKey: repoKey,
            logicalRootPath: logicalRootPath,
            logicalRootName: object["logical_root_name"]?.stringValue,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: object["worktree_name"]?.stringValue,
            branch: object["branch"]?.stringValue,
            head: object["head"]?.stringValue,
            visualLabel: object["visual_label"]?.stringValue,
            visualColorHex: object["visual_color_hex"]?.stringValue,
            boundAt: boundAt,
            source: source,
            unavailable: object["unavailable"]?.boolValue ?? false
        )
    }

    private static func interaction(from object: [String: Value]) -> AgentRunMCPSnapshot.Interaction? {
        guard let idRaw = object["id"]?.stringValue,
              let id = UUID(uuidString: idRaw),
              let kindRaw = object["kind"]?.stringValue,
              let kind = AgentRunMCPSnapshot.Interaction.Kind(rawValue: kindRaw),
              let responseTypeRaw = object["response_type"]?.stringValue,
              let responseType = AgentRunMCPSnapshot.Interaction.ResponseType(rawValue: responseTypeRaw)
        else {
            return nil
        }
        let options = object["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
            guard let optionObject = option.objectValue,
                  let label = optionObject["label"]?.stringValue else { return nil }
            return .init(label: label, description: optionObject["description"]?.stringValue)
        } ?? []
        let fields = object["fields"]?.arrayValue?.compactMap { field -> AgentRunMCPSnapshot.Interaction.Field? in
            guard let fieldObject = field.objectValue,
                  let id = fieldObject["id"]?.stringValue,
                  let prompt = fieldObject["prompt"]?.stringValue else { return nil }
            let fieldOptions = fieldObject["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
                guard let optionObject = option.objectValue,
                      let label = optionObject["label"]?.stringValue else { return nil }
                return .init(label: label, description: optionObject["description"]?.stringValue)
            } ?? []
            // `ask_user` fields encode `allows_custom` and omit `allows_other`; preserve that shape.
            let allowsOther = fieldObject["allows_other"]?.boolValue
            let allowsCustom = fieldObject["allows_custom"]?.boolValue
            return .init(
                id: id,
                header: fieldObject["header"]?.stringValue,
                prompt: prompt,
                context: fieldObject["context"]?.stringValue,
                isSecret: fieldObject["is_secret"]?.boolValue == true,
                allowsOther: allowsOther ?? allowsCustom ?? false,
                allowsMultiple: fieldObject["allows_multiple"]?.boolValue,
                allowsCustom: allowsCustom,
                emitAllowsOther: allowsOther != nil,
                options: fieldOptions
            )
        } ?? []
        let details = object["details"]?.arrayValue?.compactMap { detail -> AgentRunMCPSnapshot.Interaction.Detail? in
            guard let detailObject = detail.objectValue,
                  let label = detailObject["label"]?.stringValue,
                  let value = detailObject["value"]?.stringValue else { return nil }
            return .init(label: label, value: value, isCode: detailObject["is_code"]?.boolValue == true)
        } ?? []
        return .init(
            id: id,
            kind: kind,
            responseType: responseType,
            title: object["title"]?.stringValue,
            prompt: object["prompt"]?.stringValue,
            context: object["context"]?.stringValue,
            allowsMultiple: object["allows_multiple"]?.boolValue,
            options: options,
            fields: fields,
            details: details
        )
    }

    private func collectCurrentSnapshots(sessionIDs: [UUID], agentModeVM: AgentModeViewModel) async -> [AgentRunMCPSnapshot] {
        var snapshots: [AgentRunMCPSnapshot] = []
        snapshots.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            await snapshots.append(currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM))
        }
        return snapshots
    }

    private nonisolated func isInterestingSnapshot(_ snapshot: AgentRunMCPSnapshot) -> Bool {
        snapshot.isActionableForMCPWait
    }

    private nonisolated func pendingSessionIDs(from snapshots: [AgentRunMCPSnapshot]) -> [UUID] {
        snapshots.filter { !isInterestingSnapshot($0) }.map(\.sessionID)
    }

    static func preferredSnapshotWhenStoredTerminal(
        stored: AgentRunMCPSnapshot,
        live: AgentRunMCPSnapshot?
    ) -> AgentRunMCPSnapshot {
        if let live, !live.status.isTerminal {
            return live
        }
        return stored
    }

    /// `unregisteredRunIdentity` controls only whether the live unregistered projection reports the
    /// session's current `run_id` (so a paired device can guard its Stop). The OMP qualification
    /// transaction passes false: its run identity authority is the registration-bound snapshot, and
    /// a run-ID-less unregistered fallback must keep failing closed as `run_identity_missing`.
    private func currentSnapshot(
        sessionID: UUID,
        registration suppliedRegistration: AgentRunSessionStore.Registration? = nil,
        agentModeVM: AgentModeViewModel,
        unregisteredRunIdentity: Bool = true
    ) async -> AgentRunMCPSnapshot {
        let registration = suppliedRegistration ?? agentModeVM.mcpRegistration(sessionID: sessionID)
        let storedSnapshot: AgentRunMCPSnapshot? = if let registration {
            await AgentRunSessionStore.snapshot(for: registration)
        } else {
            nil
        }
        if let storedSnapshot, storedSnapshot.status.isTerminal {
            // Incident 2026-07-09: remote-client-premature-terminal-and-model-label-2026-07-09.md.
            // Stored turn-terminal snapshots must not outrank the live follow-up/superseding running mask.
            // This also intentionally lets mcpSnapshot's stale-mask hygiene run on poll paths that used to short-circuit.
            let liveSnapshot = registration.flatMap { agentModeVM.mcpSnapshot(registration: $0) }
            return Self.preferredSnapshotWhenStoredTerminal(stored: storedSnapshot, live: liveSnapshot)
        }
        if let providedSnapshot = await currentSnapshotProvider?(sessionID, agentModeVM) {
            return providedSnapshot
        }
        guard let registration else {
            // No MCP registration: the live session (true run state and pending interaction)
            // outranks the last saved index entry, which is only a cold-session fallback.
            if let liveSnapshot = liveUnregisteredSessionSnapshot(
                sessionID: sessionID,
                agentModeVM: agentModeVM,
                includesRunIdentity: unregisteredRunIdentity
            ) {
                return liveSnapshot
            }
            if let indexedSnapshot = indexedSessionSnapshot(sessionID: sessionID, agentModeVM: agentModeVM) {
                return indexedSnapshot
            }
            return Self.agentRunExpiredSnapshot(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot {
            return storedSnapshot
        }
        if let indexedSnapshot = indexedSessionSnapshot(sessionID: sessionID, agentModeVM: agentModeVM) {
            return indexedSnapshot
        }
        if let liveSnapshot = liveUnregisteredSessionSnapshot(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            includesRunIdentity: unregisteredRunIdentity
        ) {
            return liveSnapshot
        }
        return Self.agentRunExpiredSnapshot(sessionID: sessionID)
    }

    /// A session that is live in the window (bound to an open tab) but has no MCP control
    /// registration, for example a user-driven desktop root or a fork-staged destination that has
    /// never run. It outranks the session index (plan 2026-10-30 Step 1): it reports the true
    /// running / waiting status and the structured pending interaction, so a paired remote sees
    /// what the desktop sees. Settled states keep the indexed vocabulary (incident 2026-07-27:
    /// a live session is never reported as expired). Truly unknown/deleted sessions still
    /// synthesize expired.
    private func liveUnregisteredSessionSnapshot(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        includesRunIdentity: Bool
    ) -> AgentRunMCPSnapshot? {
        guard let live = (try? agentModeVM.authoritativeLiveSession(for: sessionID)) ?? nil,
              live.activeAgentSessionID == sessionID
        else { return nil }
        let interaction = agentModeVM.mcpPendingInteraction(for: live)
        // An idle record whose persisted state is not loaded yet carries no settled outcome of its
        // own (it would read completed with no rows): its saved index entry supplies the last
        // recorded state (for example failed or cancelled). Live active/waiting state, a pending
        // interaction, and a never-indexed session keep the live projection.
        if !live.hasLoadedPersistedState,
           !live.runState.isActive,
           interaction == nil,
           agentModeVM.sessionIndex[sessionID] != nil
        {
            return nil
        }
        let status = Self.liveUnregisteredStatus(for: live, hasPendingInteraction: interaction != nil)
        let statusText: String? = if status.isTerminal {
            indexedSessionStatusText(rawState: live.runState.rawValue, status: status)
        } else if let running = live.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !running.isEmpty
        {
            running
        } else {
            nil
        }
        return AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: includesRunIdentity ? live.runID : nil,
            tabID: live.tabID,
            sessionName: agentModeVM.sessionIndex[sessionID]?.name,
            agentRaw: live.selectedAgent.rawValue,
            agentDisplayName: live.selectedAgent.displayName,
            modelRaw: live.selectedModelRaw,
            reasoningEffortRaw: live.selectedReasoningEffortRaw,
            status: status,
            statusText: statusText,
            latestAssistantPreview: nil,
            interaction: interaction,
            transcriptItemCount: live.transcriptProjectionCounts.canonicalVisibleRowCount,
            updatedAt: live.lastActivityAt,
            parentSessionID: live.parentSessionID,
            failureReason: AgentRunMCPSnapshot.FailureReason.classify(status: status, statusText: statusText),
            worktreeBindings: [],
            activeWorktreeMerges: live.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    /// The live session's own status, mapped like `AgentModeViewModel.mcpSnapshot(for:)`: a
    /// pending interaction or a waiting run state is `waiting_for_input`, a running run is
    /// `running`, and settled states keep their terminal status (idle reads as completed).
    private static func liveUnregisteredStatus(
        for live: AgentTabSession,
        hasPendingInteraction: Bool
    ) -> AgentRunMCPSnapshot.Status {
        if hasPendingInteraction {
            return .waitingForInput
        }
        switch live.runState {
        case .running:
            return .running
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return .waitingForInput
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .idle:
            switch live.transcript.turns.last?.terminalState {
            case .failed:
                return .failed
            case .cancelled:
                return .cancelled
            default:
                return .completed
            }
        }
    }

    private func indexedSessionSnapshot(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) -> AgentRunMCPSnapshot? {
        guard let entry = agentModeVM.sessionIndex[sessionID] else { return nil }
        let indexedStatus = indexedSessionStatus(from: entry.lastRunStateRaw)
        let statusText = indexedSessionStatusText(rawState: entry.lastRunStateRaw, status: indexedStatus)
        return AgentRunMCPSnapshot(
            sessionID: entry.id,
            tabID: entry.tabID,
            sessionName: entry.name,
            agentRaw: entry.agentKindRaw,
            agentDisplayName: entry.agentKindRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
            modelRaw: entry.agentModelRaw,
            reasoningEffortRaw: entry.agentReasoningEffortRaw,
            status: indexedStatus,
            statusText: statusText,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: entry.itemCount,
            updatedAt: entry.savedAt,
            parentSessionID: entry.parentSessionID,
            failureReason: AgentRunMCPSnapshot.FailureReason.classify(status: indexedStatus, statusText: statusText),
            worktreeBindings: [],
            activeWorktreeMerges: entry.activeWorktreeMergeSummaries
        )
    }

    private func indexedSessionStatus(from rawState: String?) -> AgentRunMCPSnapshot.Status {
        guard let rawState = rawState?.trimmingCharacters(in: .whitespacesAndNewlines), !rawState.isEmpty else {
            return .completed
        }
        if let runState = AgentSessionRunState(rawValue: rawState) {
            switch runState {
            case .completed:
                return .completed
            case .failed:
                return .failed
            case .cancelled:
                return .cancelled
            case .waitingForUser, .waitingForQuestion, .waitingForApproval, .running, .idle:
                return .completed
            }
        }
        if let snapshotStatus = AgentRunMCPSnapshot.Status(rawValue: rawState) {
            switch snapshotStatus {
            case .expired:
                return .completed
            case .running, .waitingForInput:
                return .completed
            case .completed, .failed, .cancelled:
                return snapshotStatus
            }
        }
        return .completed
    }

    private func indexedSessionStatusText(rawState: String?, status: AgentRunMCPSnapshot.Status) -> String? {
        guard let rawState = rawState?.trimmingCharacters(in: .whitespacesAndNewlines), !rawState.isEmpty else {
            return "Session exists but no active control handle is available."
        }
        let normalized = rawState.lowercased()
        if status.rawValue == normalized {
            return nil
        }
        return "Session exists but no active control handle is available (last recorded state: \(rawState))."
    }

    private func resolveSessionID(reference: String?, workspace: WorkspaceModel, agentModeVM: AgentModeViewModel) async throws -> UUID? {
        guard let reference else { return nil }
        guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: reference, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
        }
        return sessionID
    }

    private func resolveWorkflow(args: [String: Value]) throws -> AgentWorkflowDefinition? {
        let workflowID = normalizedString(args["workflow_id"])
        let workflowName = normalizedString(args["workflow_name"])
        if workflowID != nil, workflowName != nil {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        }
        guard let reference = workflowID ?? workflowName else {
            return nil
        }
        guard let workflow = AgentWorkflowStore.shared.resolveWorkflowReference(reference) else {
            throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
        }
        return workflow
    }

    private func resolveMessage(_ value: Value?, name: String) throws -> String {
        let message = normalizedString(value) ?? ""
        guard !message.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return message
    }

    private struct ParsedAnswers {
        let flat: [String: [String]]
        let structured: [String: AgentAskUserAnswer]
        let hasStructuredObjects: Bool
    }

    /// Internal for wire-contract round-trip tests.
    func parseResponsePayload(args: [String: Value]) throws -> AgentModeViewModel.MCPInteractionResponsePayload {
        let parsedAnswers: ParsedAnswers = if let rawAnswers = args["answers"] {
            try parseAnswers(rawAnswers)
        } else {
            ParsedAnswers(flat: [:], structured: [:], hasStructuredObjects: false)
        }

        let responseRaw = normalizedString(args["response"])
        let explicitSkip: Bool
        if let skipValue = args["skip"] {
            guard let skipBool = skipValue.boolValue else {
                throw MCPError.invalidParams("skip must be a boolean.")
            }
            explicitSkip = skipBool
        } else {
            explicitSkip = false
        }
        let responseIsSkipSentinel = responseRaw?.lowercased() == "skip"
        let isSkip = explicitSkip || responseIsSkipSentinel
        if isSkip, !parsedAnswers.flat.isEmpty || !parsedAnswers.structured.isEmpty {
            throw MCPError.invalidParams("skip cannot be combined with answers.")
        }
        if explicitSkip, responseRaw != nil, !responseIsSkipSentinel {
            throw MCPError.invalidParams("skip cannot be combined with response.")
        }
        let decisionRaw = responseRaw

        let content = try parseAgentJSONObject(args["content"], name: "content")
        let meta = try parseAgentJSONObject(args["meta"] ?? args["_meta"], name: "meta")

        return AgentModeViewModel.MCPInteractionResponsePayload(
            text: responseRaw,
            skip: isSkip,
            explicitSkip: explicitSkip,
            decisionRaw: isSkip ? nil : decisionRaw,
            amendment: normalizedString(args["amendment"]),
            answersByQuestionID: parsedAnswers.flat,
            askUserAnswersByQuestionID: parsedAnswers.structured,
            hasStructuredAnswerObjects: parsedAnswers.hasStructuredObjects,
            elicitationActionRaw: isSkip ? nil : responseRaw,
            elicitationContent: content,
            elicitationMeta: meta
        )
    }

    private func parseAgentJSONObject(_ value: Value?, name: String) throws -> [String: AgentJSONValue] {
        guard let value else { return [:] }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("\(name) must be an object.")
        }
        return try object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
            partialResult[entry.key] = try agentJSONValue(from: entry.value)
        }
    }

    private func agentJSONValue(from value: Value) throws -> AgentJSONValue {
        switch value {
        case .null:
            return .null
        case let .bool(boolValue):
            return .bool(boolValue)
        case let .int(intValue):
            return .int(intValue)
        case let .double(doubleValue):
            return .double(doubleValue)
        case let .string(stringValue):
            return .string(stringValue)
        case let .array(values):
            return try .array(values.map { try agentJSONValue(from: $0) })
        case let .object(object):
            return try .object(object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
                partialResult[entry.key] = try agentJSONValue(from: entry.value)
            })
        default:
            throw MCPError.invalidParams("Unsupported JSON value in MCP response payload.")
        }
    }

    private func parseAnswers(_ value: Value) throws -> ParsedAnswers {
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("answers must be an object keyed by question ID.")
        }
        var flat = [String: [String]]()
        var structured = [String: AgentAskUserAnswer]()
        var hasStructuredObjects = false
        for entry in object {
            let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionID.isEmpty else {
                throw MCPError.invalidParams("answers cannot contain an empty question ID.")
            }

            if entry.value.objectValue != nil {
                hasStructuredObjects = true
            }
            let parsed = try parseAnswerValue(entry.value, questionID: questionID)
            flat[questionID] = parsed.answers
            structured[questionID] = parsed
        }
        return ParsedAnswers(flat: flat, structured: structured, hasStructuredObjects: hasStructuredObjects)
    }

    private func parseAnswerValue(_ value: Value, questionID: String) throws -> AgentAskUserAnswer {
        if let answer = value.stringValue {
            return AgentAskUserAnswer(
                answers: [answer],
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        if let answerArray = value.arrayValue {
            let answers = try parseAnswerStringArray(answerArray, name: "answers['\(questionID)']")
            return AgentAskUserAnswer(
                answers: answers,
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        guard let answerObject = value.objectValue else {
            throw MCPError.invalidParams("answers['\(questionID)'] must be a string, array of strings, or object.")
        }

        let skipped = answerObject["skipped"]?.boolValue == true || answerObject["skip"]?.boolValue == true
        let selectedOptions = try parseOptionalAnswerStrings(
            answerObject["selected_options"] ?? answerObject["selectedOptions"],
            name: "answers['\(questionID)'].selected_options"
        ) ?? []
        let customResponse = normalizedString(answerObject["custom_response"] ?? answerObject["customResponse"])
        let explicitAnswers = try parseOptionalAnswerStrings(
            answerObject["answers"],
            name: "answers['\(questionID)'].answers"
        )

        let answers: [String] = if let explicitAnswers {
            explicitAnswers
        } else {
            selectedOptions + (customResponse.map { [$0] } ?? [])
        }

        if skipped {
            let hasAnswerContent = !answers.isEmpty || !selectedOptions.isEmpty || customResponse != nil
            guard !hasAnswerContent else {
                throw MCPError.invalidParams("answers['\(questionID)'] cannot be skipped and answered at the same time.")
            }
            return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }

        return AgentAskUserAnswer(
            answers: answers,
            selectedOptions: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    private func parseOptionalAnswerStrings(_ value: Value?, name: String) throws -> [String]? {
        guard let value else { return nil }
        if let answer = value.stringValue {
            return [answer]
        }
        guard let answerArray = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be a string or array of strings.")
        }
        return try parseAnswerStringArray(answerArray, name: name)
    }

    private func parseAnswerStringArray(_ values: [Value], name: String) throws -> [String] {
        try values.map { element -> String in
            guard let text = element.stringValue else {
                throw MCPError.invalidParams("\(name) must contain only strings.")
            }
            return text
        }
    }

    /// Resolves session_id for control operations (poll/wait/cancel/steer/respond).
    /// Accepts both full UUIDs and short IDs for a uniform caller experience.
    private func resolveControlSessionID(
        reference raw: String,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available to resolve session_id '\(raw)'.")
        }
        guard let resolved = try await agentModeVM.mcpResolveSessionID(reference: raw, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(raw)' was not found. Provide a full UUID or a valid short ID.")
        }
        return resolved
    }

    private func resolveControlSessionID(
        _ args: [String: Value],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        guard let raw = normalizedString(args["session_id"]) else {
            throw MCPError.invalidParams("session_id is required for agent_run control operations.")
        }
        return try await resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)
    }

    private func parseSessionIDArray(_ args: [String: Value]) throws -> [String] {
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("Specify either session_id or session_ids, not both.")
        }
        guard let raw = args["session_ids"] else {
            throw MCPError.invalidParams("session_ids is required for multi-session wait.")
        }
        guard let values = raw.arrayValue, !values.isEmpty else {
            throw MCPError.invalidParams("session_ids must be a non-empty array of session IDs.")
        }
        return try values.map { value -> String in
            guard let reference = normalizedString(value) else {
                throw MCPError.invalidParams("session_ids must contain only non-empty strings.")
            }
            return reference
        }
    }

    private func resolveControlSessionIDs(
        _ references: [String],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> [UUID] {
        var resolved: [UUID] = []
        var seen: Set<UUID> = []
        for reference in references {
            let sessionID = try await resolveControlSessionID(
                reference: reference,
                targetWindow: targetWindow,
                agentModeVM: agentModeVM
            )
            if seen.insert(sessionID).inserted {
                resolved.append(sessionID)
            }
        }
        guard !resolved.isEmpty else {
            throw MCPError.invalidParams("session_ids did not resolve to any sessions.")
        }
        return resolved
    }

    private func requireUUID(_ value: Value?, name: String) throws -> UUID {
        guard let raw = normalizedString(value), let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("\(name) must be a UUID string.")
        }
        return uuid
    }

    private func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
        guard let normalized = normalizedString(value), !normalized.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return normalized
    }

    private func normalizedString(_ value: Value?) -> String? {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseBool(_ value: Value?) -> Bool? {
        switch value {
        case let .bool(boolValue):
            boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                true
            case "false", "0", "no":
                false
            default:
                nil
            }
        case let .int(intValue):
            intValue != 0
        case let .double(doubleValue):
            doubleValue != 0
        case .null, .array(_), .object:
            nil
        default:
            nil
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension AgentRunSessionStore.WakeReason {
    var suppressesAssistantPreview: Bool {
        switch self {
        case .instructionDelivered, .steeringRequested, .delegatedQuestionPending:
            true
        case .interactionResolved:
            false
        }
    }
}
