// swift-tools-version:5.5
//
// Local maintained copy — RepoPrompt CE bounded passkey verifier experiment.
//
// Vendored, pinned source (do not re-point without owner authorization):
//   SwiftCBOR — unrelentingtech/SwiftCBOR @ 0.4.7 / 418dab41b09a5da0d45d7b788c59085979ff4dae
//               (public domain, Sources/SwiftCBOR/UNLICENSE).
//
// This manifest preserves upstream's own `swift-tools-version:5.5` (its `public` `CBOR.Tag`
// gets no implicit Sendable conformance, so its `static let` tag constants are hard concurrency
// errors under the Swift 6 language mode; the tools-5.5 package compiles them exactly as upstream
// shipped). Kept as a separate package — rather than merged into the SwiftWebAuthn manifest — so
// the upstream per-package compile boundary is reproduced faithfully.
//
// Locally modified files carry an in-file "RPCE local modification" notice; the full delta is
// documented in ../SwiftWebAuthn/PATCHES.md. This package is linked ONLY into the root test target
// for the experiment; it is not part of the production runtime graph.

import PackageDescription

let package = Package(
    name: "SwiftCBOR",
    products: [
        .library(name: "SwiftCBOR", targets: ["SwiftCBOR"]),
    ],
    targets: [
        .target(
            name: "SwiftCBOR",
            exclude: ["UNLICENSE"]
        ),
    ]
)
