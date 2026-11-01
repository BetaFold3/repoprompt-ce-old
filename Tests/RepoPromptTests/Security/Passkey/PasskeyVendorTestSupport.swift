// Bounded passkey verifier experiment — test-local support.
//
// Drives the vendored WebAuthn library (Vendor/SwiftWebAuthn) through its PUBLIC ceremony API
// (WebAuthnManager.finishRegistration / finishAuthentication), building wire payloads exactly as
// a browser would and decoding them with the library's own Codable wire types. No production
// code is involved; this file and its tests are linked only into the root test target.
//
// `BoundedPasskeyVerifier` is the test-local adapter expressing the spec's narrow profile:
// required user verification on both ceremonies, ES256-only, `none` attestation, and
// counter-as-metadata. It never catches a verification error and turns it into success. It binds
// the asserted credential identity (expected stored credential ID, optional user handle) at the
// wire level without parsing COSE, and caps raw input size before decoding.

import Crypto
import Foundation
import SwiftCBOR
@testable import WebAuthn
import XCTest

// MARK: - Bounded adapter (test-local)

/// Errors raised by the test-local adapter itself (relying-party responsibilities), distinct from
/// the library's `WebAuthnError`. The adapter never turns a verification failure into success.
enum BoundedPasskeyAdapterError: Error, Equatable {
    /// Raw wire input exceeded the adapter's byte cap and was rejected before any decoding.
    case oversizedWireInput
    /// The asserted credential's `rawId` did not match the expected stored credential ID.
    case credentialIDMismatch
    /// The asserted response `userHandle` did not match the expected stored user handle.
    case userHandleMismatch
}

/// How the adapter treats the authenticator sign counter. The narrow profile targets synced
/// (multi-device) credentials, whose counter is unreliable, so the default is metadata-only:
/// the counter is recorded but never causes a rejection. `strict` opts into the upstream clone
/// heuristic and is used only to prove that heuristic is reachable and its error is not swallowed.
enum CounterPolicy: Equatable {
    /// Counter is metadata only — never a rejection signal (synced-credential policy).
    case metadataOnly
    /// Exercise the upstream replay/clone heuristic against an explicit stored sign count.
    case strict(storedSignCount: UInt32)
}

struct BoundedPasskeyVerifier {
    let manager: WebAuthnManager

    /// Maximum accepted raw wire payload (bytes) for either ceremony. A real passkey
    /// registration/assertion response is well under this; oversized input is rejected before
    /// decoding so a hostile blob cannot drive the decoder.
    static let maxWireBytes = 64 * 1024

    init(
        relyingPartyID: String = "example.com",
        relyingPartyName: String = "RPCE Test",
        relyingPartyOrigin: String = "https://example.com"
    ) {
        manager = WebAuthnManager(configuration: .init(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        ))
    }

