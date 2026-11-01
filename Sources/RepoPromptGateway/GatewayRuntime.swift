import CryptoKit
import Foundation
import Logging
import MCP
import RepoPromptRemoteWire

protocol RemoteFrameSink: Sendable {
    /// Returns after the frame has been accepted into the sink's ordered outbound queue.
    func send(_ frame: RemoteServerFrame) async
    func close() async
}

actor RemoteGatewayRuntime {
    typealias ObservationWindowDiscovery = @Sendable (_ deviceID: String, _ sessionID: String) async -> Int?

    static let phase0DeviceID = "phase0:static-token"

    private struct SubscriptionValidationKey: Hashable {
        let deviceID: String
        let sinkID: UUID
        let requestID: String?
        let sessionIDs: [String]
    }

    private struct EligibleStartTargetWindowSummary {
        let windowID: Int
        let workspaceID: String?
        let workspaceName: String?
        let details: JSONValue
    }

    private struct WorkspaceSessionCandidate {
        let payload: JSONValue
        let sessionID: String
        let lastModified: String
        let windowID: Int
    }

    private struct EligibleStartTargetWindowInfo {
        let details: JSONValue
        let windowIDs: [Int]
        let summaries: [EligibleStartTargetWindowSummary]
    }

    private enum EligibleStartTargetWindowInfoLookupResult {
        case available(EligibleStartTargetWindowInfo)
        case unavailable(WorkspaceMatchUnavailableReason)
    }

    private enum WorkspaceMatchUnavailableReason: String {
        case appLinkUnavailable = "app_link_unavailable"
        case appToolError = "app_tool_error"
        case decodeFailure = "decode_failure"
        case emptyWindowList = "empty_window_list"
    }

    private enum WorkspaceMatchSkippedReason: String {
        case explicitWindowID = "explicit_window_id"
    }

    private enum ListAgentsRecoveryMode: Equatable {
        case armed
        case retrying
        case disabled
    }

    private struct ListAgentsRoutingDiagnostics {
        var bindingStateInitial: String?
        var bindingStateRetry: String?
        var fallbackInitial: String?
        var fallbackRetry: String?
        var windowIDInjectedInitial: Bool?
        var windowIDInjectedRetry: Bool?
        var errorOriginInitial: String?
        var errorOriginRetry: String?
        var recoveryRetried: Bool?
    }

    private let appLink: AppLinkSession
    private let appLinkPool: AppLinkPool?
    private let ledger: CommandLedger
    private let watchManager: SessionWatchManager
    private let sessionWindowAffinity: GatewaySessionWindowAffinity
    private let auditLog: RemoteAuditLog?
    private let logger: Logger
    private let defaultBindingState: RemoteGatewayBindingState
    private let pushSubscriptionStore: WebPushSubscriptionStore?
    private let observationWindowDiscovery: ObservationWindowDiscovery?
    private let observationDiscoveryTimeoutSeconds: TimeInterval
    private let now: @Sendable () -> Date
    private var lastEligibleWindowDetailsByDevice: [String: JSONValue] = [:]
    private var autoRoutedStartWindowIDByCommandKey: [String: Int] = [:]
    private var workspaceMatchCountByCommandKey: [String: Int] = [:]
    private var workspaceStartMatchSkippedByCommandKey: [String: String] = [:]
    private var workspaceMatchUnavailableReasonByCommandKey: [String: String] = [:]
    private var listAgentsRoutingDiagnosticsByCommandKey: [String: ListAgentsRoutingDiagnostics] = [:]
    private var pendingSubscriptionValidations: [
        SubscriptionValidationKey: [SessionWatchManager.SubscriptionValidation]
    ] = [:]

    init(
        appLink: AppLinkSession,
        ledger: CommandLedger,
        watchManager: SessionWatchManager,
        auditLog: RemoteAuditLog?,
        logger: Logger = Logger(label: "com.repoprompt.gateway.runtime"),
        bindingState: RemoteGatewayBindingState = .bound,
        appLinkPool: AppLinkPool? = nil,
        pushSubscriptionStore: WebPushSubscriptionStore? = nil,
        sessionWindowAffinity: GatewaySessionWindowAffinity = GatewaySessionWindowAffinity(),
        observationWindowDiscovery: ObservationWindowDiscovery? = nil,
        observationDiscoveryTimeoutSeconds: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appLink = appLink
        self.appLinkPool = appLinkPool
        self.ledger = ledger
        self.watchManager = watchManager
        self.sessionWindowAffinity = sessionWindowAffinity
        self.auditLog = auditLog
        self.logger = logger
        defaultBindingState = bindingState
        self.pushSubscriptionStore = pushSubscriptionStore
        self.observationWindowDiscovery = observationWindowDiscovery
        self.observationDiscoveryTimeoutSeconds = max(0.01, observationDiscoveryTimeoutSeconds)
        self.now = now
    }

    func registerSink(deviceID: String, sinkID: UUID, sink: any RemoteFrameSink) async {
        await watchManager.registerSink(deviceID: deviceID, sinkID: sinkID, sink: sink)
    }

    func removeSink(deviceID: String, sinkID: UUID) async {
        // Drop any pending subscription validations owned by this connection so a deferred watch
        // activation can never fire against a torn-down sink. Keyed on the sink's unique incarnation
        // id, so a different connection reusing the same client requestID keeps its own pending entry.
        pendingSubscriptionValidations = pendingSubscriptionValidations.filter { $0.key.sinkID != sinkID }
        await watchManager.removeSink(deviceID: deviceID, sinkID: sinkID)
    }

    func teardownRevokedDevice(deviceID: String, reason: String = "device_revoked") async {
        await watchManager.teardownDevice(
            deviceID: deviceID,
            reason: reason,
            message: "This remote device is no longer trusted by the RepoPrompt app."
        )
    }

    /// Starts work that must be ordered after a correlated response is queued.
    /// Validation runs in a child task so authenticated frame admission is released.
    func didQueueResponse(
        for request: RemoteClientFrame,
        response: RemoteServerFrame,
        deviceID: String,
        sinkID: UUID
    ) {
        guard request.type == "subscribe" else { return }
        let sessionIDs = (try? sessionIDs(from: request)) ?? []
        let key = subscriptionValidationKey(
            deviceID: deviceID,
            sinkID: sinkID,
            requestID: request.requestID,
            sessionIDs: sessionIDs
        )
        guard response.type == "command_result",
              var validations = pendingSubscriptionValidations[key],
              !validations.isEmpty
        else {
            pendingSubscriptionValidations.removeValue(forKey: key)
            return
        }
        let validation = validations.removeFirst()
        if validations.isEmpty {
            pendingSubscriptionValidations.removeValue(forKey: key)
        } else {
            pendingSubscriptionValidations[key] = validations
        }
        let watchManager = watchManager
        logger.info("watch validation activation queued device_id=\(deviceID) session_count=\(sessionIDs.count)")
        Task {
            await watchManager.validateSubscription(validation)
        }
    }

    /// Discard a deferred subscription validation WITHOUT activating its watch. Called when the
    /// correlated response was dropped or lock-replaced (`sendResponse` returned anything other than
    /// `.originalEnqueued`), so the deferred validation for that request never ACTIVATES its session
    /// watch (the activation path `validateSubscription` is simply never run for it). Pops exactly one
    /// pending VALIDATION under the same FIFO key as `didQueueResponse`, so a duplicate client
    /// requestID cannot discard the wrong pending entry. It does NOT tear down any device-wide
    /// observation already registered for OTHER live subscriptions of the same device (S3-A-09): the
    /// shared watch is a device-scoped resource, and withholding one request's correlated result only
    /// cancels THAT request's pending activation, not an unrelated sibling's established watch.
    ///
    /// It also does NOT remove the withheld request's OWN observation intent: `handle` already called
    /// `watchManager.registerSubscription` for this subscribe before the response was withheld, and that
    /// registration (its per-session token) persists until an explicit unsubscribe or the connection
    /// disconnects — only its deferred catch-up validation is cancelled here, so no catch-up frame is
    /// emitted. Nothing leaks while the intent lingers: the sink still gates every delivery on current
    /// access, so a locked connection receives no frames (S3-A-09, deferred to Step 4).
    func discardQueuedResponse(
        for request: RemoteClientFrame,
        deviceID: String,
        sinkID: UUID
    ) {
        guard request.type == "subscribe" else { return }
        let sessionIDs = (try? sessionIDs(from: request)) ?? []
        let key = subscriptionValidationKey(
            deviceID: deviceID,
            sinkID: sinkID,
            requestID: request.requestID,
            sessionIDs: sessionIDs
        )
        guard var validations = pendingSubscriptionValidations[key], !validations.isEmpty else {
            pendingSubscriptionValidations.removeValue(forKey: key)
            return
        }
        validations.removeFirst()
        if validations.isEmpty {
            pendingSubscriptionValidations.removeValue(forKey: key)
        } else {
            pendingSubscriptionValidations[key] = validations
        }
    }

    func handle(
        _ frame: RemoteClientFrame,
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink
    ) async -> RemoteServerFrame? {
        switch frame.type {
        case "hello":
            .helloAck()
        case "ping":
            RemoteServerFrame(
                type: "pong",
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: frame.payload ?? .object([:])
            )
        case "subscribe":
            await handleSubscribe(frame, deviceID: deviceID, sinkID: sinkID, sink: sink)
        case "unsubscribe":
            await handleUnsubscribe(frame, deviceID: deviceID)
        case "push_subscribe":
            await handlePushSubscribe(frame, deviceID: deviceID)
        case "push_unsubscribe":
            await handlePushUnsubscribe(frame, deviceID: deviceID)
        default:
            await handleToolMappedCommand(frame, deviceID: deviceID)
        }
    }

    private func handleSubscribe(
        _ frame: RemoteClientFrame,
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink
    ) async -> RemoteServerFrame {
        // M6.6: subscription is an observation op — an unbound multi-window
        // connection must get a structured binding_required, not a silent
        // per-session failure from the catch-up poll.
        if let bindingError = await observationBindingError(deviceID: deviceID, frame: frame) {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: bindingError.code)
            return await .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: bindingError.code,
                message: bindingError.description,
                details: bindingErrorDetails(code: bindingError.code, existing: nil, deviceID: deviceID)
            )
        }
        do {
            let ids = try sessionIDs(from: frame)
            let validation = await watchManager.registerSubscription(
                deviceID: deviceID,
                sinkID: sinkID,
                sink: sink,
                sessionIDs: ids
            )
            let validationKey = subscriptionValidationKey(
                deviceID: deviceID,
                sinkID: sinkID,
                requestID: frame.requestID,
                sessionIDs: ids
            )
            pendingSubscriptionValidations[validationKey, default: []].append(validation)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            return .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "subscribed_session_ids": .array(ids.map(JSONValue.string))
                ])
            )
        } catch let error as RemoteCommandTranslatorError {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: error.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: error.code,
                message: error.description
            )
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "subscribe_failed")
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "subscribe_failed",
                message: String(describing: error)
            )
        }
    }

    private func subscriptionValidationKey(
        deviceID: String,
        sinkID: UUID,
        requestID: String?,
        sessionIDs: [String]
    ) -> SubscriptionValidationKey {
        SubscriptionValidationKey(
            deviceID: deviceID,
            sinkID: sinkID,
            requestID: requestID,
            sessionIDs: sessionIDs.sorted()
        )
    }

    private func handleUnsubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        if let bindingError = await observationBindingError(deviceID: deviceID, frame: frame) {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: bindingError.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: bindingError.code,
                message: bindingError.description
            )
        }
        do {
            let ids = try sessionIDs(from: frame)
            await watchManager.unsubscribe(deviceID: deviceID, sessionIDs: ids)
            // Validate once after removal so unsubscribe remains a thin app-tool
            // translation without inventing an app-side remote control plane.
            _ = try? await callTranslatedTool(for: frame, deviceID: deviceID)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            return .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "unsubscribed_session_ids": .array(ids.map(JSONValue.string))
                ])
            )
        } catch let error as RemoteCommandTranslatorError {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: error.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: error.code,
                message: error.description
            )
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "unsubscribe_failed")
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "unsubscribe_failed",
                message: String(describing: error)
            )
        }
    }

    /// Gateway-owned Web Push registration for the authenticated device. The
    /// subscription is keyed by the connection's device ID (never a client-chosen
    /// ID) and is removed again on unsubscribe, revocation, or endpoint expiry.
    private func handlePushSubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let pushSubscriptionStore else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_unavailable")
            return .commandError(
                requestID: frame.requestID,
                code: "push_unavailable",
                message: "Web Push is not available on this gateway."
            )
        }
        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        guard let subscriptionValue = frame.payload?.objectValue?["subscription"],
              let subscription = WebPushSubscription.parse(from: subscriptionValue, nowMs: nowMs)
        else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "invalid_push_subscription")
            return .commandError(
                requestID: frame.requestID,
                code: "invalid_push_subscription",
                message: "payload.subscription must be {endpoint, keys: {p256dh, auth}} with an HTTPS endpoint."
            )
        }
        do {
            try pushSubscriptionStore.setSubscription(subscription, forDevice: deviceID)
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_subscription_persist_failed")
            return .commandError(
                requestID: frame.requestID,
                code: "push_subscription_persist_failed",
                message: String(describing: error)
            )
        }
        await watchManager.pushEligibilityChanged(deviceID: deviceID)
        audit(frame: frame, deviceID: deviceID, outcome: "success")
        return .commandResult(
            requestID: frame.requestID,
            payload: .object(["status": .string("subscribed")])
        )
    }

    private func handlePushUnsubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let pushSubscriptionStore else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_unavailable")
            return .commandError(
                requestID: frame.requestID,
                code: "push_unavailable",
                message: "Web Push is not available on this gateway."
            )
        }
        let removed = (try? pushSubscriptionStore.removeSubscription(forDevice: deviceID)) ?? false
        await watchManager.pushEligibilityChanged(deviceID: deviceID)
        audit(frame: frame, deviceID: deviceID, outcome: "success")
        return .commandResult(
            requestID: frame.requestID,
            payload: .object(["status": .string(removed ? "unsubscribed" : "not_subscribed")])
        )
    }

    private func handleToolMappedCommand(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        if RemoteWireProtocol.mutatingClientFrameTypes.contains(frame.type) {
            return await handleMutatingCommand(frame, deviceID: deviceID)
        }
        do {
            let payload = try await callTranslatedTool(for: frame, deviceID: deviceID)
            audit(frame: frame, deviceID: deviceID, outcome: "success", responsePayload: payload)
            return .commandResult(requestID: frame.requestID, sessionID: frame.sessionID, payload: payload)
        } catch {
            let mapped = mapError(error, frame: frame)
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: mapped.code)
            return await .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: mapped.code,
                message: mapped.message,
                details: bindingErrorDetails(code: mapped.code, existing: mapped.details, deviceID: deviceID)
            )
        }
    }

    private func handleMutatingCommand(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let requestID = frame.requestID else {
            return .commandError(
                requestID: nil,
                sessionID: frame.sessionID,
                code: "missing_request_id",
                message: "request_id is required for mutating commands."
            )
        }
        let key = CommandLedger.Key(deviceID: deviceID, requestID: requestID)
        let fingerprint: CommandLedger.CommandFingerprint
        do {
            fingerprint = try RemoteWireProtocol.commandFingerprint(for: frame)
        } catch {
            return .commandError(
                requestID: requestID,
                sessionID: frame.sessionID,
                code: "fingerprint_failed",
                message: String(describing: error)
            )
        }

        switch await ledger.begin(key: key, fingerprint: fingerprint) {
        case .new:
            break
        case let .duplicate(outcome):
            audit(frame: frame, deviceID: deviceID, outcome: "duplicate", code: outcome.auditCode)
            return responseFrame(for: outcome, frame: frame)
        case .inFlight:
            audit(frame: frame, deviceID: deviceID, outcome: "in_flight", code: "in_flight")
            return .commandResult(
                requestID: requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "status": .string("in_flight"),
                    "message": .string("The original command is still in flight; poll/get_log for state if needed.")
                ])
            )
        case let .conflict(existing):
            audit(frame: frame, deviceID: deviceID, outcome: "conflict", code: "request_id_conflict")
            return .commandError(
                requestID: requestID,
                sessionID: frame.sessionID,
                code: "request_id_conflict",
                message: "request_id was already used for a different \(existing.operation) payload.",
                details: .object([
                    "existing_operation": .string(existing.operation),
                    "existing_fingerprint": .string(existing.canonicalPayloadSHA256)
                ])
            )
        case let .persistenceFailed(outcome):
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: outcome.auditCode)
            return responseFrame(for: outcome, frame: frame)
        }

        let outcome: CommandLedger.RecordedOutcome
        do {
            let payload = try await callTranslatedTool(for: frame, deviceID: deviceID)
            await recordExplicitStartAffinityIfNeeded(frame: frame, payload: payload)
            outcome = .success(payload)
            await ledger.complete(key: key, outcome: outcome)
            if frame.type == "open_workspace" {
                lastEligibleWindowDetailsByDevice.removeValue(forKey: deviceID)
                _ = await appLinkPool?.refreshBindingState(forDevice: deviceID)
            }
            audit(frame: frame, deviceID: deviceID, outcome: "success", responsePayload: payload)
            if frame.type == "steer" || frame.type == "respond" {
                await watchManager.rearm(deviceID: deviceID, sessionID: frame.sessionID)
            }
            return .commandResult(requestID: requestID, sessionID: frame.sessionID, payload: payload)
        } catch {
            outcome = ledgerOutcome(for: error, frame: frame)
            await ledger.complete(key: key, outcome: outcome)
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: outcome.auditCode)
            if frame.type == "steer" || frame.type == "respond" {
                await watchManager.rearm(deviceID: deviceID, sessionID: frame.sessionID)
            }
            // M6.6: binding errors on start carry the eligible windows so remote
            // clients can render an explicit start-target picker.
            if case let .failure(code, message) = outcome,
               ["binding_required", "ambiguous_start_target", "workspace_mismatch"].contains(code)
            {
                return await .commandError(
                    requestID: requestID,
                    sessionID: frame.sessionID,
                    code: code,
                    message: message,
                    details: bindingErrorDetails(code: code, existing: nil, deviceID: deviceID)
                )
            }
            return responseFrame(for: outcome, frame: frame)
        }
    }

    private func callTranslatedTool(for frame: RemoteClientFrame, deviceID: String) async throws -> JSONValue {
        let (link, bindingState) = try await resolveAppLink(deviceID: deviceID)
        if frame.type == "list_sessions",
           let payload = frame.payload?.objectValue,
           hasWorkspaceSelector(payload)
        {
            return try await callWorkspaceScopedListSessions(
                frame: frame,
                payload: payload,
                deviceID: deviceID,
                link: link,
                bindingState: bindingState
            )
        }
        if frame.type == "poll",
           let requestedSessionIDs = try? sessionIDs(from: frame),
           requestedSessionIDs.count > 1
        {
            return try await callPartitionedPoll(
                frame: frame,
                deviceID: deviceID,
                link: link,
                bindingState: bindingState,
                sessionIDs: requestedSessionIDs
            )
        }
        return try await callTranslatedToolSingle(
            for: frame,
            deviceID: deviceID,
            link: link,
            bindingState: bindingState,
            listAgentsRecoveryMode: .armed,
            allowCorrectiveRetry: true,
            allowStartRoutingRetry: true
        )
    }

    private func callTranslatedToolSingle(
        for frame: RemoteClientFrame,
        deviceID: String,
        link: AppLinkSession,
        bindingState: RemoteGatewayBindingState,
        listAgentsRecoveryMode: ListAgentsRecoveryMode,
        allowCorrectiveRetry: Bool,
        allowStartRoutingRetry: Bool
    ) async throws -> JSONValue {
        rememberListAgentsAttemptStart(
            frame: frame,
            deviceID: deviceID,
            bindingState: bindingState,
            mode: listAgentsRecoveryMode
        )
        let sessionID = singleSessionIDIfSessionAddressed(frame)
        var resolvedWindowID = await resolvedWindowID(
            forSession: sessionID,
            deviceID: deviceID,
            bindingState: bindingState
        )
        if frame.type == "list_agents",
           resolvedWindowID == nil,
           bindingState != .bound || listAgentsRecoveryMode == .retrying
        {
            if let fallbackWindowID = await eligibleStartTargetWindowInfo(deviceID: deviceID)?.windowIDs.first {
                resolvedWindowID = fallbackWindowID
                rememberListAgentsFallback(
                    frame: frame,
                    deviceID: deviceID,
                    outcome: "resolved",
                    mode: listAgentsRecoveryMode
                )
            } else {
                rememberListAgentsFallback(
                    frame: frame,
                    deviceID: deviceID,
                    outcome: "unavailable",
                    mode: listAgentsRecoveryMode
                )
            }
        }
        var effectiveFrame = frame
        if frame.type == "start",
           let payload = frame.payload?.objectValue,
           hasWorkspaceSelector(payload)
        {
            if explicitStartWindowID(frame) != nil {
                rememberWorkspaceStartMatchSkipped(frame: frame, deviceID: deviceID, reason: .explicitWindowID)
            } else if let match = await workspaceStartWindowMatch(payload: payload, frame: frame, deviceID: deviceID) {
                rememberWorkspaceMatchCount(frame: frame, deviceID: deviceID, count: match.matchCount)
                if let matchedWindow = match.summary {
                    effectiveFrame = startFrame(frame, routedTo: matchedWindow)
                    rememberAutoRoutedStart(frame: frame, deviceID: deviceID, windowID: matchedWindow.windowID)
                }
            }
        }
        let payload = try await executeTranslatedTool(
            frame: effectiveFrame,
            deviceID: deviceID,
            link: link,
            bindingState: bindingState,
            resolvedWindowID: resolvedWindowID,
            retrySessionID: sessionID,
            listAgentsRecoveryMode: listAgentsRecoveryMode,
            allowCorrectiveRetry: allowCorrectiveRetry,
            allowStartRoutingRetry: allowStartRoutingRetry
        )
        if effectiveFrame != frame {
            await recordExplicitStartAffinityIfNeeded(frame: effectiveFrame, payload: payload)
        }
        return payload
    }

    private func workspaceStartWindowMatch(
        payload: [String: JSONValue],
        frame: RemoteClientFrame,
        deviceID: String
    ) async -> (summary: EligibleStartTargetWindowSummary?, matchCount: Int)? {
        guard workspaceSelector(from: payload) != nil else { return nil }
        let windowInfo: EligibleStartTargetWindowInfo
        switch await eligibleStartTargetWindowInfoLookup(deviceID: deviceID) {
        case let .available(info):
            windowInfo = info
        case let .unavailable(reason):
            rememberWorkspaceMatchUnavailableReason(frame: frame, deviceID: deviceID, reason: reason.rawValue)
            return nil
        }

        let matches = matchingWindowSummaries(payload: payload, summaries: windowInfo.summaries)
        return (summary: matches.count == 1 ? matches[0] : nil, matchCount: matches.count)
    }

    private func callWorkspaceScopedListSessions(
        frame: RemoteClientFrame,
        payload: [String: JSONValue],
        deviceID: String,
        link: AppLinkSession,
        bindingState: RemoteGatewayBindingState
    ) async throws -> JSONValue {
        // Preserve the translator allow-list gate before routing lookup can produce
        // a workspace-specific error for an otherwise invalid payload.
        _ = try RemoteCommandTranslator(bindingState: bindingState).translate(frame, resolvedWindowID: 0)

        let windowInfo: EligibleStartTargetWindowInfo
        switch await eligibleStartTargetWindowInfoLookup(deviceID: deviceID) {
        case let .available(info):
            windowInfo = info
        case let .unavailable(reason):
            rememberWorkspaceMatchUnavailableReason(frame: frame, deviceID: deviceID, reason: reason.rawValue)
            throw RemoteGatewayRuntimeError.workspaceWindowLookupUnavailable(reason: reason.rawValue)
        }

        let matches = matchingWindowSummaries(payload: payload, summaries: windowInfo.summaries)
            .sorted { $0.windowID < $1.windowID }
        rememberWorkspaceMatchCount(frame: frame, deviceID: deviceID, count: matches.count)
        guard !matches.isEmpty else {
            throw RemoteGatewayRuntimeError.workspaceNotOpen(
                workspaceName: workspaceSelector(from: payload)?.name
            )
        }

        var candidatesBySessionID: [String: WorkspaceSessionCandidate] = [:]
        var responseWorkspace: JSONValue?
        for summary in matches {
            let routedFrame = listSessionsFrame(frame, routedTo: summary)
            let result = try await executeTranslatedTool(
                frame: routedFrame,
                deviceID: deviceID,
                link: link,
                bindingState: bindingState,
                resolvedWindowID: summary.windowID,
                retrySessionID: nil,
                listAgentsRecoveryMode: .disabled,
                allowCorrectiveRetry: false,
                allowStartRoutingRetry: false
            )
            if responseWorkspace == nil {
                responseWorkspace = result.objectValue?["workspace"] ?? workspaceObject(from: summary)
            }
            for session in result.objectValue?["sessions"]?.arrayValue ?? [] {
                guard let sessionID = session.objectValue?["session_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !sessionID.isEmpty
                else { continue }
                let candidate = WorkspaceSessionCandidate(
                    payload: session,
                    sessionID: sessionID,
                    lastModified: session.objectValue?["last_modified"]?.stringValue ?? "",
                    windowID: summary.windowID
                )
                if let existing = candidatesBySessionID[sessionID],
                   existing.lastModified >= candidate.lastModified
                {
                    continue
                }
                candidatesBySessionID[sessionID] = candidate
            }
        }

        for candidate in candidatesBySessionID.values {
            await sessionWindowAffinity.record(sessionID: candidate.sessionID, windowID: candidate.windowID)
        }
        let sessions = candidatesBySessionID.values.sorted {
            if $0.lastModified != $1.lastModified {
                return $0.lastModified > $1.lastModified
            }
            return $0.sessionID < $1.sessionID
        }
        let limit = max(1, payload["limit"]?.intValue ?? 100)
        return .object([
            "sessions": .array(sessions.prefix(limit).map(\.payload)),
            "workspace": responseWorkspace ?? workspaceObject(from: matches[0]),
            "window_count": .int(matches.count)
        ])
    }

    private func matchingWindowSummaries(
        payload: [String: JSONValue],
        summaries: [EligibleStartTargetWindowSummary]
    ) -> [EligibleStartTargetWindowSummary] {
        guard let selector = workspaceSelector(from: payload) else { return [] }
        let normalizedName = selector.name?.lowercased()
        return summaries.filter { summary in
            let idMatches = selector.id.map { requested in summary.workspaceID == requested } ?? true
            let nameMatches = normalizedName.map { requested in summary.workspaceName?.lowercased() == requested } ?? true
            return idMatches && nameMatches
        }
    }

    private func workspaceSelector(from payload: [String: JSONValue]) -> (id: String?, name: String?)? {
        let rawWorkspaceID = payload["workspace_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWorkspaceName = payload["workspace_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = rawWorkspaceID?.isEmpty == false ? rawWorkspaceID : nil
        let workspaceName = rawWorkspaceName?.isEmpty == false ? rawWorkspaceName : nil
        guard workspaceID != nil || workspaceName != nil else { return nil }
        return (workspaceID, workspaceName)
    }

    private func hasWorkspaceSelector(_ payload: [String: JSONValue]) -> Bool {
        workspaceSelector(from: payload) != nil
    }

    private func listSessionsFrame(
        _ frame: RemoteClientFrame,
        routedTo summary: EligibleStartTargetWindowSummary
    ) -> RemoteClientFrame {
        var payload = frame.payload?.objectValue ?? [:]
        if let workspaceID = summary.workspaceID, !workspaceID.isEmpty {
            payload["workspace_id"] = .string(workspaceID)
        }
        return RemoteClientFrame(
            v: frame.v,
            type: frame.type,
            requestID: frame.requestID,
            sessionID: frame.sessionID,
            payload: .object(payload),
            clientTime: frame.clientTime,
            sig: frame.sig
        )
    }

    private func workspaceObject(from summary: EligibleStartTargetWindowSummary) -> JSONValue {
        .object([
            "id": .string(summary.workspaceID ?? ""),
            "name": .string(summary.workspaceName ?? "")
        ])
    }

    private func startFrame(_ frame: RemoteClientFrame, routedTo summary: EligibleStartTargetWindowSummary) -> RemoteClientFrame {
        var payload = frame.payload?.objectValue ?? [:]
        payload["window_id"] = .int(summary.windowID)
        if let workspaceID = summary.workspaceID, !workspaceID.isEmpty {
            payload["workspace_id"] = .string(workspaceID)
        }
        return RemoteClientFrame(
            v: frame.v,
            type: frame.type,
            requestID: frame.requestID,
            sessionID: frame.sessionID,
            payload: .object(payload),
            clientTime: frame.clientTime,
            sig: frame.sig
        )
    }

    private func executeTranslatedTool(
        frame: RemoteClientFrame,
        deviceID: String,
        link: AppLinkSession,
        bindingState: RemoteGatewayBindingState,
        resolvedWindowID: Int?,
        retrySessionID: String?,
        listAgentsRecoveryMode: ListAgentsRecoveryMode,
        allowCorrectiveRetry: Bool,
        allowStartRoutingRetry: Bool
    ) async throws -> JSONValue {
        let translator = RemoteCommandTranslator(bindingState: bindingState)
        let toolCall: RemoteToolCall
        do {
            toolCall = try translator.translate(frame, resolvedWindowID: resolvedWindowID)
            rememberListAgentsWindowIDInjection(
                frame: frame,
                deviceID: deviceID,
                injected: toolCall.arguments["_windowID"] != nil,
                mode: listAgentsRecoveryMode
            )
        } catch {
            rememberListAgentsWindowIDInjection(
                frame: frame,
                deviceID: deviceID,
                injected: false,
                mode: listAgentsRecoveryMode
            )
            rememberListAgentsErrorOrigin(
                frame: frame,
                deviceID: deviceID,
                origin: "translator",
                mode: listAgentsRecoveryMode
            )
            if frame.type == "list_agents",
               listAgentsRecoveryMode == .armed,
               let translatorError = error as? RemoteCommandTranslatorError,
               case .bindingRequired = translatorError,
               let refreshedBindingState = await appLinkPool?.refreshBindingState(forDevice: deviceID)
            {
                return try await callTranslatedToolSingle(
                    for: frame,
                    deviceID: deviceID,
                    link: link,
                    bindingState: refreshedBindingState,
                    listAgentsRecoveryMode: .retrying,
                    allowCorrectiveRetry: false,
                    allowStartRoutingRetry: false
                )
            }
            throw error
        }

        let result = try await link.callTool(
            name: toolCall.toolName,
            arguments: toolCall.arguments,
            timeout: toolCall.timeout
        )
        let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
        if result.isError == true {
            let runtimeError = RemoteGatewayRuntimeError.appToolError(payload: payload)
            let errorCode = runtimeError.code(frame: frame)
            rememberListAgentsErrorOrigin(
                frame: frame,
                deviceID: deviceID,
                origin: "app",
                mode: listAgentsRecoveryMode
            )

            var refreshedBindingState: RemoteGatewayBindingState?
            if errorCode == "binding_required",
               !(frame.type == "list_agents" && listAgentsRecoveryMode == .retrying)
            {
                refreshedBindingState = await appLinkPool?.refreshBindingState(forDevice: deviceID)
            }
            if frame.type == "list_agents",
               errorCode == "binding_required",
               listAgentsRecoveryMode == .armed,
               let refreshedBindingState
            {
                return try await callTranslatedToolSingle(
                    for: frame,
                    deviceID: deviceID,
                    link: link,
                    bindingState: refreshedBindingState,
                    listAgentsRecoveryMode: .retrying,
                    allowCorrectiveRetry: false,
                    allowStartRoutingRetry: false
                )
            }
            if Self.isStartRoutingTargetError(runtimeError, frame: frame) {
                let refreshedBindingState = await appLinkPool?.refreshBindingState(forDevice: deviceID)
                if allowStartRoutingRetry,
                   explicitStartWindowID(frame) == nil,
                   let refreshedBindingState
                {
                    do {
                        return try await callTranslatedToolSingle(
                            for: frame,
                            deviceID: deviceID,
                            link: link,
                            bindingState: refreshedBindingState,
                            listAgentsRecoveryMode: .disabled,
                            allowCorrectiveRetry: false,
                            allowStartRoutingRetry: false
                        )
                    } catch {
                        throw RemoteCommandTranslatorError.ambiguousStartTarget
                    }
                }
                throw RemoteCommandTranslatorError.ambiguousStartTarget
            }
            if allowCorrectiveRetry,
               Self.isCorrectiveSessionWindowRoutingError(runtimeError, frame: frame),
               let retrySessionID,
               let resolvedWindowID,
               let rediscovered = await rediscoverWindowIDAfterToolError(
                   sessionID: retrySessionID,
                   deviceID: deviceID
               ),
               rediscovered != resolvedWindowID
            {
                return try await executeTranslatedTool(
                    frame: frame,
                    deviceID: deviceID,
                    link: link,
                    bindingState: bindingState,
                    resolvedWindowID: rediscovered,
                    retrySessionID: nil,
                    listAgentsRecoveryMode: .disabled,
                    allowCorrectiveRetry: false,
                    allowStartRoutingRetry: false
                )
            }
            throw runtimeError
        }
        await recordForkSessionAffinityIfNeeded(frame: frame, payload: payload, windowID: resolvedWindowID)
        return payload
    }

    private static func isCorrectiveSessionWindowRoutingError(
        _ error: RemoteGatewayRuntimeError,
        frame: RemoteClientFrame
    ) -> Bool {
        guard case .appToolError = error else { return false }
        switch error.code(frame: frame) {
        case "binding_required", "ambiguous_start_target", "session_expired":
            return true
        default:
            return false
        }
    }

    private static func isStartRoutingTargetError(
        _ error: RemoteGatewayRuntimeError,
        frame: RemoteClientFrame
    ) -> Bool {
        guard frame.type == "start", case .appToolError = error else { return false }
        let normalized = error.message.lowercased()
        return normalized.contains("requires either an explicit tab context")
            || normalized.contains("window-only connection") && normalized.contains("bound to the target window")
    }

    private func callPartitionedPoll(
        frame: RemoteClientFrame,
        deviceID: String,
        link: AppLinkSession,
        bindingState: RemoteGatewayBindingState,
        sessionIDs: [String]
    ) async throws -> JSONValue {
        var byWindow: [Int: [String]] = [:]
        var legacy: [String] = []
        for sessionID in sessionIDs {
            if let windowID = await resolvedWindowID(forSession: sessionID, deviceID: deviceID, bindingState: bindingState) {
                byWindow[windowID, default: []].append(sessionID)
            } else if bindingState == .bound {
                legacy.append(sessionID)
            } else {
                throw RemoteCommandTranslatorError.bindingRequired(bindingRequiredMessage(bindingState))
            }
        }

        var partitions: [(windowID: Int?, sessionIDs: [String])] = byWindow
            .keys
            .sorted()
            .map { ($0, byWindow[$0] ?? []) }
        if !legacy.isEmpty {
            partitions.append((nil, legacy))
        }
        guard !partitions.isEmpty else {
            return .object(["snapshots": .array([])])
        }
        if partitions.count == 1, partitions[0].windowID == nil {
            return try await callTranslatedToolSingle(
                for: frame,
                deviceID: deviceID,
                link: link,
                bindingState: bindingState,
                listAgentsRecoveryMode: .disabled,
                allowCorrectiveRetry: false,
                allowStartRoutingRetry: false
            )
        }

        var snapshots: [JSONValue] = []
        for partition in partitions {
            let partitionFrame = pollFrame(from: frame, sessionIDs: partition.sessionIDs)
            let payload = try await executeTranslatedTool(
                frame: partitionFrame,
                deviceID: deviceID,
                link: link,
                bindingState: bindingState,
                resolvedWindowID: partition.windowID,
                retrySessionID: nil,
                listAgentsRecoveryMode: .disabled,
                allowCorrectiveRetry: false,
                allowStartRoutingRetry: false
            )
            snapshots.append(contentsOf: RemoteSessionSnapshot.extractSnapshots(from: payload).map(\.payload))
        }
        return .object(["snapshots": .array(snapshots)])
    }

    /// Paired devices route through their own bootstrap app leg (`remote:<device8>`)
    /// with the pool's bind-at-connect state; the phase0 static-token device keeps the
    /// default gateway app leg.
    private func resolveAppLink(deviceID: String) async throws -> (AppLinkSession, RemoteGatewayBindingState) {
        if let appLinkPool, let session = await appLinkPool.session(forDevice: deviceID) {
            let bindingState = await appLinkPool.bindingState(forDevice: deviceID)
            let shouldRefresh = await appLinkPool.bindingStateRequiresRefresh(forDevice: deviceID)
            if case .bound = bindingState, !shouldRefresh {
                return (session, bindingState)
            }
            let refreshed = await appLinkPool.refreshBindingState(forDevice: deviceID) ?? bindingState
            return (session, refreshed)
        }
        if deviceID == Self.phase0DeviceID || !deviceID.hasPrefix("remote:") {
            return (appLink, defaultBindingState)
        }
        throw RemoteGatewayRuntimeError.deviceAppLinkUnavailable(deviceID: deviceID)
    }

    func cachedSessionWindowForObservation(deviceID: String, sessionID: String) async -> Int? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        if let cachedWindowID = await sessionWindowAffinity.windowID(forSession: normalizedSessionID) {
            logger.debug(
                "observation event=affinity_lookup outcome=warm_hit device_id=\(Self.boundedLogIdentifier(deviceID)) session_id=\(Self.boundedLogIdentifier(normalizedSessionID)) window_id=\(cachedWindowID)"
            )
            return cachedWindowID
        }
        logger.notice(
            "observation event=affinity_lookup outcome=miss device_id=\(Self.boundedLogIdentifier(deviceID)) session_id=\(Self.boundedLogIdentifier(normalizedSessionID))"
        )
        return nil
    }

    func resolveSessionWindowForObservation(deviceID: String, sessionID: String) async -> Int? {
        if let cached = await cachedSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID) {
            return cached
        }
        return await recoverSessionWindowForObservation(
            deviceID: deviceID,
            sessionID: sessionID,
            invalidate: false
        )
    }

    func recoverSessionWindowForObservation(
        deviceID: String,
        sessionID: String,
        invalidate: Bool
    ) async -> Int? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        if invalidate {
            await sessionWindowAffinity.invalidate(sessionID: normalizedSessionID)
        }
        logger.notice(
            "observation event=affinity_recovery outcome=issued device_id=\(Self.boundedLogIdentifier(deviceID)) session_id=\(Self.boundedLogIdentifier(normalizedSessionID))"
        )
        let result = await withBoundedObservationResolution(seconds: observationDiscoveryTimeoutSeconds) {
            await self.sessionWindowAffinity.resolvingWindowID(forSession: normalizedSessionID) {
                if let observationWindowDiscovery = await self.observationWindowDiscovery {
                    return await observationWindowDiscovery(deviceID, normalizedSessionID)
                }
                return await self.discoverSessionWindow(sessionID: normalizedSessionID, deviceID: deviceID)
            }
        }
        logger.notice(
            "observation event=affinity_recovery outcome=\(result == nil ? "exhausted" : "recovered") device_id=\(Self.boundedLogIdentifier(deviceID)) session_id=\(Self.boundedLogIdentifier(normalizedSessionID)) window_id=\(result.map(String.init) ?? "none")"
        )
        return result
    }

    private func resolvedWindowID(
        forSession sessionID: String?,
        deviceID: String,
        bindingState: RemoteGatewayBindingState
    ) async -> Int? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else {
            return nil
        }
        if let cached = await sessionWindowAffinity.windowID(forSession: sessionID) {
            return cached
        }
        guard bindingState != .bound else {
            return nil
        }
        return await sessionWindowAffinity.resolvingWindowID(forSession: sessionID) {
            await self.discoverSessionWindow(sessionID: sessionID, deviceID: deviceID)
        }
    }

    private func rediscoverWindowIDAfterToolError(sessionID: String, deviceID: String) async -> Int? {
        await sessionWindowAffinity.invalidate(sessionID: sessionID)
        return await sessionWindowAffinity.resolvingWindowID(forSession: sessionID) {
            await self.discoverSessionWindow(sessionID: sessionID, deviceID: deviceID)
        }
    }

    private func discoverSessionWindow(sessionID targetSessionID: String, deviceID: String) async -> Int? {
        guard let (link, _) = try? await resolveAppLink(deviceID: deviceID) else { return nil }
        guard let eligible = await eligibleStartTargetWindowInfo(deviceID: deviceID), !eligible.windowIDs.isEmpty else {
            return nil
        }

        var hit: Int?
        for windowID in eligible.windowIDs.sorted() {
            let sessions = await Self.listSessionIDs(link: link, windowID: windowID)
            for sessionID in sessions {
                await sessionWindowAffinity.record(sessionID: sessionID, windowID: windowID)
                if sessionID == targetSessionID {
                    hit = windowID
                }
            }
        }
        return hit
    }

    private static func listSessionIDs(link: AppLinkSession, windowID: Int) async -> [String] {
        guard let result = try? await link.callTool(
            name: "agent_manage",
            arguments: [
                "op": .string("list_sessions"),
                "limit": .int(500),
                "_windowID": .int(windowID),
                "_rawJSON": .bool(true)
            ],
            timeout: 10
        ), result.isError != true,
        let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
        let sessions = payload.objectValue?["sessions"]?.arrayValue
        else { return [] }
        return sessions.compactMap { value in
            value.objectValue?["session_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    /// M6.6: observation ops (subscribe/unsubscribe and the wait/poll they arm)
    /// on an unbound multi-window connection fail with `binding_required`.
    private func observationBindingError(deviceID: String, frame: RemoteClientFrame) async -> RemoteCommandTranslatorError? {
        let resolved: (AppLinkSession, RemoteGatewayBindingState)
        do {
            resolved = try await resolveAppLink(deviceID: deviceID)
        } catch RemoteGatewayRuntimeError.deviceAppLinkUnavailable {
            return nil
        } catch {
            return nil
        }
        let bindingState = resolved.1
        switch bindingState {
        case .bound:
            return nil
        case let .bindingRequired(message):
            if await observationSessionsAreResolvable(frame: frame, deviceID: deviceID, bindingState: bindingState) {
                return nil
            }
            return .bindingRequired(message)
        case let .ambiguousStartTarget(message):
            if await observationSessionsAreResolvable(frame: frame, deviceID: deviceID, bindingState: bindingState) {
                return nil
            }
            return .bindingRequired(message)
        }
    }

    private func observationSessionsAreResolvable(
        frame: RemoteClientFrame,
        deviceID: String,
        bindingState: RemoteGatewayBindingState
    ) async -> Bool {
        guard let ids = try? sessionIDs(from: frame), !ids.isEmpty else { return false }
        for sessionID in ids {
            guard await resolvedWindowID(forSession: sessionID, deviceID: deviceID, bindingState: bindingState) != nil else {
                return false
            }
        }
        return true
    }

    /// M6.6: enriches binding errors with the eligible windows so remote clients
    /// can render an explicit start-target picker. Best-effort — a gateway-internal
    /// `bind_context op=list` on the device's app leg; failures degrade to the
    /// plain error without details.
    private func bindingErrorDetails(code: String, existing: JSONValue?, deviceID: String) async -> JSONValue? {
        let enrichedCodes = [
            "binding_required",
            "ambiguous_start_target",
            "workspace_not_open",
            "workspace_mismatch"
        ]
        guard enrichedCodes.contains(code) else { return existing }
        let windows: JSONValue
        if ["workspace_not_open", "workspace_mismatch"].contains(code),
           let cached = lastEligibleWindowDetailsByDevice[deviceID]
        {
            windows = cached
        } else if let windowInfo = await eligibleStartTargetWindowInfo(deviceID: deviceID) {
            windows = windowInfo.details
        } else if let cached = lastEligibleWindowDetailsByDevice[deviceID] {
            windows = cached
        } else {
            return existing
        }
        var object = existing?.objectValue ?? [:]
        object["windows"] = windows
        return .object(object)
    }

    private func eligibleStartTargetWindowInfo(deviceID: String) async -> EligibleStartTargetWindowInfo? {
        switch await eligibleStartTargetWindowInfoLookup(deviceID: deviceID) {
        case let .available(info):
            info
        case .unavailable:
            nil
        }
    }

    private func eligibleStartTargetWindowInfoLookup(deviceID: String) async -> EligibleStartTargetWindowInfoLookupResult {
        let link: AppLinkSession
        do {
            (link, _) = try await resolveAppLink(deviceID: deviceID)
        } catch {
            return .unavailable(.appLinkUnavailable)
        }

        let result: MCPToolResult
        do {
            result = try await link.callTool(
                name: "bind_context",
                arguments: ["op": .string("list"), "_rawJSON": .bool(true)],
                timeout: 10
            )
        } catch {
            return .unavailable(.appToolError)
        }
        guard result.isError != true else { return .unavailable(.appToolError) }
        guard let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
              let windows = payload.objectValue?["windows"]?.arrayValue
        else { return .unavailable(.decodeFailure) }
        guard !windows.isEmpty else { return .unavailable(.emptyWindowList) }

        var windowIDs: [Int] = []
        let summaries: [EligibleStartTargetWindowSummary] = windows.compactMap { window in
            guard let object = window.objectValue,
                  let windowIDValue = object["window_id"],
                  let windowID = windowIDValue.intValue
            else { return nil }
            windowIDs.append(windowID)
            var summary: [String: JSONValue] = ["window_id": windowIDValue]
            var workspaceID: String?
            var workspaceName: String?
            if let workspace = object["workspace"]?.objectValue {
                if let id = workspace["id"] {
                    summary["workspace_id"] = id
                    workspaceID = id.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let name = workspace["name"] {
                    summary["workspace_name"] = name
                    workspaceName = name.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return EligibleStartTargetWindowSummary(
                windowID: windowID,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                details: .object(summary)
            )
        }
        guard !summaries.isEmpty else { return .unavailable(.decodeFailure) }
        let details = JSONValue.array(summaries.map(\.details))
        lastEligibleWindowDetailsByDevice[deviceID] = details
        return .available(EligibleStartTargetWindowInfo(details: details, windowIDs: windowIDs, summaries: summaries))
    }

    private func responseFrame(for outcome: CommandLedger.RecordedOutcome, frame: RemoteClientFrame) -> RemoteServerFrame {
        switch outcome {
        case .success:
            .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: outcome.responsePayload
            )
        case let .failure(code, message):
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: code,
                message: message
            )
        case .interactionAlreadyResolved:
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "interaction_already_resolved",
                message: "The interaction was already resolved; poll/get_log for authoritative state.",
                details: outcome.responsePayload
            )
        case .inDoubt:
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "in_doubt",
                message: "The command is in doubt after app-link loss or gateway recovery; poll/get_log for authoritative state."
            )
        }
    }

    private func ledgerOutcome(for error: Error, frame: RemoteClientFrame) -> CommandLedger.RecordedOutcome {
        if let appLinkError = error as? AppLinkError {
            switch appLinkError {
            // An authoritative RPC error proves a response arrived but not the execution outcome, and
            // an uncertain failure's provenance is unknown; both are IN DOUBT exactly like a timeout
            // or lost link — never a definite failure and never a safe-retry signal. (Step 3 Oracle
            // plan §3: response provenance does not prove execution outcome.)
            case .toolCallTimedOut, .appLinkLost, .authoritativeToolFailure, .uncertainToolFailure:
                return .inDoubt
            default:
                break
            }
        }
        if frame.type == "respond",
           let interactionID = frame.payload?.objectValue?["interaction_id"]?.stringValue,
           isInteractionAlreadyResolved(error)
        {
            return .interactionAlreadyResolved(interactionID: interactionID)
        }
        let mapped = mapError(error, frame: frame)
        return .failure(code: mapped.code, message: mapped.message)
    }

    private func mapError(_ error: Error, frame: RemoteClientFrame) -> (code: String, message: String, details: JSONValue?) {
        if let error = error as? RemoteCommandTranslatorError {
            return (error.code, error.description, nil)
        }
        if let error = error as? RemoteWireProtocolError {
            return (error.code, error.description, nil)
        }
        if let error = error as? AppLinkError {
            switch error {
            case .notConnected:
                return ("app_link_unavailable", error.description, nil)
            case .toolCallTimedOut:
                return ("tool_call_timeout", error.description, nil)
            case .appLinkLost:
                return ("app_link_lost", error.description, nil)
            default:
                return ("app_link_error", error.description, nil)
            }
        }
        if let runtimeError = error as? RemoteGatewayRuntimeError {
            return (runtimeError.code(frame: frame), runtimeError.message, runtimeError.details)
        }
        return ("command_failed", String(describing: error), nil)
    }

    private func isInteractionAlreadyResolved(_ error: Error) -> Bool {
        let message: String = if let runtimeError = error as? RemoteGatewayRuntimeError {
            runtimeError.message
        } else {
            String(describing: error)
        }
        let normalized = message.lowercased()
        return normalized.contains("already resolved")
            || normalized.contains("no pending interaction")
            || normalized.contains("not pending")
            || normalized.contains("interaction") && normalized.contains("stale")
    }

    private func sessionIDs(from frame: RemoteClientFrame) throws -> [String] {
        if let sessionID = frame.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return [sessionID]
        }
        if let values = frame.payload?.objectValue?["session_ids"]?.arrayValue {
            let ids = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !ids.isEmpty {
                return ids
            }
        }
        throw RemoteCommandTranslatorError.missingSessionID(frame.type)
    }

    private func singleSessionIDIfSessionAddressed(_ frame: RemoteClientFrame) -> String? {
        if frame.type == "list_sessions" {
            return parentSessionID(from: frame)
        }
        guard ["steer", "respond", "cancel", "get_log", "fork_session", "extract_handoff", "poll"].contains(frame.type) else {
            return nil
        }
        guard let ids = try? sessionIDs(from: frame), ids.count == 1 else { return nil }
        return ids[0]
    }

    private func parentSessionID(from frame: RemoteClientFrame) -> String? {
        guard frame.type == "list_sessions",
              let raw = frame.payload?.objectValue?["parent_session_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private func pollFrame(from frame: RemoteClientFrame, sessionIDs: [String]) -> RemoteClientFrame {
        var payload = frame.payload?.objectValue ?? [:]
        payload.removeValue(forKey: "session_id")
        if sessionIDs.count == 1 {
            payload.removeValue(forKey: "session_ids")
            return RemoteClientFrame(
                type: "poll",
                requestID: frame.requestID,
                sessionID: sessionIDs[0],
                payload: payload.isEmpty ? nil : .object(payload)
            )
        }
        payload["session_ids"] = .array(sessionIDs.map(JSONValue.string))
        return RemoteClientFrame(type: "poll", requestID: frame.requestID, payload: .object(payload))
    }

    private func bindingRequiredMessage(_ state: RemoteGatewayBindingState) -> String {
        switch state {
        case .bound:
            "The app link is not bound to a window."
        case let .bindingRequired(message), let .ambiguousStartTarget(message):
            message
        }
    }

    private func recordExplicitStartAffinityIfNeeded(frame: RemoteClientFrame, payload: JSONValue) async {
        guard frame.type == "start",
              let windowID = explicitStartWindowID(frame),
              let sessionID = payload.objectValue?["session_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else { return }
        await sessionWindowAffinity.record(sessionID: sessionID, windowID: windowID)
    }

    /// A successful `fork_session` creates a brand-new session in the window
    /// the call was routed to (the app forks under `requireTargetWindow()`).
    /// Record that session→window affinity immediately so the client's
    /// follow-up attach (subscribe validation + catch-up poll, observed ~90ms
    /// after the fork in the 2026-07-27 incident) routes deterministically
    /// instead of racing per-window discovery against the app's async
    /// registration of the staged destination tab. Recorded per successful
    /// attempt in `executeTranslatedTool` so corrective retries persist the
    /// window that actually served the call. Best-effort cache write: nil
    /// window (legacy/bound routing) and malformed payloads are silent no-ops.
    /// Depends on `executeForkSession`'s stable `{"session":{"session_id":…}}`
    /// response envelope.
    private func recordForkSessionAffinityIfNeeded(
        frame: RemoteClientFrame,
        payload: JSONValue,
        windowID: Int?
    ) async {
        guard frame.type == "fork_session",
              let windowID,
              let sessionID = payload.objectValue?["session"]?.objectValue?["session_id"]?.stringValue?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else { return }
        await sessionWindowAffinity.record(sessionID: sessionID, windowID: windowID)
    }

    private func explicitStartWindowID(_ frame: RemoteClientFrame) -> Int? {
        guard frame.type == "start", let value = frame.payload?.objectValue?["window_id"] else { return nil }
        if let intValue = value.intValue {
            return intValue
        }
        if let stringValue = value.stringValue {
            return Int(stringValue)
        }
        return nil
    }

    private func rememberAutoRoutedStart(frame: RemoteClientFrame, deviceID: String, windowID: Int) {
        guard frame.type == "start", let requestID = frame.requestID else { return }
        autoRoutedStartWindowIDByCommandKey["\(deviceID)|\(requestID)"] = windowID
    }

    private func takeAutoRoutedStartWindowID(frame: RemoteClientFrame, deviceID: String) -> Int? {
        guard frame.type == "start", let requestID = frame.requestID else { return nil }
        return autoRoutedStartWindowIDByCommandKey.removeValue(forKey: "\(deviceID)|\(requestID)")
    }

    private func commandKey(frame: RemoteClientFrame, deviceID: String) -> String? {
        guard let requestID = frame.requestID else { return nil }
        return "\(deviceID)|\(requestID)"
    }

    private func rememberListAgentsAttemptStart(
        frame: RemoteClientFrame,
        deviceID: String,
        bindingState: RemoteGatewayBindingState,
        mode: ListAgentsRecoveryMode
    ) {
        guard frame.type == "list_agents",
              mode != .disabled,
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        var diagnostics = listAgentsRoutingDiagnosticsByCommandKey[key] ?? ListAgentsRoutingDiagnostics()
        switch mode {
        case .armed:
            diagnostics.bindingStateInitial = bindingStateCategory(bindingState)
            diagnostics.fallbackInitial = "not_run"
            diagnostics.recoveryRetried = false
        case .retrying:
            diagnostics.bindingStateRetry = bindingStateCategory(bindingState)
            diagnostics.fallbackRetry = "not_run"
            diagnostics.recoveryRetried = true
        case .disabled:
            return
        }
        listAgentsRoutingDiagnosticsByCommandKey[key] = diagnostics
    }

    private func rememberListAgentsFallback(
        frame: RemoteClientFrame,
        deviceID: String,
        outcome: String,
        mode: ListAgentsRecoveryMode
    ) {
        guard frame.type == "list_agents",
              mode != .disabled,
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        var diagnostics = listAgentsRoutingDiagnosticsByCommandKey[key] ?? ListAgentsRoutingDiagnostics()
        switch mode {
        case .armed:
            diagnostics.fallbackInitial = outcome
        case .retrying:
            diagnostics.fallbackRetry = outcome
        case .disabled:
            return
        }
        listAgentsRoutingDiagnosticsByCommandKey[key] = diagnostics
    }

    private func rememberListAgentsWindowIDInjection(
        frame: RemoteClientFrame,
        deviceID: String,
        injected: Bool,
        mode: ListAgentsRecoveryMode
    ) {
        guard frame.type == "list_agents",
              mode != .disabled,
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        var diagnostics = listAgentsRoutingDiagnosticsByCommandKey[key] ?? ListAgentsRoutingDiagnostics()
        switch mode {
        case .armed:
            diagnostics.windowIDInjectedInitial = injected
        case .retrying:
            diagnostics.windowIDInjectedRetry = injected
        case .disabled:
            return
        }
        listAgentsRoutingDiagnosticsByCommandKey[key] = diagnostics
    }

    private func rememberListAgentsErrorOrigin(
        frame: RemoteClientFrame,
        deviceID: String,
        origin: String,
        mode: ListAgentsRecoveryMode
    ) {
        guard frame.type == "list_agents",
              mode != .disabled,
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        var diagnostics = listAgentsRoutingDiagnosticsByCommandKey[key] ?? ListAgentsRoutingDiagnostics()
        switch mode {
        case .armed:
            diagnostics.errorOriginInitial = origin
        case .retrying:
            diagnostics.errorOriginRetry = origin
        case .disabled:
            return
        }
        listAgentsRoutingDiagnosticsByCommandKey[key] = diagnostics
    }

    private func takeListAgentsRoutingDiagnostics(
        frame: RemoteClientFrame,
        deviceID: String
    ) -> ListAgentsRoutingDiagnostics? {
        guard frame.type == "list_agents",
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return nil }
        return listAgentsRoutingDiagnosticsByCommandKey.removeValue(forKey: key)
    }

    private nonisolated static func boundedLogIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "id_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func bindingStateCategory(_ state: RemoteGatewayBindingState) -> String {
        switch state {
        case .bound:
            "bound"
        case .bindingRequired:
            "binding_required"
        case .ambiguousStartTarget:
            "ambiguous_start_target"
        }
    }

    private func rememberWorkspaceMatchCount(frame: RemoteClientFrame, deviceID: String, count: Int) {
        guard ["start", "list_sessions"].contains(frame.type),
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        workspaceMatchCountByCommandKey[key] = count
    }

    private func takeWorkspaceMatchCount(frame: RemoteClientFrame, deviceID: String) -> Int? {
        guard ["start", "list_sessions"].contains(frame.type),
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return nil }
        return workspaceMatchCountByCommandKey.removeValue(forKey: key)
    }

    private func rememberWorkspaceStartMatchSkipped(frame: RemoteClientFrame, deviceID: String, reason: WorkspaceMatchSkippedReason) {
        guard frame.type == "start", let key = commandKey(frame: frame, deviceID: deviceID) else { return }
        workspaceStartMatchSkippedByCommandKey[key] = reason.rawValue
    }

    private func takeWorkspaceStartMatchSkipped(frame: RemoteClientFrame, deviceID: String) -> String? {
        guard frame.type == "start", let key = commandKey(frame: frame, deviceID: deviceID) else { return nil }
        return workspaceStartMatchSkippedByCommandKey.removeValue(forKey: key)
    }

    private func rememberWorkspaceMatchUnavailableReason(frame: RemoteClientFrame, deviceID: String, reason: String) {
        guard ["start", "list_sessions"].contains(frame.type),
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return }
        workspaceMatchUnavailableReasonByCommandKey[key] = reason
    }

    private func takeWorkspaceMatchUnavailableReason(frame: RemoteClientFrame, deviceID: String) -> String? {
        guard ["start", "list_sessions"].contains(frame.type),
              let key = commandKey(frame: frame, deviceID: deviceID)
        else { return nil }
        return workspaceMatchUnavailableReasonByCommandKey.removeValue(forKey: key)
    }

    private func audit(
        frame: RemoteClientFrame,
        deviceID: String,
        outcome: String,
        code: String? = nil,
        responsePayload: JSONValue? = nil
    ) {
        let requestPayload = frame.payload?.objectValue ?? [:]
        let responseObject = responsePayload?.objectValue ?? [:]
        let shouldConsumeWorkspaceDiagnostics = outcome != "duplicate" && outcome != "in_flight" && outcome != "conflict"
        let autoRoutedWindowID = shouldConsumeWorkspaceDiagnostics ? takeAutoRoutedStartWindowID(frame: frame, deviceID: deviceID) : nil
        let workspaceMatchCount = shouldConsumeWorkspaceDiagnostics ? takeWorkspaceMatchCount(frame: frame, deviceID: deviceID) : nil
        let workspaceMatchSkipped = shouldConsumeWorkspaceDiagnostics ? takeWorkspaceStartMatchSkipped(frame: frame, deviceID: deviceID) : nil
        let workspaceMatchUnavailableReason = shouldConsumeWorkspaceDiagnostics
            ? takeWorkspaceMatchUnavailableReason(frame: frame, deviceID: deviceID)
            : nil
        let listAgentsDiagnostics = shouldConsumeWorkspaceDiagnostics
            ? takeListAgentsRoutingDiagnostics(frame: frame, deviceID: deviceID)
            : nil
        let isWorkspaceSelectorFailure = ["start", "list_sessions"].contains(frame.type)
            && outcome == "failure"
            && ["binding_required", "ambiguous_start_target", "workspace_not_open", "workspace_mismatch"].contains(code)
        let recordsWorkspaceSelector = frame.type == "open_workspace" || isWorkspaceSelectorFailure
        let hasWorkspaceName = requestPayload["workspace_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasWorkspaceID = requestPayload["workspace_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        auditLog?.recordBestEffort(RemoteAuditRecord(
            deviceID: deviceID,
            requestID: frame.requestID,
            op: frame.type,
            sessionID: frame.sessionID,
            outcome: outcome,
            code: code,
            offset: frame.type == "get_log" ? requestPayload["offset"]?.intValue : nil,
            limit: frame.type == "get_log" ? requestPayload["limit"]?.intValue : nil,
            returnedTurnCount: frame.type == "get_log" ? responseObject["returned_turn_count"]?.intValue : nil,
            completedTurnCount: frame.type == "get_log" ? responseObject["completed_turn_count"]?.intValue : nil,
            transcriptXMLChars: frame.type == "get_log" ? responseObject["transcript_xml"]?.stringValue?.count : nil,
            autoRoutedWindowID: autoRoutedWindowID,
            windowID: frame.type == "open_workspace" && outcome == "success"
                ? responseObject["window_id"]?.intValue
                : nil,
            hasWorkspaceName: recordsWorkspaceSelector ? hasWorkspaceName : nil,
            hasWorkspaceID: recordsWorkspaceSelector ? hasWorkspaceID : nil,
            workspaceMatchCount: ["start", "list_sessions"].contains(frame.type) ? workspaceMatchCount : nil,
            workspaceMatchSkipped: frame.type == "start" ? workspaceMatchSkipped : nil,
            workspaceMatchUnavailableReason: ["start", "list_sessions"].contains(frame.type)
                ? workspaceMatchUnavailableReason
                : nil,
            bindingStateInitial: listAgentsDiagnostics?.bindingStateInitial,
            bindingStateRetry: listAgentsDiagnostics?.bindingStateRetry,
            fallbackInitial: listAgentsDiagnostics?.fallbackInitial,
            fallbackRetry: listAgentsDiagnostics?.fallbackRetry,
            windowIDInjectedInitial: listAgentsDiagnostics?.windowIDInjectedInitial,
            windowIDInjectedRetry: listAgentsDiagnostics?.windowIDInjectedRetry,
            errorOriginInitial: listAgentsDiagnostics?.errorOriginInitial,
            errorOriginRetry: listAgentsDiagnostics?.errorOriginRetry,
            recoveryRetried: listAgentsDiagnostics?.recoveryRetried
        ))
    }
}

