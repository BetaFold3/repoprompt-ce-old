import Foundation
import WebAuthn

// Production promotion of the bounded passkey verifier (remote passkey unlock, Step 2). This is
// the app-owned relying-party adapter around the maintained-copy WebAuthn library. It drives the
// library's ordinary public ceremony API (no `@testable`), expresses the spec's narrow profile
// (required user verification, ES256-only, `none` attestation, counter-as-metadata), binds the
// asserted credential identity at the wire level without parsing COSE, caps raw input size before
// decoding, and never turns a verification failure into success. No vendor type is exposed through
// its inputs or outputs.

// MARK: - App-owned ceremony value types

/// Inputs for a registration (enrollment) verification. All fields are supplied by the app-owned
/// ceremony service from a bound challenge; none is taken from the untrusted response.
struct RemotePasskeyRegistrationInput {
    let challenge: [UInt8]
    let origin: RemotePasskeyOrigin
    /// Relying-party display name (build label). Not security-relevant, surfaced to the authenticator.
    let relyingPartyName: String
    /// Raw `navigator.credentials.create()` response JSON.
    let credentialJSON: Data
    /// Returns `true` when the given credential ID is NOT already assigned to any record in this
    /// build's registry (including revoked records). Used as a pre-check; the authoritative
    /// uniqueness guard is the store's atomic credential commit.
    let isCredentialIDUnused: @Sendable ([UInt8]) -> Bool
}

/// The app-owned result of a verified registration — verified, library-produced material only.
struct RemotePasskeyVerifiedRegistration: Equatable {
    let credentialID: [UInt8]
    let publicKeyCOSE: [UInt8]
    let signCount: UInt32
    let backupEligible: Bool
    let backedUp: Bool
}

/// Inputs for an assertion (unlock) verification against a stored credential.
struct RemotePasskeyAssertionInput {
    let challenge: [UInt8]
    let origin: RemotePasskeyOrigin
    let credentialID: [UInt8]
    let publicKeyCOSE: [UInt8]
    /// Stored user handle. When the response carries a user handle it must equal this; an absent
    /// response user handle is accepted (explicit `allowCredentials` flow).
    let userHandle: Data?
    /// Stored backup-eligible value, enforced for cross-ceremony immutability.
    let backupEligible: Bool
    /// Raw `navigator.credentials.get()` response JSON.
    let credentialJSON: Data
}

/// Typed, generic failures. Carries no raw library error text, so a failure can be surfaced to the
/// phone without leaking internals.
enum RemotePasskeyVerificationError: Error, Equatable {
    /// Raw wire input exceeded the byte cap and was rejected before any decoding.
    case oversizedInput
    /// The response JSON could not be decoded into the expected wire shape.
    case malformedResponse
    /// The asserted response's credential identity did not bind to the stored credential ID.
    case credentialIdentityMismatch
    /// The asserted response carried a user handle that did not equal the stored handle.
    case userHandleMismatch
    /// The credential ID is already assigned to another record in this build's registry.
    case duplicateCredentialID
    /// The ceremony failed the library's verification (UV, challenge, origin, signature, flags, …).
    case verificationFailed
}

// MARK: - Verifier protocol (injected so race tests can supply a suspending fake)

protocol RemotePasskeyVerifying: Sendable {
    func verifyRegistration(_ input: RemotePasskeyRegistrationInput) async throws -> RemotePasskeyVerifiedRegistration
    func verifyAssertion(_ input: RemotePasskeyAssertionInput) async throws
}

// MARK: - WebAuthn-backed implementation

struct WebAuthnRemotePasskeyVerifier: RemotePasskeyVerifying {
    /// Maximum accepted raw wire payload (bytes) for either ceremony. A real registration/assertion
    /// response is well under this; oversized input is rejected before decoding so a hostile blob
    /// cannot drive the decoder.
    static let maxWireBytes = 64 * 1024

