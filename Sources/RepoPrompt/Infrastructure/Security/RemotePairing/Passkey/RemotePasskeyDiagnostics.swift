import Foundation
import os
import WebAuthn

/// Mac-local unified-log diagnostics for passkey ceremonies (remote passkey unlock, Step 5
/// live-acceptance diagnosis). The phone and MCP wire stay generic (`challenge_invalid` /
/// `verification_failed`); this records only that a completion was RECEIVED, WHICH fixed guard or
/// library check REJECTED it, or that an expired challenge was PRUNED, so a failed live ceremony
/// can be explained without changing any acceptance rule. Success after receipt is silent.
///
/// Read with a process filter and a short window around the attempt — test runs (`xctest`) write
/// identical fixed lines to the same subsystem/category, and the Dev app's executable is
/// `RepoPrompt`:
/// `log show --start '<attempt-2m>' --end '<attempt+5m>' --predicate 'subsystem == "com.repoprompt.app" AND category == "RemotePasskey" AND process == "RepoPrompt"'`.
///
/// Every logged field is a fixed enum token from the allowlists below. Never credential, challenge,
/// public key, origin, user, device or ceremony identifiers, raw library errors, error
/// descriptions, coding paths/keys/values, reflection, bearer material or frames.
struct RemotePasskeyDiagnosticEvent: Equatable {
    /// Fixed line prefix: semantically distinct event types.
    enum Kind: String {
        case received = "passkey_ceremony_received"
        case rejected = "passkey_ceremony_rejected"
        case pruned = "passkey_challenge_pruned"
    }

    enum Ceremony: String {
        case registration
        case assertion
    }

    enum Stage: String {
        case preBinding = "pre_binding"
        case verifier
        case postBinding = "post_binding"
        case principalLiveness = "principal_liveness"
        case store
        /// An expired pending challenge was dropped by `prune()` before any completion arrived.
        case pruned
    }

    /// Which `DecodingError` case rejected a decode — the case only, never its context.
    enum DecodingFailure: String {
        case keyNotFound = "key_not_found"
        case typeMismatch = "type_mismatch"
        case valueNotFound = "value_not_found"
        case dataCorrupted = "data_corrupted"
        case other

        init(_ error: Error) {
            guard let decoding = error as? DecodingError else {
                self = .other
                return
            }
            switch decoding {
            case .keyNotFound: self = .keyNotFound
            case .typeMismatch: self = .typeMismatch
            case .valueNotFound: self = .valueNotFound
            case .dataCorrupted: self = .dataCorrupted
            @unknown default: self = .other
            }
        }
    }

    /// Diagnostic-only re-check of the public `CollectedClientData` fields, reported ONLY for the
    /// `libraryUnknown` bucket (the library's own client-data mismatch error is internal to the
    /// vendor module). It never affects acceptance and logs no values.
    enum ClientDataCheck: String {
        case consistent
        case undecodable
        case typeMismatch = "type_mismatch"
        case challengeMismatch = "challenge_mismatch"
        case originMismatch = "origin_mismatch"
    }

    let kind: Kind
    let ceremony: Ceremony
    let stage: Stage?
    let reason: RemotePasskeyDiagnosticReason?
    let clientDataCheck: ClientDataCheck?
    let decodingFailure: DecodingFailure?

    /// A rejection at a fixed stage with a fixed reason.
    init(
        ceremony: Ceremony,
        stage: Stage,
        reason: RemotePasskeyDiagnosticReason,
        clientDataCheck: ClientDataCheck? = nil,
        decodingFailure: DecodingFailure? = nil
    ) {
        self.init(kind: .rejected, ceremony: ceremony, stage: stage, reason: reason, clientDataCheck: clientDataCheck, decodingFailure: decodingFailure)
    }

    private init(
        kind: Kind,
        ceremony: Ceremony,
        stage: Stage?,
        reason: RemotePasskeyDiagnosticReason?,
        clientDataCheck: ClientDataCheck?,
        decodingFailure: DecodingFailure?
    ) {
        self.kind = kind
        self.ceremony = ceremony
        self.stage = stage
        self.reason = reason
        self.clientDataCheck = clientDataCheck
        self.decodingFailure = decodingFailure
    }

    /// A completion reached the coordinator (before any slot lookup or guard).
    static func received(_ ceremony: Ceremony) -> Self {
        .init(kind: .received, ceremony: ceremony, stage: nil, reason: nil, clientDataCheck: nil, decodingFailure: nil)
    }

    /// An expired pending challenge was dropped by `prune()`; no ceremony data is retained.
    static func pruned(_ ceremony: Ceremony, reason: RemotePasskeyDiagnosticReason) -> Self {
        .init(kind: .pruned, ceremony: ceremony, stage: .pruned, reason: reason, clientDataCheck: nil, decodingFailure: nil)
    }

