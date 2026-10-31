import Foundation
import MCP
import RepoPromptRemoteWire
import RepoPromptShared

struct RemoteToolCall: Equatable {
    let toolName: String
    let arguments: [String: Value]
    let timeout: TimeInterval?

    init(toolName: String, arguments: [String: Value], timeout: TimeInterval? = nil) {
        self.toolName = toolName
        self.arguments = arguments
        self.timeout = timeout
    }
}

enum AppLinkCallTimeoutPolicy {
    static let fast: TimeInterval = 60
    static let grace: TimeInterval = 30
    /// App-link response cap only; expiry does not cancel an already accepted lifecycle worker.
    /// Remote callers resolve as unresolved (180 seconds), so a clamped shared envelope is only a response bound.
    static let cap: TimeInterval = 900

    static func timeout(op: String, payload: [String: JSONValue]) -> TimeInterval {
        switch op {
        case "start":
            guard let requestedSeconds = seconds(from: payload["timeout"]) else {
                // The gateway cannot determine whether an omitted-timeout start detaches.
                return clamp(MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds)
            }
            return clamp(requestedSeconds + grace)
        case "poll":
            return clamp((seconds(from: payload["timeout"]) ?? 0) + grace)
        case "steer":
            let wait = semanticBool(payload["wait"])
            guard wait != false else { return fast }
            let hasWaitIntent = wait == true || payload["timeout_seconds"] != nil
            guard hasWaitIntent else { return fast }
            guard let requestedSeconds = seconds(from: payload["timeout_seconds"]) else {
                return clamp(MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds)
            }
            return clamp(requestedSeconds + grace)
        default:
            return fast
        }
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, fast), cap)
    }

    private static func seconds(from value: JSONValue?) -> TimeInterval? {
        guard let value else { return nil }
        switch value {
        case let .int(seconds):
            return TimeInterval(seconds)
        case let .double(seconds):
            return seconds
        default:
            return nil
        }
    }

    /// Matches the app lifecycle service's accepted boolean representations.
    private static func semanticBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case let .bool(value):
            value
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                true
            case "false", "0", "no":
                false
            default:
                nil
            }
        case let .int(value):
            value != 0
        case let .double(value):
            value != 0
        default:
            nil
        }
    }
}

enum RemoteGatewayBindingState: Equatable {
    case bound
    case bindingRequired(String)
    case ambiguousStartTarget(String)
}

enum RemoteCommandTranslatorError: Error, Equatable, CustomStringConvertible {
    case unsupportedFrameType(String)
    case missingSessionID(String)
    case missingPayloadField(String)
    case invalidPayload(String)
    case unsupportedPayloadKey(operation: String, key: String)
    case arbitraryToolPassthroughRejected
    case ambiguousStartTarget
    case bindingRequired(String)

    var code: String {
        switch self {
        case .unsupportedFrameType: "unsupported_frame_type"
        case .missingSessionID: "missing_session_id"
        case .missingPayloadField: "missing_payload_field"
        case .invalidPayload: "invalid_payload"
        case .unsupportedPayloadKey: "unsupported_payload_key"
        case .arbitraryToolPassthroughRejected: "arbitrary_tool_passthrough_rejected"
        case .ambiguousStartTarget: "ambiguous_start_target"
        case .bindingRequired: "binding_required"
        }
    }

    var description: String {
        switch self {
        case let .unsupportedFrameType(type):
            "Remote frame type '\(type)' does not map to an app MCP tool."
        case let .missingSessionID(operation):
            "session_id is required for remote operation '\(operation)'."
        case let .missingPayloadField(field):
            "payload.\(field) is required."
        case let .invalidPayload(message):
            message
        case let .unsupportedPayloadKey(operation, key):
            "Remote operation '\(operation)' does not support payload key '\(key)'."
        case .arbitraryToolPassthroughRejected:
            "Remote frames cannot choose arbitrary MCP tools or raw arguments."
        case .ambiguousStartTarget:
            "Remote start is ambiguous because the app link is not bound to exactly one window."
        case let .bindingRequired(message):
            message
        }
    }
}

struct RemoteCommandTranslator {
    private let bindingState: RemoteGatewayBindingState

    init(bindingState: RemoteGatewayBindingState = .bound) {
        self.bindingState = bindingState
    }