    func verifyRegistration(_ input: RemotePasskeyRegistrationInput) async throws -> RemotePasskeyVerifiedRegistration {
        guard input.credentialJSON.count <= Self.maxWireBytes else {
            throw RemotePasskeyVerificationError.oversizedInput
        }
        let registration: RegistrationCredential
        do {
            registration = try JSONDecoder().decode(RegistrationCredential.self, from: input.credentialJSON)
        } catch {
            throw RemotePasskeyVerificationError.malformedResponse
        }

        let manager = Self.makeManager(origin: input.origin, relyingPartyName: input.relyingPartyName)
        let credential: Credential
        do {
            credential = try await manager.finishRegistration(
                challenge: input.challenge,
                credentialCreationData: registration,
                requireUserVerification: true,
                supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters(alg: .algES256)],
                // The library runs id == rawID == embeddedID before this closure, so registration.rawID
                // is the authenticator-attested credential ID here.
                confirmCredentialIDNotRegisteredYet: { _ in input.isCredentialIDUnused(registration.rawID) }
            )
        } catch {
            throw Self.mapVerificationError(error)
        }

        return RemotePasskeyVerifiedRegistration(
            credentialID: registration.rawID,
            publicKeyCOSE: credential.publicKey,
            signCount: credential.signCount,
            backupEligible: credential.backupEligible,
            backedUp: credential.isBackedUp
        )
    }

    func verifyAssertion(_ input: RemotePasskeyAssertionInput) async throws {
        guard input.credentialJSON.count <= Self.maxWireBytes else {
            throw RemotePasskeyVerificationError.oversizedInput
        }
        let assertion: AuthenticationCredential
        do {
            assertion = try JSONDecoder().decode(AuthenticationCredential.self, from: input.credentialJSON)
        } catch {
            throw RemotePasskeyVerificationError.malformedResponse
        }

        // Identity binding (relying-party responsibility), wire-level only — no COSE parsing.
        // The outer base64url `id` must decode to the same bytes as `rawId`, and `rawId` must equal
        // the stored credential ID the ceremony is bound to.
        guard let decodedID = assertion.id.decodedBytes, decodedID == assertion.rawID else {
            throw RemotePasskeyVerificationError.credentialIdentityMismatch
        }
        guard assertion.rawID == input.credentialID else {
            throw RemotePasskeyVerificationError.credentialIdentityMismatch
        }
        // Absent response user handle is accepted; a present one must equal the stored handle.
        if let responseHandle = assertion.response.userHandle {
            guard let stored = input.userHandle, Array(stored) == responseHandle else {
                throw RemotePasskeyVerificationError.userHandleMismatch
            }
        }

        let manager = Self.makeManager(origin: input.origin, relyingPartyName: Self.assertionRelyingPartyName)
        do {
            _ = try manager.finishAuthentication(
                credential: assertion,
                expectedChallenge: input.challenge,
                credentialPublicKey: input.publicKeyCOSE,
                // Metadata-only counter policy for synced credentials: a baseline of 0 means the
                // upstream clone heuristic never fires. The signature is always verified.
                credentialCurrentSignCount: 0,
                requireUserVerification: true,
                credentialBackupEligible: input.backupEligible
            )
        } catch {
            throw Self.mapVerificationError(error)
        }
    }

    // MARK: Helpers

    /// Relying-party display name used for the assertion manager. The RP name is not part of
    /// assertion verification (only RP ID / origin are), so a fixed non-empty value is sufficient.
    private static let assertionRelyingPartyName = "RepoPrompt"

    private static func makeManager(origin: RemotePasskeyOrigin, relyingPartyName: String) -> WebAuthnManager {
        WebAuthnManager(configuration: .init(
            relyingPartyID: origin.rpID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: origin.serialized
        ))
    }

    private static func mapVerificationError(_ error: Error) -> RemotePasskeyVerificationError {
        if let typed = error as? RemotePasskeyVerificationError {
            return typed
        }
        if let webAuthn = error as? WebAuthnError, webAuthn == .credentialIDAlreadyExists {
            return .duplicateCredentialID
        }
        return .verificationFailed
    }
}
