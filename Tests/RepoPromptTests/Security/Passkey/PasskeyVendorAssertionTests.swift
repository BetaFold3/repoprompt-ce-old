// Bounded passkey verifier experiment — assertion ceremony tests (public boundary).

import Crypto
import Foundation
import SwiftCBOR
@testable import WebAuthn
import XCTest

final class PasskeyVendorAssertionTests: XCTestCase {
    private func challenge() -> [UInt8] {
        SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    }

    private func storedKey(_ authenticator: SoftwareAuthenticator) -> [UInt8] {
        authenticator.coseES256PublicKey()
    }

    // MARK: Positive

    func testValidSignedAssertionSucceeds() throws {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch)
        let verified = try BoundedPasskeyVerifier().assert(
            challenge: ch,
            storedPublicKey: storedKey(authenticator),
            expectedCredentialID: authenticator.credentialID,
            json: json
        )
        XCTAssertEqual(verified.credentialID, URLEncodedBase64(Base64URL.encode(authenticator.credentialID)))
        XCTAssertFalse(verified.credentialBackedUp, "BS flag not set in default assertion")
        XCTAssertEqual(verified.credentialDeviceType, .multiDevice, "BE flag set => multi-device (synced)")
    }

    func testValidSignedAssertionWithMatchingUserHandleSucceeds() throws {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let handle = Array("user-handle-1234".utf8)
        let json = authenticator.assertionJSON(challenge: ch, userHandle: handle)
        let verified = try BoundedPasskeyVerifier().assert(
            challenge: ch,
            storedPublicKey: storedKey(authenticator),
            expectedCredentialID: authenticator.credentialID,
            expectedUserHandle: handle,
            json: json
        )
        XCTAssertEqual(verified.credentialID, URLEncodedBase64(Base64URL.encode(authenticator.credentialID)))
    }

    // MARK: Identity binding (relying-party responsibility, wire-level)

    func testAssertionRejectsUnexpectedCredentialID() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch)
        await assertThrowsAdapter(.credentialIDMismatch) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: Array("some-other-credential".utf8),
                json: json
            )
        }
    }

    func testAssertionRejectsInconsistentOuterID() async {
        // A VALID-signed assertion whose `rawId` matches the expected stored credential ID, but
        // whose outer base64url `id` decodes to different bytes. The signature covers authData only,
        // so it still verifies; the adapter must reject the internally inconsistent id (id != rawId)
        // before verifying, even though rawId == expected.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, idOverride: Array("contradictory-id".utf8))
        await assertThrowsAdapter(.credentialIDMismatch) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                json: json
            )
        }
    }

    func testAssertionRejectsUserHandleMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, userHandle: Array("handle-A".utf8))
        await assertThrowsAdapter(.userHandleMismatch) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                expectedUserHandle: Array("handle-B".utf8),
                json: json
            )
        }
    }

    func testAssertionRejectsOversizedInput() async {
        let ch = challenge()
        let oversized = Data(repeating: 0x20, count: BoundedPasskeyVerifier.maxWireBytes + 1)
        await assertThrowsAdapter(.oversizedWireInput) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: [],
                expectedCredentialID: Array("rpce-test-credential".utf8),
                json: oversized
            )
        }
    }

    // MARK: UP / UV

    func testAssertionRejectsMissingUserVerification() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.be)
        await assertThrowsWebAuthn(.userVerifiedFlagNotSet) {
            _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json)
        }
    }

    func testAssertionRejectsMissingUserPresence() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, flags: SoftwareAuthenticator.uv | SoftwareAuthenticator.be)
        await assertThrowsWebAuthn(.userPresentFlagNotSet) {
            _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json)
        }
    }

    // MARK: Origin / type / challenge / signature

    func testAssertionRejectsOriginMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, clientOrigin: "https://evil.example")
        await assertThrows { _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json) }
    }

    func testAssertionRejectsWrongCeremonyType() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, clientType: "webauthn.create")
        await assertThrows { _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json) }
    }

    func testAssertionRejectsChallengeMismatch() async {
        let authenticator = SoftwareAuthenticator()
        let json = authenticator.assertionJSON(challenge: challenge())
        await assertThrows { _ = try BoundedPasskeyVerifier().assert(challenge: self.challenge(), storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json) }
    }

    func testAssertionRejectsTamperedSignature() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, tamperSignature: true)
        await assertThrows { _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json) }
    }

    func testAssertionRejectsWrongStoredKey() async {
        let authenticator = SoftwareAuthenticator()
        let other = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch)
        await assertThrowsWebAuthn(.invalidSignature) {
            _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(other), expectedCredentialID: authenticator.credentialID, json: json)
        }
    }

    // MARK: Assertion flag structure

    func testAssertionRejectsAttestedCredentialDataFlag() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // Set AT and append a plausible attested-data tail so parsing reaches the AT rejection.
        let tail = authenticator.aaguid
            + SoftwareAuthenticator.bigEndian16(UInt16(authenticator.credentialID.count))
            + authenticator.credentialID
            + authenticator.coseES256PublicKey()
        let json = authenticator.assertionJSON(
            challenge: ch,
            flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.at,
            attestedTail: tail
        )
        await assertThrowsWebAuthn(.attestedCredentialDataFlagSetInAssertion) {
            _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json)
        }
    }

    func testAssertionRejectsBackupStateWithoutEligible() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // BS set, BE clear => invalid.
        let json = authenticator.assertionJSON(challenge: ch, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.bs)
        await assertThrowsWebAuthn(.invalidBackupFlags) {
            _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json)
        }
    }

    func testAssertionRejectsBackupEligibleMismatchWithStored() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // Assertion reports BE set, but stored credential was single-device (BE false).
        let json = authenticator.assertionJSON(challenge: ch, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.be)
        await assertThrowsWebAuthn(.backupEligibilityMismatch) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                storedBackupEligible: false,
                json: json
            )
        }
    }

    // MARK: Valid unknown extensions

    func testAssertionAcceptsValidUnknownExtensions() throws {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext = CBOR.map([.utf8String("unknownExt"): .unsignedInt(1)]).encode()
        let json = authenticator.assertionJSON(challenge: ch, extensionBytes: ext)
        let verified = try BoundedPasskeyVerifier().assert(
            challenge: ch,
            storedPublicKey: storedKey(authenticator),
            expectedCredentialID: authenticator.credentialID,
            json: json
        )
        XCTAssertEqual(verified.credentialID, URLEncodedBase64(Base64URL.encode(authenticator.credentialID)))
    }

    func testAssertionRejectsExtensionTrailingBytes() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext = CBOR.map([.utf8String("unknownExt"): .unsignedInt(1)]).encode() + [0x00]
        let json = authenticator.assertionJSON(challenge: ch, extensionBytes: ext)
        await assertThrows { _ = try BoundedPasskeyVerifier().assert(challenge: ch, storedPublicKey: self.storedKey(authenticator), expectedCredentialID: authenticator.credentialID, json: json) }
    }

    // MARK: Synced-credential counters (metadata-only policy)

    func testMetadataOnlyAcceptsAnyReportedCounterPerIndependentAssertion() throws {
        let authenticator = SoftwareAuthenticator()
        let verifier = BoundedPasskeyVerifier()
        // These are STATELESS, independent verifications — not a persisted counter transition. The
        // metadata-only adapter supplies stored sign count 0 on every call, so each asserted counter
        // value is accepted on its own; this does NOT exercise a stored-5-then-3 regression (the
        // adapter is stateless by design). The actual regression path is proven separately by
        // testCounterRegressionStillThrowsWhenNotMetadataOnly.
        for count in [UInt32(0), UInt32(5), UInt32(3), UInt32(0)] {
            let ch = challenge()
            let json = authenticator.assertionJSON(challenge: ch, signCount: count)
            // Default metadata-only policy: each independent assertion is accepted regardless of the
            // reported counter so long as the signature is valid (stored count is always 0).
            let verified = try verifier.assert(
                challenge: ch,
                storedPublicKey: storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                json: json
            )
            XCTAssertEqual(verified.newSignCount, count)
        }
    }

    func testCounterRegressionStillThrowsWhenNotMetadataOnly() async {
        // Proves the upstream clone heuristic is reachable and its error is NOT swallowed when the
        // strict counter policy supplies a non-zero stored count. The adapter's metadata-only
        // policy is what enables synced credentials; this is the behavior it deliberately avoids.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.assertionJSON(challenge: ch, signCount: 3)
        await assertThrowsWebAuthn(.potentialReplayAttack) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                counterPolicy: .strict(storedSignCount: 10),
                json: json
            )
        }
    }

    func testTamperedSignatureRejectedEvenWithValidCounter() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // Valid (increasing) counter under the strict policy, but a tampered signature must still
        // be rejected — the counter is never a substitute for signature verification.
        let json = authenticator.assertionJSON(challenge: ch, signCount: 5, tamperSignature: true)
        await assertThrowsWebAuthn(.invalidSignature) {
            _ = try BoundedPasskeyVerifier().assert(
                challenge: ch,
                storedPublicKey: self.storedKey(authenticator),
                expectedCredentialID: authenticator.credentialID,
                counterPolicy: .strict(storedSignCount: 1),
                json: json
            )
        }
    }
}
