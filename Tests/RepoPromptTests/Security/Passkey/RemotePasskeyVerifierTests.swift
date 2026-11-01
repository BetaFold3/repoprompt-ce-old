import Crypto
import Foundation
@testable import RepoPromptApp
@testable import WebAuthn
import XCTest

/// Production-adapter coverage for the promoted `WebAuthnRemotePasskeyVerifier` (remote passkey
/// unlock, Step 2). The three `PasskeyVendor*Tests` suites continue to exercise the test-local
/// `BoundedPasskeyVerifier`; this suite proves the app-owned production verifier enforces the same
/// narrow profile through the library's public API (no `@testable` in production) and that the
/// app-owned value types bind identity and bound input as specified. Fixtures reuse the test-local
/// `SoftwareAuthenticator`, which signs with a real P-256 key.
final class RemotePasskeyVerifierTests: XCTestCase {
    private let verifier = WebAuthnRemotePasskeyVerifier()
    private let origin = RemotePasskeyOrigin(httpsURLString: "https://example.com")!

    private func registrationInput(
        challenge: [UInt8],
        json: Data,
        isUnused: @escaping @Sendable ([UInt8]) -> Bool = { _ in true }
    ) -> RemotePasskeyRegistrationInput {
        RemotePasskeyRegistrationInput(
            challenge: challenge,
            origin: origin,
            relyingPartyName: "RepoPrompt Test",
            credentialJSON: json,
            isCredentialIDUnused: isUnused
        )
    }

    private func assertionInput(
        challenge: [UInt8],
        registration: RemotePasskeyVerifiedRegistration,
        json: Data,
        credentialIDOverride: [UInt8]? = nil,
        userHandle: Data? = nil
    ) -> RemotePasskeyAssertionInput {
        RemotePasskeyAssertionInput(
            challenge: challenge,
            origin: origin,
            credentialID: credentialIDOverride ?? registration.credentialID,
            publicKeyCOSE: registration.publicKeyCOSE,
            userHandle: userHandle,
            backupEligible: registration.backupEligible,
            credentialJSON: json
        )
    }

    private func expectRegistration(
        _ expected: RemotePasskeyVerificationError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected RemotePasskeyVerificationError \(expected)", file: file, line: line)
        } catch let error as RemotePasskeyVerificationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: Happy path

    func testRegistersThenAssertsWithStoredKey() async throws {
        let auth = SoftwareAuthenticator()
        let regChallenge = Array("registration-challenge".utf8)
        let verified = try await verifier.verifyRegistration(
            registrationInput(challenge: regChallenge, json: auth.registrationJSON(challenge: regChallenge))
        )
        XCTAssertEqual(verified.credentialID, auth.credentialID)
        XCTAssertFalse(verified.publicKeyCOSE.isEmpty)
        XCTAssertTrue(verified.backupEligible) // default flags set BE

        let assertChallenge = Array("assertion-challenge".utf8)
        try await verifier.verifyAssertion(
            assertionInput(
                challenge: assertChallenge,
                registration: verified,
                json: auth.assertionJSON(challenge: assertChallenge)
            )
        )
    }

    // MARK: Registration rejections

