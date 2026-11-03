import Foundation
import RepoPromptRemoteWire

// MARK: - Principal-link passkey relay (remote passkey unlock, Step 3)

// A THIN, typed relay over the SAME original principal `AppLinkSession` the gateway already uses for
// trust sync and pairing. It never opens a per-device runtime link; every passkey ceremony, the
// capability-1 trust read, and the trust acknowledgement travel the one principal leg. The relay
// only dispatches and parses: it holds no security state. The authority (DeviceAuthenticator) owns
// the pending-ceremony binding; the relay's results are validated against that binding before any
// grant is committed. (Step 3 plan §§6, 8; decision 2/3.)
//
// Provenance cannot be fully recovered from `AppLinkSession.callTool`, so the relay classifies
// conservatively (Step 3 Oracle plan; parent decision 2026-11-01). A POSITIVELY identified outage —
// not connected, timeout, link lost, handshake/socket failure — maps to `.transportFailure`, which
// the caller treats as "preserve the last valid policy". An authoritative app response (`isError`,
// `ok:false`, or a malformed/unexpected shape) AND an `uncertainToolFailure` whose provenance is
// indistinguishable from a rejected/malformed response BOTH map to the INVALIDATE outcome (for
// trust) or a generic REJECT (for a ceremony): the case names are not provenance, so an uncertain
// SDK failure locks rather than silently preserving permissive access. Cancellation propagates and
// publishes nothing. A success is only ever derived from an explicit `ok:true` with the exact
// fields present.

/// Conservatively classified outcome of the capability-1 trust read.
enum GatewayCapabilityTrustFetch: Equatable {
    /// A positively identified transport outage/timeout. The caller preserves the prior valid
    /// snapshot and its existing grant deadline.
    case transportFailure
    /// Trust cannot safely remain usable: an authoritative error/`ok:false`/malformed body, an
    /// uncertain (indistinguishable-provenance) SDK failure, or an unexpected error escaping
    /// normalization. The caller invalidates trust. (NOT a claim the app proved the rejection.)
    case invalid
    /// A fully validated capability-1 snapshot.
    case valid(GatewayCapabilityTrustSnapshot)
}

/// Transport-classified outcome of a ceremony begin.
enum GatewayPasskeyBeginOutcome {
    case transportFailure
    case rejected(code: String)
    case began(GatewayPasskeyBeginResult)
}

/// Transport-classified outcome of a ceremony completion.
enum GatewayPasskeyCompleteOutcome {
    case transportFailure
    case rejected(code: String)
    case verified(GatewayPasskeyCompleteResult)
}

/// The app-issued ceremony id plus the full begin-response options object to forward verbatim to the
/// browser. The options are app-authored WebAuthn parameters; no browser or runtime content rides it.
struct GatewayPasskeyBeginResult {
    let appCeremonyID: String
    let optionsPayload: JSONValue
}

/// Parsed, request-validated completion facts the authority commits against.
struct GatewayPasskeyCompleteResult {
    let deviceID: String
    let appCeremonyID: String
    let epoch: UInt64
    let connectionGeneration: UInt64
}

struct GatewayPasskeyRelay {
    private let appLink: AppLinkSession
    private let timeout: TimeInterval

    init(appLink: AppLinkSession, timeout: TimeInterval = 15) {
        self.appLink = appLink
        self.timeout = timeout
    }

    // MARK: Trust

