import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Spec R6: fresh Claude `--session-id` preallocation is a separate qualified gate and is never
/// combined with `--resume`. Covers the launch argument builder (no process is spawned) and the
/// gate's default-off composition.
final class ClaudeNativeRuntimeSessionArgumentsTests: XCTestCase {
    private func makeController() throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func testResumeNeverCarriesAFreshSessionID() async throws {
        let controller = try makeController()
        let resumed = await controller.test_buildArguments(existingSessionID: "session-existing", freshSessionID: "fresh-id")
        XCTAssertEqual(value(after: "--resume", in: resumed), "session-existing")
        XCTAssertFalse(resumed.contains("--session-id"), "--session-id is never combined with --resume: \(resumed)")
    }

    func testFreshSessionIDOnlyWhenQualifiedAndNotResuming() async throws {
        let controller = try makeController()
        let fresh = await controller.test_buildArguments(existingSessionID: nil, freshSessionID: "fresh-id")
        XCTAssertEqual(value(after: "--session-id", in: fresh), "fresh-id")
        XCTAssertFalse(fresh.contains("--resume"))

        let unqualified = await controller.test_buildArguments(existingSessionID: nil, freshSessionID: nil)
        XCTAssertFalse(unqualified.contains("--session-id"))
        XCTAssertFalse(unqualified.contains("--resume"))
    }

    func testFreshSessionIDGateIsOffByDefault() {
        XCTAssertFalse(AgentRuntimeLaunchAuthority.production.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(AgentRuntimeLaunchAuthority.activationOff.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(AgentRecoveryActivation.production.runtime.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(AgentRecoveryActivation.claudeAndCodex.runtime.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
    }
}
