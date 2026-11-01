// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Telemetry (Sentry) is resolved deterministically but linked only when explicitly
// requested. The official Developer ID release pipeline sets
// REPOPROMPT_ENABLE_SENTRY=1; local builds use the same gate for intentional
// Sentry testing.
let environment = ProcessInfo.processInfo.environment
let sentryEnabled = environment["REPOPROMPT_ENABLE_SENTRY"] == "1"
let benchmarkTestsEnabled = environment["RPCE_ENABLE_BENCHMARK_TESTS"] == "1"

// Optimized-diagnostics Dev lane: coordinated builds reach it only through
// `Scripts/canonical_swift.sh --rpce-optimized-diagnostics build -c release`.
// Gate off, every first-party site carries exactly the debug-only DEBUG define.
// Gate on, first-party Swift targets define DEBUG in the release build, plus a
// lane marker. Packages/RepoPromptCore and Packages/RepoPromptAgentProviders
// keep identical copies of this gate (manifests cannot share code).
// Optimized-incremental App lane (`canonical_swift.sh --rpce-optimized-incremental`): the same gate
// plus RPCE_OPTIMIZED_INCREMENTAL=1 adds the RPCE_OPTIMIZED_INCREMENTAL lane label to every
// first-party module; only the root manifest also compiles RepoPromptApp non-WMO (below).
let optimizedDiagnosticsLane = environment["RPCE_OPTIMIZED_DIAGNOSTICS"] == "1"
let optimizedIncrementalLane = optimizedDiagnosticsLane && environment["RPCE_OPTIMIZED_INCREMENTAL"] == "1"
let firstPartyDebugSettings: [SwiftSetting] = optimizedDiagnosticsLane
    ? [.define("DEBUG"), .define("RPCE_OPTIMIZED_DIAGNOSTICS", .when(configuration: .release))]
    + (optimizedIncrementalLane ? [.define("RPCE_OPTIMIZED_INCREMENTAL", .when(configuration: .release))] : [])
    : [.define("DEBUG", .when(configuration: .debug))]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "2.3.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.6.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.8.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.6.4"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.0"),
    .package(url: "https://github.com/provencher/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", exact: "0.8.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c", revision: "3efee11f784605d44623d7dadd6cd12a0f73ea92"),
    .package(url: "https://github.com/UserNobody14/tree-sitter-dart", revision: "80e23c07b64494f7e21090bb3450223ef0b192f4"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-go", revision: "c350fa54d38af725c40d061a602ee3205ef1e072"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-java", revision: "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", revision: "39798e26b6d4dbcee8e522b8db83f8b2df33a5ea"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", revision: "c5fca1a186e8e528115196178c28eefa8d86b0b0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-rust", revision: "2eaf126458a4d6a69401089b6ba78c5e5d6c1ced"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", revision: "75b3874edb2dc714fb1fd77a32013d0f8699989f"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", revision: "7a010836b74351855148818d5cb8170dc4df8e6a"),
    .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "9253825dd2570430b53fa128cbb40cb62498e75d"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp.git", revision: "b27b091bfdc5f16d0ef76421ea5609c82a57dff0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", revision: "e5cea0ec884c5c3d2d1e41a741a66ce13da4d945"),
    .package(url: "https://github.com/provencher/tree-sitter-php", revision: "0a99deca13c4af1fb9adcb03c958bfc9f4c740a9"),
    .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", revision: "b7d030cd7453f314c780f5492385f73d704cbd5d"),
    .package(url: "https://github.com/provencher/SwiftOpenAI", revision: "1211782eb337e7968124448a20d9260df1952012"),
    .package(url: "https://github.com/ChimeHQ/Neon.git", exact: "0.6.0"),
    .package(path: "Vendor/UniversalCharsetDetection"),
    // Bounded passkey verifier experiment: linked only into the root test target (see
    // repoPromptTestDependencies), not into any production target. Two vendored packages mirror
    // upstream's own manifests (SwiftCBOR @ tools 5.5, SwiftWebAuthn @ tools 6.0).
    .package(path: "Vendor/SwiftCBOR"),
    .package(path: "Vendor/SwiftWebAuthn"),
    .package(url: "https://github.com/loopwork-ai/JSONSchema.git", exact: "1.3.0"),
    .package(url: "https://github.com/loopwork-ai/ontology.git", exact: "0.6.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1"),
    .package(path: "Packages/RepoPromptAgentProviders"),
    .package(path: "Packages/RepoPromptCore")
]