    /// Fetch the strict capability-1 trust snapshot over the principal leg. A positively identified
    /// outage preserves prior policy (`.transportFailure`); an authoritative error/`ok:false`/
    /// malformed body OR an uncertain (indistinguishable-provenance) SDK failure invalidates
    /// (`.invalid`). Cancellation is the ONLY thrown outcome: the caller must propagate it without
    /// applying any trust transition.
    func fetchCapabilityTrust() async throws -> GatewayCapabilityTrustFetch {
        let result: MCPToolResult
        do {
            result = try await appLink.callTool(
                name: "remote_pairing",
                arguments: [
                    "op": .string("list_devices"),
                    "include_revoked": .bool(true),
                    "passkey_policy_capability": .int(1)
                ],
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppLinkError {
            // Authoritative and uncertain failures both invalidate (the uncertain case cannot be
            // distinguished from a rejected/malformed app response, so it locks conservatively); a
            // positively identified outage preserves the last valid snapshot.
            switch Self.trustDisposition(for: error) {
            case .preserve:
                return .transportFailure
            case .invalidate:
                return .invalid
            }
        } catch {
            // AppLinkSession normalizes every non-cancellation throw into an AppLinkError, so this is
            // unreachable in practice; invalidate conservatively rather than silently preserve.
            return .invalid
        }
        if result.isError == true {
            return .invalid
        }
        guard let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result) else {
            return .invalid
        }
        guard payload.objectValue?["ok"]?.boolValue == true else {
            return .invalid
        }
        guard let snapshot = try? GatewayCapabilityTrustSnapshot.parseStrict(from: payload) else {
            return .invalid
        }
        return .valid(snapshot)
    }

    /// Acknowledge the exact issued trust snapshot after every publication barrier has settled.
    /// Returns true only on an authoritative `ok:true`; a transport failure or authoritative
    /// rejection returns false (the caller retries on the next successful fetch).
    @discardableResult
    func acknowledgeTrust(launch: String, revision: UInt64, issuance: String) async -> Bool {
        let result: MCPToolResult
        do {
            result = try await appLink.callTool(
                name: "remote_pairing",
                arguments: [
                    "op": .string("acknowledge_trust"),
                    "trust_launch": .string(launch),
                    "trust_revision": .string(String(revision)),
                    "trust_issuance": .string(issuance)
                ],
                timeout: timeout
            )
        } catch {
            return false
        }
        guard result.isError != true,
              let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result)
        else {
            return false
        }
        return payload.objectValue?["ok"]?.boolValue == true
    }

    // MARK: Ceremonies

    func unlockBegin(deviceID: String, connectionGeneration: UInt64) async throws -> GatewayPasskeyBeginOutcome {
        try await begin(op: "passkey_unlock_begin", deviceID: deviceID, connectionGeneration: connectionGeneration)
    }

    func registerBegin(deviceID: String, connectionGeneration: UInt64) async throws -> GatewayPasskeyBeginOutcome {
        try await begin(op: "passkey_register_begin", deviceID: deviceID, connectionGeneration: connectionGeneration)
    }

    func unlockComplete(
        deviceID: String,
        appCeremonyID: String,
        connectionGeneration: UInt64,
        credentialJSON: String
    ) async throws -> GatewayPasskeyCompleteOutcome {
        try await complete(
            op: "passkey_unlock_complete",
            successFlag: "verified",
            deviceID: deviceID,
            appCeremonyID: appCeremonyID,
            connectionGeneration: connectionGeneration,
            credentialJSON: credentialJSON
        )
    }

    func registerComplete(
        deviceID: String,
        appCeremonyID: String,
        connectionGeneration: UInt64,
        credentialJSON: String
    ) async throws -> GatewayPasskeyCompleteOutcome {
        try await complete(
            op: "passkey_register_complete",
            successFlag: "enrolled",
            deviceID: deviceID,
            appCeremonyID: appCeremonyID,
            connectionGeneration: connectionGeneration,
            credentialJSON: credentialJSON
        )
    }

    // MARK: Private

