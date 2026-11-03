// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Optimized-diagnostics Dev lane gate; keep identical to the root Package.swift copy.
let optimizedDiagnosticsLane = ProcessInfo.processInfo.environment["RPCE_OPTIMIZED_DIAGNOSTICS"] == "1"
let optimizedIncrementalLane = optimizedDiagnosticsLane
    && ProcessInfo.processInfo.environment["RPCE_OPTIMIZED_INCREMENTAL"] == "1"
let firstPartyDebugSettings: [SwiftSetting] = optimizedDiagnosticsLane
    ? [.define("DEBUG"), .define("RPCE_OPTIMIZED_DIAGNOSTICS", .when(configuration: .release))]
    + (optimizedIncrementalLane ? [.define("RPCE_OPTIMIZED_INCREMENTAL", .when(configuration: .release))] : [])
    : [.define("DEBUG", .when(configuration: .debug))]

let package = Package(
    name: "RepoPromptCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RepoPromptShared", targets: ["RepoPromptShared"]),
        .library(name: "RepoPromptMCPClientKit", targets: ["RepoPromptMCPClientKit"]),
        .library(name: "RepoPromptMCPCore", targets: ["RepoPromptMCPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.8.0"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.6.4"),
        .package(
            url: "https://github.com/provencher/swift-sdk.git",
            revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"
        )
    ],
    targets: [
        .target(
            name: "RepoPromptShared",
            path: "Sources/RepoPromptShared",
            swiftSettings: firstPartyDebugSettings
        ),
        .target(
            name: "RepoPromptMCPClientKit",
            dependencies: [
                "RepoPromptShared",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Sources/RepoPromptMCPClientKit",
            swiftSettings: firstPartyDebugSettings
        ),
        .target(
            name: "RepoPromptMCPCore",
            dependencies: [
                "RepoPromptShared",
                "RepoPromptMCPClientKit",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Sources/RepoPromptMCPCore",
            swiftSettings: firstPartyDebugSettings
        ),
        .testTarget(
            name: "RepoPromptCoreTests",
            dependencies: [
                "RepoPromptMCPCore",
                "RepoPromptMCPClientKit",
                "RepoPromptShared",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/RepoPromptCoreTests",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        )
    ],
    swiftLanguageModes: [.v5]
)
