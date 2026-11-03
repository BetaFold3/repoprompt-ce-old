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
    private func makeController(
        authoritativeTurnIdleFallbackSeconds: TimeInterval = 1.0
    ) throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            mcpHost: ServerNetworkManager.shared,
            authoritativeTurnIdleFallbackSeconds: authoritativeTurnIdleFallbackSeconds
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

    // MARK: - Step 12: completion origin

    private typealias Completion = (
        turnID: UUID,
        status: ClaudeNativeProcessSessionController.TurnStatus,
        origin: ClaudeNativeProcessSessionController.TurnCompletionOrigin
    )

    /// The next turn completion on `events`, skipping stream output; nil when the stream ended.
    private func nextCompletion(
        _ events: inout AsyncStream<ClaudeNativeProcessSessionController.Event>.Iterator
    ) async -> Completion? {
        while let event = await events.next() {
            if case let .turnCompleted(turnID, status, origin) = event {
                return (turnID, status, origin)
            }
        }
        return nil
    }

    private static func interruptedResultPayload() -> [String: Any] {
        ["type": "result", "subtype": "error_during_execution", "is_error": true, "session_id": "turn-teardown-session"]
    }

    private typealias Origin = ClaudeNativeProcessSessionController.TurnCompletionOrigin

    /// `payload` with the CLI's consumed-user attribution naming exactly `outbound`.
    private static func attributed(_ payload: [String: Any], to outbound: UUID) -> [String: Any] {
        payload.merging([
            "user_message_uuid": outbound.uuidString.lowercased(),
            "user_message_uuids": [outbound.uuidString.lowercased()]
        ]) { $1 }
    }

    private static func providerResult(
        sole: Bool,
        interrupted: Bool,
        identity: Origin.MessageIdentity = .notReported
    ) -> Origin {
        .providerResult(.init(soleOutstandingTurn: sole, reportsInterruption: interrupted, messageIdentity: identity))
    }

    /// Step 12: an interrupted turn's own CLI result (naming its outbound UUID) is exclusive
    /// provider evidence only while that turn is the controller's sole outstanding written turn.
    /// With a skipped message ahead of a fresh one (FIFO [phantom, fresh]), the cancelled result is
    /// attributed to the phantom and is not exclusive. Same in immediate and deferred (`idle`)
    /// completion.
    func testInterruptedResultIsExclusiveProviderEvidenceOnlyForTheSoleOutstandingTurn() async throws {
        for deferred in [false, true] {
            let controller = try makeController()
            var events = await controller.eventsSubscription().events.makeAsyncIterator()
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("running"))
            }

            let soleOutbound = UUID()
            let sole = await controller.test_beginTurnTracking(outboundUserMessageUUID: soleOutbound)
            await controller.test_setTurnWasInterrupted(true)
            await controller.test_handleStreamPayload(Self.attributed(Self.interruptedResultPayload(), to: soleOutbound))
            // A later write (the steer's own message) does not change the result's origin.
            let steer = await controller.test_beginTurnTracking()
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let soleCompletion = await nextCompletion(&events)
            XCTAssertEqual(soleCompletion?.turnID, sole, "deferred=\(deferred)")
            XCTAssertEqual(soleCompletion?.status, .cancelled, "deferred=\(deferred)")
            XCTAssertEqual(
                soleCompletion?.origin,
                Self.providerResult(sole: true, interrupted: true, identity: .namesTurn),
                "deferred=\(deferred)"
            )
            XCTAssertTrue(soleCompletion?.origin.isExclusiveInterruptedResult == true, "deferred=\(deferred)")

            // The steer's own result closes it; then a skipped phantom ahead of a fresh message.
            await controller.test_handleStreamPayload(Self.realisticResultPayload())
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let steerCompletion = await nextCompletion(&events)
            XCTAssertEqual(steerCompletion?.turnID, steer, "deferred=\(deferred)")
            XCTAssertEqual(steerCompletion?.origin, Self.providerResult(sole: true, interrupted: false), "deferred=\(deferred)")

            let phantom = await controller.test_beginTurnTracking()
            let fresh = await controller.test_beginTurnTracking()
            await controller.test_setTurnWasInterrupted(true)
            await controller.test_handleStreamPayload(Self.interruptedResultPayload())
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let shared = await nextCompletion(&events)
            XCTAssertEqual(shared?.turnID, phantom, "deferred=\(deferred): FIFO credits the head")
            XCTAssertEqual(shared?.status, .cancelled, "deferred=\(deferred)")
            XCTAssertEqual(shared?.origin, Self.providerResult(sole: false, interrupted: true), "deferred=\(deferred)")
            XCTAssertFalse(shared?.origin.isExclusiveInterruptedResult ?? true, "deferred=\(deferred)")
            XCTAssertNotEqual(shared?.turnID, fresh)
            await controller.shutdown()
        }
    }

    /// Step 12 (P1-B): the order the steer produces matters. If the steer writes its own message
    /// after the interrupt acknowledgement (the controller has set its interrupt marker) but before
    /// the interrupted turn's result, that result finds two outstanding turns and is never exclusive.
    /// Only result-before-write, which the coordinator's bounded wait produces, is exclusive.
    func testAcknowledgementThenSteerWriteThenResultIsNotExclusiveButResultBeforeTheWriteIs() async throws {
        for deferred in [false, true] {
            let controller = try makeController()
            var events = await controller.eventsSubscription().events.makeAsyncIterator()
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("running"))
            }

            // Acknowledgement, then the steer's write, then the interrupted turn's result.
            let interruptedOutbound = UUID()
            let interrupted = await controller.test_beginTurnTracking(outboundUserMessageUUID: interruptedOutbound)
            await controller.test_setTurnWasInterrupted(true)
            let steer = await controller.test_beginTurnTracking()
            await controller.test_handleStreamPayload(Self.attributed(Self.interruptedResultPayload(), to: interruptedOutbound))
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let writeFirst = await nextCompletion(&events)
            XCTAssertEqual(writeFirst?.turnID, interrupted, "deferred=\(deferred)")
            XCTAssertEqual(writeFirst?.status, .cancelled, "deferred=\(deferred)")
            XCTAssertEqual(
                writeFirst?.origin,
                Self.providerResult(sole: false, interrupted: true, identity: .namesTurn),
                "deferred=\(deferred): even its own attribution cannot make a shared FIFO exclusive"
            )
            XCTAssertFalse(writeFirst?.origin.isExclusiveInterruptedResult ?? true, "deferred=\(deferred)")
            await controller.test_handleStreamPayload(Self.realisticResultPayload())
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let steerCompletion = await nextCompletion(&events)
            XCTAssertEqual(steerCompletion?.turnID, steer, "deferred=\(deferred)")

            // Acknowledgement, then the result, then the steer's write (the held steer).
            let heldOutbound = UUID()
            let held = await controller.test_beginTurnTracking(outboundUserMessageUUID: heldOutbound)
            await controller.test_setTurnWasInterrupted(true)
            await controller.test_handleStreamPayload(Self.attributed(Self.interruptedResultPayload(), to: heldOutbound))
            let inFlightAfterResult = await controller.hasTurnInFlight
            XCTAssertEqual(inFlightAfterResult, deferred, "deferred=\(deferred): immediate mode ends the turn at its result")
            _ = await controller.test_beginTurnTracking()
            if deferred {
                await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
            }
            let resultFirst = await nextCompletion(&events)
            XCTAssertEqual(resultFirst?.turnID, held, "deferred=\(deferred)")
            XCTAssertEqual(
                resultFirst?.origin,
                Self.providerResult(sole: true, interrupted: true, identity: .namesTurn),
                "deferred=\(deferred)"
            )
            XCTAssertTrue(resultFirst?.origin.isExclusiveInterruptedResult == true, "deferred=\(deferred)")
            await controller.shutdown()
        }
    }

    /// Step 12 (P1-A): after an acknowledged interrupt the sticky marker classifies whatever result
    /// comes next as `.cancelled`. Only a result whose payload itself reports an interruption is
    /// exclusive evidence; a `success` result (an ordinary, background-continuation or replayed
    /// turn) never is, even as the sole outstanding turn whose outbound UUID it names.
    func testOnlyAResultThatItselfReportsAnInterruptionIsExclusiveEvidence() async throws {
        let cases: [(label: String, payload: [String: Any], reportsInterruption: Bool)] = [
            ("background continuation success", Self.realisticResultPayload(), false),
            ("bare success", ["type": "result", "subtype": "success", "is_error": false], false),
            ("success naming a cancel reason", ["type": "result", "subtype": "success", "stop_reason": "cancelled"], false),
            ("max turns error", ["type": "result", "subtype": "error_max_turns", "is_error": true], false),
            ("error during execution", Self.interruptedResultPayload(), true),
            (
                "aborted streaming",
                ["type": "result", "subtype": "error_during_execution", "is_error": true, "terminal_reason": "aborted_streaming"],
                true
            ),
            ("interrupt errors", ["type": "result", "subtype": "error", "errors": ["Request was aborted."]], true)
        ]
        for testCase in cases {
            let controller = try makeController()
            var events = await controller.eventsSubscription().events.makeAsyncIterator()
            let outbound = UUID()
            let turn = await controller.test_beginTurnTracking(outboundUserMessageUUID: outbound)
            await controller.test_setTurnWasInterrupted(true)
            await controller.test_handleStreamPayload(Self.attributed(testCase.payload, to: outbound))
            let completion = await nextCompletion(&events)
            XCTAssertEqual(completion?.turnID, turn, testCase.label)
            XCTAssertEqual(completion?.status, .cancelled, "\(testCase.label): the sticky marker still classifies it cancelled")
            XCTAssertEqual(
                completion?.origin,
                Self.providerResult(sole: true, interrupted: testCase.reportsInterruption, identity: .namesTurn),
                testCase.label
            )
            XCTAssertEqual(completion?.origin.isExclusiveInterruptedResult, testCase.reportsInterruption, testCase.label)
            await controller.shutdown()
        }
    }

    /// Step 12 (P1-A, final): exclusive evidence requires the result's own consumed-user attribution
    /// to name exactly the outbound UUID the credited turn was written with. Absent or null
    /// attribution (an unattributed `error_during_execution`, for example an aborted background
    /// continuation or an API failure), any other attribution, and a turn written without an
    /// outbound UUID never qualify.
    func testResultAttributionMustNameTheCreditedTurnsOutboundUUID() async throws {
        let outbound = UUID()
        let other = UUID()
        let cases: [(label: String, written: UUID?, attribution: [String: Any], identity: Origin.MessageIdentity)] = [
            ("names the turn", outbound, [
                "user_message_uuid": outbound.uuidString.lowercased(),
                "user_message_uuids": [outbound.uuidString.lowercased()]
            ], .namesTurn),
            ("absent", outbound, [:], .notReported),
            ("null", outbound, ["user_message_uuid": NSNull(), "user_message_uuids": NSNull()], .notReported),
            ("names another message", outbound, ["user_message_uuid": other.uuidString], .contradictsTurn),
            ("list names two", outbound, ["user_message_uuids": [outbound.uuidString, other.uuidString]], .contradictsTurn),
            ("single agrees, list disagrees", outbound, [
                "user_message_uuid": outbound.uuidString,
                "user_message_uuids": [other.uuidString]
            ], .contradictsTurn),
            ("turn written without a UUID", nil, ["user_message_uuid": other.uuidString], .contradictsTurn),
            ("turn written without a UUID, unattributed result", nil, [:], .notReported)
        ]
        for testCase in cases {
            let controller = try makeController()
            var events = await controller.eventsSubscription().events.makeAsyncIterator()
            let turn = await controller.test_beginTurnTracking(outboundUserMessageUUID: testCase.written)
            await controller.test_setTurnWasInterrupted(true)
            await controller.test_handleStreamPayload(Self.interruptedResultPayload().merging(testCase.attribution) { $1 })
            let completion = await nextCompletion(&events)
            XCTAssertEqual(completion?.turnID, turn, testCase.label)
            XCTAssertEqual(
                completion?.origin,
                Self.providerResult(sole: true, interrupted: true, identity: testCase.identity),
                testCase.label
            )
            XCTAssertEqual(completion?.origin.isExclusiveInterruptedResult, testCase.identity == .namesTurn, testCase.label)
            await controller.shutdown()
        }
    }

    /// Step 12 (deferred mode): a surplus result processed while an earlier result still waits for
    /// `idle` is never exclusive, even though only one turn is queued, so it cannot bind at a later
    /// `idle` to a turn written afterwards as exclusive evidence.
    func testDeferredSurplusResultIsNotExclusiveForALaterTurn() async throws {
        let controller = try makeController(authoritativeTurnIdleFallbackSeconds: 60)
        var events = await controller.eventsSubscription().events.makeAsyncIterator()
        await controller.test_handleStreamPayload(Self.sessionStatePayload("running"))
        let first = await controller.test_beginTurnTracking()
        await controller.test_handleStreamPayload(Self.realisticResultPayload())
        // A second result while the first still waits for `idle`: one turn queued, one completion pending.
        await controller.test_setTurnWasInterrupted(true)
        await controller.test_handleStreamPayload(Self.interruptedResultPayload())
        let later = await controller.test_beginTurnTracking()
        await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
        await controller.test_handleStreamPayload(Self.sessionStatePayload("idle"))
        let firstCompletion = await nextCompletion(&events)
        XCTAssertEqual(firstCompletion?.turnID, first)
        let surplus = await nextCompletion(&events)
        XCTAssertEqual(surplus?.turnID, later, "FIFO credits the surplus result to the later turn")
        XCTAssertEqual(surplus?.origin, Self.providerResult(sole: false, interrupted: true))
        XCTAssertFalse(surplus?.origin.isExclusiveInterruptedResult ?? true)
        await controller.shutdown()
    }

    /// Step 12: completions the controller times itself are never provider-result evidence, even
    /// when they carry a cancelled status classified from a CLI result: the deferred idle-fallback
    /// timer, the shutdown flush of a deferred completion, and the stdout-EOF failure.
    func testControllerTimedCompletionsAreSynthesizedNotProviderResults() async throws {
        // Idle fallback: the CLI's `idle` never arrives.
        let fallback = try makeController(authoritativeTurnIdleFallbackSeconds: 0.05)
        var fallbackEvents = await fallback.eventsSubscription().events.makeAsyncIterator()
        await fallback.test_handleStreamPayload(Self.sessionStatePayload("running"))
        let fallbackTurn = await fallback.test_beginTurnTracking()
        await fallback.test_setTurnWasInterrupted(true)
        await fallback.test_handleStreamPayload(Self.interruptedResultPayload())
        let fallbackCompletion = await nextCompletion(&fallbackEvents)
        XCTAssertEqual(fallbackCompletion?.turnID, fallbackTurn)
        XCTAssertEqual(fallbackCompletion?.status, .cancelled)
        XCTAssertEqual(fallbackCompletion?.origin, .controllerSynthesized, "timed by the fallback, not by the CLI")
        await fallback.shutdown()

        // Shutdown flush: the result arrived, `idle` did not, and the controller shut down.
        let flushed = try makeController(authoritativeTurnIdleFallbackSeconds: 60)
        var flushedEvents = await flushed.eventsSubscription().events.makeAsyncIterator()
        await flushed.test_handleStreamPayload(Self.sessionStatePayload("running"))
        let flushedTurn = await flushed.test_beginTurnTracking()
        await flushed.test_setTurnWasInterrupted(true)
        await flushed.test_handleStreamPayload(Self.interruptedResultPayload())
        await flushed.shutdown()
        let flushedCompletion = await nextCompletion(&flushedEvents)
        XCTAssertEqual(flushedCompletion?.turnID, flushedTurn)
        XCTAssertEqual(flushedCompletion?.status, .cancelled)
        XCTAssertEqual(flushedCompletion?.origin, .controllerSynthesized, "a shutdown flush is timed by the controller")

        // Stdout EOF: the process exited with the turn unresolved.
        let exited = try makeController()
        var exitedEvents = await exited.eventsSubscription().events.makeAsyncIterator()
        let launch = await exited.test_beginSyntheticUsageLaunch()
        let lostTurn = await exited.test_beginTurnTracking()
        await exited.test_handleStdoutEOF(launchToken: launch.token)
        let exitedCompletion = await nextCompletion(&exitedEvents)
        XCTAssertEqual(exitedCompletion?.turnID, lostTurn)
        XCTAssertEqual(exitedCompletion?.status, .failed)
        XCTAssertEqual(exitedCompletion?.origin, .controllerSynthesized)
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
