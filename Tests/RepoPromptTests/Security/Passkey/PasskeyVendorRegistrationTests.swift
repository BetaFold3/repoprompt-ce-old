// Bounded passkey verifier experiment — registration ceremony tests (public boundary).

import Crypto
import Foundation
import SwiftCBOR
@testable import WebAuthn
import XCTest

final class PasskeyVendorRegistrationTests: XCTestCase {
    private func challenge() -> [UInt8] {
        SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    }

    // MARK: Positive

    func testValidES256SyncedRegistrationSucceeds() async throws {
        let verifier = BoundedPasskeyVerifier()
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch) // UP|UV|BE by default

        let credential = try await verifier.register(challenge: ch, json: json)

        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
        XCTAssertFalse(credential.publicKey.isEmpty)
        XCTAssertTrue(credential.backupEligible, "BE flag set => backup eligible (synced)")
        // The stored public key must verify a fresh assertion (round-trip sanity).
        let assertionChallenge = challenge()
        let assertionJSON = authenticator.assertionJSON(challenge: assertionChallenge)
        let verified = try BoundedPasskeyVerifier().assert(
            challenge: assertionChallenge,
            storedPublicKey: credential.publicKey,
            expectedCredentialID: authenticator.credentialID,
            json: assertionJSON
        )
        XCTAssertEqual(verified.credentialID, URLEncodedBase64(Base64URL.encode(authenticator.credentialID)))
    }

    // MARK: User presence / verification

    func testRegistrationRejectsMissingUserVerification() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.be) // no UV
        await assertThrowsWebAuthn(.userVerificationRequiredButFlagNotSet) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsMissingUserPresence() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, flags: SoftwareAuthenticator.uv | SoftwareAuthenticator.be) // no UP
        await assertThrowsWebAuthn(.userPresentFlagNotSet) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Origin / RP / challenge / type

    func testRegistrationRejectsOriginPortMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, clientOrigin: "https://example.com:8443")
        await assertThrows { try await BoundedPasskeyVerifier().register(challenge: ch, json: json) }
    }

    func testRegistrationRejectsRelyingPartyHashMismatch() async {
        var authenticator = SoftwareAuthenticator()
        authenticator.relyingPartyID = "attacker.example" // authData RP hash will not match verifier RP
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch)
        await assertThrowsWebAuthn(.relyingPartyIDHashDoesNotMatch) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsChallengeMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let stored = challenge()
        let json = authenticator.registrationJSON(challenge: challenge()) // clientData embeds a different challenge
        await assertThrows { try await BoundedPasskeyVerifier().register(challenge: stored, json: json) }
    }

    func testRegistrationRejectsWrongCeremonyType() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, clientType: "webauthn.get")
        await assertThrows { try await BoundedPasskeyVerifier().register(challenge: ch, json: json) }
    }

    // MARK: Credential-ID binding (id == rawID == embeddedID)

    func testRegistrationRejectsEmbeddedOuterIDMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // Outer rawId differs from the attested embedded credential ID.
        let json = authenticator.registrationJSON(challenge: ch, rawIDOverride: Array("different-outer-id".utf8))
        await assertThrowsWebAuthn(.credentialIDMismatch) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsOuterIDVsRawIDMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // JSON `id` differs from `rawId` (both outer fields must be the same bytes).
        let json = authenticator.registrationJSON(challenge: ch, idOverride: Array("different-id-field".utf8))
        await assertThrowsWebAuthn(.credentialIDMismatch) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Backup flag structure (BS => BE) at registration

    func testRegistrationRejectsBackupStateWithoutEligible() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // BS set, BE clear => invalid backup-flag structure, rejected at registration.
        let json = authenticator.registrationJSON(challenge: ch, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.bs)
        await assertThrowsWebAuthn(.invalidBackupFlags) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Oversized input rejected before decoding

    func testRegistrationRejectsOversizedInput() async {
        let ch = challenge()
        let oversized = Data(repeating: 0x20, count: BoundedPasskeyVerifier.maxWireBytes + 1)
        await assertThrowsAdapter(.oversizedWireInput) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: oversized)
        }
    }

    // MARK: Key shape

    func testRegistrationRejectsShortXCoordinate() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let badKey = authenticator.coseES256PublicKey(xOverride: [UInt8](repeating: 0x01, count: 31))
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidXCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsPointNotOnCurve() async {
        // A valid-length but OFF-CURVE point: the real x with one bit flipped in y. Enrollment
        // MUST reject this at registration time. The verifier rebuilds the canonical on-curve y
        // from x via swift-crypto's compressed-point decompression and compares it to the supplied
        // y, so the tampered (off-curve) y mismatches and is rejected — it is never stored.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let (x, y) = authenticator.publicKeyXY
        var badY = y
        badY[badY.count - 1] ^= 0x01
        let badKey = authenticator.coseES256PublicKey(xOverride: x, yOverride: badY)
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidYCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    /// Deterministically finds a 32-byte x that has NO point on P-256 for either parity, using the
    /// existing Crypto decompression API (no field arithmetic): the first x whose compressed form
    /// cannot be decompressed is a non-residue of the curve equation. ~half of x values qualify, so
    /// this resolves within a few iterations and is stable for the fixed curve.
    private func firstNoSolutionX() -> [UInt8]? {
        for i in 0 ... 255 {
            let x = [UInt8](repeating: 0, count: 31) + [UInt8(i)]
            if (try? P256.Signing.PublicKey(compressedRepresentation: [0x02] + x)) == nil {
                return x
            }
        }
        return nil
    }

    func testRegistrationRejectsNoSolutionX() async throws {
        // An x with no on-curve y (decompression throws, non-trapping) => rejected at registration.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let noSolutionX = try XCTUnwrap(firstNoSolutionX())
        let badKey = authenticator.coseES256PublicKey(
            xOverride: noSolutionX,
            yOverride: [UInt8](repeating: 0x00, count: 32)
        )
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidXCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsOutOfFieldCoordinate() async {
        // x = 0xFF*32 (all-ones) is rejected at registration. The canonical compressed-point
        // decompression and raw comparison reject it regardless of how the backend treats an
        // out-of-field encoding; this test does not assert a specific internal cause.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let badKey = authenticator.coseES256PublicKey(
            xOverride: [UInt8](repeating: 0xFF, count: 32),
            yOverride: [UInt8](repeating: 0x00, count: 32)
        )
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidXCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsSameParityInvalidY() async {
        // Off-curve y that keeps the SAME parity as the real y (flip a high bit, not the LSB). The
        // canonical y rebuilt for that parity differs from the supplied y => invalidYCoordinate.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let (x, y) = authenticator.publicKeyXY
        var badY = y
        badY[0] ^= 0x01 // high byte: changes value, preserves integer (LSB) parity
        let badKey = authenticator.coseES256PublicKey(xOverride: x, yOverride: badY)
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidYCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationAcceptsBothYParities() async throws {
        // Positive controls for BOTH y parities. The authenticator key (x, y) is one parity; its
        // negation (x, p-y) — obtained via opposite-parity decompression, no field math — is the
        // other. Both are valid on-curve points and must register. Also assert the parities differ.
        let authenticator = SoftwareAuthenticator()
        let (x, y) = authenticator.publicKeyXY
        let realParity = y[y.count - 1] & 0x01
        let oppositePrefix: UInt8 = realParity == 0 ? 0x03 : 0x02
        let negated = try XCTUnwrap(try? P256.Signing.PublicKey(compressedRepresentation: [oppositePrefix] + x)).rawRepresentation
        let negY = Array(Array(negated)[32 ..< 64])
        XCTAssertNotEqual(negY[negY.count - 1] & 0x01, realParity, "negated point must have opposite y parity")

        // Real point (parity A).
        let chA = challenge()
        let jsonA = authenticator.registrationJSON(challenge: chA, coseKey: authenticator.coseES256PublicKey())
        _ = try await BoundedPasskeyVerifier().register(challenge: chA, json: jsonA)

        // Negated point (parity B) — valid on-curve, must also be accepted at construction.
        let chB = challenge()
        let jsonB = authenticator.registrationJSON(challenge: chB, coseKey: authenticator.coseES256PublicKey(xOverride: x, yOverride: negY))
        _ = try await BoundedPasskeyVerifier().register(challenge: chB, json: jsonB)
    }

    func testRegistrationRejectsShortYCoordinate() async {
        // Deterministic key-shape rejection that does not depend on the crypto backend's point
        // validation: a y coordinate shorter than the 32-byte field length is rejected, and the
        // error names the y coordinate specifically (split length guards).
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let badKey = authenticator.coseES256PublicKey(yOverride: [UInt8](repeating: 0x01, count: 31))
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.invalidYCoordinate) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsCurveAlgorithmInconsistency() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // ES256 alg but crv=2 (P-384): our eager check requires algES384 for p384 => reject.
        let badKey = authenticator.coseES256PublicKey(overrideCurve: 2)
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.unsupportedCOSEAlgorithmForEC2PublicKey) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Key-type / algorithm profile gate (reject before non-EC2 constructor dispatch)

    func testRegistrationRejectsRSAKeyTypeWithES256Algorithm() async {
        // An RSA COSE key (kty=3) that carries the EC algorithm id ES256 (-7) must be rejected for
        // the narrow EC2/ES256 profile BEFORE it can construct an RSAPublicKeyData and slip past the
        // registration ES256 allowlist on the strength of a later signature failure.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let rsaKey = authenticator.coseRSAPublicKey(algES256: true)
        let json = authenticator.registrationJSON(challenge: ch, coseKey: rsaKey)
        await assertThrowsWebAuthn(.unsupported) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsOutOfProfileValidAlgorithm() async {
        // An EC2 key carrying a recognized-but-out-of-profile algorithm (ES384 = -35) is rejected
        // by the profile gate before EC2 construction.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let badKey = authenticator.coseES256PublicKey(overrideAlg: -35) // ES384
        let json = authenticator.registrationJSON(challenge: ch, coseKey: badKey)
        await assertThrowsWebAuthn(.unsupportedCOSEAlgorithm) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Deterministic attestation-object truncation table (no fuzzing)

    func testRegistrationTruncatedAttestationObjectRejectedNotTrapped() async {
        // Take one valid attestation object and truncate it at a fixed table of prefix lengths.
        // Every truncation must produce an ORDINARY thrown error (never a trap / SIGTRAP).
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let authData = authenticator.registrationAuthData(
            flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.be | SoftwareAuthenticator.at
        )
        let full = authenticator.attestationObject(authData: authData)
        let lengths = [0, 1, 2, 3, 5, 8, 13, 21, full.count / 2, full.count - 1]
        for len in lengths where len >= 0 && len < full.count {
            let json = authenticator.registrationJSON(challenge: ch, attestationObjectOverride: Array(full.prefix(len)))
            await assertThrows {
                try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
            }
        }
    }

    // MARK: Attestation format

    func testRegistrationRejectsNonNoneAttestationFormat() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, attestationFmt: "packed", attestationStatement: .map([.utf8String("alg"): .negativeInt(6)]))
        await assertThrowsWebAuthn(.attestationVerificationNotSupported) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testRegistrationRejectsNoneWithNonEmptyStatement() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, attestationStatement: .map([.utf8String("x"): .unsignedInt(1)]))
        await assertThrowsWebAuthn(.attestationStatementMustBeEmpty) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }
}
