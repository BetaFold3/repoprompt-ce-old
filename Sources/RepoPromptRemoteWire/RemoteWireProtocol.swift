import CryptoKit
import Foundation

/// Gateway remote-control wire protocol v1.
public enum RemoteWireProtocol {
    public static let version = 1

    public static let clientFrameTypes: Set<String> = [
        "hello",
        "start",
        "steer",
        "respond",
        "cancel",
        "poll",
        "subscribe",
        "unsubscribe",
        "list_agents",
        "list_sessions",
        // Read-only, gateway-owned discovery of open windows' active workspaces (fresh app read;
        // no workspace mutation). Not mutating, so no request_id requirement beyond correlation.
        "list_workspaces",
        "open_workspace",
        "get_log",
        "fork_session",
        "extract_handoff",
        "ping",
        // M5: gateway-owned Web Push subscription registration for the connected
        // (authenticated) device; never translated to an app tool call.
        "push_subscribe",
        "push_unsubscribe",
        // Remote passkey unlock, Step 3: gateway-owned WebAuthn ceremony + lock control frames for
        // the connected device. Never translated to an app tool call; dispatched to the principal
        // passkey relay and the device-access authority instead.
        "passkey_register_begin",
        "passkey_register_complete",
        "passkey_unlock_begin",
        "passkey_unlock_complete",
        // Explicit signed foreground activity: renews the idle grant deadline (never ordinary
        // traffic). The phone-initiated lock drops the shared grant immediately.
        "passkey_activity",
        "lock"
    ]

    public static let serverFrameTypes: Set<String> = [
        "hello_ack",
        "command_result",
        "command_error",
        "session_update",
        "session_terminal",
        "session_expired",
        "observation_failure",
        // M6.2: emitted when a pending interaction is resolved (by this device,
        // another device, a CLI client, or the local user).
        "interaction_resolved",
        "channel_closing",
        "pong",
        // Remote passkey unlock, Step 3 safe-control frames (content-free; emitted by the gateway's
        // unforgeable safe-control path even while a connection is locked).
        "lock_state",
        "passkey_challenge",
        "passkey_ceremony_complete"
    ]

    public static let mutatingClientFrameTypes: Set<String> = [
        "start",
        "steer",
        "respond",
        "cancel",
        "open_workspace",
        "fork_session",
        // The passkey ceremony frames carry a request_id so the gateway can correlate the challenge
        // it returns and the completion the browser sends back.
        "passkey_register_begin",
        "passkey_register_complete",
        "passkey_unlock_begin",
        "passkey_unlock_complete"
    ]

    /// Decode a client frame. With `allowUnknownTypes: false` (the default, used by non-gateway
    /// callers) an unknown frame type is rejected. The gateway WebSocket handler passes
    /// `allowUnknownTypes: true` so a syntactically valid frame carrying an UNKNOWN type is still
    /// decoded: on a signed paired connection it is then signature/counter verified and routed to the
    /// generic locked-deny / unsupported path, rather than being rejected pre-verification with a raw
    /// decoder description. Malformed bytes (invalid JSON, wrong version) are still rejected here.
    public static func decodeClientFrame(from data: Data, allowUnknownTypes: Bool = false) throws -> RemoteClientFrame {
        let frame: RemoteClientFrame
        do {
            frame = try JSONDecoder().decode(RemoteClientFrame.self, from: data)
        } catch {
            throw RemoteWireProtocolError.invalidJSON
        }
        try validateClientFrame(frame, allowUnknownTypes: allowUnknownTypes)
        return frame
    }

    public static func validateClientFrame(_ frame: RemoteClientFrame, allowUnknownTypes: Bool = false) throws {
        guard frame.v == version else {
            throw RemoteWireProtocolError.unsupportedVersion(frame.v)
        }
        if !allowUnknownTypes, !clientFrameTypes.contains(frame.type) {
            throw RemoteWireProtocolError.unsupportedFrameType(frame.type)
        }
        if mutatingClientFrameTypes.contains(frame.type), frame.requestID?.isEmptyOrWhitespace != false {
            throw RemoteWireProtocolError.missingRequestID(frame.type)
        }
    }

    /// Decode server frames with additive-evolution tolerance. Unknown server frame
    /// types are preserved as strings so clients can ignore them without a v1 bump.
    public static func decodeServerFrame(from data: Data) throws -> RemoteServerFrame {
        let frame = try JSONDecoder().decode(RemoteServerFrame.self, from: data)
        guard frame.v == version else {
            throw RemoteWireProtocolError.unsupportedVersion(frame.v)
        }
        return frame
    }

    public static func encodeServerFrame(_ frame: RemoteServerFrame) throws -> Data {
        try canonicalData(for: JSONValue(frame))
    }

    public static func canonicalData(for value: JSONValue) throws -> Data {
        try value.canonicalString().data(using: .utf8).okOrThrow(RemoteWireProtocolError.canonicalEncodingFailed)
    }

    public static func canonicalJSONString(for value: JSONValue) throws -> String {
        try value.canonicalString()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension RemoteWireProtocol {
    /// Context line for the canonical remote frame signing payload.
    static let frameSigningContext = "RemoteFrameV1"

    /// SHA-256 hex digest of the canonical JSON encoding of the raw frame object
    /// with the `sig` member removed. Computed from raw bytes so unknown fields the
    /// device signed over are preserved verbatim.
    static func canonicalFrameHashHex(fromRawFrameData data: Data) throws -> String {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RemoteWireProtocolError.invalidJSON
        }
        guard var object = value.objectValue else {
            throw RemoteWireProtocolError.invalidJSON
        }
        object.removeValue(forKey: "sig")
        return try sha256Hex(of: canonicalData(for: .object(object)))
    }

    /// Canonical signing payload:
    /// `RemoteFrameV1\n<ticket_id>\n<device_id>\n<counter>\n<sha256(canonical_json_without_sig)>\n`
    static func frameSigningPayload(
        ticketID: UUID,
        deviceID: String,
        counter: UInt64,
        frameHashHex: String
    ) -> Data {
        let lines = [
            frameSigningContext,
            ticketID.uuidString.lowercased(),
            deviceID,
            String(counter),
            frameHashHex
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private extension Optional {
    func okOrThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

private extension String {
    var isEmptyOrWhitespace: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
