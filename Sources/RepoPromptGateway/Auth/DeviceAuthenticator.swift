import CryptoKit
import Foundation
import MCP
import RepoPromptRemoteWire

// MARK: - Trust snapshot

/// A paired device as trusted by the gateway. The gateway holds only public keys;
/// the host private key never leaves the app.
struct GatewayTrustedDevice: Equatable {
    let deviceID: String
    let displayName: String
    let publicKeyRawRepresentation: Data
    let isRevoked: Bool
    /// App-supplied lower bound for accepted frame counters. The gateway advances
    /// counters in memory per authenticated connection; cross-restart replay is
    /// primarily prevented by one-time ticket IDs persisted in `UsedTicketStore`.
    let counterFloor: UInt64
}

/// Gateway-side snapshot of the app-owned pairing registry, fetched through the
/// gateway-principal app leg via `remote_pairing list_devices`.
struct GatewayTrustSnapshot: Equatable {
    let hostPublicKeyRawRepresentation: Data
    let hostFingerprint: String
    let devices: [String: GatewayTrustedDevice]
}

// MARK: - Errors

enum DeviceAuthenticationError: Error, Equatable, CustomStringConvertible {
    case trustUnavailable
    case ticketRequired
    case invalidTicket(String)
    case invalidTrustSnapshot(String)
    case unknownDevice(String)
    case deviceRevoked(String)
    case ticketExpired
    case invalidTicketLifetime
    case ticketSignatureInvalid
    case ticketAlreadyUsed
    case usedTicketPersistenceFailed(String)
    case signatureRequired(String)
    case unsupportedSignatureAlgorithm(String)
    case signatureContextMismatch
    case signatureInvalid
    case counterNotIncreasing(counter: UInt64, floor: UInt64)
    case unauthenticatedConnection

    var code: String {
        switch self {
        case .trustUnavailable: "trust_unavailable"
        case .ticketRequired: "ticket_required"
        case .invalidTicket: "invalid_ticket"
        case .invalidTrustSnapshot: "invalid_trust_snapshot"
        case .unknownDevice: "unknown_device"
        case .deviceRevoked: "device_revoked"
        case .ticketExpired: "ticket_expired"
        case .invalidTicketLifetime: "invalid_ticket_lifetime"
        case .ticketSignatureInvalid: "ticket_signature_invalid"
        case .ticketAlreadyUsed: "ticket_already_used"
        case .usedTicketPersistenceFailed: "used_ticket_persistence_failed"
        case .signatureRequired: "signature_required"
        case .unsupportedSignatureAlgorithm: "unsupported_signature_algorithm"
        case .signatureContextMismatch: "signature_context_mismatch"
        case .signatureInvalid: "signature_invalid"
        case .counterNotIncreasing: "counter_replayed"
        case .unauthenticatedConnection: "unauthenticated_connection"
        }
    }

    var description: String {
        switch self {
        case .trustUnavailable:
            "The gateway has not yet synchronized paired-device trust from the app."
        case .ticketRequired:
            "hello requires an app-minted ticket."
        case let .invalidTicket(message):
            "Invalid remote connection ticket: \(message)"
        case let .invalidTrustSnapshot(message):
            "Invalid gateway trust snapshot: \(message)"
        case let .unknownDevice(deviceID):
            "Device \(deviceID) is not paired."
        case let .deviceRevoked(deviceID):
            "Device \(deviceID) is revoked."
        case .ticketExpired:
            "The remote connection ticket has expired."
        case .invalidTicketLifetime:
            "The remote connection ticket lifetime is invalid (must be positive and at most 60s)."
        case .ticketSignatureInvalid:
            "The remote connection ticket host signature is invalid."
        case .ticketAlreadyUsed:
            "The remote connection ticket was already used."
        case let .usedTicketPersistenceFailed(message):
            "Could not persist the used ticket; admission fails closed: \(message)"
        case let .signatureRequired(frameType):
            "Remote frame '\(frameType)' requires a device signature."
        case let .unsupportedSignatureAlgorithm(algorithm):
            "Unsupported remote frame signature algorithm '\(algorithm)'."
        case .signatureContextMismatch:
            "The frame signature ticket/device context does not match the connection."
        case .signatureInvalid:
            "The remote frame device signature is invalid."
        case let .counterNotIncreasing(counter, floor):
            "Frame counter \(counter) does not strictly increase past \(floor); frame rejected as replay."
        case .unauthenticatedConnection:
            "The connection is not authenticated."
        }
    }
}

// MARK: - Authenticator

