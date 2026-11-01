import Foundation
import RepoPromptRemoteWire

// MARK: - Gateway access state (remote passkey unlock, Step 3)

// Internal, immutable value types describing per-connection outbound authorization. These are the
// vocabulary the authority actor publishes and the event-loop-owned sink enforces. Nothing here holds
// credential material, private keys, or grant secrets that could authorize access on their own: a
// grant identifier is a random non-bearer reference, and all security decisions are taken against the
// authority's live state, never against a value a browser supplies. (Step 3 plan §§1-3.)

/// What a bound connection is, for authorization purposes.
enum GatewayAccessPrincipal: Equatable {
    /// Not yet bound by the authority. Closed to all protected content.
    case unbound
    /// A ticket-authenticated paired browser identity.
    case pairedDevice(deviceID: String)
    /// The developer-only static-token connection (distinct from a phase-0 paired identity).
    case staticDeveloper
}

/// Process-local, monotonically increasing revision used to order authorization publications so a
/// late publication can never overwrite a newer one on a sink.
struct GatewayPublicationRevision: Comparable, Hashable {
    let value: UInt64

    static let initial = GatewayPublicationRevision(value: 0)

    func next() -> GatewayPublicationRevision {
        GatewayPublicationRevision(value: value &+ 1)
    }

    static func < (lhs: GatewayPublicationRevision, rhs: GatewayPublicationRevision) -> Bool {
        lhs.value < rhs.value
    }
}

/// A shared per-device grant. The identifier is a random, non-bearer reference; possession of it
/// authorizes nothing. The deadline is monotonic and the only time authority for access.
struct GatewayDeviceGrant: Equatable {
    let id: String
    let deadline: GatewayMonotonicInstant
}

/// The immutable security binding a grant or verification is tied to. Any change to these fields
/// (new launch identity, policy epoch, authoritative origin revision, or a lock) invalidates an
/// existing grant and any pending ceremony/renewal bound to the old values.
struct GatewayDeviceAccessBinding: Equatable {
    let launchNonce: String
    let policyEpoch: UInt64
    let originRevision: UInt64
    let lockGeneration: UInt64
    /// Authoritative, app-published origin. `nil` is a valid locked-but-published state (required
    /// policy with no origin yet), never "no policy".
    let authoritativeOrigin: String?
}

/// Whether protected content may currently be delivered to a bound connection.
enum GatewayAccess: Equatable {
    /// No passkey policy applies to this connection, so protected content delivers freely. This is
    /// the authority-published access for a policy-OFF paired device or an allowed static-developer
    /// connection (trust valid, no required policy anywhere); capability is NOT advertised in this
    /// mode, so it is not a required-policy activation.
    case unprotected
    /// Required policy currently unlocked by a live grant. Delivery is permitted only while the
    /// grant exists and `now < grant.deadline`.
    case unlockedUntilGrantDeadline
    /// Required policy, locked. Only safe lock settlements/controls may be delivered.
    case locked
}

/// An immutable per-connection authorization snapshot published by the authority and applied on the
/// connection's event loop. A sink ignores any snapshot whose revision is not strictly newer than the
/// one it already applied.
struct GatewayAuthorizationSnapshot: Equatable {
    let publicationRevision: GatewayPublicationRevision
    let principal: GatewayAccessPrincipal
    let access: GatewayAccess
    let grant: GatewayDeviceGrant?
    let binding: GatewayDeviceAccessBinding?

    /// Whether protected (non-control) content may be enqueued right now. The deadline is rechecked
    /// at the moment of enqueue with no intervening suspension.
    func authorizesProtectedContent(now: GatewayMonotonicInstant) -> Bool {
        switch access {
        case .unprotected:
            return true
        case .locked:
            return false
        case .unlockedUntilGrantDeadline:
            guard let grant else { return false }
            return now < grant.deadline
        }
    }
}

/// Outcome of settling a correlated runtime response through the final sink.
enum GatewayDeliveryOutcome: Equatable {
    /// The original response was authorized and enqueued.
    case originalEnqueued
    /// The original response was withheld and a generic lock settlement was enqueued in its place.
    case lockReplacementEnqueued
    /// Nothing was enqueued (connection closed, or no settlement owed).
    case notEnqueued
}