    private func begin(op: String, deviceID: String, connectionGeneration: UInt64) async throws -> GatewayPasskeyBeginOutcome {
        let result: MCPToolResult
        do {
            result = try await appLink.callTool(
                name: "remote_pairing",
                arguments: [
                    "op": .string(op),
                    "device_id": .string(deviceID),
                    "connection_generation": .int(generationInt(connectionGeneration))
                ],
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppLinkError {
            // Authoritative and uncertain failures are a generic non-success (the ceremony may or may
            // not have run on the app; never retried or rolled back here); a positively identified
            // outage is surfaced so the handler can report it without committing a grant.
            switch Self.trustDisposition(for: error) {
            case .invalidate:
                return .rejected(code: "passkey_begin_failed")
            case .preserve:
                return .transportFailure
            }
        } catch {
            return .rejected(code: "passkey_begin_failed")
        }
        if result.isError == true {
            return .rejected(code: "passkey_begin_failed")
        }
        guard let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
              let object = payload.objectValue
        else {
            return .rejected(code: "passkey_begin_failed")
        }
        guard object["ok"]?.boolValue == true else {
            return .rejected(code: object["code"]?.stringValue ?? "passkey_begin_failed")
        }
        guard let ceremonyID = object["ceremony_id"]?.stringValue, !ceremonyID.isEmpty else {
            return .rejected(code: "passkey_begin_failed")
        }
        return .began(GatewayPasskeyBeginResult(appCeremonyID: ceremonyID, optionsPayload: payload))
    }

    private func complete(
        op: String,
        successFlag: String,
        deviceID: String,
        appCeremonyID: String,
        connectionGeneration: UInt64,
        credentialJSON: String
    ) async throws -> GatewayPasskeyCompleteOutcome {
        let result: MCPToolResult
        do {
            result = try await appLink.callTool(
                name: "remote_pairing",
                arguments: [
                    "op": .string(op),
                    "device_id": .string(deviceID),
                    "ceremony_id": .string(appCeremonyID),
                    "connection_generation": .int(generationInt(connectionGeneration)),
                    "credential": .string(credentialJSON)
                ],
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppLinkError {
            // Completion may have occurred on the app even when this throws; it is a generic
            // non-success with no automatic retry and no claim that enrollment was rolled back.
            switch Self.trustDisposition(for: error) {
            case .invalidate:
                return .rejected(code: "passkey_complete_failed")
            case .preserve:
                return .transportFailure
            }
        } catch {
            return .rejected(code: "passkey_complete_failed")
        }
        if result.isError == true {
            return .rejected(code: "passkey_complete_failed")
        }
        guard let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
              let object = payload.objectValue
        else {
            return .rejected(code: "passkey_complete_failed")
        }
        guard object["ok"]?.boolValue == true, object[successFlag]?.boolValue == true else {
            return .rejected(code: object["code"]?.stringValue ?? "passkey_complete_failed")
        }
        // Validate the echoed identity against the request BEFORE the authority commits. A response
        // that does not match the exact device, ceremony, and connection generation we dispatched is
        // treated as a rejection, never a success for a different ceremony.
        guard object["device_id"]?.stringValue == deviceID,
              object["ceremony_id"]?.stringValue == appCeremonyID,
              let epochRaw = object["epoch"]?.stringValue,
              let epoch = UInt64(epochRaw),
              let generationValue = object["connection_generation"]?.intValue,
              generationValue >= 0,
              UInt64(generationValue) == connectionGeneration
        else {
            return .rejected(code: "passkey_stale_ceremony")
        }
        return .verified(GatewayPasskeyCompleteResult(
            deviceID: deviceID,
            appCeremonyID: appCeremonyID,
            epoch: epoch,
            connectionGeneration: connectionGeneration
        ))
    }

    /// The app accepts `connection_generation` as a JSON integer. Generations are process-local and
    /// allocated far below `Int.max`; clamp defensively so an out-of-range value cannot wrap.
    private func generationInt(_ generation: UInt64) -> Int {
        generation > UInt64(Int.max) ? Int.max : Int(generation)
    }

    /// Whether a thrown `AppLinkError` should PRESERVE the last valid trust/grant (a positively
    /// identified outage) or INVALIDATE conservatively. Exhaustive so a newly added error case forces
    /// a deliberate classification rather than defaulting to permissive preservation. The authoritative
    /// and uncertain cases are deliberately grouped: an uncertain failure's name is not provenance, so
    /// it cannot be allowed to preserve permissive access. (Step 3 Oracle plan §1–2.)
    private enum TrustThrowDisposition {
        case preserve
        case invalidate
    }

    private static func trustDisposition(for error: AppLinkError) -> TrustThrowDisposition {
        switch error {
        case .authoritativeToolFailure, .uncertainToolFailure:
            .invalidate
        case .notConnected, .socketCreationFailed, .descriptorConfigurationFailed, .pathTooLong,
             .connectFailed, .handshakeEncodingFailed, .handshakeTimeout, .handshakeRejected,
             .invalidHandshakeResponse, .toolCallTimedOut, .appLinkLost:
            .preserve
        }
    }
}
