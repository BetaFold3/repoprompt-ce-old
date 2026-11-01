// swift-tools-version: 6.0
//
// Local maintained copy — RepoPrompt CE bounded passkey verifier experiment.
//
// Vendored, pinned source (do not re-point without owner authorization):
//   WebAuthn  — brokenhandsio/swift-webauthn @ 030acd1eedaa835958ae3fcc0e491bec03b2abf1
//               (Apache-2.0; see LICENSE.txt / NOTICE.txt). Locally modified files carry an
//               in-file "RPCE local modification" notice; see PATCHES.md for the full delta.
//
// SwiftCBOR lives in the sibling `Vendor/SwiftCBOR` package at its own upstream
// `swift-tools-version:5.5`, reproducing upstream swift-webauthn's two-package compile boundary
// (see that manifest for why SwiftCBOR must compile in the Swift 5 language mode). Upstream
// swift-webauthn itself built at tools 6.0, matched here.
//
// Retains the upstream Crypto/_CryptoExtras verification and the SwiftCBOR decoder; only the
// localized validation fixes described in PATCHES.md are applied. This package is linked ONLY
// into the root test target for the experiment; it is not part of the production runtime graph.

import PackageDescription

let package = Package(
    name: "SwiftWebAuthn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebAuthn", targets: ["WebAuthn"]),
    ],
    dependencies: [
        // Sibling vendored CBOR package (tools 5.5). Unified with the root graph's own
        // `.package(path: "Vendor/SwiftCBOR")` reference (same canonical path = same package).
        .package(path: "../SwiftCBOR"),
        // Already resolved in the root graph (swift-crypto 4.5.0, swift-log 1.6.3); these
        // ranges unify with those pins and add no new Package.resolved entry.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.1" ..< "6.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "WebAuthn",
            dependencies: [
                .product(name: "SwiftCBOR", package: "SwiftCBOR"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