/// Fixed, content-free reasons attached to safe control frames. These map to a small closed set of
/// public codes; raw decoder/runtime/app error text is never emitted through the safe path.
enum GatewaySafeControlReason: String, Equatable {
    case locked = "passkey_locked"
    case grantExpired = "passkey_expired"
    case staleCeremony = "passkey_stale_ceremony"
    case authenticationFailure = "authentication_failed"
    /// Registration verified, but the gateway could not reconcile its trust (post-registration refresh
    /// failed). A sanitized pending/unavailable state: the browser must NOT treat the next ceremony as
    /// ready, and the gateway performs no false rollback and no auto-retry (S3-I05).
    case unavailable = "passkey_unavailable"
    case protocolError = "protocol_error"
    case closing
}

/// Internal server-created context for a single correlated runtime request. It is minted AFTER
/// authentication from authority state, never looked up by a client-chosen request ID. The browser
/// `requestID` is echoed for correlation only and never determines privilege.
struct GatewayRequestContext: Equatable {
    /// Opaque server token; the one-shot settlement authority for this request.
    let serverToken: UUID
    let principal: GatewayAccessPrincipal
    let deviceID: String?
    /// Correlation echo only.
    let requestID: String?
    /// The authorization in force when the request was admitted; settlement re-checks current state
    /// against this binding so a result admitted under an older lock generation cannot surface after a
    /// later unlock.
    let admissionBinding: GatewayDeviceAccessBinding?
    let admissionRevision: GatewayPublicationRevision

    init(
        serverToken: UUID = UUID(),
        principal: GatewayAccessPrincipal,
        deviceID: String?,
        requestID: String?,
        admissionBinding: GatewayDeviceAccessBinding?,
        admissionRevision: GatewayPublicationRevision
    ) {
        self.serverToken = serverToken
        self.principal = principal
        self.deviceID = deviceID
        self.requestID = requestID
        self.admissionBinding = admissionBinding
        self.admissionRevision = admissionRevision
    }
}

/// A synchronous, thread-safe connection lifecycle fence. Once closed it is permanently closed. It
/// holds NO policy, grant, or authorization state — only liveness. It lets a late verification or
/// renewal commit (running inside the authority's synchronous mutation) atomically reject if the
/// initiating connection already disconnected, so a delayed success cannot establish a shared grant
/// for a connection that is gone. (Step 3 plan §2.)
final class GatewayConnectionLifecycleFence: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    /// Permanently close the fence. Idempotent. Returns `true` only for the call that performed the
    /// transition.
    @discardableResult
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    /// Run `body` under the fence lock only while still active, linearizing a commit decision and its
    /// effect against `close()`. Returns `nil` if the fence was already closed.
    func withActive<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : body()
    }
}

/// Allowlisted, bounded per-connection access metadata carried on hello_ack and lock_state so the
/// browser (Step 4) can render policy/lock state and so the activity handler's client can echo the
/// exact grant reference. Every field is fixed and non-secret: the grant id is a random, non-bearer
/// reference that authorizes nothing on its own, and epoch/lock_generation are opaque monotonic
/// counters. No session content, runtime result, or app error text is representable here.
struct GatewayAccessMetadata: Equatable {
    enum PolicyState: String, Equatable {
        /// A paired device with passkey policy off (delivered freely).
        case off
        /// A paired device under required passkey policy (locked unless a live grant exists).
        case required
        /// The developer static-token connection (no passkey identity).
        case unprotected
    }

    let policyState: PolicyState
    let locked: Bool
    let enrolled: Bool
    let enrollmentOpen: Bool
    /// Set only on a lock_state notification; nil on hello_ack.
    let reason: GatewaySafeControlReason?
    /// The current grant's non-bearer reference (present only while unlocked under a live grant).
    let grantID: String?
    let epoch: UInt64
    let lockGeneration: UInt64
    /// Remaining grant lifetime in seconds (present only while unlocked under a live grant). Clamped
    /// to be non-negative.
    let deadlineSecondsRemaining: Double?