var repoPromptAppDependencies: [Target.Dependency] = [
    "RepoPromptAgentCore",
    "RepoPromptPlatform",
    "RepoPromptUI",
    "RepoPromptWorkspace",
    .product(name: "RepoPromptShared", package: "RepoPromptCore"),
    "RepoPromptRemoteWire",
    "RepoPromptC", "CSwiftPCRE2", "TreeSitterScannerSupport",
    "Sparkle",
    .product(name: "Logging", package: "swift-log"),
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    .product(name: "Markdown", package: "swift-markdown"),
    .product(name: "MCP", package: "swift-sdk"),
    .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
    .product(name: "TreeSitterC", package: "tree-sitter-c"),
    .product(name: "TreeSitterDart", package: "tree-sitter-dart"),
    .product(name: "TreeSitterGo", package: "tree-sitter-go"),
    .product(name: "TreeSitterJava", package: "tree-sitter-java"),
    .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
    .product(name: "TreeSitterPython", package: "tree-sitter-python"),
    .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
    .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
    .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
    .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
    .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
    .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
    .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
    .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
    .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
    .product(name: "Neon", package: "Neon"),
    .product(name: "UniversalCharsetDetection", package: "UniversalCharsetDetection"),
    .product(name: "Cuchardet", package: "UniversalCharsetDetection"),
    .product(name: "JSONSchema", package: "JSONSchema"),
    .product(name: "Ontology", package: "ontology"),
    .product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders")
]

/// Shared by RepoPromptApp and the lower app-split library targets so compile conditions stay aligned.
let repoPromptLayerSwiftSettings: [SwiftSetting] = firstPartyDebugSettings + [
    .enableUpcomingFeature("BareSlashRegexLiterals")
]

var repoPromptAppSwiftSettings: [SwiftSetting] = repoPromptLayerSwiftSettings
// Optimized-incremental App lane only: RepoPromptApp alone overrides SwiftPM's release
// -whole-module-optimization (the driver honors the last of the pair) with incremental batch mode.
// SwiftPM's own -j<host CPUs> sets frontend parallelism. Every other module keeps -O WMO;
// Scripts/verify_build_lane_flags.py --lane optimized-incremental proves both on every lane package.
if optimizedIncrementalLane {
    repoPromptAppSwiftSettings.append(
        .unsafeFlags(["-no-whole-module-optimization", "-incremental", "-enable-batch-mode"], .when(configuration: .release))
    )
}

var repoPromptTestDependencies: [Target.Dependency] = [
    "RepoPromptApp",
    "RepoPromptAgentCore",
    "RepoPromptPlatform",
    "RepoPromptUI",
    "RepoPromptWorkspace",
    "RepoPromptGateway",
    "RepoPromptRemoteWire",
    .product(name: "RepoPromptShared", package: "RepoPromptCore"),
    .product(name: "RepoPromptMCPClientKit", package: "RepoPromptCore"),
    .product(name: "RepoPromptMCPCore", package: "RepoPromptCore"),
    // Bounded passkey verifier experiment (test-only; not in the production runtime graph).
    .product(name: "WebAuthn", package: "SwiftWebAuthn"),
    .product(name: "SwiftCBOR", package: "SwiftCBOR")
]

var repoPromptTestSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug))
]

if sentryEnabled {
    let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")
    repoPromptAppDependencies.append(sentryDependency)
    repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
    repoPromptTestDependencies.append(sentryDependency)
    repoPromptTestSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))
}

if benchmarkTestsEnabled {
    repoPromptTestSwiftSettings.append(.define("RPCE_BENCHMARK_TESTS"))
}