    func translate(_ frame: RemoteClientFrame, resolvedWindowID: Int? = nil) throws -> RemoteToolCall {
        let payload = try payloadObject(frame.payload)
        try rejectPassthroughKeys(payload)
        try enforceBinding(for: frame.type, payload: payload, resolvedWindowID: resolvedWindowID)

        switch frame.type {
        case "start":
            return try translateAgentRun(
                frame: frame,
                op: "start",
                payload: payload,
                allowedPayloadKeys: Self.startPayloadKeys,
                requiresSessionID: false,
                resolvedWindowID: nil
            )
        case "steer":
            return try translateAgentRun(
                frame: frame,
                op: "steer",
                payload: payload,
                allowedPayloadKeys: Self.steerPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        case "respond":
            return try translateAgentRun(
                frame: frame,
                op: "respond",
                payload: payload,
                allowedPayloadKeys: Self.respondPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        case "cancel":
            return try translateAgentRun(
                frame: frame,
                op: "cancel",
                payload: payload,
                allowedPayloadKeys: Self.cancelPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        case "poll":
            return try translateAgentRun(
                frame: frame,
                op: "poll",
                payload: payload,
                allowedPayloadKeys: Self.pollPayloadKeys,
                requiresSessionID: frame.sessionID == nil && payload["session_ids"] == nil,
                resolvedWindowID: resolvedWindowID
            )
        case "subscribe", "unsubscribe":
            // Subscriptions are gateway-owned observation state, but their immediate
            // catch-up/validation is still an agent_run poll of the addressed session(s).
            return try translateAgentRun(
                frame: frame,
                op: "poll",
                payload: payload,
                allowedPayloadKeys: Self.pollPayloadKeys,
                requiresSessionID: frame.sessionID == nil && payload["session_ids"] == nil,
                resolvedWindowID: resolvedWindowID
            )
        case "list_agents":
            return try translateAgentManage(
                op: "list_agents",
                payload: payload,
                allowedPayloadKeys: Self.listAgentsPayloadKeys,
                resolvedWindowID: resolvedWindowID
            )
        case "list_sessions":
            return try translateAgentManage(
                op: "list_sessions",
                payload: payload,
                allowedPayloadKeys: Self.listSessionsPayloadKeys,
                resolvedWindowID: resolvedWindowID
            )
        case "open_workspace":
            return try translateOpenWorkspace(payload: payload)
        case "get_log":
            return try translateAgentManage(
                frame: frame,
                op: "get_log",
                payload: payload,
                allowedPayloadKeys: Self.getLogPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        case "fork_session":
            return try translateAgentManage(
                frame: frame,
                op: "fork_session",
                payload: payload,
                allowedPayloadKeys: Self.forkSessionPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        case "extract_handoff":
            return try translateAgentManage(
                frame: frame,
                op: "extract_handoff",
                payload: payload,
                allowedPayloadKeys: Self.extractHandoffPayloadKeys,
                requiresSessionID: true,
                resolvedWindowID: resolvedWindowID
            )
        default:
            throw RemoteCommandTranslatorError.unsupportedFrameType(frame.type)
        }
    }

    private func enforceBinding(for operation: String, payload: [String: JSONValue], resolvedWindowID: Int?) throws {
        // open_workspace names its own workspace target and is intentionally binding-exempt.
        if operation == "open_workspace" {
            return
        }

        switch bindingState {
        case .bound:
            return
        case let .bindingRequired(message):
            // M6.6: an explicit start selector names its own target, so start may
            // proceed on an unbound multi-window connection. Observation and
            // session-addressed operations still require binding.
            if operation == "start", hasExplicitStartTarget(payload) {
                return
            }
            if resolvedWindowID != nil, Self.sessionAddressedOperations.contains(operation) {
                return
            }
            if operation == "list_agents", resolvedWindowID != nil {
                return
            }
            throw RemoteCommandTranslatorError.bindingRequired(message)
        case .ambiguousStartTarget where operation == "start":
            if hasExplicitStartTarget(payload) {
                return
            }
            throw RemoteCommandTranslatorError.ambiguousStartTarget
        case let .ambiguousStartTarget(message):
            if resolvedWindowID != nil, Self.sessionAddressedOperations.contains(operation) {
                return
            }
            if operation == "list_agents", resolvedWindowID != nil {
                return
            }
            throw RemoteCommandTranslatorError.bindingRequired(message)
        }
    }

    private func hasExplicitStartTarget(_ payload: [String: JSONValue]) -> Bool {
        // Only `window_id` names a resolvable target at translation time.
        // `workspace_id` and `workspace_name` are matching/validation hints;
        // alone they cannot route here, so they must not suppress structured
        // binding_required/ambiguous_start_target errors that carry
        // `details.windows` and drive client window pickers.
        payload["window_id"] != nil
    }

    private func translateAgentRun(
        frame: RemoteClientFrame,
        op: String,
        payload: [String: JSONValue],
        allowedPayloadKeys: Set<String>,
        requiresSessionID: Bool,
        resolvedWindowID: Int?
    ) throws -> RemoteToolCall {
        try validateAllowedPayloadKeys(payload, operation: frame.type, allowed: allowedPayloadKeys)
        var arguments = commonArguments(op: op)
        if let sessionID = frame.sessionID {
            arguments["session_id"] = .string(sessionID)
        } else if requiresSessionID {
            throw RemoteCommandTranslatorError.missingSessionID(frame.type)
        }
        // Phase 2 (plan §6.1): forward the remote request_id so the app-side
        // idempotency registry can absorb duplicates end-to-end.
        if let requestID = frame.requestID, ["start", "steer", "respond"].contains(op) {
            arguments["request_id"] = .string(requestID)
        }
        for (key, value) in payload {
            if key == "session_ids" {
                arguments[key] = value.mcpValue
            } else if key == "window_id" {
                // M6.6 explicit start selector: reuse the app's hidden one-shot
                // `_windowID` routing override (dispatcher priority 0). Never
                // synthesize routing state — the app binds/redirects per call.
                if let intValue = value.intValue {
                    arguments["_windowID"] = .int(intValue)
                } else if let stringValue = value.stringValue, let intValue = Int(stringValue) {
                    arguments["_windowID"] = .int(intValue)
                } else {
                    throw RemoteCommandTranslatorError.invalidPayload("payload.window_id must be an integer window id.")
                }
            } else if key == "workspace_id" {
                // Validated app-side against the resolved window's active workspace.
                arguments["workspace_id"] = value.mcpValue
            } else if key == "workspace_name" {
                // Gateway-only routing hint; the app agent_run payload has no matching field.
                continue
            } else if key == "interaction_id" || key == "message" || key == "response" || key == "answers"
                || key == "content" || key == "meta" || key == "_meta" || key == "amendment"
                || key == "workflow_id" || key == "workflow_name" || key == "model_id"
                || key == "session_name" || key == "timeout" || key == "timeout_seconds"
                || key == "wait" || key == "skip" || key.hasPrefix("worktree") || key == "detach"
                || key == "allow_external_worktree_path" || key == "run_id"
            {
                arguments[key] = value.mcpValue
            }
        }
        if let resolvedWindowID, Self.sessionAddressedAgentRunOps.contains(op) {
            arguments["_windowID"] = .int(resolvedWindowID)
        }
        return RemoteToolCall(
            toolName: "agent_run",
            arguments: arguments,
            timeout: AppLinkCallTimeoutPolicy.timeout(op: op, payload: payload)
        )
    }

    private func translateAgentManage(
        frame: RemoteClientFrame? = nil,
        op: String,
        payload: [String: JSONValue],
        allowedPayloadKeys: Set<String>,
        requiresSessionID: Bool = false,
        resolvedWindowID: Int? = nil
    ) throws -> RemoteToolCall {
        try validateAllowedPayloadKeys(payload, operation: frame?.type ?? op, allowed: allowedPayloadKeys)
        var arguments = commonArguments(op: op)
        if let sessionID = frame?.sessionID {
            arguments["session_id"] = .string(sessionID)
        } else if requiresSessionID {
            throw RemoteCommandTranslatorError.missingSessionID(frame?.type ?? op)
        }
        for (key, value) in payload {
            if op == "list_sessions", key == "workspace_name" {
                // Gateway-only routing hint; the host validates workspace_id instead.
                continue
            }
            arguments[key] = value.mcpValue
        }
        if let resolvedWindowID, Self.sessionAddressedAgentManageOps.contains(op) || op == "list_agents" {
            arguments["_windowID"] = .int(resolvedWindowID)
        }
        return RemoteToolCall(
            toolName: "agent_manage",
            arguments: arguments,
            timeout: AppLinkCallTimeoutPolicy.timeout(op: op, payload: payload)
        )
    }

    private func translateOpenWorkspace(payload: [String: JSONValue]) throws -> RemoteToolCall {
        try validateAllowedPayloadKeys(
            payload,
            operation: "open_workspace",
            allowed: Self.openWorkspacePayloadKeys
        )
        let rawWorkspaceID = payload["workspace_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWorkspaceName = payload["workspace_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = rawWorkspaceID?.isEmpty == false ? rawWorkspaceID : nil
        let workspaceName = rawWorkspaceName?.isEmpty == false ? rawWorkspaceName : nil
        guard workspaceID != nil || workspaceName != nil else {
            throw RemoteCommandTranslatorError.invalidPayload(
                "open_workspace requires a nonblank payload.workspace_id or payload.workspace_name."
            )
        }

        var arguments: [String: Value] = [
            "action": .string("open"),
            "_rawJSON": .bool(true)
        ]
        if let workspaceID {
            // ID precedence is encoded by forwarding only the ID when both selectors are present.
            arguments["workspace_id"] = .string(workspaceID)
        } else if let workspaceName {
            arguments["workspace_name"] = .string(workspaceName)
        }
        return RemoteToolCall(
            toolName: "manage_workspaces",
            arguments: arguments,
            timeout: AppLinkCallTimeoutPolicy.timeout(op: "manage_workspaces", payload: payload)
        )
    }

    private func commonArguments(op: String) -> [String: Value] {
        [
            "op": .string(op),
            "_rawJSON": .bool(true)
        ]
    }

    private func payloadObject(_ payload: JSONValue?) throws -> [String: JSONValue] {
        guard let payload else { return [:] }
        guard let object = payload.objectValue else {
            throw RemoteCommandTranslatorError.invalidPayload("payload must be an object when present.")
        }
        return object
    }

    private func rejectPassthroughKeys(_ payload: [String: JSONValue]) throws {
        let forbidden = ["tool", "tool_name", "name", "arguments", "args"]
        if payload.keys.contains(where: { forbidden.contains($0) }) {
            throw RemoteCommandTranslatorError.arbitraryToolPassthroughRejected
        }
        if payload["op"] != nil {
            throw RemoteCommandTranslatorError.arbitraryToolPassthroughRejected
        }
    }

    private func validateAllowedPayloadKeys(
        _ payload: [String: JSONValue],
        operation: String,
        allowed: Set<String>
    ) throws {
        for key in payload.keys.sorted() where !allowed.contains(key) {
            throw RemoteCommandTranslatorError.unsupportedPayloadKey(operation: operation, key: key)
        }
    }

    private static let commonWorktreePayloadKeys: Set<String> = [
        "worktree",
        "worktree_id",
        "worktree_create",
        "worktree_repo_root",
        "worktree_branch",
        "worktree_base_ref",
        "worktree_path",
        "allow_external_worktree_path",
        "worktree_label",
        "worktree_color",
        "inherit_worktree"
    ]

    private static let startPayloadKeys: Set<String> = Set([
        "message",
        "model_id",
        "session_name",
        "timeout",
        "detach",
        "workflow_id",
        "workflow_name",
        // M6.6 explicit multi-window start selectors plus gateway-only matching hints.
        "window_id",
        "workspace_id",
        "workspace_name"
    ]).union(commonWorktreePayloadKeys)

    private static let steerPayloadKeys: Set<String> = [
        "message",
        "workflow_id",
        "workflow_name",
        "wait",
        "timeout_seconds"
    ]

    private static let respondPayloadKeys: Set<String> = [
        "interaction_id",
        "response",
        "answers",
        "skip",
        "content",
        "meta",
        "_meta",
        "amendment",
        "workflow_id",
        "workflow_name"
    ]

    /// `run_id` is the run the caller last observed. The app refuses the cancel when a newer
    /// run has replaced it, so a stale Stop can't end a later run.
    private static let cancelPayloadKeys: Set<String> = [
        "run_id"
    ]

    private static let pollPayloadKeys: Set<String> = [
        "session_ids",
        "timeout"
    ]

    private static let listAgentsPayloadKeys: Set<String> = [
        "include_model_parameters"
    ]

    private static let openWorkspacePayloadKeys: Set<String> = [
        "workspace_id",
        "workspace_name"
    ]

    private static let listSessionsPayloadKeys: Set<String> = [
        "agent",
        "state",
        "limit",
        "parent_session_id",
        "workspace_id",
        "workspace_name"
    ]

    private static let getLogPayloadKeys: Set<String> = [
        "offset",
        "limit",
        "include_row_timestamps",
        "include_host_row_ids"
    ]

    private static let forkSessionPayloadKeys: Set<String> = [
        "up_to_item_id",
        "destination_agent",
        "destination_model_id",
        "destination_effort"
    ]

    private static let extractHandoffPayloadKeys: Set<String> = [
        "up_to_item_id",
        "max_transcript_items",
        "max_tool_args_characters"
    ]

    private static let sessionAddressedOperations: Set<String> = [
        "steer",
        "respond",
        "cancel",
        "poll",
        "subscribe",
        "unsubscribe",
        "get_log",
        "fork_session",
        "extract_handoff",
        "list_sessions"
    ]

    private static let sessionAddressedAgentRunOps: Set<String> = [
        "steer",
        "respond",
        "cancel",
        "poll"
    ]

    private static let sessionAddressedAgentManageOps: Set<String> = [
        "get_log",
        "fork_session",
        "extract_handoff",
        "list_sessions"
    ]
}
