//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift WebAuthn open source project
//
// Copyright (c) 2022 the Swift WebAuthn project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// RPCE local modification (bounded passkey verifier experiment, 2026-11-01): enforce BS => BE
// (backup-state implies backup-eligible) at registration. See Vendor/SwiftWebAuthn/PATCHES.md.
// Change is marked inline.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Crypto
@preconcurrency import SwiftCBOR

/// Contains the cryptographic attestation that a new key pair was created by that authenticator.
public struct AttestationObject: Sendable {
    let authenticatorData: AuthenticatorData
    let rawAuthenticatorData: [UInt8]
    let format: AttestationFormat
    let attestationStatement: CBOR

    /// The Authenticator Attestation Globally Unique Identifier (AAGUID) from the attestation object.
    /// Returns nil if attested credential data is not present.
    /// - SeeAlso: [WebAuthn Level 3 Editor's Draft §6.5.1. Attested Credential Data](https://w3c.github.io/webauthn/#sctn-attested-credential-data)
    public var aaguid: AAGUID? {
        authenticatorData.attestedData?.authenticatorAttestationGUID
    }

    func verify(
        relyingPartyID: String,
        verificationRequired: Bool,
        clientDataHash: SHA256.Digest,
        supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters],
        pemRootCertificatesByFormat: [AttestationFormat: [Data]] = [:]
    ) async throws -> AttestedCredentialData {
        let relyingPartyIDHash = SHA256.hash(data: Data(relyingPartyID.utf8))

        guard relyingPartyIDHash == authenticatorData.relyingPartyIDHash else {
            throw WebAuthnError.relyingPartyIDHashDoesNotMatch
        }

        guard authenticatorData.flags.userPresent else {
            throw WebAuthnError.userPresentFlagNotSet
        }

        if verificationRequired {
            guard authenticatorData.flags.userVerified else {
                throw WebAuthnError.userVerificationRequiredButFlagNotSet
            }
        }

        // RPCE local modification: a credential whose authenticator data reports "currently backed
        // up" (BS) MUST also be backup-eligible (BE). Enforce the malformed-flag-structure contract
        // at registration too (the assertion ceremony enforces the same rule).
        guard !(authenticatorData.flags.isCurrentlyBackedUp && !authenticatorData.flags.isBackupEligible) else {
            throw WebAuthnError.invalidBackupFlags
        }

        guard let attestedCredentialData = authenticatorData.attestedData else {
            throw WebAuthnError.attestedCredentialDataMissing
        }

        // Step 17.
        let credentialPublicKey = try CredentialPublicKey(publicKeyBytes: attestedCredentialData.publicKey)
        guard supportedPublicKeyAlgorithms.map(\.alg).contains(credentialPublicKey.key.algorithm) else {
            throw WebAuthnError.unsupportedCredentialPublicKeyAlgorithm
        }

        // let pemRootCertificates = pemRootCertificatesByFormat[format] ?? []
        switch format {
        case .none:
            // if format is `none` statement must be empty
            guard attestationStatement == .map([:]) else {
                throw WebAuthnError.attestationStatementMustBeEmpty
            }
        // case .packed:
        //     try await PackedAttestation.verify(
        //         attStmt: attestationStatement,
        //         authenticatorData: rawAuthenticatorData,
        //         clientDataHash: Data(clientDataHash),
        //         credentialPublicKey: credentialPublicKey,
        //         pemRootCertificates: pemRootCertificates
        //     )
        // case .tpm:
        //     try TPMAttestation.verify(
        //         attStmt: attestationStatement,
        //         authenticatorData: rawAuthenticatorData,
        //         attestedCredentialData: attestedCredentialData,
        //         clientDataHash: Data(clientDataHash),
        //         credentialPublicKey: credentialPublicKey,
        //         pemRootCertificates: pemRootCertificates
        //     )
        default:
            throw WebAuthnError.attestationVerificationNotSupported
        }

        return attestedCredentialData
    }
}
