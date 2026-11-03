import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Formatted `agent_run` / `agent_explore` text after a parent steering wake ends a child wait
/// early (`wait.result == "interrupted_by_steering"`). The formatted text is all a parent model
/// sees, so it must say exactly once how to resume the same wait, targeting only sessions that
/// are still reported pending and are not already finished or awaiting input.
@MainActor
final class ToolOutputFormatterAgentRunSteeringWaitTests: XCTestCase {
    private static let resumeHeading = "### Resume waiting"
    private static let steeringStatusText = "Wait interrupted by a new steering instruction; the agent run is still running."
    private static let canonicalNote = "Steering interrupted this wait; the agent run has not completed. After responding to the user, call agent_run.wait for this session again to resume waiting."

    func testSingleSteeringInterruptRendersOneToolCorrectSameSessionResume() throws {
        let sessionID = UUID()
        let value = Self.singleSteeringInterruptValue(sessionID: sessionID, status: "running")

        let runText = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: value))
        XCTAssertEqual(Self.occurrences(of: Self.resumeHeading, in: runText), 1)
        XCTAssertEqual(Self.occurrences(of: "`op=wait`", in: runText), 1)
        XCTAssertTrue(runText.contains(
            "After answering the user, if you still need this session's result, call `agent_run` with `op=wait` and `session_id=\"\(sessionID.uuidString)\"` to keep waiting on the same session. Do not `start` a new session or `steer` just to resume waiting."
        ))
        XCTAssertEqual(Self.occurrences(of: Self.steeringStatusText, in: runText), 1, "Existing status note stays, once")
        XCTAssertFalse(runText.contains(Self.canonicalNote), "Raw _meta.note / wait.instruction are not echoed")
        XCTAssertTrue(runText.contains("- Status: **Running**"))
        XCTAssertTrue(runText.contains("- Session ID: `\(sessionID.uuidString)`"))
        XCTAssertFalse(runText.lowercased().contains("cancel"))

        let exploreText = try Self.text(ToolOutputFormatter.formatAgentExplore(args: ["op": .string("wait")], value: value))
        XCTAssertEqual(Self.occurrences(of: Self.resumeHeading, in: exploreText), 1)
        XCTAssertTrue(exploreText.contains(
            "call `agent_explore` with `op=wait` and `session_id=\"\(sessionID.uuidString)\"`"
        ))
        XCTAssertFalse(exploreText.contains("agent_run"), "Explore output must not direct the caller to agent_run")
    }

    func testSingleSteeringInterruptDoesNotAdviseRewaitForTerminalOrInputSnapshot() throws {
        for status in ["completed", "failed", "cancelled", "expired"] {
            let value = Self.singleSteeringInterruptValue(sessionID: UUID(), status: status)
            let text = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: value))
            XCTAssertFalse(text.contains(Self.resumeHeading), "No rewait for a \(status) snapshot")
        }

        let sessionID = UUID()
        let interactionID = UUID()
        guard case var .object(waiting) = Self.singleSteeringInterruptValue(sessionID: sessionID, status: "waiting_for_input") else {
            return XCTFail("Expected object")
        }
        waiting["interaction_id"] = .string(interactionID.uuidString)
        waiting["interaction"] = .object([
            "id": .string(interactionID.uuidString),
            "kind": .string("approval"),
            "prompt": .string("Allow ls?")
        ])
        let waitingText = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: .object(waiting)))
        XCTAssertFalse(waitingText.contains(Self.resumeHeading))
        XCTAssertTrue(waitingText.contains("### How to respond"))

        guard case var .object(runningWithInteraction) = Self.singleSteeringInterruptValue(sessionID: sessionID, status: "running") else {
            return XCTFail("Expected object")
        }
        runningWithInteraction["interaction"] = .object(["id": .string(interactionID.uuidString), "kind": .string("approval")])
        let interactionText = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: .object(runningWithInteraction)))
        XCTAssertFalse(interactionText.contains(Self.resumeHeading))
    }

    func testMultiSteeringInterruptTargetsFilteredPendingSessionsAndHandlesReadyFirst() throws {
        let interruptedID = UUID()
        let missingID = UUID()
        let completedID = UUID()
        let waitingID = UUID()
        let field = AgentRunMCPSnapshot.Interaction.Field(
            id: "target", header: nil, prompt: "Which target?", context: nil, isSecret: false,
            allowsOther: false, allowsMultiple: false, allowsCustom: false, emitAllowsOther: false,
            options: [.init(label: "staging", description: nil)]
        )
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: UUID(), kind: .question, responseType: .structured, title: nil,
            prompt: "Which target?", context: nil, allowsMultiple: nil,
            options: [], fields: [field], details: []
        )
        let value = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [interruptedID, missingID, completedID, waitingID],
            snapshots: [
                Self.snapshot(interruptedID, .running),
                Self.snapshot(completedID, .completed, preview: "Finished output"),
                Self.snapshot(waitingID, .waitingForInput, interaction: interaction)
            ],
            // A caller-supplied pending list may still name a session whose snapshot settled and
            // may repeat ids; immediate rewait targets must filter settled ids and dedupe in order.
            pendingSessionIDs: [missingID, completedID, interruptedID, missingID],
            interruptedSessionID: interruptedID
        )

        let text = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: value))
        XCTAssertTrue(text.contains("- Result: **wait interrupted by steering** (the wait ended early; this is not a session result)"))
        XCTAssertFalse(text.contains("- Result: `interrupted_by_steering`"))
        XCTAssertEqual(Self.occurrences(of: Self.resumeHeading, in: text), 1)
        XCTAssertTrue(text.contains(
            "Handle these first (finished or needs input): `\(completedID.uuidString)` (Completed), `\(waitingID.uuidString)` (Waiting For Input). If their results are not shown above, call `agent_run` with `op=poll` and `session_ids=[\"\(completedID.uuidString)\", \"\(waitingID.uuidString)\"]`."
        ))
        XCTAssertTrue(text.contains(
            "After answering the user, if you still need them, call `agent_run` with `op=wait` and `session_ids=[\"\(missingID.uuidString)\", \"\(interruptedID.uuidString)\"]` to resume waiting on the sessions reported pending."
        ))
        XCTAssertFalse(text.contains("all sessions are still running"))
        XCTAssertFalse(text.contains("No session was cancelled"))
        XCTAssertFalse(text.contains(Self.canonicalNote))
        // Existing nested input-request content and the raw pending line are preserved
        // alongside the filtered reminder.
        XCTAssertTrue(text.contains("- Additional result: `\(waitingID.uuidString)` — **Waiting For Input**"))
        XCTAssertTrue(text.contains("`op=respond`, `session_id=\"\(waitingID.uuidString)\"`, `interaction_id=\"\(interaction.id.uuidString)\"`"))
        XCTAssertTrue(text.contains("- Pending: `\(missingID.uuidString)`, `\(completedID.uuidString)`"))

        let exploreText = try Self.text(ToolOutputFormatter.formatAgentExplore(args: ["op": .string("wait")], value: value))
        XCTAssertTrue(exploreText.contains("call `agent_explore` with `op=wait` and `session_ids=["))
        XCTAssertTrue(exploreText.contains("call `agent_explore` with `op=poll` and `session_ids=["))
        XCTAssertFalse(exploreText.contains("`agent_run`"))
    }

    func testMultiSteeringInterruptSinglePendingTargetIsNotTheRepresentative() throws {
        let interruptedID = UUID()
        let siblingID = UUID()
        // Production can keep a running trigger as the top-level representative while its fresh
        // aggregate snapshot is terminal; only the reported pending sibling is a rewait target.
        let value = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [interruptedID, siblingID],
            representativeSnapshot: Self.snapshot(interruptedID, .running),
            snapshots: [Self.snapshot(interruptedID, .completed), Self.snapshot(siblingID, .running)],
            pendingSessionIDs: [siblingID],
            interruptedSessionID: interruptedID
        )
        let text = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: value))
        XCTAssertTrue(text.contains("call `agent_run` with `op=wait` and `session_id=\"\(siblingID.uuidString)\"`"))
        XCTAssertFalse(text.contains("`op=wait` and `session_id=\"\(interruptedID.uuidString)\"`"))
        XCTAssertTrue(text.contains(
            "Handle these first (finished or needs input): `\(interruptedID.uuidString)` (Completed). If their results are not shown above, call `agent_run` with `op=poll` and `session_id=\"\(interruptedID.uuidString)\"`."
        ))
    }

    func testMultiSteeringInterruptWithoutEligiblePendingKeepsOnlyReadyResultsGuidance() throws {
        let completedID = UUID()
        let value = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [completedID],
            snapshots: [Self.snapshot(completedID, .completed)],
            pendingSessionIDs: [completedID],
            interruptedSessionID: completedID
        )
        let text = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: value))
        XCTAssertTrue(text.contains("- Result: **wait interrupted by steering**"))
        XCTAssertFalse(text.contains(Self.resumeHeading))
        XCTAssertFalse(text.contains("`op=wait`"))
        XCTAssertEqual(Self.occurrences(of: "### Ready results", in: text), 1)
        XCTAssertTrue(text.contains(
            "Handle these (finished or needs input): `\(completedID.uuidString)` (Completed). If their results are not shown above, call `agent_run` with `op=poll` and `session_id=\"\(completedID.uuidString)\"`."
        ))

        let exploreText = try Self.text(ToolOutputFormatter.formatAgentExplore(args: ["op": .string("wait")], value: value))
        XCTAssertTrue(exploreText.contains("call `agent_explore` with `op=poll` and `session_id=\"\(completedID.uuidString)\"`"))
        XCTAssertFalse(exploreText.contains("`op=wait`"))
        XCTAssertFalse(exploreText.contains("agent_run"))

        // Nothing ready and nothing pending: no readiness or resume section at all.
        let empty = AgentRunMCPToolService.test_decoratedMultiWaitInterruptValue(
            sessionIDs: [completedID],
            snapshots: [],
            pendingSessionIDs: [],
            interruptedSessionID: completedID
        )
        let emptyText = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: empty))
        XCTAssertFalse(emptyText.contains("### Ready results"))
        XCTAssertFalse(emptyText.contains(Self.resumeHeading))
    }

    func testNonSteeringResultsRenderNoResumeGuidance() throws {
        let sessionID = UUID()
        let siblingID = UUID()
        let plainRunning: Value = .object(Self.snapshot(sessionID, .running).asObject())
        var steeringMetaOnly = Self.snapshot(sessionID, .running).asObject()
        steeringMetaOnly["_meta"] = .object(["wake_reason": .string("steering_requested")])
        var cancelled = Self.snapshot(sessionID, .cancelled).asObject()
        cancelled["wait"] = .object(["result": .string("cancelled")])
        var delegated = Self.snapshot(sessionID, .running).asObject()
        delegated["wait"] = .object([
            "result": .string(AgentDelegatedQuestionNoticeWire.agentRunWaitResult),
            "instruction": .string("Woken early: another child agent is waiting for your answer.")
        ])
        let multiResults = ["snapshot_ready", "timed_out", "expired", "superseded", AgentDelegatedQuestionNoticeWire.agentRunWaitResult]
        let multiValues: [Value] = multiResults.map { result in
            var object = Self.snapshot(sessionID, .running).asObject()
            object["wait"] = .object([
                "mode": .string("any"),
                "result": .string(result),
                "waited_count": .int(2),
                "pending_session_ids": .array([.string(siblingID.uuidString)])
            ])
            object["snapshots"] = .array([.object(Self.snapshot(siblingID, .running).asObject())])
            return .object(object)
        }

        for value in [plainRunning, .object(steeringMetaOnly), .object(cancelled), .object(delegated)] + multiValues {
            for op in ["wait", "poll", "start"] {
                let runText = try Self.text(ToolOutputFormatter.formatAgentRun(args: ["op": .string(op)], value: value))
                let exploreText = try Self.text(ToolOutputFormatter.formatAgentExplore(args: ["op": .string(op)], value: value))
                XCTAssertFalse(runText.contains(Self.resumeHeading), runText)
                XCTAssertFalse(exploreText.contains(Self.resumeHeading), exploreText)
                XCTAssertFalse(runText.contains("### Ready results"), runText)
                XCTAssertFalse(exploreText.contains("### Ready results"), exploreText)
                XCTAssertFalse(runText.contains("wait interrupted by steering"))
            }
        }
    }

    // MARK: - Fixtures

    /// Mirrors the final decorated single-wait shape (`decoratedRunValue` with a steering wake
    /// plus merged raw `_meta`); the real service bridge is covered by the drain integration test.
    private static func singleSteeringInterruptValue(sessionID: UUID, status: String) -> Value {
        .object([
            "session_id": .string(sessionID.uuidString),
            "status": .string(status),
            "status_text": .string(steeringStatusText),
            "session": .object(["id": .string(sessionID.uuidString), "name": .string("Child Agent")]),
            "_meta": .object([
                "wake_reason": .string("steering_requested"),
                "note": .string(canonicalNote)
            ]),
            "wait": .object([
                "result": .string("interrupted_by_steering"),
                "instruction": .string(canonicalNote)
            ])
        ])
    }

    private static func snapshot(
        _ sessionID: UUID,
        _ status: AgentRunMCPSnapshot.Status,
        preview: String? = nil,
        interaction: AgentRunMCPSnapshot.Interaction? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: preview,
            interaction: interaction,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func text(_ blocks: [MCP.Tool.Content]) throws -> String {
        XCTAssertEqual(blocks.count, 1)
        guard case let .text(text, _, _) = try XCTUnwrap(blocks.first) else {
            XCTFail("Expected a text block")
            return ""
        }
        return text
    }
}