    /// Registration at the public boundary. Required UV, ES256-only, `none` attestation.
    /// Oversized raw input is rejected before decoding.
    func register(challenge: [UInt8], json: Data) async throws -> Credential {
        guard json.count <= Self.maxWireBytes else { throw BoundedPasskeyAdapterError.oversizedWireInput }
        let credential = try JSONDecoder().decode(RegistrationCredential.self, from: json)
        return try await manager.finishRegistration(
            challenge: challenge,
            credentialCreationData: credential,
            requireUserVerification: true,
            supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters(alg: .algES256)],
            confirmCredentialIDNotRegisteredYet: { _ in true }
        )
    }

    /// Assertion at the public boundary. Required UV. The relying party looks a credential up by
    /// ID, so the adapter binds the expected stored credential ID (and, when known, the user
    /// handle) against the asserted wire fields BEFORE verifying — without parsing COSE. The
    /// counter is metadata-only by default (synced credentials); the signature is always verified
    /// regardless of the counter.
    func assert(
        challenge: [UInt8],
        storedPublicKey: [UInt8],
        expectedCredentialID: [UInt8],
        expectedUserHandle: [UInt8]? = nil,
        counterPolicy: CounterPolicy = .metadataOnly,
        storedBackupEligible: Bool? = nil,
        json: Data
    ) throws -> VerifiedAuthentication {
        guard json.count <= Self.maxWireBytes else { throw BoundedPasskeyAdapterError.oversizedWireInput }
        let credential = try JSONDecoder().decode(AuthenticationCredential.self, from: json)

        // Identity binding (relying-party responsibility), wire-level only — no COSE parsing.
        // First require the asserted response to be internally consistent: the outer base64url `id`
        // must decode to the same bytes as `rawId`. The library's AuthenticationCredential decoder
        // does not enforce this and `finishAuthentication` returns the caller-supplied id, so a
        // response could otherwise carry an `id` that contradicts its `rawId`.
        guard let decodedID = credential.id.decodedBytes, decodedID == credential.rawID else {
            throw BoundedPasskeyAdapterError.credentialIDMismatch
        }
        guard credential.rawID == expectedCredentialID else {
            throw BoundedPasskeyAdapterError.credentialIDMismatch
        }
        if let expectedUserHandle {
            guard credential.response.userHandle == expectedUserHandle else {
                throw BoundedPasskeyAdapterError.userHandleMismatch
            }
        }

        let storedSignCount: UInt32 = switch counterPolicy {
        case .metadataOnly:
            0 // baseline 0 => upstream clone heuristic never fires for synced credentials
        case let .strict(count):
            count
        }

        return try manager.finishAuthentication(
            credential: credential,
            expectedChallenge: challenge,
            credentialPublicKey: storedPublicKey,
            credentialCurrentSignCount: storedSignCount,
            requireUserVerification: true,
            credentialBackupEligible: storedBackupEligible
        )
    }
}

// MARK: - Software authenticator fixture builder

/// Builds registration and assertion wire payloads with a software P-256 key, so tests exercise
/// the real verification/signature path. Deliberately malformed variants are produced by tweaking
/// the inputs below; raw-byte CBOR edge cases live in the malformed-CBOR test file.
struct SoftwareAuthenticator {
    var relyingPartyID = "example.com"
    var origin = "https://example.com"
    var aaguid = [UInt8](repeating: 0, count: 16)
    var credentialID: [UInt8] = Array("rpce-test-credential".utf8)
    let privateKey = P256.Signing.PrivateKey()

    // Flag bits (WebAuthn authenticator data).
    static let up: UInt8 = 0x01
    static let uv: UInt8 = 0x04
    static let be: UInt8 = 0x08 // backup eligible
    static let bs: UInt8 = 0x10 // backup state (currently backed up)
    static let at: UInt8 = 0x40 // attested credential data included
    static let ed: UInt8 = 0x80 // extension data included

    var publicKeyXY: (x: [UInt8], y: [UInt8]) {
        let raw = [UInt8](privateKey.publicKey.rawRepresentation) // 64 bytes: x(32) || y(32)
        return (Array(raw[0 ..< 32]), Array(raw[32 ..< 64]))
    }

    // MARK: COSE / CBOR encoders (using the retained SwiftCBOR encoder)

    /// COSE_Key for ES256 / EC2 / P-256. Optionally override fields to craft invalid keys.
    func coseES256PublicKey(
        overrideAlg: Int64? = nil,
        overrideCurve: UInt64? = nil,
        xOverride: [UInt8]? = nil,
        yOverride: [UInt8]? = nil
    ) -> [UInt8] {
        let (x, y) = publicKeyXY
        // alg ES256 = -7; SwiftCBOR negativeInt payload is (-1 - value) => 6.
        let algValue: CBOR = if let overrideAlg {
            overrideAlg < 0 ? .negativeInt(UInt64(-1 - overrideAlg)) : .unsignedInt(UInt64(overrideAlg))
        } else {
            .negativeInt(6)
        }
        let map: [CBOR: CBOR] = [
            .unsignedInt(1): .unsignedInt(2), // kty: EC2
            .unsignedInt(3): algValue, // alg
            .negativeInt(0): .unsignedInt(overrideCurve ?? 1), // crv: P-256 (key -1)
            .negativeInt(1): .byteString(xOverride ?? x), // x (key -2)
            .negativeInt(2): .byteString(yOverride ?? y) // y (key -3)
        ]
        return CBOR.map(map).encode()
    }