    /// A bounded JSON object. UInt64 counters are emitted as lossless decimal strings so the browser
    /// can echo them back without float rounding; the activity handler parses them strictly.
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "policy_state": .string(policyState.rawValue),
            "locked": .bool(locked),
            "enrolled": .bool(enrolled),
            "enrollment_open": .bool(enrollmentOpen),
            "epoch": .string(String(epoch)),
            "lock_generation": .string(String(lockGeneration))
        ]
        if let reason {
            object["reason"] = .string(reason.rawValue)
        }
        if let grantID {
            object["grant_id"] = .string(grantID)
        }
        if let deadlineSecondsRemaining {
            object["deadline_seconds_remaining"] = .double(max(0, deadlineSecondsRemaining))
        }
        return .object(object)
    }
}

/// Allowlisted hello_ack identity fields. The envelope assembles the handshake payload from these
/// typed fields plus the access metadata; there is deliberately no arbitrary-payload constructor, so
/// a caller cannot smuggle content onto the handshake.
struct GatewayHelloAckIdentity: Equatable {
    let deviceID: String
    /// "ticket" or "static_token".
    let auth: String
    let ticketID: String?
    let scopes: [String]
    let hostName: String
    let vapidPublicKeyBase64URL: String?
    /// The static-token connection emits an explicit `"sig": null` marker; paired connections do not.
    let includeNullSig: Bool
}

/// An UNFORGEABLE, internally-constructed control frame. The only way to obtain one is through the
/// sanitizing static constructors below; the initializer is private and there is deliberately no
/// constructor that accepts an arbitrary `RemoteServerFrame` or an arbitrary payload. Every
/// constructor emits a bounded, allowlisted frame, so a caller cannot smuggle session content,
/// runtime errors, or app error text through the control path. The sink accepts only this envelope
/// for control delivery, making "safe control" a real type boundary rather than a naming convention.
/// (Step 3 plan §3.)
struct GatewaySafeControlEnvelope: Equatable {
    let frame: RemoteServerFrame

    private init(frame: RemoteServerFrame) {
        self.frame = frame
    }

