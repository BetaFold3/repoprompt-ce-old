import Foundation

/// Remote scope raw values shared with the app's `RemoteScope` vocabulary.
enum GatewayRemoteScope {
    static let sessionsObserve = "sessions:observe"
    static let sessionsOperate = "sessions:operate"
    static let interactionsRespond = "interactions:respond"
    static let workspaceRead = "workspace:read"
}

struct ScopeEnforcementError: Error, Equatable, CustomStringConvertible {
    let operation: String
    let requiredScope: String

    var code: String {
        "insufficient_scope"
    }

    var description: String {
        "Remote operation '\(operation)' requires scope '\(requiredScope)'."
    }
}

/// Least-privilege frame-type → scope mapping (M4 scope table):
///
/// | Frame | Required scope |
/// |---|---|
/// | subscribe, unsubscribe, poll, list_agents, list_sessions, list_workspaces, get_log, extract_handoff | sessions:observe |
/// | start, steer, cancel, open_workspace, fork_session | sessions:operate |
/// | respond | interactions:respond |
/// | future workspace browsing/read-only context | workspace:read (reserved) |
enum ScopeEnforcer {
    enum Decision: Equatable {
        case allowed
        case denied(requiredScope: String)
        case unknownOperation
    }

    /// Frame types that require no scope: connection control only.
    static let scopeExemptFrameTypes: Set<String> = ["hello", "ping"]

    static func requiredScope(forFrameType type: String) -> String? {
        switch type {
        case "subscribe", "unsubscribe", "poll", "list_agents", "list_sessions", "get_log", "extract_handoff":
            GatewayRemoteScope.sessionsObserve
        case "list_workspaces":
            // Read-only discovery of the open Mac windows' active workspaces, used only to choose
            // which workspace's sessions to observe. It never opens, focuses, or binds anything.
            GatewayRemoteScope.sessionsObserve
        case "push_subscribe", "push_unsubscribe":
            // Push wake registration is observation-adjacent: it only lets the
            // authenticated device be woken to observe, never to operate.
            GatewayRemoteScope.sessionsObserve
        case "start", "steer", "cancel", "open_workspace", "fork_session":
            GatewayRemoteScope.sessionsOperate
        case "respond":
            GatewayRemoteScope.interactionsRespond
        default:
            nil
        }
    }

    static func decision(frameType: String, grantedScopes: Set<String>) -> Decision {
        if scopeExemptFrameTypes.contains(frameType) {
            return .allowed
        }
        guard let required = requiredScope(forFrameType: frameType) else {
            return .unknownOperation
        }
        return grantedScopes.contains(required) ? .allowed : .denied(requiredScope: required)
    }

    /// Throwing convenience used at the enforcement point before translation.
    static func validate(frameType: String, grantedScopes: Set<String>) throws {
        switch decision(frameType: frameType, grantedScopes: grantedScopes) {
        case .allowed:
            return
        case let .denied(requiredScope):
            throw ScopeEnforcementError(operation: frameType, requiredScope: requiredScope)
        case .unknownOperation:
            throw ScopeEnforcementError(operation: frameType, requiredScope: "unknown_operation")
        }
    }
}