    /// COSE_Key for an RSA key (kty=3) carrying an arbitrary `alg`. Used to prove the narrow
    /// profile rejects a non-EC2 key type even when it carries a recognized EC algorithm id such
    /// as ES256 (-7): COSE labels are kty=1, alg=3, n=-1 (negativeInt 0), e=-2 (negativeInt 1).
    func coseRSAPublicKey(algES256: Bool = true) -> [UInt8] {
        let algValue: CBOR = algES256 ? .negativeInt(6) /* -7 */ : .negativeInt(256) /* -257 RS256 */
        let modulus = [UInt8](repeating: 0xAB, count: 32) // placeholder n; never reached in profile
        let exponent: [UInt8] = [0x01, 0x00, 0x01] // e = 65537
        let map: [CBOR: CBOR] = [
            .unsignedInt(1): .unsignedInt(3), // kty: RSA
            .unsignedInt(3): algValue, // alg
            .negativeInt(0): .byteString(modulus), // n (key -1)
            .negativeInt(1): .byteString(exponent) // e (key -2)
        ]
        return CBOR.map(map).encode()
    }

    func rpIDHash() -> [UInt8] {
        Array(SHA256.hash(data: Data(relyingPartyID.utf8)))
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func bigEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// Registration authenticator data (attested credential data present).
    func registrationAuthData(
        flags: UInt8,
        signCount: UInt32 = 0,
        coseKey: [UInt8]? = nil,
        credentialIDOverride: [UInt8]? = nil,
        extensionBytes: [UInt8]? = nil
    ) -> [UInt8] {
        let credID = credentialIDOverride ?? credentialID
        var data = rpIDHash()
        data.append(flags)
        data.append(contentsOf: Self.bigEndian(signCount))
        data.append(contentsOf: aaguid)
        data.append(contentsOf: Self.bigEndian16(UInt16(credID.count)))
        data.append(contentsOf: credID)
        data.append(contentsOf: coseKey ?? coseES256PublicKey())
        if let extensionBytes { data.append(contentsOf: extensionBytes) }
        return data
    }

    /// Assertion authenticator data (no attested credential data unless `flags` sets AT).
    func assertionAuthData(
        flags: UInt8,
        signCount: UInt32 = 0,
        extensionBytes: [UInt8]? = nil,
        attestedTail: [UInt8]? = nil
    ) -> [UInt8] {
        var data = rpIDHash()
        data.append(flags)
        data.append(contentsOf: Self.bigEndian(signCount))
        if let attestedTail { data.append(contentsOf: attestedTail) }
        if let extensionBytes { data.append(contentsOf: extensionBytes) }
        return data
    }

    func attestationObject(authData: [UInt8], fmt: String = "none", statement: CBOR = .map([:]), trailing: [UInt8] = []) -> [UInt8] {
        let map: [CBOR: CBOR] = [
            .utf8String("fmt"): .utf8String(fmt),
            .utf8String("attStmt"): statement,
            .utf8String("authData"): .byteString(authData)
        ]
        return CBOR.map(map).encode() + trailing
    }

    func clientDataJSON(type: String, challenge: [UInt8], origin: String? = nil) -> [UInt8] {
        // Field order is fixed so the bytes are stable; the verifier only parses it as JSON.
        let json = "{\"type\":\"\(type)\",\"challenge\":\"\(Base64URL.encode(challenge))\",\"origin\":\"\(origin ?? self.origin)\"}"
        return Array(json.utf8)
    }

    // MARK: Full wire payloads

    func registrationJSON(
        challenge: [UInt8],
        flags: UInt8 = up | uv | be,
        signCount: UInt32 = 0,
        coseKey: [UInt8]? = nil,
        credentialIDOverride: [UInt8]? = nil,
        rawIDOverride: [UInt8]? = nil,
        idOverride: [UInt8]? = nil,
        clientType: String = "webauthn.create",
        clientOrigin: String? = nil,
        attestationFmt: String = "none",
        attestationStatement: CBOR = .map([:]),
        attestationTrailing: [UInt8] = [],
        attestationObjectOverride: [UInt8]? = nil,
        extensionBytes: [UInt8]? = nil
    ) -> Data {
        // Attested credential data is always written for registration, so the AT flag is always
        // set here; callers only control UP/UV/BE/BS (and ED is added when extensions are present).
        let effectiveFlags = (flags | Self.at) | (extensionBytes == nil ? 0 : Self.ed)
        let authData = registrationAuthData(
            flags: effectiveFlags,
            signCount: signCount,
            coseKey: coseKey,
            credentialIDOverride: credentialIDOverride,
            extensionBytes: extensionBytes
        )
        // `attestationObjectOverride` injects raw bytes verbatim (e.g. a truncated attestation
        // object) so truncation/edge-case tests can drive the exact wire the decoder sees.
        let attObj = attestationObjectOverride
            ?? attestationObject(authData: authData, fmt: attestationFmt, statement: attestationStatement, trailing: attestationTrailing)
        let clientData = clientDataJSON(type: clientType, challenge: challenge, origin: clientOrigin)
        let rawID = rawIDOverride ?? credentialID
        return wireJSON([
            "id": Base64URL.encode(idOverride ?? rawID),
            "type": "public-key",
            "rawId": Base64URL.encode(rawID),
            "response": [
                "clientDataJSON": Base64URL.encode(clientData),
                "attestationObject": Base64URL.encode(attObj)
            ]
        ])
    }

    func assertionJSON(
        challenge: [UInt8],
        flags: UInt8 = up | uv | be,
        signCount: UInt32 = 0,
        clientType: String = "webauthn.get",
        clientOrigin: String? = nil,
        extensionBytes: [UInt8]? = nil,
        attestedTail: [UInt8]? = nil,
        tamperSignature: Bool = false,
        rawIDOverride: [UInt8]? = nil,
        idOverride: [UInt8]? = nil,
        userHandle: [UInt8]? = nil
    ) -> Data {
        let effectiveFlags = extensionBytes == nil ? flags : (flags | Self.ed)
        let authData = assertionAuthData(flags: effectiveFlags, signCount: signCount, extensionBytes: extensionBytes, attestedTail: attestedTail)
        let clientData = clientDataJSON(type: clientType, challenge: challenge, origin: clientOrigin)
        let clientHash = Array(SHA256.hash(data: Data(clientData)))
        var signature = (try? privateKey.signature(for: Data(authData + clientHash)).derRepresentation).map { Array($0) } ?? []
        if tamperSignature, !signature.isEmpty { signature[signature.count - 1] ^= 0xFF }
        let rawID = rawIDOverride ?? credentialID
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientData),
            "authenticatorData": Base64URL.encode(authData),
            "signature": Base64URL.encode(signature)
        ]
        if let userHandle { response["userHandle"] = Base64URL.encode(userHandle) }
        // `idOverride` sets the outer base64url `id` independently of `rawId` so a VALID-signed
        // response can carry an id that contradicts its rawId (signature covers authData only).
        return wireJSON([
            "id": Base64URL.encode(idOverride ?? rawID),
            "type": "public-key",
            "rawId": Base64URL.encode(rawID),
            "response": response
        ])
    }

    private func wireJSON(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [])
    }
}

// MARK: - base64url

enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Assertion helpers

extension XCTestCase {
    /// Asserts the body throws any error.
    func assertThrows(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected an error to be thrown", file: file, line: line)
        } catch {
            // expected
        }
    }

    /// Asserts the body throws a specific adapter error (relying-party responsibility).
    func assertThrowsAdapter(
        _ expected: BoundedPasskeyAdapterError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected BoundedPasskeyAdapterError \(expected)", file: file, line: line)
        } catch let error as BoundedPasskeyAdapterError {
            XCTAssertEqual(error, expected, "unexpected adapter error", file: file, line: line)
        } catch {
            XCTFail("Expected BoundedPasskeyAdapterError \(expected), got \(error)", file: file, line: line)
        }
    }

    /// Asserts the body throws a specific WebAuthnError (ordinary error, not a trap).
    func assertThrowsWebAuthn(
        _ expected: WebAuthnError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected WebAuthnError \(expected)", file: file, line: line)
        } catch let error as WebAuthnError {
            XCTAssertEqual(error, expected, "unexpected WebAuthnError", file: file, line: line)
        } catch {
            XCTFail("Expected WebAuthnError \(expected), got \(error)", file: file, line: line)
        }
    }
}
