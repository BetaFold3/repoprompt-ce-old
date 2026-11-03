// Bounded passkey verifier experiment — malformed-input and trap-regression tests.
//
// Every case drives the PUBLIC registration boundary and asserts an ORDINARY thrown error.
// These inputs would fatally trap against the unpatched upstream (0x04 slice, UInt64 alg
// conversion); here they must throw. The deliberate pre-patch crash itself is never executed.

import Crypto
import Foundation
import SwiftCBOR
@testable import WebAuthn
import XCTest

final class PasskeyVendorMalformedCBORTests: XCTestCase {
    private func challenge() -> [UInt8] {
        SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    }

    // MARK: Trap regressions (now ordinary rejects)

    func testRawU2F0x04KeyRejectedNotTrapped() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        // COSE key region is the single CBOR scalar 0x04 (the historic trapping input).
        let json = authenticator.registrationJSON(challenge: ch, coseKey: [0x04])
        await assertThrowsWebAuthn(.rawU2FPublicKeyUnsupported) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testExtremeNegativeAlgorithmRejectedNotTrapped() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let (x, y) = authenticator.publicKeyXY
        // kty EC2, alg = negativeInt(UInt64.max) => Int(exactly:) returns nil => ordinary reject.
        // The COSE map is assembled by hand: SwiftCBOR's *encoder* asserts on negativeInt(UInt64.max),
        // which is a fixture-side trap, not part of the verifier path under test. The decoder (which
        // the verifier uses) reads these raw bytes back as negativeInt(UInt64.max).
        var hugeAlgKey: [UInt8] = [0xA5] // map(5)
        hugeAlgKey += [0x01, 0x02] // 1: 2            (kty = EC2)
        hugeAlgKey += [0x03, 0x3B] + [UInt8](repeating: 0xFF, count: 8) // 3: negativeInt(UInt64.max) (alg)
        hugeAlgKey += [0x20, 0x01] // -1: 1           (crv = P-256)
        hugeAlgKey += [0x21, 0x58, 0x20] + x // -2: byteString(32) x
        hugeAlgKey += [0x22, 0x58, 0x20] + y // -3: byteString(32) y
        let json = authenticator.registrationJSON(challenge: ch, coseKey: hugeAlgKey)
        await assertThrowsWebAuthn(.unsupportedCOSEAlgorithm) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: Duplicate map keys (rejected by the retained SwiftCBOR decoder, surfaced via ED)

