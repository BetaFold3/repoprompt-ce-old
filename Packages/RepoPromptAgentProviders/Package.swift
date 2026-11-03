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
    name: "RepoPromptAgentProviders",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "RepoPromptClaudeCompatibleProvider",
            targets: ["RepoPromptClaudeCompatibleProvider"]
        )
    ],
    targets: [
        .target(
            name: "RepoPromptClaudeCompatibleProvider",
            path: "Sources/RepoPromptClaudeCompatibleProvider",
            swiftSettings: firstPartyDebugSettings
        ),
        .testTarget(
            name: "RepoPromptClaudeCompatibleProviderTests",
            dependencies: ["RepoPromptClaudeCompatibleProvider"],
            path: "Tests/RepoPromptClaudeCompatibleProviderTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