/// DPoP-lite enforcement for remote WebSocket connections (M4):
/// - host-signed one-time tickets (≤60s, persisted before WS accept),
/// - per-frame P256 device signatures over the canonical signing payload,
/// - strictly increasing counters per ticket/connection,
/// - revocation fails closed.
actor DeviceAuthenticator {
    struct AuthenticatedDevice: Equatable {
        let deviceID: String
        let displayName: String
        let ticketID: UUID
        let scopes: Set<String>
    }

    private struct ConnectionAuthState {
        let deviceID: String
        let displayName: String
        let ticketID: UUID
        let scopes: Set<String>
        var lastCounter: UInt64
    }

    private let usedTicketStore: UsedTicketStore
    private let now: @Sendable () -> Date
    private var trust: GatewayTrustSnapshot?
    private var connections: [UUID: ConnectionAuthState] = [:]

    // MARK: Step 3 access-authority state (remote passkey unlock)

    // These extend the one gateway authority (no second actor/store). The Step 3 handler wires the
    // closed-by-default sink, lock/expiry/renewal, and principal-link ceremonies over this state. See
    // `GatewayDeviceAccessAuthority.swift` for the operations over it.
    let accessClock: GatewayAccessClock
    var publicationRevision: GatewayPublicationRevision = .initial
    var capabilityTrust: GatewayCapabilityTrustAvailability = .unavailable
    var deviceAccess: [String: GatewayDeviceAccessRecord] = [:]
    var handles: [UUID: GatewayConnectionHandle] = [:]

    init(
        usedTicketStore: UsedTicketStore,
        trust: GatewayTrustSnapshot? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        accessClock: GatewayAccessClock = GatewayContinuousAccessClock()
    ) {
        self.usedTicketStore = usedTicketStore
        self.trust = trust
        self.now = now
        self.accessClock = accessClock
    }

    /// Replaces the trust snapshot. Returns device IDs that must be disconnected:
    /// devices explicitly revoked in the new snapshot, plus any currently
    /// authenticated connections whose device vanished from trust.
    @discardableResult
    func updateTrust(_ snapshot: GatewayTrustSnapshot) -> [String] {
        let connectedDeviceIDs = Set(connections.values.map(\.deviceID))
        trust = snapshot
        let revokedDeviceIDs = snapshot.devices.values
            .filter(\.isRevoked)
            .map(\.deviceID)
        let disconnectedDeviceIDs = connectedDeviceIDs.filter { deviceID in
            guard let device = snapshot.devices[deviceID] else { return true }
            return device.isRevoked
        }
        return Set(revokedDeviceIDs).union(disconnectedDeviceIDs).sorted()
    }

    var hasTrust: Bool {
        trust != nil
    }

    func isRevoked(deviceID: String) -> Bool {
        guard let device = trust?.devices[deviceID] else { return true }
        return device.isRevoked
    }

    /// Verifies a `hello` frame carrying `payload.ticket` plus a device frame signature,
    /// marks the one-time ticket used (persisted durably BEFORE the caller may accept
    /// the WebSocket), and records per-connection counter state.
    func admitHello(
        rawFrame: Data,
        frame: RemoteClientFrame,
        connectionID: UUID
    ) throws -> AuthenticatedDevice {
        guard let trust else { throw DeviceAuthenticationError.trustUnavailable }
        guard let ticketValue = frame.payload?.objectValue?["ticket"] else {
            throw DeviceAuthenticationError.ticketRequired
        }
        let ticket: RemoteTicket
        do {
            ticket = try RemoteTicket.parse(from: ticketValue)
        } catch let error as RemoteTicketError {
            throw Self.mapTicketError(error)
        }
        guard let device = trust.devices[ticket.deviceID] else {
            throw DeviceAuthenticationError.unknownDevice(ticket.deviceID)
        }
        guard !device.isRevoked else {
            throw DeviceAuthenticationError.deviceRevoked(device.deviceID)
        }

        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        do {
            try ticket.verify(hostPublicKeyRaw: trust.hostPublicKeyRawRepresentation, nowMs: nowMs)
        } catch let error as RemoteTicketError {
            throw Self.mapTicketError(error)
        }

        let signature = try requireSignature(frame: frame)
        guard signature.ticketID == ticket.ticketID, signature.deviceID == ticket.deviceID else {
            throw DeviceAuthenticationError.signatureContextMismatch
        }
        guard signature.counter > device.counterFloor else {
            throw DeviceAuthenticationError.counterNotIncreasing(
                counter: signature.counter,
                floor: device.counterFloor
            )
        }
        try verifyDeviceSignature(
            signature,
            rawFrame: rawFrame,
            devicePublicKeyRaw: device.publicKeyRawRepresentation
        )

        // One-time ticket: persist as used BEFORE the WS is accepted; persistence
        // failure fails admission closed.
        if usedTicketStore.isUsed(ticket.ticketID) {
            throw DeviceAuthenticationError.ticketAlreadyUsed
        }
        do {
            try usedTicketStore.markUsed(ticketID: ticket.ticketID, expiresAtMs: ticket.expiresAtMs)
        } catch {
            throw DeviceAuthenticationError.usedTicketPersistenceFailed(String(describing: error))
        }

        let state = ConnectionAuthState(
            deviceID: device.deviceID,
            displayName: device.displayName,
            ticketID: ticket.ticketID,
            scopes: ticket.scopes,
            lastCounter: signature.counter
        )
        connections[connectionID] = state
        return AuthenticatedDevice(
            deviceID: state.deviceID,
            displayName: state.displayName,
            ticketID: state.ticketID,
            scopes: state.scopes
        )
    }

    /// Verifies a post-hello frame: signature required, ticket/device context pinned,
    /// counter strictly increasing, device not revoked.
    @discardableResult
    func verifyFrame(
        rawFrame: Data,
        frame: RemoteClientFrame,
        connectionID: UUID
    ) throws -> AuthenticatedDevice {
        guard var state = connections[connectionID] else {
            throw DeviceAuthenticationError.unauthenticatedConnection
        }
        guard let trust, let device = trust.devices[state.deviceID], !device.isRevoked else {
            throw DeviceAuthenticationError.deviceRevoked(state.deviceID)
        }
        let signature = try requireSignature(frame: frame)
        guard signature.ticketID == state.ticketID, signature.deviceID == state.deviceID else {
            throw DeviceAuthenticationError.signatureContextMismatch
        }
        guard signature.counter > state.lastCounter else {
            throw DeviceAuthenticationError.counterNotIncreasing(
                counter: signature.counter,
                floor: state.lastCounter
            )
        }
        try verifyDeviceSignature(
            signature,
            rawFrame: rawFrame,
            devicePublicKeyRaw: device.publicKeyRawRepresentation
        )
        state.lastCounter = signature.counter
        connections[connectionID] = state
        return AuthenticatedDevice(
            deviceID: state.deviceID,
            displayName: state.displayName,
            ticketID: state.ticketID,
            scopes: state.scopes
        )
    }

    func authenticatedDevice(forConnection connectionID: UUID) -> AuthenticatedDevice? {
        guard let state = connections[connectionID] else { return nil }
        return AuthenticatedDevice(
            deviceID: state.deviceID,
            displayName: state.displayName,
            ticketID: state.ticketID,
            scopes: state.scopes
        )
    }

    func endConnection(_ connectionID: UUID) {
        connections.removeValue(forKey: connectionID)
    }

    private static func mapTicketError(_ error: RemoteTicketError) -> DeviceAuthenticationError {
        switch error {
        case let .invalidTicket(message):
            .invalidTicket(message)
        case .invalidHostPublicKey:
            .invalidTrustSnapshot("Host public key is invalid.")
        case .ticketExpired:
            .ticketExpired
        case .invalidTicketLifetime:
            .invalidTicketLifetime
        case .invalidTicketSignature, .hostFingerprintMismatch:
            .ticketSignatureInvalid
        }
    }

    private func requireSignature(frame: RemoteClientFrame) throws -> RemoteFrameSignature {
        guard let signature = RemoteFrameSignature(jsonValue: frame.sig) else {
            throw DeviceAuthenticationError.signatureRequired(frame.type)
        }
        guard signature.algorithm == RemoteFrameSignature.requiredAlgorithm else {
            throw DeviceAuthenticationError.unsupportedSignatureAlgorithm(signature.algorithm)
        }
        return signature
    }

    private func verifyDeviceSignature(
        _ signature: RemoteFrameSignature,
        rawFrame: Data,
        devicePublicKeyRaw: Data
    ) throws {
        let devicePublicKey: P256.Signing.PublicKey
        do {
            devicePublicKey = try P256.Signing.PublicKey(rawRepresentation: devicePublicKeyRaw)
        } catch {
            throw DeviceAuthenticationError.invalidTrustSnapshot("Device public key is invalid.")
        }
        let frameHashHex: String
        do {
            frameHashHex = try RemoteWireProtocol.canonicalFrameHashHex(fromRawFrameData: rawFrame)
        } catch {
            throw DeviceAuthenticationError.signatureInvalid
        }
        let payload = RemoteWireProtocol.frameSigningPayload(
            ticketID: signature.ticketID,
            deviceID: signature.deviceID,
            counter: signature.counter,
            frameHashHex: frameHashHex
        )
        guard let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature.signature),
              devicePublicKey.isValidSignature(ecdsaSignature, for: payload)
        else {
            throw DeviceAuthenticationError.signatureInvalid
        }
    }
}
