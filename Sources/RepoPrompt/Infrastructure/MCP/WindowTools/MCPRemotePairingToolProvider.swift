import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptAgentCore
import RepoPromptRemoteWire

struct RemotePairingExpectedFailure: Error, Equatable {
    let code: String
    let message: String
    let status: Int
}

enum RemotePairingOperation: String, Codable, CaseIterable {
    case discoverHost = "discover_host"
    case beginPairing = "begin_pairing"
    case completePairing = "complete_pairing"
    case mintTicket = "mint_ticket"
    case revokeDevice = "revoke_device"
    case listDevices = "list_devices"
    case passkeyRegisterBegin = "passkey_register_begin"
    case passkeyRegisterComplete = "passkey_register_complete"
    case passkeyUnlockBegin = "passkey_unlock_begin"
    case passkeyUnlockComplete = "passkey_unlock_complete"
    case acknowledgeTrust = "acknowledge_trust"
}

private enum MCPRemotePairingToolDefinition {
    static let description = """
    Gateway-only remote-control pairing authority.

    This tool is only callable by the app-spawned gateway connection carrying the verified gateway principal. It never authorizes by clientName. Pairing begins with a short-lived challenge, completes only after device-proof verification and user consent, and tickets are host-signed by the app-owned P256 key.

    Operations:
    - `discover_host`: sign the active fixed-channel origin and issue a short-lived approval context.
    - `begin_pairing`: atomically consume an approval context and create a ≤60s challenge. Does not persist trust.
    - `complete_pairing`: verify device proof, show consent UI, persist after approval.
    - `mint_ticket`: mint a one-time ≤60s host-signed ticket for a paired non-revoked device. Scopes are clamped to the device record.
    - `revoke_device`: mark a device revoked and clear push metadata.
    - `list_devices`: list paired devices and host fingerprint. Set `passkey_policy_capability` to 1 to receive the full passkey-policy projection, the authoritative origin, the current trust revision, and the exact issuance identity to acknowledge.
    - `passkey_register_begin` / `passkey_register_complete`: run the app-owned WebAuthn registration ceremony for a required device inside an open enrollment window. Registration never grants access.
    - `passkey_unlock_begin` / `passkey_unlock_complete`: run the assertion ceremony for an enrolled device. The app returns the verified fact; the gateway issues the grant.
    - `acknowledge_trust`: acknowledge the exact trust snapshot (`trust_launch`, `trust_revision`, `trust_issuance`) most recently issued to this capable principal.
    """

    static let inputSchema: JSONSchema = .object(
        properties: [
            "op": .string(
                description: "Remote pairing operation.",
                enum: ["discover_host", "begin_pairing", "complete_pairing", "mint_ticket", "revoke_device", "list_devices", "passkey_register_begin", "passkey_register_complete", "passkey_unlock_begin", "passkey_unlock_complete", "acknowledge_trust"]
            ),
            "ceremony_id": .string(description: "Passkey ceremony ID minted by the host at a begin op and echoed back at the matching complete op."),
            "connection_generation": .integer(description: "The gateway sink's connection generation, supplied from the authenticated connection."),
            "credential": .string(description: "Raw navigator.credentials create/get response JSON for a passkey complete op. Rejected over 64 KiB."),
            "passkey_policy_capability": .integer(description: "Set to 1 by a passkey-capable gateway on list_devices to receive the full policy projection."),
            "trust_launch": .string(description: "Host launch nonce echoed on acknowledge_trust."),
            "trust_revision": .string(description: "Store save-revision the gateway is acknowledging on acknowledge_trust, echoed exactly as the decimal string issued in list_devices (a JSON number is also accepted)."),
            "trust_issuance": .string(description: "Unguessable issuance ID from the acknowledged list_devices trust_revision; must be echoed exactly on acknowledge_trust."),
            "nonce": .string(description: "Discovery nonce from the native client."),
            "channel": .string(description: "Expected build channel: release or debug."),
            "approval_context": .string(description: "Fresh signed discovery approval context required by begin_pairing."),
            "pairing_id": .string(description: "Pairing UUID from begin_pairing, required by complete_pairing."),
            "display_name": .string(description: "Human-readable device name for complete_pairing."),
            "device_id": .string(description: "Device ID, usually remote:<fingerprint8>. Required for ticket/revoke; optional for complete_pairing when derivable from public_key."),
            "public_key": .string(description: "Base64 P256.Signing public-key rawRepresentation for complete_pairing."),
            "proof": .string(description: "Base64 P256 signature over the canonical device challenge payload."),
            "scopes": .array(description: "Requested/granted scope raw values.", items: .string()),
            "ttl_seconds": .integer(description: "Requested challenge/ticket TTL in seconds. Clamped to 60."),
            "include_revoked": .boolean(description: "Whether list_devices includes revoked devices. Default true.")
        ],
        required: ["op"]
    )