let package = Package(
    name: "RepoPromptCE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RepoPrompt", targets: ["RepoPrompt"]),
        .executable(name: "repoprompt-mcp", targets: ["RepoPromptMCP"]),
        .executable(name: "repoprompt-gateway", targets: ["RepoPromptGateway"])
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "RepoPrompt",
            dependencies: ["RepoPromptApp"],
            path: "Sources/RepoPromptExecutable",
            // Debug builds already define DEBUG here; only the lane adds settings.
            swiftSettings: optimizedDiagnosticsLane ? firstPartyDebugSettings : nil
        ),
        .target(
            name: "RepoPromptApp",
            dependencies: repoPromptAppDependencies,
            path: "Sources/RepoPrompt",
            swiftSettings: repoPromptAppSwiftSettings
        ),
        .target(
            name: "RepoPromptAgentCore",
            dependencies: [
                "RepoPromptPlatform",
                "RepoPromptWorkspace",
                .product(name: "RepoPromptShared", package: "RepoPromptCore"),
                "RepoPromptRemoteWire",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
                .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
                .product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders")
            ],
            path: "Sources/RepoPromptAgentCore",
            swiftSettings: repoPromptLayerSwiftSettings
        ),
        .target(
            name: "RepoPromptPlatform",
            dependencies: [
                .product(name: "RepoPromptShared", package: "RepoPromptCore"),
                "RepoPromptC",
                "CSwiftPCRE2"
            ],
            path: "Sources/RepoPromptPlatform",
            swiftSettings: repoPromptLayerSwiftSettings
        ),
        .target(
            name: "RepoPromptUI",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")
            ],
            path: "Sources/RepoPromptUI",
            swiftSettings: repoPromptLayerSwiftSettings
        ),
        .target(
            name: "RepoPromptWorkspace",
            dependencies: [
                "RepoPromptPlatform",
                .product(name: "RepoPromptShared", package: "RepoPromptCore"),
                "RepoPromptC",
                "TreeSitterScannerSupport",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterDart", package: "tree-sitter-dart"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
                .product(name: "UniversalCharsetDetection", package: "UniversalCharsetDetection"),
                .product(name: "Cuchardet", package: "UniversalCharsetDetection")
            ],
            path: "Sources/RepoPromptWorkspace",
            swiftSettings: repoPromptLayerSwiftSettings
        ),
        .target(
            name: "RepoPromptRemoteWire",
            path: "Sources/RepoPromptRemoteWire",
            swiftSettings: firstPartyDebugSettings
        ),
        .executableTarget(
            name: "RepoPromptMCP",
            dependencies: [
                .product(name: "RepoPromptMCPCore", package: "RepoPromptCore"),
                // Restart safely private relaunch mode only (`ProcessRelaunchHelper`).
                "RepoPromptPlatform"
            ],
            path: "Sources/RepoPromptMCP",
            swiftSettings: firstPartyDebugSettings
        ),
        .executableTarget(
            name: "RepoPromptGateway",
            dependencies: [
                .product(name: "RepoPromptMCPClientKit", package: "RepoPromptCore"),
                .product(name: "RepoPromptShared", package: "RepoPromptCore"),
                "RepoPromptRemoteWire",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Sources/RepoPromptGateway",
            resources: [
                .copy("Resources/pwa")
            ],
            swiftSettings: firstPartyDebugSettings
        ),
        .target(name: "CSwiftPCRE2", path: "Sources/CSwiftPCRE2", exclude: ["deps/sljit/sljit_src/sljitNativeARM_64.c", "deps/sljit/sljit_src/sljitSerialize.c", "deps/sljit/sljit_src/sljitUtils.c", "deps/sljit/sljit_src/sljitNativeX86_common.c", "deps/sljit/sljit_src/sljitNativeX86_64.c", "deps/sljit/sljit_src/sljitNativeX86_32.c", "deps/sljit/sljit_src/allocator_src/sljitWXExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitProtExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorPosix.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorCore.c", "deps/sljit/sljit_src/allocator_src/sljitExecAllocatorApple.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("include"), .headerSearchPath("src"), .define("PCRE2_CODE_UNIT_WIDTH", to: "8"), .define("HAVE_CONFIG_H")]),
        .target(name: "RepoPromptC", path: "Sources/RepoPromptC", publicHeadersPath: "include", cSettings: [.headerSearchPath("include")]),
        // Exact-snapshot scanner ABI fallback for upstream JavaScript/Python products.
        // See docs/architecture/source-layout.md and ThirdPartyLicenses/tree-sitter/README.md.
        .target(name: "TreeSitterScannerSupport", path: "Sources/TreeSitterScannerSupport", sources: ["src/javascript/scanner.c", "src/python/scanner.c"], publicHeadersPath: "include"),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .testTarget(
            name: "RepoPromptTests",
            dependencies: repoPromptTestDependencies,
            path: "Tests/RepoPromptTests",
            resources: [
                .copy("CodeMap/Fixtures"),
                .copy("CodeMap/Goldens")
            ],
            swiftSettings: repoPromptTestSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
