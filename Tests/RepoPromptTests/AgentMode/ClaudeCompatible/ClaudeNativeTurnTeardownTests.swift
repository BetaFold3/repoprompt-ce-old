import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Teardown-race contracts for the Claude native process controller.
///
/// The subprocess emits a trailing `result` after an interrupt, and the stdout consumer can
/// still deliver it after `shutdown()` has cleared the pending turn-ID queue (cancellation is
/// cooperative and the consume path performs no cancellation check). That sequence must be
/// recorded and recovered from, never trapped, and it must not leak turn state into the next
/// session on this reusable controller.
final class ClaudeNativeTurnTeardownTests: XCTestCase {
    private func makeController() throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            mcpHost: ServerNetworkManager.shared
        )
    }

    func testTrailingResultAfterShutdownIsRecoveredWithoutTrappingOrRestoringTurnInFlight() async throws {
        let controller = try makeController()
        await controller.test_setTurnWasInterrupted(true)
        await controller.shutdown()

        // Mirrors the observed crash sequence exactly: interrupt ACK, session shutdown, then
        // the CLI's trailing `error_during_execution` result. Before the fix the missing
        // pending turn ID hit assertionFailure() and killed the debug app.
        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "error_during_execution",
            "stop_reason": "tool_use"
        ])

        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight, "A post-shutdown trailing result must not resurrect turn tracking.")
    }

    func testReplayedResultWithoutShutdownIsRecoveredWithoutTrapping() async throws {
        let controller = try makeController()

        // Mirrors the 2026-07-27 19:28 host crash: reattaching an existing CLI
        // session replayed the final `result`/`message_stop` of an
        // already-completed turn while the controller was fully live
        // (isShuttingDown == false) with no pending turn ID. The former
        // assertionFailure killed the debug host; the signal must be recorded
        // and recovered instead.
        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "success",
            "stop_reason": "end_turn",
            "result": "replayed final message"
        ])

        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight, "A replayed live-path result must not resurrect turn tracking.")
    }

    /// O49: `startedTurnID` is the FIFO turn model output is attributed to. A written turn queued
    /// behind it is never reported before its own output, a completed turn is cleared, and
    /// shutdown clears it.
    func testStartedTurnIsTheTurnOutputIsAttributedToAndNeverAQueuedOne() async throws {
        let controller = try makeController()
        let first = await controller.test_beginTurnTracking()
        let second = await controller.test_beginTurnTracking()
        XCTAssertNil(controller.startedTurnID, "Written turns the CLI has not begun are not started")

        await controller.test_handleStreamPayload(Self.assistantTextPayload(id: "msg_first"))
        XCTAssertEqual(controller.startedTurnID, first)
        XCTAssertNotEqual(controller.startedTurnID, second)

        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "success",
            "stop_reason": "end_turn"
        ])
        XCTAssertNil(controller.startedTurnID, "The first turn completed; the queued second has not begun")

        await controller.test_handleStreamPayload(Self.assistantTextPayload(id: "msg_second"))
        XCTAssertEqual(controller.startedTurnID, second)

        await controller.shutdown()
        XCTAssertNil(controller.startedTurnID, "Shutdown clears the queue and the started turn")
    }

    /// G3: a realistic final `result` (result text, usage, `is_error`) closes turn A and never
    /// starts turn B queued behind it, whether completion is immediate or deferred until `idle`.
    func testRealisticResultMessageNeverStartsTheQueuedTurnBehindIt() async throws {
        for deferred in [false, true] {
            let controller = try makeController()
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("running"))
            }
            let first = await controller.test_beginTurnTracking()
            let second = await controller.test_beginTurnTracking()
            await controller.test_handleStreamPayload(Self.assistantTextPayload(id: "msg_first"))
            XCTAssertEqual(controller.startedTurnID, first, "deferred=\(deferred)")

            await controller.test_handleStreamPayload(Self.realisticResultPayload())
            XCTAssertNotEqual(controller.startedTurnID, second, "deferred=\(deferred): B has not begun")
            if deferred {
                XCTAssertEqual(controller.startedTurnID, first, "A's completion waits for idle")
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            XCTAssertNil(controller.startedTurnID, "deferred=\(deferred): A completed and B has not begun")

            await controller.test_handleStreamPayload(Self.assistantTextPayload(id: "msg_second"))
            XCTAssertEqual(controller.startedTurnID, second, "deferred=\(deferred)")
            await controller.shutdown()
        }
    }

    private static func realisticResultPayload() -> [String: Any] {
        [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "duration_ms": 1200,
            "num_turns": 1,
            "result": "Done.",
            "stop_reason": "end_turn",
            "session_id": "turn-teardown-session",
            "total_cost_usd": 0.01,
            "usage": [
                "input_tokens": 10,
                "output_tokens": 5,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
            ]
        ]
    }

    private static func sessionStatePayload(_ state: String) -> [String: Any] {
        ["type": "system", "subtype": "session_state_changed", "state": state, "session_id": "turn-teardown-session"]
    }

    /// Output with no written turn queued is attributed to nothing.
    func testOutputWithoutAQueuedTurnStartsNothing() async throws {
        let controller = try makeController()
        await controller.test_handleStreamPayload(Self.assistantTextPayload(id: "msg_replayed"))
        XCTAssertNil(controller.startedTurnID)
    }

    private static func assistantTextPayload(id: String) -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "id": id,
                "type": "message",
                "role": "assistant",
                "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "output"]],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull()
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": "turn-teardown-session"
        ]
    }

    func testShutdownClearsInterruptMarkerSoALaterResultIsNotMisreportedAsCancelled() async throws {
        let controller = try makeController()
        await controller.test_setTurnWasInterrupted(true)
        await controller.shutdown()

        let status = await controller.test_determineTurnStatus(payload: ["type": "result"])
        guard case .completed = status else {
            return XCTFail(
                "A successful result must not inherit the previous session's interrupt marker; got \(status)."
            )
        }
    }
}