    func testRegistrationRejectsMissingUserVerification() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        // UP + BE but no UV.
        let json = auth.registrationJSON(challenge: challenge, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.be)
        await expectRegistration(.verificationFailed) {
            _ = try await self.verifier.verifyRegistration(self.registrationInput(challenge: challenge, json: json))
        }
    }

    func testRegistrationRejectsNonES256Key() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        let json = auth.registrationJSON(challenge: challenge, coseKey: auth.coseRSAPublicKey())
        await expectRegistration(.verificationFailed) {
            _ = try await self.verifier.verifyRegistration(self.registrationInput(challenge: challenge, json: json))
        }
    }

    func testRegistrationRejectsDuplicateCredentialID() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        let json = auth.registrationJSON(challenge: challenge)
        await expectRegistration(.duplicateCredentialID) {
            _ = try await self.verifier.verifyRegistration(
                self.registrationInput(challenge: challenge, json: json, isUnused: { _ in false })
            )
        }
    }

    func testRegistrationRejectsOversizedInput() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        var json = auth.registrationJSON(challenge: challenge)
        json.append(Data(repeating: 0x20, count: WebAuthnRemotePasskeyVerifier.maxWireBytes))
        await expectRegistration(.oversizedInput) {
            _ = try await self.verifier.verifyRegistration(self.registrationInput(challenge: challenge, json: json))
        }
    }

    func testRegistrationRejectsNonTextTopLevelExtensionKey() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        // Extensions block: a one-entry map whose single key is an unsigned int (0x01), not text.
        // {1: 1} => A1 01 01. The ED flag is set automatically when extensionBytes is non-nil.
        let json = auth.registrationJSON(challenge: challenge, extensionBytes: [0xA1, 0x01, 0x01])
        await expectRegistration(.verificationFailed) {
            _ = try await self.verifier.verifyRegistration(self.registrationInput(challenge: challenge, json: json))
        }
    }

    func testRegistrationDepthBombRejectedWithoutCrash() async {
        let auth = SoftwareAuthenticator()
        let challenge = Array("c".utf8)
        // A one-key map whose value is 40 nested single-element arrays exceeds maximumDepth:16.
        // {"x": [[[…]]]} => A1 61 78 (81 × 40) 01. The bounded decoder must throw, not crash.
        let depthBomb: [UInt8] = [0xA1, 0x61, 0x78] + Array(repeating: 0x81, count: 40) + [0x01]
        let json = auth.registrationJSON(challenge: challenge, extensionBytes: depthBomb)
        await expectRegistration(.verificationFailed) {
            _ = try await self.verifier.verifyRegistration(self.registrationInput(challenge: challenge, json: json))
        }
    }

    // MARK: Assertion rejections

    private func registerDefault(_ auth: SoftwareAuthenticator) async throws -> RemotePasskeyVerifiedRegistration {
        let regChallenge = Array("reg".utf8)
        return try await verifier.verifyRegistration(
            registrationInput(challenge: regChallenge, json: auth.registrationJSON(challenge: regChallenge))
        )
    }

    func testAssertionRejectsWrongChallenge() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        // Signed for a different challenge than the one the verifier expects.
        let json = auth.assertionJSON(challenge: Array("signed".utf8))
        await expectRegistration(.verificationFailed) {
            try await self.verifier.verifyAssertion(
                self.assertionInput(challenge: Array("expected".utf8), registration: verified, json: json)
            )
        }
    }

    func testAssertionRejectsWrongOrigin() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let json = auth.assertionJSON(challenge: challenge, clientOrigin: "https://evil.example")
        await expectRegistration(.verificationFailed) {
            try await self.verifier.verifyAssertion(self.assertionInput(challenge: challenge, registration: verified, json: json))
        }
    }

    func testAssertionRejectsTamperedSignature() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let json = auth.assertionJSON(challenge: challenge, tamperSignature: true)
        await expectRegistration(.verificationFailed) {
            try await self.verifier.verifyAssertion(self.assertionInput(challenge: challenge, registration: verified, json: json))
        }
    }

    func testAssertionRejectsCredentialIDMismatch() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let json = auth.assertionJSON(challenge: challenge)
        await expectRegistration(.credentialIdentityMismatch) {
            try await self.verifier.verifyAssertion(
                self.assertionInput(
                    challenge: challenge,
                    registration: verified,
                    json: json,
                    credentialIDOverride: Array("a-different-credential".utf8)
                )
            )
        }
    }

    func testAssertionRejectsIdRawIdContradiction() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        // Valid signature over rawId, but the outer base64url `id` is different bytes.
        let json = auth.assertionJSON(challenge: challenge, idOverride: Array("contradicting-id".utf8))
        await expectRegistration(.credentialIdentityMismatch) {
            try await self.verifier.verifyAssertion(self.assertionInput(challenge: challenge, registration: verified, json: json))
        }
    }

    func testAssertionAcceptsAbsentUserHandleWhenStoredPresent() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let json = auth.assertionJSON(challenge: challenge) // no userHandle in response
        try await verifier.verifyAssertion(
            assertionInput(challenge: challenge, registration: verified, json: json, userHandle: Data([0x01, 0x02]))
        )
    }

    func testAssertionAcceptsMatchingUserHandle() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let handle: [UInt8] = [0x01, 0x02, 0x03]
        let json = auth.assertionJSON(challenge: challenge, userHandle: handle)
        try await verifier.verifyAssertion(
            assertionInput(challenge: challenge, registration: verified, json: json, userHandle: Data(handle))
        )
    }

    func testAssertionRejectsMismatchedUserHandle() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        let json = auth.assertionJSON(challenge: challenge, userHandle: [0x01, 0x02, 0x03])
        await expectRegistration(.userHandleMismatch) {
            try await self.verifier.verifyAssertion(
                self.assertionInput(challenge: challenge, registration: verified, json: json, userHandle: Data([0x09]))
            )
        }
    }

    func testAssertionRejectsOversizedInput() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let challenge = Array("c".utf8)
        var json = auth.assertionJSON(challenge: challenge)
        json.append(Data(repeating: 0x20, count: WebAuthnRemotePasskeyVerifier.maxWireBytes))
        await expectRegistration(.oversizedInput) {
            try await self.verifier.verifyAssertion(self.assertionInput(challenge: challenge, registration: verified, json: json))
        }
    }

    // MARK: Origin

    func testOriginSerializationOmitsDefaultPortAndKeepsNonDefault() {
        XCTAssertEqual(RemotePasskeyOrigin(httpsURLString: "https://example.com")?.serialized, "https://example.com")
        XCTAssertEqual(RemotePasskeyOrigin(httpsURLString: "https://example.com:443")?.serialized, "https://example.com")
        XCTAssertEqual(RemotePasskeyOrigin(httpsURLString: "https://example.com:8443")?.serialized, "https://example.com:8443")
        XCTAssertEqual(RemotePasskeyOrigin(httpsURLString: "https://EXAMPLE.com")?.rpID, "example.com")
    }

    func testOriginRejectsNonHTTPSAndIPLiterals() {
        XCTAssertNil(RemotePasskeyOrigin(httpsURLString: "http://example.com"))
        XCTAssertNil(RemotePasskeyOrigin(httpsURLString: "https://192.168.1.10"))
        XCTAssertNil(RemotePasskeyOrigin(httpsURLString: "https://[::1]"))
        XCTAssertNil(RemotePasskeyOrigin(httpsURLString: "https://user:pass@example.com"))
    }
}
