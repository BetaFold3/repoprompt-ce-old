import Foundation
@testable import RepoPromptPlatform
import XCTest

/// Lossless-restart Phase 3 (R6) runtime marker composition. Pure environment tests; nothing
/// is spawned.
final class ProcessLauncherRuntimeMarkerTests: XCTestCase {
    private let runtimeID = UUID(uuidString: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9")!

    func testMarkerNameAvoidsStrippedEnvironmentWords() {
        let key = ProcessLauncher.runtimeMarkerEnvironmentKey
        XCTAssertEqual(key, "RPCE_RUNTIME_ID")
        for word in ["KEY", "TOKEN", "SECRET"] {
            XCTAssertFalse(key.contains(word))
        }
    }

    func testNilRuntimeIDPassesEnvironmentUnchangedIncludingExistingMarker() {
        let environment = ["PATH": "/usr/bin", "RPCE_RUNTIME_ID": "caller-supplied"]

        XCTAssertEqual(ProcessLauncher.launchEnvironment(environment, runtimeID: nil), environment)
        XCTAssertEqual(ProcessLauncher.launchEnvironment([:], runtimeID: nil), [:])
    }

    func testRuntimeIDAddsCanonicalMarkerWithoutTouchingOtherEntries() {
        let environment = ["PATH": "/usr/bin", "HOME": "/Users/me"]

        XCTAssertEqual(
            ProcessLauncher.launchEnvironment(environment, runtimeID: runtimeID),
            ["PATH": "/usr/bin", "HOME": "/Users/me", "RPCE_RUNTIME_ID": "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"]
        )
    }

    func testRuntimeIDReplacesExistingMarkerAndLeavesCallerDictionaryUnchanged() {
        let environment = ["PATH": "/usr/bin", "RPCE_RUNTIME_ID": "stale-marker"]
        let original = environment

        let composed = ProcessLauncher.launchEnvironment(environment, runtimeID: runtimeID)

        XCTAssertEqual(composed["RPCE_RUNTIME_ID"], runtimeID.uuidString)
        XCTAssertEqual(composed["PATH"], "/usr/bin")
        XCTAssertEqual(composed.count, 2)
        XCTAssertEqual(environment, original)
    }

    func testComposedMarkerParsesBackThroughInspectionParser() {
        let composed = ProcessLauncher.launchEnvironment([:], runtimeID: runtimeID)
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(0)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/bin/tool".utf8) + [0, 0])
        for (key, value) in composed {
            buffer.append(contentsOf: Array("\(key)=\(value)".utf8) + [0])
        }

        XCTAssertEqual(
            ProcessInspection.parseEnvironmentIdentity(procArgs2: buffer),
            .success(ProcessEnvironmentIdentity(runtimeID: runtimeID, claudeConfigDirectory: nil))
        )
    }
}