    /// The one rendered line. Built only from fixed raw values.
    var rendered: String {
        var line = "\(kind.rawValue) ceremony=\(ceremony.rawValue)"
        if let stage { line += " stage=\(stage.rawValue)" }
        if let reason { line += " reason=\(reason.rawValue)" }
        if let clientDataCheck { line += " client_data=\(clientDataCheck.rawValue)" }
        if let decodingFailure { line += " decoding=\(decodingFailure.rawValue)" }
        return line
    }
}

/// Fixed, allowlisted rejection reasons.
enum RemotePasskeyDiagnosticReason: String, CaseIterable {
    // MARK: Binding (coordinator)

    case challengeSlotEmpty = "challenge_slot_empty"
    case ceremonyIDMismatch = "ceremony_id_mismatch"
    case principalMismatch = "principal_mismatch"
    case connectionGenerationMismatch = "connection_generation_mismatch"
    case ceremonyTokenSuperseded = "ceremony_token_superseded"
    case principalInvalidated = "principal_invalidated"
    case challengeExpired = "challenge_expired"
    /// The challenge's deadline was capped at the enrollment window's end and that deadline passed.
    case challengeExpiredWindowCapped = "challenge_expired_window_capped"
    case originUnavailable = "origin_unavailable"
    case originChanged = "origin_changed"
    case originRevisionChanged = "origin_revision_changed"
    case deviceUnavailable = "device_unavailable"
    case deviceRevoked = "device_revoked"
    case epochChanged = "epoch_changed"
    case policyNotRequired = "policy_not_required"
    case alreadyEnrolled = "already_enrolled"
    case windowMissing = "window_missing"
    case windowReplaced = "window_replaced"
    case windowExpired = "window_expired"
    case windowBindingChanged = "window_binding_changed"
    case credentialChanged = "credential_changed"
    case assertionMaterialMissing = "assertion_material_missing"

    // MARK: Principal liveness

    case principalNotLive = "principal_not_live"

    // MARK: Store

    case storePolicyConflict = "store_policy_conflict"
    case storeDuplicateCredentialID = "store_duplicate_credential_id"
    case storeDeviceNotFound = "store_device_not_found"
    case storeFailed = "store_failed"

    // MARK: Verifier: envelope / adapter

    case oversizedInput = "oversized_input"
    case malformedEnvelope = "malformed_envelope"
    /// The response's outer `id` and `rawId` are different bytes.
    case credentialIDWireMismatch = "credential_id_wire_mismatch"
    /// The response's `rawId` is not the stored credential the ceremony is bound to.
    case credentialIDNotBound = "credential_id_not_bound"
    case userHandleMismatch = "user_handle_mismatch"
    case clientDataUndecodable = "client_data_undecodable"

    // MARK: Verifier: library (public `WebAuthnError` constants)

    case attestedCredentialDataMissing = "attested_credential_data_missing"
    case rpIDHashMismatch = "rp_id_hash_mismatch"
    case userPresentMissing = "user_present_missing"
    case invalidSignature = "invalid_signature"
    case userVerificationMissing = "user_verification_missing"
    case attestationStatementNotEmpty = "attestation_statement_not_empty"
    case attestationFormatUnsupported = "attestation_format_unsupported"
    case invalidUserID = "invalid_user_id"
    case unsupportedCredentialAlgorithm = "unsupported_credential_algorithm"
    case duplicateCredentialID = "duplicate_credential_id"
    case potentialReplay = "potential_replay"
    case invalidAssertionCredentialType = "invalid_assertion_credential_type"
    case invalidAttestationObject = "invalid_attestation_object"
    case invalidAuthData = "invalid_auth_data"
    case invalidFmt = "invalid_fmt"
    case missingAttStmt = "missing_att_stmt"
    case invalidCredentialCreationType = "invalid_credential_creation_type"
    case credentialRawIDTooLong = "credential_raw_id_too_long"
    case authDataTooShort = "auth_data_too_short"
    case attestedCredentialFlagNotSet = "attested_credential_flag_not_set"
    case extensionDataMissing = "extension_data_missing"
    case leftOverBytesInAuthenticatorData = "left_over_bytes_in_authenticator_data"
    case credentialIDLength = "credential_id_length"
    case invalidPublicKeyLength = "invalid_public_key_length"
    case badPublicKey = "bad_public_key"
    case unsupportedPublicKeyProfile = "unsupported_public_key_profile"
    case invalidPublicKeyCoordinate = "invalid_public_key_coordinate"
    case credentialIDMismatch = "credential_id_mismatch"
    case attestedCredentialDataInAssertion = "attested_credential_data_in_assertion"
    case invalidBackupFlags = "invalid_backup_flags"
    case backupEligibilityMismatch = "backup_eligibility_mismatch"
    case invalidExtensions = "invalid_extensions"
    /// Any library/internal error without a mapped public constant (e.g. the internal client-data
    /// verify error, CBOR decoder or crypto errors, or an unmapped `WebAuthnError`).
    case libraryUnknown = "library_unknown"