    private func expectInvalidExtensions(_ extensionBytes: [UInt8], line: UInt = #line) async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: extensionBytes)
        await assertThrowsWebAuthn(.invalidExtensions, line: line) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testDuplicateKeyDefiniteMapRejected() async {
        // map(2) { 1: 1, 1: 2 }
        await expectInvalidExtensions([0xA2, 0x01, 0x01, 0x01, 0x02])
    }

    func testDuplicateKeyIndefiniteMapRejected() async {
        // indefinite map { 1: 1, 1: 2 } break
        await expectInvalidExtensions([0xBF, 0x01, 0x01, 0x01, 0x02, 0xFF])
    }

    func testDuplicateKeyNestedMapRejected() async {
        // { 1: { 2: 2, 2: 3 } } — duplicate in the inner map
        await expectInvalidExtensions([0xA1, 0x01, 0xA2, 0x02, 0x02, 0x02, 0x03])
    }

    func testDuplicateKeyEqualLabelDifferentEncodingRejected() async {
        // { 1: 1, 1(uint8-encoded): 2 } — 0x18 0x01 also decodes to unsignedInt(1)
        await expectInvalidExtensions([0xA2, 0x01, 0x01, 0x18, 0x01, 0x02])
    }

    // MARK: Extension-data structure

    func testExtensionsNonMapRejected() async {
        // A bare unsigned int (0x01) is not a CBOR map.
        await expectInvalidExtensions([0x01])
    }

    func testExtensionsTrailingBytesRejected() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext = CBOR.map([.utf8String("unknownExt"): .unsignedInt(1)]).encode() + [0x00]
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        await assertThrowsWebAuthn(.leftOverBytesInAuthenticatorData) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testValidUnknownExtensionsAccepted() async throws {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext = CBOR.map([
            .utf8String("unknownExt"): .unsignedInt(1),
            .utf8String("another"): .array([.unsignedInt(1), .unsignedInt(2)])
        ]).encode()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        // `Credential.id` is standard (padded) base64 of the credential ID.
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    // MARK: P0-01 — non-map COSE key must not trap on label subscript

    func testCOSEKeyEmptyArrayRejectedNotTrapped() async {
        // coseKey = [0x80] (empty CBOR array). Subscripting an array positionally with COSE label 1
        // would trap out-of-bounds in the unpatched path; it must now be an ordinary rejection.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, coseKey: [0x80])
        await assertThrowsWebAuthn(.badPublicKeyBytes) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testCOSEKeyShortArrayRejectedNotTrapped() async {
        // coseKey = [0x81, 0x01] = array(1)[1]. COSE label 1 would index element 1 (out of bounds).
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, coseKey: [0x81, 0x01])
        await assertThrowsWebAuthn(.badPublicKeyBytes) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: P0-02 — a tiny array header must not request an enormous allocation

    func testEnormousDeclaredArrayCountRejectedNotTrapped() async {
        // Extension value {"x": array(Int.max)} with no elements. The decoder must build the array
        // incrementally (never reserve from the declared count) and throw when elements run out.
        let ext: [UInt8] = [0xA1, 0x61, 0x78, 0x9B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        await assertThrowsWebAuthn(.invalidExtensions) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    func testTruncatedDeclaredArrayRejected() async {
        // {"x": array(3)} declaring 3 elements but supplying one — must throw, not over-read/trap.
        let ext: [UInt8] = [0xA1, 0x61, 0x78, 0x83, 0x01]
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        await assertThrowsWebAuthn(.invalidExtensions) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }

    // MARK: P1-01 — structural validity: breaks and indefinite-string chunks

    func testDefiniteMapWithBreakValueRejected() async {
        // A1 61 78 FF — definite map with a break marker where a value belongs.
        await expectInvalidExtensions([0xA1, 0x61, 0x78, 0xFF])
    }

    func testIndefiniteMapMissingValueRejected() async {
        // BF 61 78 FF FF — indefinite map with a key then an immediate break (missing value).
        await expectInvalidExtensions([0xBF, 0x61, 0x78, 0xFF, 0xFF])
    }

    func testIndefiniteByteStringWithIndefiniteChunkRejected() async {
        // A1 61 78 5F 5F 40 FF FF — indefinite byte string whose chunk is itself an indefinite
        // byte string. RFC 8949 requires definite-length chunks only.
        await expectInvalidExtensions([0xA1, 0x61, 0x78, 0x5F, 0x5F, 0x40, 0xFF, 0xFF])
    }

    func testIndefiniteTextStringWithIndefiniteChunkRejected() async {
        // A1 61 79 7F 7F 60 FF FF — indefinite TEXT string whose chunk is itself an indefinite text
        // string. Like the byte-string case, only definite-length chunks are allowed. The unpatched
        // decoder flattened this nested indefinite chunk and accepted it.
        await expectInvalidExtensions([0xA1, 0x61, 0x79, 0x7F, 0x7F, 0x60, 0xFF, 0xFF])
    }

    func testBareBreakRejected() async {
        // A bare break is malformed input, never a usable value. Assert at BOTH levels: the decoder
        // itself rejects a top-level break (this is what actually regressed — the unpatched decoder
        // returned `.break` here), and the registration extension path surfaces it as
        // `.invalidExtensions`.
        XCTAssertThrowsError(try CBOR.decode([0xFF]))
        await expectInvalidExtensions([0xFF])
    }

    func testDefiniteArrayElementBreakRejected() async {
        // A1 61 78 81 FF — a break where a definite-length array element belongs. The unpatched
        // decoder stored `.break` as the element and accepted it; it must now be rejected.
        await expectInvalidExtensions([0xA1, 0x61, 0x78, 0x81, 0xFF])
    }

    func testTaggedItemBreakRejected() async {
        // A1 61 78 C0 FF — a break where a tagged value's content belongs. The unpatched decoder
        // accepted the break as the tagged item; it must now be rejected.
        await expectInvalidExtensions([0xA1, 0x61, 0x78, 0xC0, 0xFF])
    }

    // MARK: P1-01 — valid indefinite controls (must still be ACCEPTED)

    func testValidIndefiniteMapExtensionAccepted() async throws {
        // BF 61 78 01 FF = {"x": 1} as an indefinite-length map.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: [0xBF, 0x61, 0x78, 0x01, 0xFF])
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    func testValidIndefiniteByteStringValueAccepted() async throws {
        // A1 61 79 5F 42 AA BB FF = {"y": <indefinite byte string of one definite chunk AA BB>}.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext: [UInt8] = [0xA1, 0x61, 0x79, 0x5F, 0x42, 0xAA, 0xBB, 0xFF]
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    func testValidIndefiniteTextStringValueAccepted() async throws {
        // A1 61 79 7F 61 61 61 62 FF = {"y": <indefinite text string of two definite chunks "a","b">}.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext: [UInt8] = [0xA1, 0x61, 0x79, 0x7F, 0x61, 0x61, 0x61, 0x62, 0xFF]
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    func testValidIndefiniteArrayValueAccepted() async throws {
        // A1 61 7A 9F 01 02 FF = {"z": [1, 2]} with an indefinite-length array value.
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let ext: [UInt8] = [0xA1, 0x61, 0x7A, 0x9F, 0x01, 0x02, 0xFF]
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    // MARK: P2-01 — KNOWN LIMITATION (not a guarantee): float/NaN key-equivalence for duplicates

    func testKnownLimitationDuplicateNaNKeyInUnknownExtensionNotRejected() async throws {
        // A1 61 78 A2 F9 7E 00 01 F9 7E 00 02 — an unknown extension whose nested map repeats an
        // identical half-float NaN key. Because duplicate detection relies on the CBOR enum's
        // Hashable/== (NaN != NaN, and different float widths are different cases), this duplicate
        // is NOT detected and the map is currently ACCEPTED. This is a deliberately recorded
        // limitation (Oracle P2-01): duplicate rejection is qualified for tested scalar integer/text
        // labels, NOT floating or compound keys (see PATCHES.md P2-03). A correct fix needs an
        // explicit canonical key-equivalence definition (a new subsystem) and is deferred (see
        // evidence); this is an unusual extension shape, not a demonstrated authentication bypass.
        let ext: [UInt8] = [0xA1, 0x61, 0x78, 0xA2, 0xF9, 0x7E, 0x00, 0x01, 0xF9, 0x7E, 0x00, 0x02]
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, extensionBytes: ext)
        let credential = try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        XCTAssertEqual(credential.id, Data(authenticator.credentialID).base64EncodedString())
    }

    // MARK: Full attestation-object consumption

    func testAttestationObjectTrailingBytesRejected() async {
        let authenticator = SoftwareAuthenticator()
        let ch = challenge()
        let json = authenticator.registrationJSON(challenge: ch, attestationTrailing: [0x00])
        await assertThrowsWebAuthn(.invalidAttestationObject) {
            try await BoundedPasskeyVerifier().register(challenge: ch, json: json)
        }
    }
}