    static func contextForAppWideExecution(args _: [String: Value]) throws -> MCPWindowToolContext {
        MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 0)
    }
}

@MainActor
final class MCPRemotePairingToolService: Service {
    private let executionDependencies: MCPRemotePairingToolProvider.ExecutionDependencies

    init() {
        executionDependencies = .liveGatewayDependencies()
    }

    init(executionDependencies: MCPRemotePairingToolProvider.ExecutionDependencies) {
        self.executionDependencies = executionDependencies
    }

    var tools: [Tool] {
        get async { [remotePairingTool()] }
    }

    private func remotePairingTool() -> Tool {
        Tool(
            name: MCPWindowToolName.remotePairing,
            description: MCPRemotePairingToolDefinition.description,
            inputSchema: MCPRemotePairingToolDefinition.inputSchema,
            annotations: .repoPromptLocalEphemeralState,
            returnsValue: { [executionDependencies] args in
                let context = try MCPRemotePairingToolDefinition.contextForAppWideExecution(args: args)
                return try await MCPRemotePairingToolProvider.execute(
                    args: args,
                    context: context,
                    dependencies: executionDependencies
                )
            }
        )
    }
}

@MainActor
final class MCPRemotePairingToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .remotePairing

    struct ExecutionDependencies: @unchecked Sendable {
        let captureRequestMetadata: MCPWindowToolDependencies.CaptureRequestMetadata
        let isGatewayPrincipalConnection: MCPWindowToolDependencies.IsGatewayPrincipalConnection
        let identityStore: RemotePairingIdentityStore
        let approvalRouter: any RemotePairingApprovalRouting
        let discoveryAuthority: RemotePairingDiscoveryAuthority
        let challengeStore: RemotePairingChallengeStore
        let passkeyCoordinator: RemotePasskeyCoordinator
        let now: @Sendable () -> Date

        /// @MainActor so the `RemotePasskeyCoordinator.shared` default (a main-actor singleton) can
        /// be evaluated; every construction site is already on the main actor.
        @MainActor
        init(
            captureRequestMetadata: @escaping MCPWindowToolDependencies.CaptureRequestMetadata,
            isGatewayPrincipalConnection: @escaping MCPWindowToolDependencies.IsGatewayPrincipalConnection,
            identityStore: RemotePairingIdentityStore = .shared,
            approvalRouter: any RemotePairingApprovalRouting,
            discoveryAuthority: RemotePairingDiscoveryAuthority = .shared,
            challengeStore: RemotePairingChallengeStore = .shared,
            passkeyCoordinator: RemotePasskeyCoordinator = .shared,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.captureRequestMetadata = captureRequestMetadata
            self.isGatewayPrincipalConnection = isGatewayPrincipalConnection
            self.identityStore = identityStore
            self.approvalRouter = approvalRouter
            self.discoveryAuthority = discoveryAuthority
            self.challengeStore = challengeStore
            self.passkeyCoordinator = passkeyCoordinator
            self.now = now
        }

        @MainActor
        static func liveGatewayDependencies() -> ExecutionDependencies {
            ExecutionDependencies(
                captureRequestMetadata: {
                    // The gateway principal connection is never run-routed (policy hydration and
                    // routing fallback skip it), so it has no actor-side run tab.
                    MCPServerViewModel.RequestMetadata(
                        connectionID: ServerNetworkManager.currentConnectionID,
                        clientName: nil,
                        windowID: nil,
                        actorRoutedRunTab: nil
                    )
                },
                isGatewayPrincipalConnection: { connectionID in
                    await ServerNetworkManager.shared.isGatewayPrincipalConnection(connectionID)
                },
                approvalRouter: RemotePairingApprovalRouter.shared
            )
        }
    }

    private let runtime: MCPWindowToolRuntime
    private let executionDependencies: ExecutionDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        executionDependencies = ExecutionDependencies(
            captureRequestMetadata: dependencies.captureRequestMetadata,
            isGatewayPrincipalConnection: dependencies.isGatewayPrincipalConnection,
            approvalRouter: RemotePairingApprovalRouter.shared
        )
    }

    init(runtime: MCPWindowToolRuntime, executionDependencies: ExecutionDependencies) {
        self.runtime = runtime
        self.executionDependencies = executionDependencies
    }

    func buildTools() -> [Tool] {
        [remotePairingTool()]
    }

    private func remotePairingTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.remotePairing,
            freshnessPolicy: .none,
            description: MCPRemotePairingToolDefinition.description,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: MCPRemotePairingToolDefinition.inputSchema
        ) { [executionDependencies] context, args in
            try await Self.execute(args: args, context: context, dependencies: executionDependencies)
        }
    }

    static func execute(
        args: [String: Value],
        context: MCPWindowToolContext,
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        try await requireGatewayPrincipal(dependencies: dependencies)

        guard let opRaw = args["op"]?.stringValue,
              let operation = RemotePairingOperation(rawValue: opRaw)
        else {
            throw MCPError.invalidParams("op must be one of: \(RemotePairingOperation.allCases.map(\.rawValue).joined(separator: ", ")).")
        }

        switch operation {
        case .discoverHost:
            return try await executeExpectedFailureBoundary {
                try await executeDiscoverHost(args: args, dependencies: dependencies)
            }
        case .beginPairing:
            return try await executeExpectedFailureBoundary {
                try await executeBeginPairing(args: args, dependencies: dependencies)
            }
        case .completePairing:
            return try await executeExpectedFailureBoundary {
                try await executeCompletePairing(args: args, dependencies: dependencies)
            }
        case .mintTicket:
            return try await executeExpectedFailureBoundary {
                try executeMintTicket(args: args, dependencies: dependencies)
            }
        case .revokeDevice:
            return try executeRevokeDevice(args: args, dependencies: dependencies)
        case .listDevices:
            return try await executeExpectedFailureBoundary {
                try await executeListDevices(args: args, dependencies: dependencies)
            }
        case .passkeyRegisterBegin:
            return try await executeExpectedFailureBoundary {
                try await executePasskeyRegisterBegin(args: args, dependencies: dependencies)
            }
        case .passkeyRegisterComplete:
            return try await executeExpectedFailureBoundary {
                try await executePasskeyRegisterComplete(args: args, dependencies: dependencies)
            }
        case .passkeyUnlockBegin:
            return try await executeExpectedFailureBoundary {
                try await executePasskeyUnlockBegin(args: args, dependencies: dependencies)
            }
        case .passkeyUnlockComplete:
            return try await executeExpectedFailureBoundary {
                try await executePasskeyUnlockComplete(args: args, dependencies: dependencies)
            }
        case .acknowledgeTrust:
            return try await executeExpectedFailureBoundary {
                try await executeAcknowledgeTrust(args: args, dependencies: dependencies)
            }
        }
    }

    private static func executeExpectedFailureBoundary(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let failure as RemotePairingExpectedFailure {
            return expectedFailureValue(failure)
        } catch let error as RemotePairingDiscoveryAuthorityError {
            let failure: RemotePairingExpectedFailure = switch error {
            case .unavailable:
                .init(code: "discovery_unavailable", message: "Remote Control discovery is not active.", status: 503)
            case .buildChannelMismatch:
                .init(code: "build_channel_mismatch", message: "The requested build channel is not active.", status: 409)
            case .approvalContextRequired:
                .init(code: "approval_context_required", message: "A fresh approval context is required.", status: 409)
            case .approvalContextExpired:
                .init(code: "approval_context_expired", message: "The approval context expired; search again.", status: 409)
            case .approvalContextReplayed:
                .init(code: "approval_context_replayed", message: "The approval context was already used; search again.", status: 409)
            }
            return expectedFailureValue(failure)
        } catch let error as RemotePairingApprovalRouterError {
            let failure: RemotePairingExpectedFailure = switch error {
            case .approvalWindowUnavailable:
                .init(code: "approval_window_unavailable", message: "Open one RepoPrompt host window and retry.", status: 409)
            case .approvalWindowAmbiguous:
                .init(code: "approval_window_ambiguous", message: "Close extra RepoPrompt host windows and retry.", status: 409)
            case .approvalTargetStale:
                .init(code: "approval_target_stale", message: "The approval window closed; retry.", status: 409)
            case .cancelled:
                .init(code: "approval_cancelled", message: "Approval was cancelled.", status: 409)
            }
            return expectedFailureValue(failure)
        } catch let error as RemotePairingCryptoError {
            let failure: RemotePairingExpectedFailure? = switch error {
            case .expiredChallenge:
                .init(code: "pairing_challenge_expired", message: "The pairing challenge expired; retry.", status: 409)
            case .challengeAlreadyUsed:
                .init(code: "pairing_challenge_replayed", message: "The pairing challenge was already used.", status: 409)
            case .challengeNotFound:
                .init(code: "pairing_challenge_not_found", message: "The pairing challenge was not found.", status: 409)
            default:
                nil
            }
            if let failure { return expectedFailureValue(failure) }
            throw error
        } catch let failure as RemotePasskeyFailure {
            return expectedFailureValue(passkeyFailureValue(failure))
        }
    }

    /// Map a typed coordinator failure to the shared expected-failure envelope. The generic
    /// `challenge_invalid` code is preserved so a response never reveals which guard rejected.
    private static func passkeyFailureValue(_ failure: RemotePasskeyFailure) -> RemotePairingExpectedFailure {
        let status = switch failure {
        case .unknownDevice:
            404
        case .deviceRevoked, .gatewayUnsupported:
            403
        case .verificationFailed, .challengeInvalid, .staleAcknowledgment:
            401
        case .originUnavailable, .gatewayUnavailable, .storageFailed:
            503
        default:
            409
        }
        return RemotePairingExpectedFailure(code: failure.code, message: "Passkey operation rejected: \(failure.code).", status: status)
    }

    private static func expectedFailureValue(_ failure: RemotePairingExpectedFailure) -> Value {
        .object([
            "ok": .bool(false),
            "code": .string(failure.code),
            "error": .string(failure.message),
            "status": .int(failure.status)
        ])
    }

    private static func requireGatewayPrincipal(dependencies: ExecutionDependencies) async throws {
        let metadata = await dependencies.captureRequestMetadata()
        guard let connectionID = metadata.connectionID else {
            throw MCPError.invalidRequest("remote_pairing requires a verified gateway principal connection.")
        }
        guard await dependencies.isGatewayPrincipalConnection(connectionID) else {
            throw MCPError.invalidRequest("remote_pairing is restricted to the verified gateway principal.")
        }
    }

    private static func executeDiscoverHost(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let nonce = try requiredTrimmedString(args["nonce"], name: "nonce")
        let channelRaw = try requiredTrimmedString(args["channel"], name: "channel")
        guard let channel = RemoteControlBuildChannel(rawValue: channelRaw) else {
            throw MCPError.invalidParams("channel must be release or debug.")
        }
        let request = try RemoteDiscoveryRequest(nonce: nonce, channel: channel)
        let response = try await dependencies.discoveryAuthority.discover(request)
        return discoveryValue(response)
    }

    private static func executeBeginPairing(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let host = try dependencies.identityStore.hostPublicKeyInfo()
        let token = try requiredTrimmedString(args["approval_context"], name: "approval_context")
        let approvalContext = try await dependencies.discoveryAuthority.consumeContext(token)
        let now = dependencies.now()
        let remainingLifetime = approvalContext.expiresAt.timeIntervalSince(now)
        guard remainingLifetime > 0 else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextExpired
        }
        let ttl = min(ttlSeconds(from: args["ttl_seconds"]), remainingLifetime)
        let challenge = try await dependencies.challengeStore.issue(
            now: now,
            ttl: ttl,
            approvalContext: approvalContext,
            expiresAtLimit: approvalContext.expiresAt
        )
        return .object([
            "ok": .bool(true),
            "pairing_id": .string(challenge.pairingID.uuidString),
            "challenge": .string(challenge.challenge),
            "host_public_key": .string(host.rawRepresentation.base64EncodedString()),
            "host_fingerprint": .string(host.fingerprint),
            "expires_at": .string(formatDate(challenge.expiresAt))
        ])
    }

    private static func executeCompletePairing(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let pairingID = try requiredUUID(args["pairing_id"], name: "pairing_id")
        let displayName = try requiredTrimmedString(args["display_name"], name: "display_name")
        let publicKeyRaw = try requiredBase64Data(args["public_key"], name: "public_key")
        let proof = try requiredBase64Data(args["proof"], name: "proof")
        guard let requestedScopes = try parseScopes(args["scopes"], required: true) else {
            throw MCPError.invalidParams("scopes is required.")
        }
        let deviceID = try resolvedDeviceID(args["device_id"]?.stringValue, publicKeyRawRepresentation: publicKeyRaw)

        let challenge = try await dependencies.challengeStore.consume(pairingID: pairingID, now: dependencies.now())
        guard let approvalContext = challenge.approvalContext else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextRequired
        }
        try await dependencies.discoveryAuthority.validateActiveContext(approvalContext)
        let proofPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge.challenge,
            deviceID: deviceID,
            displayName: displayName,
            publicKeyRawRepresentation: publicKeyRaw,
            scopes: requestedScopes
        )
        try RemotePairingCrypto.verifyDeviceChallenge(payload: proofPayload, signature: proof)

        let host = try dependencies.identityStore.hostPublicKeyInfo()
        guard let deviceFingerprint = RemotePairingCrypto.fingerprint(forRawPublicKey: publicKeyRaw) else {
            throw MCPError.invalidParams("public_key is not a valid P256 signing public key.")
        }
        guard let grantedScopes = try await dependencies.approvalRouter.requestApproval(
            deviceID: deviceID,
            displayName: displayName,
            devicePublicKeyFingerprint: deviceFingerprint,
            requestedScopes: requestedScopes,
            hostFingerprint: host.fingerprint
        ), !grantedScopes.isEmpty else {
            throw RemotePairingExpectedFailure(code: "pairing_denied", message: "Remote device pairing was denied by the user.", status: 403)
        }

        try await dependencies.discoveryAuthority.validateActiveContext(approvalContext)
        let existingDevice = try dependencies.identityStore.device(id: deviceID)
        // deviceID is the pubkey fingerprint, so a re-pair reuses the same key;
        // resetting the anti-replay counterFloor would open a replay window for
        // previously captured signed frames.
        let record = PairedDeviceRecord(
            id: deviceID,
            displayName: displayName,
            publicKeyRawRepresentation: publicKeyRaw,
            scopes: grantedScopes,
            createdAt: dependencies.now(),
            counterFloor: existingDevice?.counterFloor ?? 0
        )
        let savedRecord = try dependencies.identityStore.upsertDevicePreservingCounterFloor(record)
        return .object([
            "ok": .bool(true),
            "device": deviceValue(savedRecord)
        ])
    }

    private static func executeMintTicket(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) throws -> Value {
        let deviceID = try requiredTrimmedString(args["device_id"], name: "device_id")
        guard let device = try dependencies.identityStore.device(id: deviceID) else {
            throw RemotePairingExpectedFailure(
                code: "unknown_device",
                message: "No paired device exists for \(deviceID).",
                status: 404
            )
        }
        guard !device.isRevoked else {
            throw RemotePairingExpectedFailure(
                code: "device_revoked",
                message: "Device \(deviceID) is revoked.",
                status: 403
            )
        }
        let requestedScopes = try parseScopes(args["scopes"], required: false) ?? device.scopes
        let grantedScopes = requestedScopes.intersection(device.scopes)
        guard !grantedScopes.isEmpty else {
            throw MCPError.invalidParams("Requested ticket scopes are not granted to \(deviceID).")
        }

        let issuedAt = dependencies.now()
        let expiresAt = issuedAt.addingTimeInterval(ttlSeconds(from: args["ttl_seconds"]))
        let host = try dependencies.identityStore.hostPublicKeyInfo()
        let key = try dependencies.identityStore.hostSigningPrivateKey()
        let ticket = try RemotePairingCrypto.signTicket(
            deviceID: deviceID,
            scopes: grantedScopes,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            hostFingerprint: host.fingerprint,
            hostSigner: key
        )
        return .object([
            "ok": .bool(true),
            "ticket": ticketValue(ticket)
        ])
    }

    private static func executeRevokeDevice(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) throws -> Value {
        let deviceID = try requiredTrimmedString(args["device_id"], name: "device_id")
        let record = try dependencies.identityStore.revokeDevice(id: deviceID, revokedAt: dependencies.now())
        return .object([
            "ok": .bool(true),
            "device": deviceValue(record),
            "gateway_sync_required": .bool(true)
        ])
    }

    private static func executeListDevices(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let includeRevoked = args["include_revoked"]?.boolValue ?? true
        let capable = (args["passkey_policy_capability"]?.intValue ?? 0) == 1
        let principalConnectionID = try await requirePrincipalConnectionID(dependencies)
        let host = try dependencies.identityStore.hostPublicKeyInfo()

        // A single lock-scope read so the device view and the revision it is acknowledged at
        // cannot tear. A registry fault is an authoritative "unavailable", never a silent empty.
        let snapshot: (registry: PairedDeviceRegistry, revision: UInt64)
        do {
            snapshot = try dependencies.identityStore.trustSnapshot()
        } catch {
            throw RemotePairingExpectedFailure(
                code: "registry_unavailable",
                message: "The paired-device registry could not be read.",
                status: 503
            )
        }
        let devices = snapshot.registry.devices
            .sorted { $0.createdAt < $1.createdAt }
            .filter { includeRevoked ? true : !$0.isRevoked }

        if capable {
            // A capable gateway receives the full policy projection, the current trust revision, the
            // authoritative origin, and the exact issued snapshot it may acknowledge.
            dependencies.passkeyCoordinator.recordTrustCall(capable: true, principalConnectionID: principalConnectionID)
            let projection = dependencies.passkeyCoordinator.trustProjection()
            var deviceEpochs: [String: UInt64] = [:]
            for device in devices where device.passkey.isRequired {
                deviceEpochs[device.id] = device.passkey.epoch
            }
            let issuanceID = dependencies.passkeyCoordinator.recordIssuedTrustSnapshot(
                principalConnectionID: principalConnectionID,
                revision: snapshot.revision,
                originRevision: projection.originRevision,
                deviceEpochs: deviceEpochs
            )
            let deviceValues = devices.map { device -> Value in
                let enrollment = dependencies.passkeyCoordinator.enrollmentProjection(for: device.id)
                return deviceValue(device, policyView: .full, policyExtras: [
                    "enrollment_open": .bool(enrollment.enrollmentOpen),
                    "needs_reenrollment": .bool(enrollment.needsReenrollment)
                ])
            }
            return .object([
                "ok": .bool(true),
                "passkey_policy_version": .int(1),
                "trust_revision": .object([
                    "launch": .string(dependencies.identityStore.launchNonce),
                    // Decimal string: lossless for a UInt64 revision on the JSON wire.
                    "revision": .string(String(snapshot.revision)),
                    // Unguessable per-issuance identity; acknowledge_trust must echo it exactly so an
                    // acknowledgment for a superseded issuance (same revision, different origin)
                    // cannot be accepted for the current one.
                    "issuance": issuanceID.map(Value.string) ?? .null
                ]),
                // Authoritative, app-published origin for Step 3 reconciliation (never a header).
                "origin": projection.originSerialized.map(Value.string) ?? .null,
                "origin_revision": .string(String(projection.originRevision)),
                "host_public_key": .string(host.rawRepresentation.base64EncodedString()),
                "host_fingerprint": .string(host.fingerprint),
                "devices": .array(deviceValues)
            ])
        }

        // Mixed-version safety: an old gateway that cannot enforce the passkey policy is told every
        // required device is revoked, so its existing revocation handling closes those connections.
        // This is a RESPONSE projection only — it does NOT durably revoke the device.
        dependencies.passkeyCoordinator.recordTrustCall(capable: false, principalConnectionID: principalConnectionID)
        return .object([
            "ok": .bool(true),
            "host_public_key": .string(host.rawRepresentation.base64EncodedString()),
            "host_fingerprint": .string(host.fingerprint),
            "devices": .array(devices.map { deviceValue($0, policyView: .maskedForLegacyGateway) })
        ])
    }

    // MARK: - Passkey ceremony operations (Step 2)

    private static func executePasskeyRegisterBegin(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let context = try await passkeyBeginContext(args: args, dependencies: dependencies)
        let options = try dependencies.passkeyCoordinator.registerBegin(context)
        return .object([
            "ok": .bool(true),
            "device_id": .string(context.deviceID),
            "ceremony_id": .string(options.ceremonyID),
            "challenge": .string(options.challengeBase64URL),
            "rp": .object(["id": .string(options.relyingPartyID), "name": .string(options.relyingPartyName)]),
            "user": .object([
                "id": .string(options.userHandleBase64URL),
                "name": .string(options.userName),
                "display_name": .string(options.userDisplayName)
            ]),
            "pub_key_cred_params": .array([.object(["type": .string("public-key"), "alg": .int(-7)])]),
            "authenticator_selection": .object([
                "resident_key": .string("preferred"),
                "user_verification": .string("required")
            ]),
            "attestation": .string("none"),
            "timeout": .int(options.timeoutMilliseconds)
        ])
    }

    private static func executePasskeyRegisterComplete(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let context = try await passkeyCeremonyContext(args: args, dependencies: dependencies)
        let json = try requiredCredentialJSON(args)
        let outcome = try await dependencies.passkeyCoordinator.registerComplete(context, credentialJSON: json)
        return .object([
            "ok": .bool(true),
            "enrolled": .bool(true),
            "device_id": .string(outcome.deviceID),
            "epoch": .string(String(outcome.epoch)),
            "ceremony_id": .string(outcome.ceremonyID),
            "connection_generation": .int(Int(outcome.connectionGeneration))
        ])
    }

    private static func executePasskeyUnlockBegin(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let context = try await passkeyBeginContext(args: args, dependencies: dependencies)
        let options = try dependencies.passkeyCoordinator.unlockBegin(context)
        return .object([
            "ok": .bool(true),
            "device_id": .string(context.deviceID),
            "ceremony_id": .string(options.ceremonyID),
            "challenge": .string(options.challengeBase64URL),
            "rp_id": .string(options.relyingPartyID),
            "allow_credentials": .array([.object([
                "type": .string("public-key"),
                "id": .string(options.allowedCredentialBase64URL)
            ])]),
            "user_verification": .string("required"),
            "timeout": .int(options.timeoutMilliseconds)
        ])
    }

    private static func executePasskeyUnlockComplete(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let context = try await passkeyCeremonyContext(args: args, dependencies: dependencies)
        let json = try requiredCredentialJSON(args)
        let outcome = try await dependencies.passkeyCoordinator.unlockComplete(context, credentialJSON: json)
        return .object([
            "ok": .bool(true),
            "verified": .bool(true),
            "device_id": .string(outcome.deviceID),
            "epoch": .string(String(outcome.epoch)),
            "ceremony_id": .string(outcome.ceremonyID),
            "connection_generation": .int(Int(outcome.connectionGeneration))
        ])
    }

    private static func executeAcknowledgeTrust(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let principalConnectionID = try await requirePrincipalConnectionID(dependencies)
        let launch = try requiredTrimmedString(args["trust_launch"], name: "trust_launch")
        // The revision is issued as a decimal string (lossless UInt64 on the JSON wire); accept the
        // echoed string as well as a JSON number so a conformant client round-trips it exactly.
        let revision = try requiredUInt64StringOrInt(args["trust_revision"], name: "trust_revision")
        let issuanceID = try requiredTrimmedString(args["trust_issuance"], name: "trust_issuance")
        try dependencies.passkeyCoordinator.acknowledgeTrust(
            principalConnectionID: principalConnectionID,
            launch: launch,
            revision: revision,
            issuanceID: issuanceID
        )
        return .object(["ok": .bool(true)])
    }

    // MARK: Passkey argument helpers

    private static func requirePrincipalConnectionID(_ dependencies: ExecutionDependencies) async throws -> String {
        let metadata = await dependencies.captureRequestMetadata()
        guard let connectionID = metadata.connectionID else {
            throw MCPError.invalidRequest("remote_pairing requires a verified gateway principal connection.")
        }
        return connectionID.uuidString
    }

    private static func passkeyBeginContext(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> RemotePasskeyBeginContext {
        let deviceID = try requiredPasskeyDeviceID(args)
        let connectionGeneration = try requiredUInt64(args["connection_generation"], name: "connection_generation")
        let principalConnectionID = try await requirePrincipalConnectionID(dependencies)
        return RemotePasskeyBeginContext(
            deviceID: deviceID,
            connectionGeneration: connectionGeneration,
            principalConnectionID: principalConnectionID
        )
    }

    private static func passkeyCeremonyContext(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> RemotePasskeyCeremonyContext {
        let deviceID = try requiredPasskeyDeviceID(args)
        let ceremonyID = try requiredTrimmedString(args["ceremony_id"], name: "ceremony_id")
        guard (16 ... 64).contains(ceremonyID.count) else {
            throw MCPError.invalidParams("ceremony_id must be 16...64 characters.")
        }
        let connectionGeneration = try requiredUInt64(args["connection_generation"], name: "connection_generation")
        let principalConnectionID = try await requirePrincipalConnectionID(dependencies)
        return RemotePasskeyCeremonyContext(
            deviceID: deviceID,
            ceremonyID: ceremonyID,
            connectionGeneration: connectionGeneration,
            principalConnectionID: principalConnectionID
        )
    }

    private static func requiredPasskeyDeviceID(_ args: [String: Value]) throws -> String {
        let deviceID = try requiredTrimmedString(args["device_id"], name: "device_id")
        guard RemotePairingCrypto.isValidDeviceID(deviceID) else {
            throw MCPError.invalidParams("device_id must match remote:<lowercase-hex>.")
        }
        return deviceID
    }

    private static func requiredCredentialJSON(_ args: [String: Value]) throws -> Data {
        guard let raw = args["credential"]?.stringValue, !raw.isEmpty else {
            throw MCPError.invalidParams("credential is required.")
        }
        let data = Data(raw.utf8)
        guard data.count <= 64 * 1024 else {
            throw MCPError.invalidParams("credential exceeds the 64 KiB limit.")
        }
        return data
    }

    private static func requiredUInt64(_ value: Value?, name: String) throws -> UInt64 {
        guard let intValue = value?.intValue, intValue >= 0 else {
            throw MCPError.invalidParams("\(name) must be a non-negative integer.")
        }
        return UInt64(intValue)
    }

    /// Accept a non-negative UInt64 supplied either as a JSON number or as a decimal string. The
    /// trust revision is issued to the client as a decimal string (lossless for the full UInt64
    /// range), so a conformant acknowledgment echoes that string; a plain JSON number is tolerated.
    private static func requiredUInt64StringOrInt(_ value: Value?, name: String) throws -> UInt64 {
        if let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty
        {
            guard let parsed = UInt64(string) else {
                throw MCPError.invalidParams("\(name) must be a non-negative integer.")
            }
            return parsed
        }
        if let intValue = value?.intValue, intValue >= 0 {
            return UInt64(intValue)
        }
        throw MCPError.invalidParams("\(name) must be a non-negative integer.")
    }

    private static func discoveryValue(_ response: RemoteDiscoveryResponse) -> Value {
        .object([
            "v": .int(response.v),
            "kind": .string(response.kind),
            "nonce": .string(response.nonce),
            "channel": .string(response.channel.rawValue),
            "origin": .string(response.origin.string),
            "host_public_key": .string(response.hostPublicKey.base64EncodedString()),
            "host_fingerprint": .string(response.hostFingerprint),
            "host_name": .string(response.hostName),
            "bundle_id": .string(response.bundleID),
            "marketing_version": .string(response.marketingVersion),
            "build_version": .string(response.buildVersion),
            "capabilities": .array(response.capabilities.map(Value.string)),
            "approval_context": .string(response.approvalContext),
            "issued_at_ms": .int(Int(response.issuedAtMs)),
            "expires_at_ms": .int(Int(response.expiresAtMs)),
            "algorithm": .string(response.algorithm),
            "signature": .string(response.signature.base64EncodedString())
        ])
    }

    private static func ttlSeconds(from value: Value?) -> TimeInterval {
        guard let seconds = value?.intValue, seconds > 0 else {
            return RemotePairingCrypto.maximumTicketTTL
        }
        return min(TimeInterval(seconds), RemotePairingCrypto.maximumTicketTTL)
    }

    private static func parseScopes(_ value: Value?, required: Bool) throws -> Set<RemoteScope>? {
        guard let value else {
            if required { throw MCPError.invalidParams("scopes is required.") }
            return nil
        }
        guard let entries = value.arrayValue else {
            throw MCPError.invalidParams("scopes must be an array of scope strings.")
        }
        let scopes = try Set(entries.map { entry in
            guard let raw = entry.stringValue,
                  let scope = RemoteScope(rawValue: raw)
            else {
                throw MCPError.invalidParams("Unknown remote scope in scopes.")
            }
            return scope
        })
        guard !scopes.isEmpty else {
            throw MCPError.invalidParams("scopes must not be empty.")
        }
        return scopes
    }

    private static func resolvedDeviceID(_ raw: String?, publicKeyRawRepresentation: Data) throws -> String {
        let derived = try RemotePairingCrypto.deviceID(forRawPublicKey: publicKeyRawRepresentation)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return derived }
        guard RemotePairingCrypto.isValidDeviceID(trimmed) else {
            throw MCPError.invalidParams("device_id must match remote:<lowercase-hex>.")
        }
        guard trimmed == derived else {
            throw MCPError.invalidParams("device_id must equal the ID derived from public_key.")
        }
        return trimmed
    }

    private static func requiredUUID(_ value: Value?, name: String) throws -> UUID {
        guard let raw = value?.stringValue,
              let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MCPError.invalidParams("\(name) must be a UUID string.")
        }
        return uuid
    }

    private static func requiredTrimmedString(_ value: Value?, name: String) throws -> String {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return string
    }

    private static func requiredBase64Data(_ value: Value?, name: String) throws -> Data {
        guard let raw = value?.stringValue,
              let data = Data(base64Encoded: raw)
        else {
            throw MCPError.invalidParams("\(name) must be base64 data.")
        }
        return data
    }

    private static func ticketValue(_ ticket: RemoteConnectionTicket) -> Value {
        .object([
            "ticket_id": .string(ticket.ticketID.uuidString),
            "device_id": .string(ticket.deviceID),
            "scopes": .array(ticket.scopes.sorted().map { .string($0.rawValue) }),
            "issued_at": .string(formatDate(ticket.issuedAt)),
            "expires_at": .string(formatDate(ticket.expiresAt)),
            // Canonical signed milliseconds: verifiers must use these exact values so
            // signature checks never depend on a lossy ISO-8601 date round-trip.
            "issued_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(ticket.issuedAt))),
            "expires_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(ticket.expiresAt))),
            "host_fingerprint": .string(ticket.hostFingerprint),
            "host_signature": .string(ticket.hostSignature.base64EncodedString())
        ])
    }

    /// How a device's passkey policy is projected into a `deviceValue` response.
    enum PolicyView {
        /// No policy fields (complete-pairing and revoke responses).
        case none
        /// Full policy projection for a passkey-capable gateway.
        case full
        /// Legacy gateway: a required device is reported `revoked` so the old gateway's revocation
        /// handling closes it; no policy fields are added. Response-only, not a durable revocation.
        case maskedForLegacyGateway
    }

    private static func deviceValue(_ device: PairedDeviceRecord, policyView: PolicyView = .none, policyExtras: [String: Value]? = nil) -> Value {
        var object: [String: Value] = [
            "schema_version": .int(device.schemaVersion),
            "id": .string(device.id),
            "display_name": .string(device.displayName),
            "public_key": .string(device.publicKeyRawRepresentation.base64EncodedString()),
            "public_key_fingerprint": .string(device.publicKeyFingerprint ?? ""),
            "scopes": .array(device.scopes.sorted().map { .string($0.rawValue) }),
            "created_at": .string(formatDate(device.createdAt)),
            "counter_floor": .int(Int(device.counterFloor)),
            "revoked": .bool(device.isRevoked)
        ]
        if let lastSeenAt = device.lastSeenAt {
            object["last_seen_at"] = .string(formatDate(lastSeenAt))
        } else {
            object["last_seen_at"] = .null
        }
        if let revokedAt = device.revokedAt {
            object["revoked_at"] = .string(formatDate(revokedAt))
        } else {
            object["revoked_at"] = .null
        }
        object["has_push_subscription"] = .bool(device.pushSubscription != nil)

        switch policyView {
        case .none:
            break
        case .maskedForLegacyGateway:
            if device.passkey.isRequired {
                object["revoked"] = .bool(true)
            }
        case .full:
            var policy: [String: Value] = [
                "version": .int(1),
                "state": .string(device.passkey.state.rawValue),
                "enrolled": .bool(device.passkey.isEnrolled),
                // Decimal string: lossless for a UInt64 epoch on the JSON wire.
                "epoch": .string(String(device.passkey.epoch))
            ]
            if let policyExtras {
                policy.merge(policyExtras) { _, extra in extra }
            }
            object["passkey_policy"] = .object(policy)
        }
        return .object(object)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