    /// Equality-only mapping from the library's PUBLIC `WebAuthnError` constants; nil when unmapped
    /// (including any future constant), so the caller falls through to `libraryUnknown`.
    static func knownLibraryReason(_ error: WebAuthnError) -> RemotePasskeyDiagnosticReason? {
        libraryTable[error]
    }

    private static let libraryTable: [WebAuthnError: RemotePasskeyDiagnosticReason] = [
        .attestedCredentialDataMissing: .attestedCredentialDataMissing,
        .relyingPartyIDHashDoesNotMatch: .rpIDHashMismatch,
        .userPresentFlagNotSet: .userPresentMissing,
        .invalidSignature: .invalidSignature,
        .userVerificationRequiredButFlagNotSet: .userVerificationMissing,
        .userVerifiedFlagNotSet: .userVerificationMissing,
        .attestationStatementMustBeEmpty: .attestationStatementNotEmpty,
        .attestationVerificationNotSupported: .attestationFormatUnsupported,
        .attestationFormatNotSupported: .attestationFormatUnsupported,
        .invalidUserID: .invalidUserID,
        .unsupportedCredentialPublicKeyAlgorithm: .unsupportedCredentialAlgorithm,
        .credentialIDAlreadyExists: .duplicateCredentialID,
        .potentialReplayAttack: .potentialReplay,
        .invalidAssertionCredentialType: .invalidAssertionCredentialType,
        .invalidAttestationObject: .invalidAttestationObject,
        .invalidAuthData: .invalidAuthData,
        .invalidFmt: .invalidFmt,
        .missingAttStmt: .missingAttStmt,
        .invalidCredentialCreationType: .invalidCredentialCreationType,
        .credentialRawIDTooLong: .credentialRawIDTooLong,
        .authDataTooShort: .authDataTooShort,
        .attestedCredentialFlagNotSet: .attestedCredentialFlagNotSet,
        .extensionDataMissing: .extensionDataMissing,
        .leftOverBytesInAuthenticatorData: .leftOverBytesInAuthenticatorData,
        .credentialIDTooLong: .credentialIDLength,
        .credentialIDTooShort: .credentialIDLength,
        .invalidPublicKeyLength: .invalidPublicKeyLength,
        .badPublicKeyBytes: .badPublicKey,
        .rawU2FPublicKeyUnsupported: .badPublicKey,
        .invalidKeyType: .unsupportedPublicKeyProfile,
        .invalidAlgorithm: .unsupportedPublicKeyProfile,
        .invalidCurve: .unsupportedPublicKeyProfile,
        .unsupportedCOSEAlgorithm: .unsupportedPublicKeyProfile,
        .unsupportedCOSEAlgorithmForEC2PublicKey: .unsupportedPublicKeyProfile,
        .unsupportedCOSEAlgorithmForRSAPublicKey: .unsupportedPublicKeyProfile,
        .invalidModulus: .unsupportedPublicKeyProfile,
        .invalidExponent: .unsupportedPublicKeyProfile,
        .unsupported: .unsupportedPublicKeyProfile,
        .invalidXCoordinate: .invalidPublicKeyCoordinate,
        .invalidYCoordinate: .invalidPublicKeyCoordinate,
        .credentialIDMismatch: .credentialIDMismatch,
        .attestedCredentialDataFlagSetInAssertion: .attestedCredentialDataInAssertion,
        .invalidBackupFlags: .invalidBackupFlags,
        .backupEligibilityMismatch: .backupEligibilityMismatch,
        .invalidExtensions: .invalidExtensions
    ]
}

/// Injected diagnostic sink. Production uses `.unifiedLog`; focused tests inject a recorder.
struct RemotePasskeyDiagnostics {
    private let sink: @Sendable (RemotePasskeyDiagnosticEvent) -> Void

    init(sink: @escaping @Sendable (RemotePasskeyDiagnosticEvent) -> Void) {
        self.sink = sink
    }

    func record(_ event: RemotePasskeyDiagnosticEvent) {
        sink(event)
    }

    private static let logger = Logger(subsystem: "com.repoprompt.app", category: "RemotePasskey")

    static let unifiedLog = RemotePasskeyDiagnostics { event in
        logger.notice("\(event.rendered, privacy: .public)")
    }

    /// Classify the public client-data fields against the bound ceremony values. Diagnostic only:
    /// called after the library has already rejected, never consulted for acceptance.
    static func clientDataCheck(
        clientDataJSON: [UInt8],
        expectedType: CollectedClientData.CeremonyType,
        expectedChallenge: [UInt8],
        expectedOrigin: String
    ) -> RemotePasskeyDiagnosticEvent.ClientDataCheck {
        guard let clientData = try? JSONDecoder().decode(CollectedClientData.self, from: Data(clientDataJSON)) else {
            return .undecodable
        }
        if clientData.type != expectedType { return .typeMismatch }
        if clientData.challenge != expectedChallenge.base64URLEncodedString() { return .challengeMismatch }
        if clientData.origin != expectedOrigin { return .originMismatch }
        return .consistent
    }
}
