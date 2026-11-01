# Vendor/SwiftWebAuthn (+ Vendor/SwiftCBOR) — local modification notes

Bounded passkey verifier experiment (2026-11-01). Linked **only** into the root test target;
not part of the production runtime graph. No upstream fork published; no network publication.

## Provenance (frozen pins)
- `Vendor/SwiftWebAuthn/Sources/WebAuthn/**` — brokenhandsio/swift-webauthn @
  `030acd1eedaa835958ae3fcc0e491bec03b2abf1`. Apache-2.0 (`LICENSE.txt`, `NOTICE.txt`).
  `Docs.docc` was dropped from the vendored copy (documentation catalog only; not needed to
  build). All other files are verbatim except those listed below, which carry an in-file
  "RPCE local modification" notice as required by Apache-2.0 §4(b).
- `Vendor/SwiftCBOR/Sources/SwiftCBOR/**` — unrelentingtech/SwiftCBOR @ `0.4.7` /
  `418dab41b09a5da0d45d7b788c59085979ff4dae`. Public domain (`Sources/SwiftCBOR/UNLICENSE`;
  excluded from the target). `Info.plist` dropped. Verbatim except the file listed below.

## Package layout (two packages, mirroring upstream)
SwiftCBOR is kept as its **own** package (`Vendor/SwiftCBOR`, `swift-tools-version:5.5`) that
`Vendor/SwiftWebAuthn` (`swift-tools-version:6.0`) depends on via `.package(path: "../SwiftCBOR")`;
the root `Package.swift` references both path packages and links `WebAuthn` + `SwiftCBOR` into the
root test target only. This reproduces upstream's per-package compile boundary: SwiftCBOR's
`public` `CBOR.Tag` gets no implicit `Sendable`, so its `static let` tag constants are hard
concurrency errors under the Swift 6 language mode — upstream never hit that because SwiftCBOR
ships its own tools-5.5 manifest and compiles in the Swift 5 language mode. Keeping two packages
restores that; no vendored source was changed to satisfy the compiler.

Retains the upstream Crypto/_CryptoExtras verification and the SwiftCBOR parser. No new parser,
no cryptographic change, no gratuitous refactor/prune. This candidate actively rejects everything
outside the ES256 / EC2 / P-256 profile at COSE-key construction: a non-EC2 key type (RSA, OKP) or
a non-ES256 algorithm throws before any non-EC2 constructor runs. The upstream RSA/OKP types and
the ES384/ES512 branches in `EC2PublicKey.verify` are retained in the source (nothing removed) but
are unreachable in this candidate — they are NOT a supported curve/algorithm here. Other
attestation formats than `none` likewise remain in the source but are rejected by the ceremony.

## Delta (all reject-only / additive validation)

### SwiftCBOR
- `CBORDecoder.swift` — reject-only hardening of the retained decoder (valid, well-formed, unique-key
  CBOR still decodes unchanged):
  - Added `CBORError.duplicateMapKey`; both map readers (definite- and indefinite-length) reject a
    repeated key before insertion instead of last-wins overwrite. Uniqueness only — not canonical
    order or minimal encoding. **Scope (P2-01):** duplicates are compared by the CBOR enum's value
    equality (`Hashable`/`==`), which does NOT canonicalize NaN keys (`NaN != NaN`) or equivalent
    floating-point keys encoded at different widths. Map-valued keys, including compound keys
    containing maps, also remain unqualified: map hashing depends on dictionary iteration order
    although map equality is order-independent (P2-03). Duplicate rejection is qualified for the
    scalar integer/text labels covered by the profile tests, not universally for floating or
    compound keys. General key-equivalence/hash consistency work is deferred beyond this bounded
    experiment; a production adoption must revisit this limitation.
  - `readN` (definite-length arrays, P0-02) builds the array incrementally and never reserves
    capacity from the declared element count. The prior `(0..<n).map { … }` reserved the full
    declared count (`Range.underestimatedCount`), so a tiny header (e.g. `9b 7f ff ff ff ff ff ff ff`,
    `array(Int.max)`) could abort on allocation before the missing elements produced an ordinary
    `unfinishedSequence`. Byte/text-string lengths were already length-safe (`popBytes` throws when
    short and never reserves).
  - Break (`0xff`) handling is context-sensitive (P1-01). `decodeItem` gained a private
    `allowBreak` parameter; the public entry point passes `false`. A break is accepted only at the
    legal termination position of an indefinite-length array/map (its element/key position); it is
    rejected as a definite-element, map value, tagged item, standalone value, or top-level item.
    Indefinite byte/text strings now read their chunks directly and require each chunk to be a
    definite-length string of the same major type (RFC 8949 §3.2.3), rejecting a nested indefinite
    chunk or any other major type. Valid indefinite arrays/maps/strings still decode.

