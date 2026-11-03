import Crypto
import Foundation
@testable import RepoPromptApp
@testable import WebAuthn
import XCTest

/// Thread-safe recorder for the injected passkey diagnostic sink (shared by the passkey suites).
final class RecordingPasskeyDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RemotePasskeyDiagnosticEvent] = []

    var events: [RemotePasskeyDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var diagnostics: RemotePasskeyDiagnostics {
        RemotePasskeyDiagnostics { [self] event in
            lock.lock()
            recorded.append(event)
            lock.unlock()
        }
    }
}

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
        origin overrideOrigin: RemotePasskeyOrigin? = nil,
        isUnused: @escaping @Sendable ([UInt8]) -> Bool = { _ in true }
    ) -> RemotePasskeyRegistrationInput {
        RemotePasskeyRegistrationInput(
            challenge: challenge,
            origin: overrideOrigin ?? origin,
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

    // MARK: Diagnostics (fixed reason codes; rejection unchanged)

    private func registrationDiagnostic(
        challenge: [UInt8] = Array("c".utf8),
        json: Data,
        origin overrideOrigin: RemotePasskeyOrigin? = nil,
        isUnused: @escaping @Sendable ([UInt8]) -> Bool = { _ in true },
        expectedError: RemotePasskeyVerificationError = .verificationFailed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [RemotePasskeyDiagnosticEvent] {
        let recorder = RecordingPasskeyDiagnostics()
        let instrumented = WebAuthnRemotePasskeyVerifier(diagnostics: recorder.diagnostics)
        let input = registrationInput(challenge: challenge, json: json, origin: overrideOrigin, isUnused: isUnused)
        await expectRegistration(expectedError, {
            _ = try await instrumented.verifyRegistration(input)
        }, file: file, line: line)
        return recorder.events
    }

    private func verifierEvent(
        _ reason: RemotePasskeyDiagnosticReason,
        _ ceremony: RemotePasskeyDiagnosticEvent.Ceremony = .registration,
        clientData: RemotePasskeyDiagnosticEvent.ClientDataCheck? = nil
    ) -> RemotePasskeyDiagnosticEvent {
        .init(ceremony: ceremony, stage: .verifier, reason: reason, clientDataCheck: clientData)
    }

    func testRegistrationDiagnosticsReportLibraryReasonsAndStillReject() async {
        let auth = SoftwareAuthenticator()
        let c = Array("c".utf8)
        let noUV = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.be))
        XCTAssertEqual(noUV, [verifierEvent(.userVerificationMissing)])

        let packed = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, attestationFmt: "packed"))
        XCTAssertEqual(packed, [verifierEvent(.attestationFormatUnsupported)])

        let bsWithoutBE = await registrationDiagnostic(
            json: auth.registrationJSON(challenge: c, flags: SoftwareAuthenticator.up | SoftwareAuthenticator.uv | SoftwareAuthenticator.bs)
        )
        XCTAssertEqual(bsWithoutBE, [verifierEvent(.invalidBackupFlags)])

        let rsa = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, coseKey: auth.coseRSAPublicKey()))
        XCTAssertEqual(rsa, [verifierEvent(.unsupportedPublicKeyProfile)])

        let nonTextExtension = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, extensionBytes: [0xA1, 0x01, 0x01]))
        XCTAssertEqual(nonTextExtension, [verifierEvent(.invalidExtensions)])

        let idMismatch = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, idOverride: Array("other-id".utf8)))
        XCTAssertEqual(idMismatch, [verifierEvent(.credentialIDMismatch)])

        let duplicate = await registrationDiagnostic(
            json: auth.registrationJSON(challenge: c), isUnused: { _ in false }, expectedError: .duplicateCredentialID
        )
        XCTAssertEqual(duplicate, [verifierEvent(.duplicateCredentialID)])

        // Same RP origin string on both sides, but the authenticator data's RP ID hash is for
        // example.com while the ceremony's RP ID is other.example.
        var otherRP = SoftwareAuthenticator()
        otherRP.origin = "https://other.example"
        let rpMismatch = await registrationDiagnostic(
            json: otherRP.registrationJSON(challenge: c),
            origin: RemotePasskeyOrigin(httpsURLString: "https://other.example")
        )
        XCTAssertEqual(rpMismatch, [verifierEvent(.rpIDHashMismatch)])
    }

    func testRegistrationDiagnosticsClassifyClientDataWithoutValues() async {
        let auth = SoftwareAuthenticator()
        let c = Array("c".utf8)
        let wrongOrigin = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, clientOrigin: "https://evil.example"))
        XCTAssertEqual(wrongOrigin, [verifierEvent(.libraryUnknown, clientData: .originMismatch)])

        let portMismatch = await registrationDiagnostic(
            json: auth.registrationJSON(challenge: c),
            origin: RemotePasskeyOrigin(httpsURLString: "https://example.com:8443")
        )
        XCTAssertEqual(portMismatch, [verifierEvent(.libraryUnknown, clientData: .originMismatch)])

        let wrongChallenge = await registrationDiagnostic(challenge: Array("expected".utf8), json: auth.registrationJSON(challenge: c))
        XCTAssertEqual(wrongChallenge, [verifierEvent(.libraryUnknown, clientData: .challengeMismatch)])

        let wrongType = await registrationDiagnostic(json: auth.registrationJSON(challenge: c, clientType: "webauthn.get"))
        XCTAssertEqual(wrongType, [verifierEvent(.libraryUnknown, clientData: .typeMismatch)])
    }

    func testRegistrationDiagnosticsSeparateEnvelopeFromLibraryAndStaySilentOnSuccess() async throws {
        let auth = SoftwareAuthenticator()
        let c = Array("c".utf8)
        let envelope = await registrationDiagnostic(json: Data("{}".utf8), expectedError: .malformedResponse)
        XCTAssertEqual(envelope, [.init(ceremony: .registration, stage: .verifier, reason: .malformedEnvelope, decodingFailure: .keyNotFound)])

        var oversized = auth.registrationJSON(challenge: c)
        oversized.append(Data(repeating: 0x20, count: WebAuthnRemotePasskeyVerifier.maxWireBytes))
        let tooBig = await registrationDiagnostic(json: oversized, expectedError: .oversizedInput)
        XCTAssertEqual(tooBig, [verifierEvent(.oversizedInput)])

        let recorder = RecordingPasskeyDiagnostics()
        let instrumented = WebAuthnRemotePasskeyVerifier(diagnostics: recorder.diagnostics)
        _ = try await instrumented.verifyRegistration(registrationInput(challenge: c, json: auth.registrationJSON(challenge: c)))
        XCTAssertEqual(recorder.events, [], "a verified registration records nothing")
    }

    func testAssertionDiagnosticsReportFixedReasons() async throws {
        let auth = SoftwareAuthenticator()
        let verified = try await registerDefault(auth)
        let c = Array("c".utf8)
        let recorder = RecordingPasskeyDiagnostics()
        let instrumented = WebAuthnRemotePasskeyVerifier(diagnostics: recorder.diagnostics)

        await expectRegistration(.verificationFailed) {
            try await instrumented.verifyAssertion(self.assertionInput(challenge: c, registration: verified, json: auth.assertionJSON(challenge: c, tamperSignature: true)))
        }
        await expectRegistration(.verificationFailed) {
            try await instrumented.verifyAssertion(
                self.assertionInput(challenge: c, registration: verified, json: auth.assertionJSON(challenge: c, clientOrigin: "https://evil.example"))
            )
        }
        await expectRegistration(.credentialIdentityMismatch) {
            try await instrumented.verifyAssertion(
                self.assertionInput(challenge: c, registration: verified, json: auth.assertionJSON(challenge: c), credentialIDOverride: Array("x".utf8))
            )
        }
        await expectRegistration(.credentialIdentityMismatch) {
            try await instrumented.verifyAssertion(
                self.assertionInput(challenge: c, registration: verified, json: auth.assertionJSON(challenge: c, idOverride: Array("contradicting-id".utf8)))
            )
        }
        XCTAssertEqual(recorder.events, [
            verifierEvent(.invalidSignature, .assertion),
            verifierEvent(.libraryUnknown, .assertion, clientData: .originMismatch),
            verifierEvent(.credentialIDNotBound, .assertion),
            verifierEvent(.credentialIDWireMismatch, .assertion)
        ])
    }

    /// The classifier's fallbacks: anything that is not a MAPPED public `WebAuthnError` (here an
    /// opaque error) reaches the value-free client-data check; a `DecodingError` carries only its
    /// case token; a mapped constant is unchanged.
    func testLibraryFailureClassificationFallbacks() {
        struct OpaqueLibraryError: Error {}
        let auth = SoftwareAuthenticator()
        let c = Array("c".utf8)
        func classify(_ error: Error, clientOrigin: String? = nil) -> RemotePasskeyDiagnosticEvent {
            WebAuthnRemotePasskeyVerifier.libraryFailureEvent(
                .registration, error,
                clientDataJSON: auth.clientDataJSON(type: "webauthn.create", challenge: c, origin: clientOrigin),
                expectedType: .create, challenge: c, origin: origin
            )
        }
        XCTAssertEqual(classify(OpaqueLibraryError()), verifierEvent(.libraryUnknown, clientData: .consistent))
        XCTAssertEqual(classify(OpaqueLibraryError(), clientOrigin: "https://evil.example"), verifierEvent(.libraryUnknown, clientData: .originMismatch))
        XCTAssertEqual(
            classify(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not logged"))),
            .init(ceremony: .registration, stage: .verifier, reason: .clientDataUndecodable, decodingFailure: .dataCorrupted)
        )
        XCTAssertEqual(classify(WebAuthnError.invalidBackupFlags), verifierEvent(.invalidBackupFlags))
    }

    func testDiagnosticRenderingUsesOnlyFixedTokens() {
        let token = try? NSRegularExpression(pattern: "^[a-z_]+$")
        for reason in RemotePasskeyDiagnosticReason.allCases {
            let range = NSRange(reason.rawValue.startIndex..., in: reason.rawValue)
            XCTAssertNotNil(token?.firstMatch(in: reason.rawValue, range: range), "non-token reason \(reason)")
        }
        let event = RemotePasskeyDiagnosticEvent(
            ceremony: .registration, stage: .postBinding, reason: .challengeExpiredWindowCapped, clientDataCheck: .originMismatch
        )
        XCTAssertEqual(
            event.rendered,
            "passkey_ceremony_rejected ceremony=registration stage=post_binding reason=challenge_expired_window_capped client_data=origin_mismatch"
        )
        XCTAssertEqual(
            RemotePasskeyDiagnosticEvent(ceremony: .assertion, stage: .verifier, reason: .malformedEnvelope, decodingFailure: .typeMismatch).rendered,
            "passkey_ceremony_rejected ceremony=assertion stage=verifier reason=malformed_envelope decoding=type_mismatch"
        )
        XCTAssertEqual(RemotePasskeyDiagnosticEvent.received(.registration).rendered, "passkey_ceremony_received ceremony=registration")
        XCTAssertEqual(
            RemotePasskeyDiagnosticEvent.pruned(.assertion, reason: .challengeExpired).rendered,
            "passkey_challenge_pruned ceremony=assertion stage=pruned reason=challenge_expired"
        )
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