private actor BoundedObservationResolutionGate {
    private var resolved = false
    private var result: Int?
    private var waiters: [CheckedContinuation<Int?, Never>] = []

    func resolve(_ result: Int?) {
        guard !resolved else { return }
        resolved = true
        self.result = result
        waiters.forEach { $0.resume(returning: result) }
        waiters.removeAll()
    }

    func value() async -> Int? {
        if resolved {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func withBoundedObservationResolution(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> Int?
) async -> Int? {
    let gate = BoundedObservationResolutionGate()
    let discoveryTask = Task {
        await gate.resolve(operation())
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: .milliseconds(Int64((max(0.01, seconds) * 1000).rounded(.up))))
        guard !Task.isCancelled else { return }
        await gate.resolve(nil)
    }
    let result = await withTaskCancellationHandler {
        await gate.value()
    } onCancel: {
        Task { await gate.resolve(nil) }
    }
    timeoutTask.cancel()
    discoveryTask.cancel()
    return result
}

enum RemoteGatewayRuntimeError: Error, Equatable {
    case appToolError(payload: JSONValue)
    case deviceAppLinkUnavailable(deviceID: String)
    case workspaceNotOpen(workspaceName: String?)
    case workspaceWindowLookupUnavailable(reason: String)

    var message: String {
        switch self {
        case let .appToolError(payload):
            if let object = payload.objectValue {
                if let error = object["error"]?.stringValue {
                    return error
                }
                if let message = object["message"]?.stringValue {
                    return message
                }
            }
            return "App tool returned an error."
        case let .deviceAppLinkUnavailable(deviceID):
            return "Device app link \(deviceID) is not active; remote commands are paused until it reconnects."
        case let .workspaceNotOpen(workspaceName):
            if let workspaceName {
                return "Workspace '\(workspaceName)' is not open on the host."
            }
            return "The requested workspace is not open on the host."
        case let .workspaceWindowLookupUnavailable(reason):
            return "Workspace window lookup is unavailable (\(reason))."
        }
    }

    var details: JSONValue? {
        switch self {
        case let .appToolError(payload):
            payload
        case let .deviceAppLinkUnavailable(deviceID):
            .object(["device_id": .string(deviceID)])
        case .workspaceNotOpen, .workspaceWindowLookupUnavailable:
            nil
        }
    }

    func code(frame: RemoteClientFrame) -> String {
        switch self {
        case let .appToolError(payload):
            let normalized = message.lowercased()
            if normalized.contains("workspace_mismatch") {
                return "workspace_mismatch"
            }
            if let code = payload.objectValue?["code"]?.stringValue {
                return code
            }
            if frame.type != "open_workspace",
               normalized.contains("bind"),
               normalized.contains("window")
            {
                return "binding_required"
            }
            if frame.type == "start", normalized.contains("ambiguous") || normalized.contains("multiple") {
                return "ambiguous_start_target"
            }
            if normalized.contains("session"), normalized.contains("not found") || normalized.contains("no longer active") {
                return "session_expired"
            }
            return "app_tool_error"
        case .deviceAppLinkUnavailable:
            return "app_link_unavailable"
        case .workspaceNotOpen:
            return "workspace_not_open"
        case let .workspaceWindowLookupUnavailable(reason):
            return reason == "app_link_unavailable"
                ? "app_link_unavailable"
                : "app_tool_error"
        }
    }
}
