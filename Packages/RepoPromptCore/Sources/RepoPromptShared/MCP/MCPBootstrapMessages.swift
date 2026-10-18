//
//  MCPBootstrapMessages.swift
//  RepoPrompt
//
//  Shared bootstrap socket handshake message types.
//  Used by the app bootstrap server and bootstrap MCP clients.
//

import CryptoKit
import Foundation

// MARK: - Protocol Version

/// Bootstrap socket protocol versioning.
public enum MCPBootstrapProtocol {
    /// Current protocol version.
    /// - v1: Initial bootstrap socket implementation
    /// - v2: Added client identity caching for reconnects, improved retry logic
    public static let currentVersion = 2
}

// MARK: - Timing

/// Shared timing budgets for bootstrap socket startup.
/// Keep proxy startup under common outer host timeouts so retries can engage.
public enum MCPBootstrapTiming {
    public static let initialResponseTimeout: TimeInterval = 5
    public static let initialRequestWriteTimeout: TimeInterval = 5
}

// MARK: - Handshake Request

/// Request sent by CLI when connecting to bootstrap socket.
public struct MCPBootstrapRequest: Codable, Sendable {
    /// Message type identifier (always "connect")
    public let type: String

    /// Unique session token for this CLI instance.
    /// Used by the app to identify this CLI across reconnections.
    public let sessionToken: String

    /// CLI process ID for debugging and diagnostics.
    public let clientPid: Int

    /// Client executable name (e.g., "cursor", "claude", "repoprompt-mcp").
    /// May be nil if detection fails.
    public let clientName: String?

    /// Protocol version for compatibility checking.
    public let protocolVersion: Int

    /// Optional launch-scoped credential proving this bootstrap client is the app-spawned gateway.
    /// This is intentionally transported inside the local UNIX-socket handshake and must never be
    /// passed through command-line arguments.
    public let gatewayCredential: String?

    /// Optional launch-generation credential proving this bootstrap client is the read-only
    /// companion server an app-owned agent transport was configured with. Like
    /// `gatewayCredential`, it travels only inside the local UNIX-socket handshake; the app
    /// keeps a digest, never the raw value, and the client never logs it.
    public let companionCredential: String?

    public init(
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        protocolVersion: Int = MCPBootstrapProtocol.currentVersion,
        gatewayCredential: String? = nil,
        companionCredential: String? = nil
    ) {
        type = "connect"
        self.sessionToken = sessionToken
        self.clientPid = clientPid
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.gatewayCredential = gatewayCredential
        self.companionCredential = companionCredential
    }
}

// MARK: - Companion Credential Transport

/// Environment handoff for the read-only companion credential. The app places the credential
/// only in the companion server's launch environment; the bundled MCP client reads it once and
/// forwards it inside the bootstrap handshake.
public enum MCPBootstrapCompanionCredential {
    public static let environmentKey = "REPOPROMPT_MCP_COMPANION_CREDENTIAL"

    /// Returns the trimmed, non-empty credential from `environment`, or nil.
    public static func credential(from environment: [String: String]) -> String? {
        guard let raw = environment[environmentKey] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mints one launch-generation credential: 32 bytes from CryptoKit's secure key generator
    /// (already a `RepoPromptShared` dependency on its macOS-only platform), base64url, unpadded.
    public static func mint() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 of the trimmed credential. The app stores and compares only this.
    public static func digest(of credential: String) -> String {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Handshake Response

/// Response sent by app after receiving connect request.
/// Bootstrap only establishes the transport; user-facing approval happens later during MCP initialize.
public struct MCPBootstrapResponse: Codable, Sendable {
    /// Response type: "accepted" or "rejected"
    public let type: String

    /// Reason for rejection (if type == "rejected")
    public let reason: String?

    /// Error code for programmatic handling
    public let errorCode: String?

    public init(type: String, reason: String? = nil, errorCode: String? = nil) {
        self.type = type
        self.reason = reason
        self.errorCode = errorCode
    }

    // MARK: Factory Methods

    /// Creates an accepted response.
    public static func accepted() -> MCPBootstrapResponse {
        MCPBootstrapResponse(type: "accepted", reason: nil, errorCode: nil)
    }

    /// Creates a rejected response with reason.
    public static func rejected(reason: String, errorCode: String? = nil) -> MCPBootstrapResponse {
        MCPBootstrapResponse(type: "rejected", reason: reason, errorCode: errorCode)
    }
}

// MARK: - Error Codes

/// Known error codes for programmatic error handling.
public enum MCPBootstrapErrorCode: String {
    case approvalDenied = "approval_denied"
    case protocolVersionMismatch = "protocol_version_mismatch"
    case serverNotReady = "server_not_ready"
    case serverUnavailable = "server_unavailable"
    case connectionLimitReached = "connection_limit_reached"
    case capacityExceeded = "capacity_exceeded"
    case sessionBlocked = "session_blocked"
    case clientCooldown = "client_cooldown"
}
