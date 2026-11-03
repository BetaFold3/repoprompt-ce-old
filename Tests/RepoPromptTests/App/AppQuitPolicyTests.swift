@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AppQuitPolicyTests: XCTestCase {
    func testEnabledWarningPromptsForEveryIdleNormalQuit() {
        let expected = AppQuitRequestDecision.showConfirmation(
            AppQuitConfirmation(
                title: "Quit RepoPrompt?",
                message: "Are you sure you want to quit RepoPrompt?",
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Quit"
            )
        )

        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: []
            ),
            expected
        )
    }

    func testActiveWorkAcrossWindowsOnlyEnrichesWarning() {
        let activeItems = [
            activity(id: "z-search", count: 2, singular: "active search", plural: "active searches"),
            activity(id: "a-session", count: 1, singular: "active agent session", plural: "active agent sessions"),
            activity(id: "a-session", count: 2, singular: "active agent session", plural: "active agent sessions"),
            activity(id: "mcp-active-execution", count: 1, singular: "active MCP tool execution", plural: "active MCP tool executions"),
            activity(id: "mcp-active-execution", count: 2, singular: "active MCP tool execution", plural: "active MCP tool executions"),
            activity(id: "ignored", count: 0, singular: "ignored item", plural: "ignored items")
        ]

        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: activeItems
            ),
            .showConfirmation(
                AppQuitConfirmation(
                    title: "Quit RepoPrompt?",
                    message: "Are you sure you want to quit RepoPrompt? Quitting will end 3 active agent sessions and 3 active MCP tool executions and 2 active searches.",
                    cancelButtonTitle: "Cancel",
                    confirmButtonTitle: "Quit"
                )
            )
        )
        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: false,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: activeItems
            ),
            .beginTermination
        )
    }

    func testUITestsBypassWarning() {
        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: true,
                phase: .idle,
                activeItems: []
            ),
            .beginTermination
        )
    }

    func testRepeatedRequestsDoNotCreateAnotherPrompt() {
        for phase in [AppQuitRequestPhase.awaitingConfirmation, .terminating] {
            XCTAssertEqual(
                AppQuitPolicy.decide(
                    warningEnabled: true,
                    suppressesConfirmation: false,
                    phase: phase,
                    activeItems: []
                ),
                .awaitCurrentRequest
            )
        }
    }

    // MARK: Shutdown reason latch (review A P1-09)

    func testCancelledRestartConfirmationThenOrdinaryQuitIsAPlainQuit() {
        var latch = AppShutdownReasonLatch()
        XCTAssertEqual(latch.pending, .appQuit)
        // Restart safely arms its own termination request; the termination entry takes it first thing,
        // then the user cancels the quit confirmation (R4 never starts).
        latch.armSafeRestart()
        XCTAssertEqual(latch.take(), .safeRestart)
        latch.disarm()
        // A later ordinary Quit (Cmd-Q, menu, Dock) is never a restart.
        XCTAssertEqual(latch.take(), .appQuit)
        XCTAssertEqual(latch.pending, .appQuit)
    }

    func testRestartReasonIsBoundToExactlyOneTerminationRequest() {
        var latch = AppShutdownReasonLatch()
        latch.armSafeRestart()
        XCTAssertEqual(latch.take(), .safeRestart)
        XCTAssertEqual(latch.take(), .appQuit, "a second request in the same cycle (joining one in progress) is a plain quit")
        // A restart whose terminate was never delivered to the delegate disarms afterwards.
        latch.armSafeRestart()
        latch.disarm()
        XCTAssertEqual(latch.take(), .appQuit)
    }

    private func activity(
        id: String,
        count: Int,
        singular: String,
        plural: String
    ) -> WindowCloseActivityItem {
        WindowCloseActivityItem(
            id: id,
            count: count,
            singularLabel: singular,
            pluralLabel: plural
        )
    }
}