### WebAuthn
- `WebAuthnError.swift` — added reasons/statics: `rawU2FPublicKeyUnsupported`,
  `credentialIDMismatch`, `attestedCredentialDataFlagSetInAssertion`, `invalidBackupFlags`,
  `backupEligibilityMismatch`, `invalidExtensions`.
- `Ceremonies/Shared/CredentialPublicKey.swift`
  - The leading-`0x04` (raw U2F) branch now `throw`s `rawU2FPublicKeyUnsupported` instead of
    slicing `publicKeyBytes[1...33]`/`[33...65]` — removes a fatal index-out-of-bounds trap on
    short attacker-controlled input.
  - Algorithm-id conversion uses `Int(exactly:)` — removes a fatal trap when the decoded
    `UInt64` exceeds `Int.max` (reached before algorithm validation on the COSE-map path).
  - P0-01: requires the decoded credential public key to be a CBOR `.map` BEFORE any COSE-label
    subscripting. SwiftCBOR subscripts a `.array` positionally (`l[Int(i)]`), so subscripting a
    non-map (e.g. an empty/short array `coseKey` such as `[0x80]` or `[0x81,0x01]`) with an unsigned
    COSE label would trap out-of-bounds; it now throws `badPublicKeyBytes`.
  - `EC2PublicKey.init(publicKeyObject:algorithm:)` is bounded to the narrow profile: it accepts
    **only** EC2 / P-256 / ES256 and eagerly validates exact 32-byte coordinate length at
    construction (registration and assertion). Any other curve/algorithm is rejected with an
    ordinary error rather than eagerly constructing P-384/P-521 keys. It then enforces that the
    point is ON the P-256 curve at construction (so an off-curve key is rejected at REGISTRATION,
    not merely at later signature verification), using only swift-crypto's existing public
    point-decompression initializer: it builds the X9.63 compressed encoding (0x02/0x03 prefix from
    y's parity, then x) and asks swift-crypto to decompress it. Decompression solves the curve
    equation for y and throws a swift-crypto error when x has no on-curve point; for a valid x
    there is exactly one on-curve y per parity, so the decompressed canonical point is required to
    equal the supplied (x || y), which rejects any off-curve y (`invalidXCoordinate` for a bad x,
    `invalidYCoordinate` for an off-curve y). No field arithmetic / cryptographic routine was added
    by us — the curve math is swift-crypto's. `rawRepresentation` note: swift-crypto's
    `rawRepresentation` initializer alone did not reliably reject off-curve / over-range points in
    this environment, which is why the compressed-decompression + canonical-compare path above is
    used instead.
  - `CredentialPublicKey.init(publicKeyBytes:)` now gates the COSE key type and algorithm to the
    profile BEFORE dispatching to a key-type constructor: a non-EC2 `kty` throws `unsupported` and
    a non-ES256 `alg` throws `unsupportedCOSEAlgorithm`. Without this gate an RSA COSE map carrying
    a recognized EC algorithm id (e.g. alg=-7 / ES256) would construct an `RSAPublicKeyData` and
    pass the registration ES256 allowlist, deferring rejection to a later signature failure. The
    `switch keyType` and the RSA/OKP constructors below the gate are retained unchanged but
    unreachable. Neither guard traps.
- `Ceremonies/Registration/RegistrationCredential.swift` — `ParsedCredentialCreationResponse.
  verify` requires the outer JSON `id` and `rawId` to be the same bytes and both to equal the
  attested embedded `credentialID` (id == rawID == embeddedID; `credentialIDMismatch`). No second
  parser — the embedded ID is the library's own parsed value.
- `Ceremonies/Registration/AuthenticatorAttestationResponse.swift` — the attestation object is
  decoded via a stream and must be exactly one complete CBOR item with no trailing bytes
  (full consumption at the attestation-object boundary).
- `Ceremonies/Registration/AttestationObject.swift` — registration enforces BS⇒BE (a
  "currently backed up" credential must also be backup-eligible; `invalidBackupFlags`), matching
  the assertion ceremony.
- `Ceremonies/Shared/AuthenticatorData.swift` — when the extension-data flag is set, the
  extensions block must decode as exactly one complete CBOR map (valid unknown entries allowed)
  with no trailing bytes (`invalidExtensions` for a decode failure / non-map;
  `leftOverBytesInAuthenticatorData` for trailing bytes). Embedded per-item `decodeItem` for the
  public key is unchanged (not globally full-consumption).
- `Ceremonies/Authentication/AuthenticatorAssertionResponse.swift` — assertion verify rejects the
  AT flag (`attestedCredentialDataFlagSetInAssertion`), enforces BS⇒BE (`invalidBackupFlags`),
  and, when a stored backup-eligible value is supplied, enforces cross-ceremony immutability
  (`backupEligibilityMismatch`). Added optional `credentialBackupEligible` parameter (default nil
  = upstream behavior).
- `WebAuthnManager.swift` — `finishAuthentication` gained an optional `credentialBackupEligible`
  parameter (default nil) threaded to the assertion verify.

## Explicitly NOT changed
- Counter policy: the upstream sign-count logic is unchanged. Synced-credential "metadata-only"
  behavior is achieved by the caller passing `credentialCurrentSignCount: 0`; a thrown counter
  error is never caught and converted to success. (The test-local adapter makes this explicit via
  a `CounterPolicy` enum; the library is untouched.)
- Required user verification: enforced by the caller passing `requireUserVerification: true` to
  both ceremonies (library already checks the flag when true).
- Credential-identity binding at assertion (asserted-response internal consistency `id == rawId`,
  expected stored credential ID, optional user handle) and raw input size caps are relying-party
  responsibilities handled in the **test-local adapter** (`BoundedPasskeyVerifier`), not the
  library. The `AuthenticationCredential` decoder does not enforce outer `id == rawId` and
  `finishAuthentication` returns the caller-supplied id, so the adapter rejects an asserted response
  whose outer `id` contradicts its `rawId` before verifying.
- Codable CBOR path (out-of-profile boundary): the duplicate-map-key rejection was added only to the
  raw stream decoder (`CBORDecoder.readNPairs`/`readPairsUntilBreak`). SwiftCBOR's separate
  `CodableCBORDecoder` map-counting path (`Decoder/KeyedDecodingContainer.swift` `count()` /
  `nestedContainers()`) parses maps independently and does NOT reject duplicate keys. This is not a
  gap for this experiment: every WebAuthn verification path decodes exclusively through raw
  `CBOR.decode` / `CBORDecoder(stream:)` (attestation object, authenticator data, extensions, COSE
  key), so the scalar-key guard described above is active. The Codable layer is unused here and left
  unchanged; if any future adoption routes attacker-controlled CBOR through `CodableCBORDecoder`, the
  uniqueness guard must be mirrored there (or that path documented out-of-profile) at that time.
- No cryptographic routines, no replacement parser, no dependency upgrades.

## External/upstream positive fixture — limitation (recorded, not worked around)
The bounded copy vendors only `Sources/WebAuthn` (and `Vendor/SwiftCBOR/Sources/SwiftCBOR`); the
upstream swift-webauthn `Tests/` tree and its fixtures were intentionally NOT vendored. There is
therefore no readily-available pinned-upstream ES256 vector in-tree to assert against. Importing
upstream test resources would be out-of-scope new work, and the known upstream ES256 registration
vectors are authored for the upstream default ceremony (not the required-UV + synced/backup-eligible
profile), so they would not satisfy this candidate's profile unchanged. The positive fixtures here
are therefore self-generated by `SoftwareAuthenticator` using a real `P256.Signing.PrivateKey`:
signatures are genuine (not hand-forged), verified through the retained swift-crypto path. No
provenance was fabricated and no authentic signature was rewritten. Introducing an independent,
properly-provenanced upstream/third-party vector is deferred to any production-adoption step.