    /// Lock-state metadata announcing the connection's current access, including the lock reason and
    /// the grant references the client needs to drive foreground activity.
    static func lockState(access: GatewayAccessMetadata) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "lock_state",
            payload: access.jsonValue
        ))
    }

    /// Generic settlement enqueued in place of a withheld correlated response. Carries no session
    /// content or app error detail; only the fixed reason code and a fixed message.
    static func lockSettlement(requestID: String?, reason: GatewaySafeControlReason = .locked) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "command_error",
            requestID: requestID,
            payload: .object([
                "code": .string(reason.rawValue),
                "message": .string("This connection is locked and requires passkey verification.")
            ])
        ))
    }

    /// Fixed protocol/authentication failure. Never forwards raw decoder descriptions.
    static func failure(requestID: String?, reason: GatewaySafeControlReason) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "command_error",
            requestID: requestID,
            payload: .object([
                "code": .string(reason.rawValue),
                "message": .string("The request was rejected.")
            ])
        ))
    }

    /// Sanitized ceremony completion acknowledgement. Only the fixed kind marker is emitted; no
    /// browser-supplied or app-supplied content rides this path.
    static func ceremonyCompletion(requestID: String?, kind: GatewayCeremonyKind) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "passkey_ceremony_complete",
            requestID: requestID,
            payload: .object([
                "kind": .string(kind.rawValue)
            ])
        ))
    }

    /// Fixed, content-free result for a connection-management op that EXECUTED while the connection is
    /// locked (`ping` / `unsubscribe` / `push_subscribe` / `push_unsubscribe`). A heartbeat must not see
    /// a `passkey_locked` command_error (which a client reads as a FAILURE) for an op that actually ran:
    /// `ping` gets a `pong`, the others get an empty `command_result`. No session content or app error
    /// text rides this path — the payload is a fixed empty object (S3-A-11).
    static func managementResult(requestID: String?, sessionID: String? = nil, frameType: String) -> GatewaySafeControlEnvelope {
        let type = frameType == "ping" ? "pong" : "command_result"
        return GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: type,
            requestID: requestID,
            sessionID: sessionID,
            payload: .object([:])
        ))
    }

    /// A sanitized admission/verification failure. Carries a stable, closed-set failure CODE (from the
    /// gateway's own error enums or a fixed literal) and a FIXED message; raw decoder/app/SDK error
    /// text is never forwarded. The code is length-bounded so no oversized string can ride the path.
    static func commandFailure(requestID: String?, sessionID: String? = nil, code: String) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "command_error",
            requestID: requestID,
            sessionID: sessionID,
            payload: .object([
                "code": .string(boundedCode(code)),
                "message": .string("The request was rejected.")
            ])
        ))
    }

    /// A sanitized channel-closing notice. `reason` is a bounded, closed-set code; the message is
    /// fixed. Raw app-link or SDK error text is never forwarded.
    static func channelClosing(reason: String) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string(boundedCode(reason)),
                "message": .string("The connection is closing.")
            ])
        ))
    }

    /// Handshake acknowledgement. Delivered via the safe path so it reaches a locked connection too
    /// (the browser must learn it is connected-but-locked). Assembled from typed, allowlisted identity
    /// fields plus the current access metadata — never a runtime result or app error. There is no
    /// arbitrary-payload constructor, so session content cannot ride this path.
    static func helloAck(identity: GatewayHelloAckIdentity, access: GatewayAccessMetadata) -> GatewaySafeControlEnvelope {
        var payload: [String: JSONValue] = [
            "device_id": .string(identity.deviceID),
            "auth": .string(identity.auth),
            "host_name": .string(identity.hostName),
            "locked": .bool(access.locked),
            "features": .array(RemoteWireFeatures.all.map(JSONValue.string)),
            "access": access.jsonValue
        ]
        if let ticketID = identity.ticketID {
            payload["ticket_id"] = .string(ticketID)
        }
        if !identity.scopes.isEmpty {
            payload["scopes"] = .array(identity.scopes.sorted().map(JSONValue.string))
        }
        if let vapid = identity.vapidPublicKeyBase64URL {
            payload["vapid_public_key"] = .string(vapid)
        }
        if identity.includeNullSig {
            payload["sig"] = .null
        }
        return GatewaySafeControlEnvelope(frame: RemoteServerFrame(type: "hello_ack", payload: .object(payload)))
    }

    /// A passkey ceremony challenge forwarded to the browser while locked. The `options` are the
    /// principal app's own WebAuthn begin parameters (app-authored, not browser- or runtime-derived);
    /// the gateway relays them only after enforcing object shape and a size bound, so no scalar or
    /// oversized content can ride the safe path. The app verifier remains authoritative over contents.
    static func passkeyChallenge(
        requestID: String?,
        kind: GatewayCeremonyKind,
        deviceID: String,
        ceremonyID: String,
        options: JSONValue
    ) -> GatewaySafeControlEnvelope {
        GatewaySafeControlEnvelope(frame: RemoteServerFrame(
            type: "passkey_challenge",
            requestID: requestID,
            payload: .object([
                "kind": .string(kind.rawValue),
                "device_id": .string(deviceID),
                "ceremony_id": .string(ceremonyID),
                "options": sanitizedChallengeOptions(options)
            ])
        ))
    }

    /// Defensive bound for safe-path codes. Codes originate from closed error enums or fixed literals;
    /// capping length ensures no oversized or non-code string can ride the safe path if a future
    /// caller misuses it.
    private static func boundedCode(_ code: String) -> String {
        String(code.prefix(64))
    }

    /// Enforce object shape and a size bound on relayed WebAuthn begin options.
    private static func sanitizedChallengeOptions(_ options: JSONValue) -> JSONValue {
        guard case .object = options else { return .object([:]) }
        guard let data = try? RemoteWireProtocol.canonicalData(for: options), data.count <= 32 * 1024 else {
            return .object([:])
        }
        return options
    }
}

/// The two principal-link ceremony kinds. Per device, at most one of each may be pending.
enum GatewayCeremonyKind: String, Equatable {
    case registration
    case assertion
}

/// An internally-correlated ceremony outcome handed from the principal relay to the authority. It is
/// NOT a wire frame and carries no browser-controlled content; the authority validates it against the
/// pending ceremony binding and maps it to a sanitized envelope for delivery. Malformed app responses
/// map to `.rejected`; the app verifier remains authoritative. (Step 3 plan §6.)
enum GatewayCeremonyResult: Equatable {
    case registrationCompleted(epoch: UInt64)
    case assertionVerified(epoch: UInt64)
    case rejected(reason: GatewaySafeControlReason)
}
