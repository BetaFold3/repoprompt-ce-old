import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Step 4d3b (inactive, default-off): the producer-owned classifier of Claude live output and the
/// native controller's monotonic qualification latch. Fixtures mirror the allowlisted O19 live shapes
/// recorded in the Phase 4d3 evidence notes (one dispatched turn: replayed user message, one
/// single-text assistant envelope, success result). Fixture-backed only: this is not qualification
/// of Claude's live format.
final class ClaudeLiveTranscriptQualificationTests: XCTestCase {
    private typealias State = ClaudeLiveTranscriptProducerState

    private let session = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let prompt = "Reply with exactly: ALPHA-7"
    private let reply = "ALPHA-7"

    // MARK: Payload fixtures

    private func systemInit() -> [String: Any] {
        ["type": "system", "subtype": "init", "session_id": session, "claude_code_version": "2.1.268", "tools": [], "uuid": UUID().uuidString]
    }

    private func lifecycle(_ state: String) -> [String: Any] {
        ["type": "command_lifecycle", "command_uuid": UUID().uuidString, "session_id": session, "state": state, "uuid": UUID().uuidString]
    }

    private func rateLimit(status: String = "allowed") -> [String: Any] {
        [
            "type": "rate_limit_event",
            "session_id": session,
            "uuid": UUID().uuidString,
            "rate_limit_info": ["status": status, "rateLimitType": "five_hour", "resetsAt": 1_800_000_000, "isUsingOverage": false]
        ]
    }

    private func replay(_ outbound: UUID, text: String? = nil) -> [String: Any] {
        [
            "type": "user",
            "isReplay": true,
            "message": ["role": "user", "content": text ?? prompt],
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "timestamp": "2026-10-23T00:00:00.000Z",
            "uuid": outbound.uuidString.lowercased()
        ]
    }

    /// `attributedTo`: the consumed-user attribution the current app's (no-replay) output carries.
    private func assistant(
        entry: String = "a1",
        content: [[String: Any]]? = nil,
        text: String? = nil,
        attributedTo outbound: UUID? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": "msg_\(entry)",
                "type": "message",
                "role": "assistant",
                "model": "claude-sonnet-5",
                "content": content ?? [["type": "text", "text": text ?? reply]],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 4, "output_tokens": 3]
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "request_id": "req_\(entry)",
            "uuid": entry
        ]
        if let outbound { attribute(&payload, to: outbound) }
        return payload
    }

    private func attribute(_ payload: inout [String: Any], to outbound: UUID) {
        payload["user_message_uuid"] = outbound.uuidString.lowercased()
        payload["user_message_uuids"] = [outbound.uuidString.lowercased()]
    }

    /// `attributedTo`: the current app's success result (attribution plus its terminal markers).
    private func result(
        _ text: String? = nil,
        subtype: String = "success",
        isError: Bool = false,
        attributedTo outbound: UUID? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "result", "subtype": subtype, "is_error": isError, "result": text ?? reply, "session_id": session,
            "uuid": UUID().uuidString, "num_turns": 1, "permission_denials": [],
            "usage": ["input_tokens": 4, "output_tokens": 3]
        ]
        if let outbound {
            attribute(&payload, to: outbound)
            payload["terminal_reason"] = "completed"
            payload["stop_reason"] = "end_turn"
            payload["safety_stops"] = 0
        }
        return payload
    }

    private func data(_ payload: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: payload)
    }

    private func content(_ text: String) -> AIStreamResult {
        AIStreamResult(type: "content", text: text)
    }

    private func eligibleState(token: UUID = UUID()) -> State {
        var state = State(launchToken: token)
        state.markEligible()
        return state
    }

    /// Drives the benign prefix of one O19 turn up to the replay.
    private func replayed(_ state: inout State, outbound: UUID = UUID()) {
        for payload in [systemInit(), lifecycle("queued"), rateLimit()] {
            XCTAssertEqual(state.classify(envelope: data(payload), translated: [], turnInFlight: false), .benign)
        }
        state.noteOutbound(uuid: outbound, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(lifecycle("started")), translated: [], turnInFlight: true), .benign)
        XCTAssertEqual(state.classify(envelope: data(replay(outbound)), translated: [], turnInFlight: true), .benign)
    }

    private func disqualification(_ outcome: ClaudeLiveTranscriptOutcome) -> ClaudeLiveTranscriptDisqualification? {
        guard case let .standalone(evidence) = outcome, case let .disqualified(reason) = evidence.kind else { return nil }
        return reason
    }

    // MARK: Pure classifier

    /// The O19 turn attaches exactly once to the envelope's one `content` result, with the history
    /// reader's deterministic ID and complete-envelope proof; the success result agrees; a second
    /// dispatched turn qualifies the same way.
    func testO19TurnAttachesOnceWithTheReadersIdentityAndResultAgrees() throws {
        let token = UUID()
        var state = eligibleState(token: token)
        replayed(&state)
        let usage = AIStreamResult(type: "usage", text: nil)
        let outcome = state.classify(envelope: data(assistant()), translated: [usage, content(reply)], turnInFlight: true)
        guard case let .attach(index, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("expected an attachment, got \(outcome)")
        }
        XCTAssertEqual(index, 1, "the content result, never the usage companion")
        XCTAssertEqual(evidence.producerLaunchToken, token)
        let row = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: session, nativeEntryID: "a1", text: reply))
        XCTAssertEqual(complete.localItemID, row.localItemID)
        XCTAssertEqual(complete.envelopeDigest, row.envelopeDigest)
        XCTAssertEqual(complete.nativeSessionID, session)
        XCTAssertEqual(complete.nativeEntryID, "a1")
        XCTAssertEqual(complete.text, reply)
        XCTAssertEqual(complete.ledgerItem.key, complete.ledgerKey)
        XCTAssertEqual(complete.ledgerItem.envelopeDigest, row.envelopeDigest)
        XCTAssertEqual(complete.ledgerItem.localItemID, row.localItemID)
        let item = try XCTUnwrap(complete.canonicalItem)
        XCTAssertEqual(item.id, complete.localItemID)
        XCTAssertEqual(item.kind, .assistant)
        XCTAssertEqual(item.text, reply)
        XCTAssertFalse(item.isStreaming)

        let agreement = state.classify(envelope: data(result()), translated: [], turnInFlight: true)
        XCTAssertEqual(agreement, .standalone(.init(producerLaunchToken: token, kind: .resultAgreement(localItemID: complete.localItemID, text: reply))))
        XCTAssertEqual(state.classify(envelope: data(lifecycle("completed")), translated: [], turnInFlight: false), .benign)

        // A later dispatched turn of the same producer.
        let next = UUID()
        state.noteOutbound(uuid: next, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(replay(next)), translated: [], turnInFlight: true), .benign)
        guard case .attach = state.classify(envelope: data(assistant(entry: "a2")), translated: [content(reply)], turnInFlight: true) else {
            return XCTFail("the second turn qualifies")
        }
        XCTAssertNil(state.disqualification)
    }

    /// Every unrecognized, unsupported or contradicting payload disqualifies, including payloads whose
    /// translated results are empty or would be suppressed.
    func testUnsupportedShapesDisqualifyWithTheirReason() {
        typealias Case = (String, ClaudeLiveTranscriptDisqualification, (inout State) -> ClaudeLiveTranscriptOutcome)
        let cases: [Case] = [
            ("unknown type, empty translation", .unsupportedPayload, { state in
                state.classify(envelope: self.data(["type": "stream_event", "session_id": self.session, "event": [:]]), translated: [], turnInFlight: true)
            }),
            ("suppressed system task", .unsupportedPayload, { state in
                state.classify(
                    envelope: self.data(["type": "system", "subtype": "task_started", "session_id": self.session, "task_id": "t1"]),
                    translated: [AIStreamResult(type: "system", text: "Task started: t1")],
                    turnInFlight: true
                )
            }),
            ("compact boundary", .unsupportedPayload, { state in
                state.classify(envelope: self.data(["type": "system", "subtype": "compact_boundary", "session_id": self.session]), translated: [], turnInFlight: true)
            }),
            ("lifecycle state", .unsupportedLifecycle, { state in
                state.classify(envelope: self.data(self.lifecycle("failed")), translated: [], turnInFlight: true)
            }),
            ("lifecycle extra key", .unsupportedLifecycle, { state in
                var payload = self.lifecycle("queued")
                payload["error"] = "x"
                return state.classify(envelope: self.data(payload), translated: [], turnInFlight: true)
            }),
            ("rate limit status", .unsupportedRateLimit, { state in
                state.classify(envelope: self.data(self.rateLimit(status: "rejected")), translated: [], turnInFlight: true)
            }),
            ("semantic marker", .semanticMarker, { state in
                var payload = self.assistant()
                payload["supersedes"] = "a0"
                return state.classify(envelope: self.data(payload), translated: [self.content(self.reply)], turnInFlight: true)
            }),
            ("session mismatch", .sessionMismatch, { state in
                var payload = self.lifecycle("completed")
                payload["session_id"] = "other"
                return state.classify(envelope: self.data(payload), translated: [], turnInFlight: true)
            }),
            ("replay of another message", .unsupportedUserReplay, { state in
                state.classify(envelope: self.data(self.replay(UUID())), translated: [], turnInFlight: true)
            }),
            ("tool use block", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "tool_use", "id": "t", "name": "Read", "input": [:]]])),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("redacted thinking block", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "redacted_thinking", "data": "x"]])),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("thinking block with an extra key", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "thinking", "thinking": "x", "citations": []]])),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("thinking with a translated row", .translationMismatch, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "thinking", "thinking": "x", "signature": "s"]])),
                    translated: [AIStreamResult(type: "reasoning", text: nil)],
                    turnInFlight: true
                )
            }),
            ("thinking attributed to another message", .attributionMismatch, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "thinking", "thinking": "x", "signature": "s"]], attributedTo: UUID())),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("multiblock", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "text", "text": "A"], ["type": "text", "text": "B"]])),
                    translated: [self.content("A"), self.content("B")],
                    turnInFlight: true
                )
            }),
            ("non-null stop reason", .unsupportedAssistant, { state in
                var payload = self.assistant()
                var message = payload["message"] as! [String: Any]
                message["stop_reason"] = "end_turn"
                payload["message"] = message
                return state.classify(envelope: self.data(payload), translated: [self.content(self.reply)], turnInFlight: true)
            }),
            ("translation without the text", .translationMismatch, { state in
                state.classify(envelope: self.data(self.assistant()), translated: [], turnInFlight: true)
            }),
            ("no owned dispatch", .unownedAssistant, { state in
                state.classify(envelope: self.data(self.assistant()), translated: [self.content(self.reply)], turnInFlight: false)
            }),
            ("error result", .unsupportedResult, { state in
                state.classify(envelope: self.data(self.result(subtype: "error_during_execution", isError: true)), translated: [], turnInFlight: true)
            }),
            ("result before an answer", .resultTextMismatch, { state in
                state.classify(envelope: self.data(self.result()), translated: [], turnInFlight: true)
            }),
            ("malformed payload", .malformedPayload, { state in
                state.classify(envelope: Data("[1]".utf8), translated: [], turnInFlight: true)
            })
        ]
        for (name, reason, classify) in cases {
            var state = eligibleState()
            replayed(&state)
            XCTAssertEqual(disqualification(classify(&state)), reason, name)
            XCTAssertEqual(state.disqualification, reason, name)
        }

        // A result whose text differs from the qualified answer, and the outbound-side refusals.
        var state = eligibleState()
        replayed(&state)
        _ = state.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true)
        XCTAssertEqual(disqualification(state.classify(envelope: data(result("ALPHA-8")), translated: [], turnInFlight: true)), .resultTextMismatch)
        var unidentified = eligibleState()
        unidentified.noteOutbound(uuid: nil, text: prompt)
        XCTAssertEqual(unidentified.disqualification, .unidentifiedOutbound)
        var overlapping = eligibleState()
        overlapping.noteOutbound(uuid: UUID(), text: prompt)
        overlapping.noteOutbound(uuid: UUID(), text: "steer")
        XCTAssertEqual(overlapping.disqualification, .overlappingOutbound)
        // An assistant before the launch identity is known never qualifies.
        var pending = State(launchToken: UUID())
        pending.noteOutbound(uuid: UUID(), text: prompt)
        XCTAssertEqual(disqualification(pending.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true)), .unownedAssistant)
    }

    /// S1 (9-live round 2): a thinking-only envelope before the answer is benign and changes nothing
    /// (the history reader skips it the same way); the answer that follows, in the same API message,
    /// still attaches with the reader's identity and the success result agrees. A thinking envelope
    /// after the answer is still an unowned second assistant.
    func testAThinkingOnlyEnvelopeBeforeTheAnswerIsBenignAndTheAnswerStillQualifies() {
        let token = UUID()
        var state = eligibleState(token: token)
        let outbound = UUID()
        state.noteOutbound(uuid: outbound, text: prompt)
        let thinking = assistant(entry: "a1t", content: [["type": "thinking", "thinking": "x", "signature": "s"]], attributedTo: outbound)
        let usage = AIStreamResult(type: "usage", text: nil)
        XCTAssertEqual(state.classify(envelope: data(thinking), translated: [usage], turnInFlight: true), .benign)
        let unattributed = assistant(entry: "a1t", content: [["type": "thinking", "thinking": "y"]])
        XCTAssertEqual(state.classify(envelope: data(unattributed), translated: [], turnInFlight: true), .benign, "attribution and signature are optional")
        XCTAssertNil(state.disqualification)
        let outcome = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true)
        guard case let .attach(_, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("expected an attachment, got \(outcome)")
        }
        XCTAssertEqual(complete.nativeEntryID, "a1")
        XCTAssertEqual(complete.text, reply)
        XCTAssertTrue(complete.matchesProjection, "the reader's identity for the text entry, unaffected by the thinking entry")
        XCTAssertEqual(
            state.classify(envelope: data(result(attributedTo: outbound)), translated: [], turnInFlight: true),
            .standalone(.init(producerLaunchToken: token, kind: .resultAgreement(localItemID: complete.localItemID, text: reply)))
        )

        var answered = eligibleState()
        let next = UUID()
        answered.noteOutbound(uuid: next, text: prompt)
        _ = answered.classify(envelope: data(assistant(attributedTo: next)), translated: [content(reply)], turnInFlight: true)
        XCTAssertEqual(
            disqualification(answered.classify(envelope: data(thinking), translated: [], turnInFlight: true)),
            .unownedAssistant,
            "thinking after the answer is a second assistant"
        )
    }

    /// S1 round 1: the real CLI's thinking envelope (key names as recorded on K1/E7 stdout; values
    /// invented): every message key, null `container`/`context_management`/`diagnostics`/`stop_*`,
    /// empty `input_transformations`, plus top-level `thinking_display`/`thinking_duration_ms` and
    /// no consumed-user attribution.
    private func realThinkingEnvelope(entry: String = "a1t") -> [String: Any] {
        let message: [String: Any] = [
            "id": "msg_a1",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-5",
            "content": [["type": "thinking", "thinking": "fixture", "signature": "fixture-signature"]],
            "container": NSNull(),
            "context_management": NSNull(),
            "diagnostics": NSNull(),
            "input_transformations": [Any](),
            "stop_details": NSNull(),
            "stop_reason": NSNull(),
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 4, "output_tokens": 3]
        ]
        return [
            "type": "assistant",
            "message": message,
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "request_id": "req_a1",
            "timestamp": "2026-10-29T00:00:00.000Z",
            "thinking_display": "updates",
            "thinking_duration_ms": 1234,
            "uuid": entry
        ]
    }

    /// S1 round 1: the real thinking envelope's two extra keys are accepted, type-checked, on a
    /// thinking envelope only; the answer that follows still attaches.
    func testTheRealCLIThinkingEnvelopeIsBenignAndItsExtraKeysAreTypeCheckedOnThinkingOnly() {
        var state = eligibleState()
        let outbound = UUID()
        state.noteOutbound(uuid: outbound, text: prompt)
        XCTAssertEqual(
            state.classify(envelope: data(realThinkingEnvelope()), translated: [AIStreamResult(type: "usage", text: nil)], turnInFlight: true),
            .benign
        )
        let outcome = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true)
        guard case let .attach(_, evidence) = outcome, case .completeText = evidence.kind else {
            return XCTFail("expected an attachment, got \(outcome)")
        }

        let wrongTypes: [(String, String, Any)] = [
            ("numeric display", "thinking_display", 1),
            ("null display", "thinking_display", NSNull()),
            ("string duration", "thinking_duration_ms", "1234"),
            ("boolean duration", "thinking_duration_ms", true),
            ("negative duration", "thinking_duration_ms", -1)
        ]
        for (name, key, value) in wrongTypes {
            var envelope = realThinkingEnvelope()
            envelope[key] = value
            var refusing = eligibleState()
            refusing.noteOutbound(uuid: UUID(), text: prompt)
            XCTAssertEqual(
                disqualification(refusing.classify(envelope: data(envelope), translated: [], turnInFlight: true)),
                .unsupportedAssistant,
                name
            )
        }

        let textOwner = UUID()
        var text = assistant(attributedTo: textOwner)
        text["thinking_display"] = "updates"
        text["thinking_duration_ms"] = 1234
        var textOnly = eligibleState()
        textOnly.noteOutbound(uuid: textOwner, text: prompt)
        XCTAssertEqual(
            disqualification(textOnly.classify(envelope: data(text), translated: [content(reply)], turnInFlight: true)),
            .unsupportedAssistant,
            "the thinking keys are accepted on thinking envelopes only"
        )
    }

    /// The current app requests no user-message replay: an unreplayed dispatch qualifies only through
    /// affirmative consumed-user attribution naming exactly its outbound message (assistant and
    /// result), never a latest-message guess. Contradicting attribution refuses, replayed or not.
    func testUnreplayedDispatchQualifiesOnlyWithExactConsumedUserAttribution() {
        let token = UUID()
        var state = eligibleState(token: token)
        let outbound = UUID()
        XCTAssertEqual(state.classify(envelope: data(systemInit()), translated: [], turnInFlight: false), .benign)
        state.noteOutbound(uuid: outbound, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(lifecycle("started")), translated: [], turnInFlight: true), .benign)
        let outcome = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true)
        guard case let .attach(_, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("the current app shape qualifies, got \(outcome)")
        }
        XCTAssertEqual(
            state.classify(envelope: data(result(attributedTo: outbound)), translated: [], turnInFlight: true),
            .standalone(.init(producerLaunchToken: token, kind: .resultAgreement(localItemID: complete.localItemID, text: reply)))
        )
        XCTAssertNil(state.disqualification)

        typealias Case = (String, ClaudeLiveTranscriptDisqualification, Bool, (UUID) -> [String: Any])
        let other = UUID()
        let assistantCases: [Case] = [
            ("no replay and no attribution", .unattributedAssistant, false, { _ in self.assistant() }),
            ("another message", .attributionMismatch, false, { _ in self.assistant(attributedTo: other) }),
            ("replayed but contradicting", .attributionMismatch, true, { _ in self.assistant(attributedTo: other) }),
            ("user_message_uuid contradicting", .attributionMismatch, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                payload["user_message_uuid"] = other.uuidString
                return payload
            }),
            ("more than the singleton", .attributionMismatch, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                payload["user_message_uuids"] = [outbound.uuidString, other.uuidString]
                return payload
            }),
            ("nonempty input transformations", .unsupportedAssistant, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                var message = payload["message"] as? [String: Any] ?? [:]
                message["input_transformations"] = [["type": "x"]]
                payload["message"] = message
                return payload
            })
        ]
        for (name, reason, replay, makePayload) in assistantCases {
            var state = eligibleState()
            let outbound = UUID()
            state.noteOutbound(uuid: outbound, text: prompt)
            if replay {
                XCTAssertEqual(state.classify(envelope: data(self.replay(outbound)), translated: [], turnInFlight: true), .benign, name)
            }
            let outcome = state.classify(envelope: data(makePayload(outbound)), translated: [content(reply)], turnInFlight: true)
            XCTAssertEqual(disqualification(outcome), reason, name)
        }

        // Result markers and attribution: unknown keys and other values refuse.
        let resultCases: [(String, ClaudeLiveTranscriptDisqualification, (UUID) -> [String: Any])] = [
            ("contradicting attribution", .attributionMismatch, { _ in self.result(attributedTo: other) }),
            ("unknown key", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["compaction"] = true
                return payload
            }),
            ("terminal reason", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["terminal_reason"] = "max_turns"
                return payload
            }),
            ("stop reason", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["stop_reason"] = "max_tokens"
                return payload
            }),
            ("safety stops", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["safety_stops"] = 1
                return payload
            })
        ]
        for (name, reason, makePayload) in resultCases {
            var state = eligibleState()
            let outbound = UUID()
            state.noteOutbound(uuid: outbound, text: prompt)
            guard case .attach = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true) else {
                return XCTFail(name)
            }
            XCTAssertEqual(disqualification(state.classify(envelope: data(makePayload(outbound)), translated: [], turnInFlight: true)), reason, name)
        }

        // An unknown `system/init` key refuses.
        var initState = eligibleState()
        var unknownInit = systemInit()
        unknownInit["compact_metadata"] = true
        XCTAssertEqual(disqualification(initState.classify(envelope: data(unknownInit), translated: [], turnInFlight: false)), .unsupportedPayload)
    }

    /// Monotonic: once disqualified, a valid turn never qualifies again; the first reason sticks and is
    /// repeated only on user/assistant/result payloads.
    func testDisqualificationIsStickyAndNeverRequalifies() {
        let token = UUID()
        var state = eligibleState(token: token)
        XCTAssertEqual(disqualification(state.classify(envelope: data(["type": "mystery"]), translated: [], turnInFlight: false)), .unsupportedPayload)
        state.markEligible()
        for payload in [systemInit(), lifecycle("queued"), rateLimit(status: "rejected")] {
            XCTAssertEqual(state.classify(envelope: data(payload), translated: [], turnInFlight: false), .benign)
        }
        let outbound = UUID()
        state.noteOutbound(uuid: outbound, text: prompt)
        let sticky = ClaudeLiveTranscriptOutcome.standalone(.init(producerLaunchToken: token, kind: .disqualified(.unsupportedPayload)))
        XCTAssertEqual(state.classify(envelope: data(replay(outbound)), translated: [], turnInFlight: true), sticky)
        XCTAssertEqual(state.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true), sticky)
        XCTAssertEqual(state.classify(envelope: data(result()), translated: [], turnInFlight: true), sticky)
        XCTAssertEqual(state.disqualification, .unsupportedPayload)
    }

    // MARK: Native controller

    private func makeController(enabled: Bool) throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared,
            liveTranscriptQualificationEnabled: enabled
        )
    }

    /// Every stream result emitted since the last drain (a marker bounds the buffered stream).
    /// The controller's events subscription, read through the runtime protocol as the runner reads it
    /// (a direct `await` call on the actor would bind the protocol extension's async defaults).
    private final class EventsReader {
        let runtime: any NativeAgentRuntimeControlling
        let generation: UInt64?
        private var iterator: AsyncStream<NativeAgentRuntimeEvent>.AsyncIterator

        init(_ controller: ClaudeNativeProcessSessionController) async {
            runtime = controller
            let subscription = await runtime.eventsSubscription()
            generation = subscription.generation
            iterator = subscription.events.makeAsyncIterator()
        }

        /// Every stream result emitted since the last drain, bounded by an in-band marker.
        func drain(file: StaticString = #filePath, line: UInt = #line) async -> [AIStreamResult] {
            let marker = UUID()
            let markerGeneration = await runtime.emitEventMarker(marker)
            guard markerGeneration != nil, markerGeneration == generation else {
                XCTFail("the marker went to another events stream (\(String(describing: markerGeneration)))", file: file, line: line)
                return []
            }
            var results: [AIStreamResult] = []
            while let event = await iterator.next() {
                if case let .marker(id) = event, id == marker { return results }
                if case let .stream(result) = event { results.append(result) }
            }
            XCTFail("the events stream ended before the marker", file: file, line: line)
            return results
        }

        /// Every stream result until the events stream ends (stdout EOF finishes it).
        func drainToEnd() async -> [AIStreamResult] {
            var results: [AIStreamResult] = []
            while let event = await iterator.next() {
                if case let .stream(result) = event { results.append(result) }
            }
            return results
        }
    }

    /// One O19 turn of the current app (standard flags: no user-message replay; consumed-user
    /// attribution on the assistant and result) through the production `handleStreamPayload` path of
    /// a synthetic launch.
    private func runTurn(
        _ controller: ClaudeNativeProcessSessionController,
        outbound: UUID = UUID(),
        entry: String = "a1"
    ) async {
        await controller.test_registerSyntheticDispatch()
        await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
        let payloads = [
            lifecycle("started"), assistant(entry: entry, attributedTo: outbound), rateLimit(),
            result(attributedTo: outbound), lifecycle("completed")
        ]
        for payload in payloads {
            await controller.test_handleStreamPayload(payload)
        }
    }

    private func transcriptSignature(_ results: [AIStreamResult]) -> [String] {
        results.map { "\($0.type)|\($0.text ?? "<nil>")" }
    }

    private func evidenceCarriers(_ results: [AIStreamResult]) -> [ClaudeLiveTranscriptEvidence] {
        results.filter { $0.type == AIStreamResult.lifecycleType && $0.text == nil }.compactMap(\.claudeLiveTranscriptEvidence)
    }

    /// Gate OFF, and an ineligible launch with the gate ON, emit exactly the legacy results with no
    /// evidence; an eligible launch emits the same results in the same order, plus metadata-only
    /// carriers and the one attachment.
    func testGateOffAndIneligibleLaunchesMatchLegacyOutputAndEligibleAddsOnlyEvidence() async throws {
        func run(enabled: Bool, provenance: ClaudeNativeProcessSessionController.CommandProvenance) async throws -> [AIStreamResult] {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch(commandProvenance: provenance)
            await controller.test_handleStreamPayload(systemInit())
            await runTurn(controller)
            let results = await reader.drain()
            let state = await controller.test_liveTranscriptQualification()
            if enabled, provenance != .programmaticOverride {
                XCTAssertEqual(state?.eligibility, .eligible)
            } else {
                XCTAssertNil(state, "no state for a disabled or ineligible producer")
            }
            return results
        }
        let off = try await run(enabled: false, provenance: .automaticResolved)
        XCTAssertFalse(off.isEmpty)
        XCTAssertTrue(off.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        let ineligible = try await run(enabled: true, provenance: .programmaticOverride)
        XCTAssertEqual(transcriptSignature(ineligible), transcriptSignature(off))
        XCTAssertTrue(ineligible.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })

        let eligible = try await run(enabled: true, provenance: .automaticResolved)
        // Owner decision (2026-10-29): a configured exact path qualifies exactly like automatic.
        let configured = try await run(enabled: true, provenance: .configuredOverride)
        XCTAssertEqual(transcriptSignature(configured), transcriptSignature(eligible))
        XCTAssertEqual(
            configured.compactMap(\.claudeLiveTranscriptEvidence).map(\.kind),
            eligible.compactMap(\.claudeLiveTranscriptEvidence).map(\.kind)
        )
        let carriers = evidenceCarriers(eligible)
        let withoutCarriers = eligible.filter { !($0.type == AIStreamResult.lifecycleType && $0.text == nil && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(transcriptSignature(withoutCarriers), transcriptSignature(off), "the same results, order and finalization")
        let attached = eligible.filter { $0.type == "content" && $0.claudeLiveTranscriptEvidence != nil }
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(eligible.count { $0.type == "content" }, off.count { $0.type == "content" }, "content is never duplicated")
        guard case let .completeText(complete) = attached.first?.claudeLiveTranscriptEvidence?.kind else {
            return XCTFail("expected complete text")
        }
        XCTAssertEqual(complete.text, reply)
        XCTAssertEqual(carriers.map(\.kind), [.resultAgreement(localItemID: complete.localItemID, text: reply)])
        for carrier in eligible where carrier.claudeLiveTranscriptEvidence != nil && carrier.type == AIStreamResult.lifecycleType {
            XCTAssertNil(carrier.usageObservation)
            XCTAssertNil(carrier.promptTokens)
            XCTAssertNil(carrier.stopReason)
        }
    }

    /// A payload with empty or suppressed translated output still delivers its disqualification as a
    /// metadata-only carrier; a malformed stdout line disqualifies through the production line path.
    func testEmptySuppressedAndMalformedOutputDeliverDisqualification() async throws {
        let controller = try makeController(enabled: true)
        let reader = await EventsReader(controller)
        await controller.test_beginSyntheticUsageLaunch()
        await controller.test_handleStreamPayload(["type": "system", "subtype": "task_started", "session_id": session, "task_id": "t1"])
        let suppressed = await reader.drain()
        XCTAssertEqual(evidenceCarriers(suppressed).map(\.kind), [.disqualified(.unsupportedPayload)])
        XCTAssertEqual(suppressed.count, 1, "the suppressed result itself never surfaces; only the carrier does")

        let second = try makeController(enabled: true)
        let secondReader = await EventsReader(second)
        await second.test_beginSyntheticUsageLaunch()
        await second.test_handleStreamPayload(["type": "mystery_event", "session_id": session])
        let empty = await secondReader.drain()
        XCTAssertEqual(evidenceCarriers(empty).map(\.kind), [.disqualified(.unsupportedPayload)])

        // A direct disqualification (no payload of its own) is delivered at once, once, even when no
        // later payload arrives.
        let third = try makeController(enabled: true)
        let thirdReader = await EventsReader(third)
        await third.test_beginSyntheticUsageLaunch()
        await third.test_handleLine(Data("{not json".utf8))
        let state = await third.test_liveTranscriptQualification()
        XCTAssertEqual(state?.disqualification, .malformedLine)
        let direct = await thirdReader.drain()
        XCTAssertEqual(evidenceCarriers(direct).map(\.kind), [.disqualified(.malformedLine)])
        await third.test_noteLiveTranscriptOutbound(uuid: nil, text: prompt)
        let repeated = await thirdReader.drain()
        XCTAssertTrue(evidenceCarriers(repeated).isEmpty, "a later direct disqualification adds no second carrier")

        for overlapping in [false, true] {
            let controller = try makeController(enabled: true)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch()
            if overlapping { await controller.test_noteLiveTranscriptOutbound(uuid: UUID(), text: prompt) }
            await controller.test_noteLiveTranscriptOutbound(uuid: overlapping ? UUID() : nil, text: prompt)
            let carriers = await reader.drain()
            XCTAssertEqual(
                evidenceCarriers(carriers).map(\.kind),
                [.disqualified(overlapping ? .overlappingOutbound : .unidentifiedOutbound)]
            )
        }

        // Disabled and ineligible producers emit nothing for the same direct disqualification.
        for (enabled, provenance) in [(false, ClaudeNativeProcessSessionController.CommandProvenance.automaticResolved), (true, .programmaticOverride)] {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch(commandProvenance: provenance)
            await controller.test_handleLine(Data("{not json".utf8))
            await controller.test_noteLiveTranscriptOutbound(uuid: nil, text: prompt)
            let results = await reader.drain()
            XCTAssertTrue(results.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        }
    }

    /// The exited launch's buffered stdout tail (a final record without a newline) is classified while
    /// its EOF drains it: a result contradicting the qualified assistant is refused on the events
    /// stream before the stream ends, and the producer is retired. Gate OFF, the same tail yields the
    /// same results in the same order with no evidence.
    func testEOFDrainedTailIsClassifiedBeforeTheProducerRetires() async throws {
        func run(enabled: Bool) async throws -> (beforeEOF: [AIStreamResult], afterEOF: [AIStreamResult]) {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            let launch = await controller.test_beginSyntheticUsageLaunch()
            await controller.test_handleStreamPayload(systemInit())
            let outbound = UUID()
            await controller.test_registerSyntheticDispatch()
            await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
            await controller.test_handleStreamPayload(lifecycle("started"))
            await controller.test_handleStreamPayload(assistant(attributedTo: outbound))
            let tail = try JSONSerialization.data(withJSONObject: result("CONTRADICTION", attributedTo: outbound))
            await controller.test_handleStdoutChunk(tail, launchToken: launch.token)
            let beforeEOF = await reader.drain()
            await controller.test_handleStdoutEOF(launchToken: launch.token)
            let afterEOF = await reader.drainToEnd()
            let retired = await controller.test_liveTranscriptQualification()
            XCTAssertNil(retired, "no producer state survives its EOF drain")
            return (beforeEOF, afterEOF)
        }
        let off = try await run(enabled: false)
        XCTAssertTrue((off.beforeEOF + off.afterEOF).allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        XCTAssertFalse(off.afterEOF.isEmpty, "the tail is translated")

        let on = try await run(enabled: true)
        XCTAssertEqual(
            on.beforeEOF.count { if case .completeText = $0.claudeLiveTranscriptEvidence?.kind { true } else { false } }, 1,
            "the assistant qualified before EOF"
        )
        XCTAssertTrue(evidenceCarriers(on.beforeEOF).isEmpty, "the unterminated tail is not classified before EOF")
        XCTAssertEqual(evidenceCarriers(on.afterEOF).map(\.kind), [.disqualified(.resultTextMismatch)])
        let withoutCarriers = on.afterEOF.filter { !($0.type == AIStreamResult.lifecycleType && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(transcriptSignature(withoutCarriers), transcriptSignature(off.afterEOF), "gate-off results and order")
    }

    /// The latch belongs to the producer: a consumer reset and later turns never requalify it, a stale
    /// launch's stdout never touches the current one, and only a newly installed launch starts fresh.
    func testLatchSurvivesConsumerResetAndTurnsAndOnlyANewLaunchResetsIt() async throws {
        let controller = try makeController(enabled: true)
        let first = await controller.test_beginSyntheticUsageLaunch()
        await controller.test_handleStreamPayload(systemInit())
        await controller.test_handleStreamPayload(["type": "mystery_event", "session_id": session])
        await controller.resetEventsStreamForNewRun()
        let reader = await EventsReader(controller)
        await runTurn(controller)
        let later = await reader.drain()
        XCTAssertTrue(later.allSatisfy { result in
            guard let evidence = result.claudeLiveTranscriptEvidence else { return true }
            return evidence.kind == .disqualified(.unsupportedPayload) && result.type == AIStreamResult.lifecycleType
        }, "no attachment or agreement after disqualification")
        XCTAssertEqual(evidenceCarriers(later).count, 2, "repeated on the assistant and the result")
        let latched = await controller.test_liveTranscriptQualification()
        XCTAssertEqual(latched?.launchToken, first.token)
        XCTAssertEqual(latched?.disqualification, .unsupportedPayload)

        // A new launch installs a fresh producer; the old launch's stdout is dropped.
        let second = await controller.test_beginSyntheticUsageLaunch()
        let fresh = await controller.test_liveTranscriptQualification()
        XCTAssertEqual(fresh?.launchToken, second.token)
        XCTAssertNil(fresh?.disqualification)
        XCTAssertEqual(fresh?.eligibility, .eligible)
        let staleLine = try JSONSerialization.data(withJSONObject: ["type": "mystery_event", "session_id": session]) + Data([0x0A])
        await controller.test_handleStdoutChunk(staleLine, launchToken: first.token)
        await controller.test_handleStdoutChunk(Data("{broken\n".utf8), launchToken: first.token)
        let afterStale = await controller.test_liveTranscriptQualification()
        XCTAssertNil(afterStale?.disqualification, "a stale producer never stamps the replacement launch")
        await controller.test_handleStreamPayload(systemInit())
        await runTurn(controller)
        let qualified = await reader.drain()
        XCTAssertEqual(qualified.count { if case .completeText = $0.claudeLiveTranscriptEvidence?.kind { true } else { false } }, 1)
    }

    // MARK: Step 4d5 single main-thread Read (O20 stdout shape)

    // Modeled on main's offline key/type-only O20 shape notes (phase4d5.md): no captured IDs, paths
    // or contents. Fixture-backed only, never live or installed no-replay evidence.
    private let readPath = "/fixture/workspace/notes.txt"
    private let readFileContent = "BRAVO-42\n"
    private let readToolUseID = "toolu_o20_1"
    private let readReply = "BRAVO-42"
    private let translatedInvocation = UUID()

    /// The tool-result block text: the file content is a substring of it, never equal to it.
    private var readBlockOutput: String {
        "     1\t" + readFileContent
    }

    private func readCallBlock(caller: Any? = ["type": "direct"], name: String = "Read", input: [String: Any]? = nil) -> [String: Any] {
        var block: [String: Any] = ["type": "tool_use", "id": readToolUseID, "name": name, "input": input ?? ["file_path": readPath]]
        if let caller { block["caller"] = caller }
        return block
    }

    /// The observed call envelope: assistant keys plus `wire_tool_inputs` (the singleton mapping of
    /// the tool-use ID to the same input), both attributions when `attributedTo` is given.
    private func readCall(entry: String = "c1", block: [String: Any]? = nil, attributedTo outbound: UUID?) -> [String: Any] {
        let block = block ?? readCallBlock()
        var payload = assistant(entry: entry, content: [block], attributedTo: outbound)
        payload["timestamp"] = "2026-10-23T00:00:01.000Z"
        payload["wire_tool_inputs"] = [readToolUseID: block["input"] ?? [:]]
        return payload
    }

    /// The observed tool-result user payload (own UUID; no replay, parent or attribution keys).
    private func readResult(
        entry: String = "r1",
        toolUseID: String? = nil,
        metaID: String? = nil,
        filePath: String? = nil,
        fileContent: String? = nil,
        block: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "type": "user",
            "message": [
                "role": "user",
                "content": [block ?? ["type": "tool_result", "tool_use_id": toolUseID ?? readToolUseID, "content": readBlockOutput]]
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "timestamp": "2026-10-23T00:00:02.000Z",
            "uuid": entry,
            "tool_use_result": [
                "type": "text",
                "file": [
                    "content": fileContent ?? readFileContent, "filePath": filePath ?? readPath,
                    "numLines": 1, "startLine": 1, "totalLines": 1
                ] as [String: Any]
            ] as [String: Any],
            "tool_result_meta": [[
                "id": metaID ?? readToolUseID,
                "permission_decision": ["decision": "accept", "source": "config", "reason_type": "mode"]
            ] as [String: Any]]
        ]
    }

    /// The observed final assistant: assistant keys without caller attribution or wire inputs.
    private func readAnswer(entry: String = "a2", text: String? = nil) -> [String: Any] {
        var payload = assistant(entry: entry, text: text ?? readReply)
        payload["timestamp"] = "2026-10-23T00:00:03.000Z"
        return payload
    }

    /// The translator's call result (pretty-printed sorted arguments, its own pairing ID).
    private func translatedReadCall(_ invocation: UUID?, name: String = "Read", args: [String: Any]? = nil) -> AIStreamResult {
        let data = try! JSONSerialization.data(withJSONObject: args ?? ["file_path": readPath], options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8)
        return AIStreamResult(type: "tool_call", text: nil, toolName: name, toolArgs: json, toolInvocationID: invocation, toolArgsJSON: json)
    }

    private func translatedReadResult(_ invocation: UUID?, output: String? = nil, isError: Bool? = nil) -> AIStreamResult {
        AIStreamResult(
            type: "tool_result", text: nil, toolName: "Read", toolOutput: output ?? readBlockOutput,
            toolInvocationID: invocation, toolResultJSON: output ?? readBlockOutput, toolIsError: isError
        )
    }

    private enum ReadStage: Int, Comparable {
        case dispatched, called, returned, answered

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Drives one O20 Read turn of an eligible producer through `stage`; returns its outbound.
    @discardableResult
    private func driveRead(
        _ state: inout State,
        through stage: ReadStage,
        replay: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UUID {
        let outbound = UUID()
        XCTAssertEqual(state.classify(envelope: data(systemInit()), translated: [], turnInFlight: false), .benign, file: file, line: line)
        state.noteOutbound(uuid: outbound, text: prompt)
        if replay {
            XCTAssertEqual(state.classify(envelope: data(self.replay(outbound)), translated: [], turnInFlight: true), .benign, file: file, line: line)
        }
        let usage = AIStreamResult(type: "usage", text: nil)
        let steps: [(ReadStage, [String: Any], [AIStreamResult])] = [
            (.called, readCall(attributedTo: outbound), [usage, translatedReadCall(translatedInvocation)]),
            (.returned, readResult(), [translatedReadResult(translatedInvocation)]),
            (.answered, readAnswer(), [usage, content(readReply)])
        ]
        for (step, payload, translated) in steps where step <= stage {
            guard case .attach = state.classify(envelope: data(payload), translated: translated, turnInFlight: true) else {
                XCTFail("the \(step) step attaches", file: file, line: line)
                return outbound
            }
        }
        return outbound
    }

    /// Step 4d5: replayed or not, the exact O20 call, result and final text each attach once to their
    /// one translated result, with the history reader's rows (deterministic row and pairing IDs,
    /// digests, payloads; never the translator's invocation ID), each naming its prerequisites; the
    /// attributed success agrees with all three; the producer then qualifies a later O19 turn.
    func testO20ReadChainAttachesTheReadersRowsAlongItsLinksAndAgrees() throws {
        for replay in [false, true] {
            let token = UUID()
            var state = eligibleState(token: token)
            let outbound = driveRead(&state, through: .dispatched, replay: replay)
            let usage = AIStreamResult(type: "usage", text: nil)

            let inputJSON = try XCTUnwrap(ClaudeSessionHistoryReader.canonicalToolInputJSON(["file_path": readPath] as NSDictionary))
            XCTAssertEqual(inputJSON, #"{"file_path":"\/fixture\/workspace\/notes.txt"}"#, "the reader's canonical input JSON")
            let call = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
                nativeSessionID: session, nativeEntryID: "c1", kind: .toolCall, toolUseID: readToolUseID, toolName: "Read", payload: inputJSON
            ))
            let invocation = ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "rpce-claude-history-tool-v1", components: [ClaudeSessionHistoryReader.providerRaw, session, readToolUseID]
            )
            XCTAssertEqual(call.invocationID, invocation)
            XCTAssertNotEqual(call.invocationID, translatedInvocation, "canonical IDs come only from the reader")
            XCTAssertTrue(call.matchesProjection)
            let callOutcome = state.classify(
                envelope: data(readCall(attributedTo: outbound)), translated: [usage, translatedReadCall(translatedInvocation)], turnInFlight: true
            )
            XCTAssertEqual(callOutcome, .attach(index: 1, .init(producerLaunchToken: token, kind: .readToolCall(call))), "replay \(replay)")
            let callItem = try XCTUnwrap(call.canonicalItem)
            XCTAssertEqual(callItem.id, call.localItemID)
            XCTAssertEqual(callItem.kind, .toolCall)
            XCTAssertEqual(callItem.toolInvocationID, invocation)
            XCTAssertEqual(callItem.toolArgsJSON, inputJSON)

            let result = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
                nativeSessionID: session, nativeEntryID: "r1", kind: .toolResult, toolUseID: readToolUseID, toolName: "Read", payload: readBlockOutput
            ))
            XCTAssertEqual(result.invocationID, invocation, "the shared tool-use ID pairs call and result")
            let resultOutcome = state.classify(envelope: data(readResult()), translated: [translatedReadResult(translatedInvocation)], turnInFlight: true)
            XCTAssertEqual(resultOutcome, .attach(index: 0, .init(producerLaunchToken: token, kind: .readToolResult(result, call: call))))
            let resultItem = try XCTUnwrap(result.canonicalItem)
            XCTAssertEqual(resultItem.kind, .toolResult)
            XCTAssertNil(resultItem.toolIsError, "an absent is_error stays unknown")
            XCTAssertNotEqual(resultItem.id, callItem.id, "call and result are distinct rows")

            let answerRow = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: session, nativeEntryID: "a2", text: readReply))
            let answer = try ClaudeLiveTranscriptCompleteText(
                nativeSessionID: session, nativeEntryID: "a2", localItemID: XCTUnwrap(answerRow.localItemID),
                text: readReply, envelopeDigest: answerRow.envelopeDigest
            )
            let answerOutcome = state.classify(envelope: data(readAnswer()), translated: [usage, content(readReply)], turnInFlight: true)
            XCTAssertEqual(answerOutcome, .attach(index: 1, .init(producerLaunchToken: token, kind: .readAnswer(answer, call: call, result: result))))

            let agreement = state.classify(envelope: data(self.result(readReply, attributedTo: outbound)), translated: [], turnInFlight: true)
            XCTAssertEqual(agreement, .standalone(.init(producerLaunchToken: token, kind: .readAgreement(call: call, result: result, answer: answer))))
            XCTAssertEqual(state.classify(envelope: data(lifecycle("completed")), translated: [], turnInFlight: false), .benign)

            // The chain returned the producer to idle: a later O19 single-text turn still qualifies.
            let next = UUID()
            state.noteOutbound(uuid: next, text: prompt)
            guard case let .attach(_, later) = state.classify(
                envelope: data(assistant(entry: "a3", attributedTo: next)), translated: [content(reply)], turnInFlight: true
            ), case .completeText = later.kind else {
                return XCTFail("a later single-text turn qualifies (replay \(replay))")
            }
            XCTAssertNil(state.disqualification)
        }
    }

    /// Step 4d5: every other call, result, final-text or success shape, link, attribution or
    /// translation, and every out-of-order payload, disqualifies with its reason (sticky).
    func testO20ReadChainRefusesEveryOtherShapeLinkAttributionOrTranslation() {
        typealias Case = (String, ClaudeLiveTranscriptDisqualification, (inout State) -> ClaudeLiveTranscriptOutcome)
        let usage = AIStreamResult(type: "usage", text: nil)
        func call(_ state: inout State, translated: [AIStreamResult]? = nil, replay: Bool = false, _ payload: (UUID) -> [String: Any]) -> ClaudeLiveTranscriptOutcome {
            let outbound = driveRead(&state, through: .dispatched, replay: replay)
            return state.classify(envelope: data(payload(outbound)), translated: translated ?? [usage, translatedReadCall(translatedInvocation)], turnInFlight: true)
        }
        func returned(_ state: inout State, _ payload: [String: Any], translated: [AIStreamResult]? = nil, turnInFlight: Bool = true) -> ClaudeLiveTranscriptOutcome {
            driveRead(&state, through: .called)
            return state.classify(envelope: data(payload), translated: translated ?? [translatedReadResult(translatedInvocation)], turnInFlight: turnInFlight)
        }
        func answered(_ state: inout State, translated: [AIStreamResult]? = nil, _ payload: (UUID) -> [String: Any]) -> ClaudeLiveTranscriptOutcome {
            let outbound = driveRead(&state, through: .returned)
            return state.classify(envelope: data(payload(outbound)), translated: translated ?? [usage, content(readReply)], turnInFlight: true)
        }
        func succeeded(_ state: inout State, _ payload: (UUID) -> [String: Any]) -> ClaudeLiveTranscriptOutcome {
            let outbound = driveRead(&state, through: .answered)
            return state.classify(envelope: data(payload(outbound)), translated: [], turnInFlight: true)
        }
        let input: [String: Any] = ["file_path": readPath]
        let cases: [Case] = [
            // The call: exact five-key block with the direct caller, exact input and wire inputs.
            ("no caller", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(caller: nil), attributedTo: $0) } }),
            ("another caller type", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(caller: ["type": "subagent"]), attributedTo: $0) } }),
            ("caller with an extra key", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(caller: ["type": "direct", "id": "x"]), attributedTo: $0) } }),
            ("caller as a string", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(caller: "direct"), attributedTo: $0) } }),
            ("another tool", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(name: "Bash"), attributedTo: $0) } }),
            ("extra input key", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(input: ["file_path": self.readPath, "limit": 5]), attributedTo: $0) } }),
            ("empty path", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(input: ["file_path": ""]), attributedTo: $0) } }),
            ("non-string path", .unsupportedAssistant, { call(&$0) { self.readCall(block: self.readCallBlock(input: ["file_path": 1]), attributedTo: $0) } }),
            ("extra block key", .unsupportedAssistant, { call(&$0) { outbound in
                var block = self.readCallBlock()
                block["is_error"] = false
                return self.readCall(block: block, attributedTo: outbound)
            } }),
            ("wire inputs differ", .unsupportedAssistant, { call(&$0) { outbound in
                var payload = self.readCall(attributedTo: outbound)
                payload["wire_tool_inputs"] = [self.readToolUseID: ["file_path": "/fixture/other"]]
                return payload
            } }),
            ("wire inputs missing", .unsupportedAssistant, { call(&$0) { outbound in
                var payload = self.readCall(attributedTo: outbound)
                payload["wire_tool_inputs"] = nil
                return payload
            } }),
            ("wire inputs of another tool use", .unsupportedAssistant, { call(&$0) { outbound in
                var payload = self.readCall(attributedTo: outbound)
                payload["wire_tool_inputs"] = ["toolu_other": input]
                return payload
            } }),
            ("tool use beside text", .unsupportedAssistant, { call(&$0) { self.assistant(content: [self.readCallBlock(), ["type": "text", "text": "x"]], attributedTo: $0) } }),
            ("unattributed though replayed", .unattributedAssistant, { call(&$0, replay: true) { _ in self.readCall(attributedTo: nil) } }),
            ("one attribution field", .unattributedAssistant, { call(&$0) { outbound in
                var payload = self.readCall(attributedTo: outbound)
                payload["user_message_uuids"] = nil
                return payload
            } }),
            ("attributed to another message", .attributionMismatch, { call(&$0) { _ in self.readCall(attributedTo: UUID()) } }),
            ("translated another tool name", .translationMismatch, { call(&$0, translated: [self.translatedReadCall(self.translatedInvocation, name: "read")]) { self.readCall(attributedTo: $0) } }),
            ("translated without a pairing ID", .translationMismatch, { call(&$0, translated: [self.translatedReadCall(nil)]) { self.readCall(attributedTo: $0) } }),
            ("translated other arguments", .translationMismatch, { call(&$0, translated: [self.translatedReadCall(self.translatedInvocation, args: ["file_path": "/x"])]) { self.readCall(attributedTo: $0) } }),
            ("no translated call", .translationMismatch, { call(&$0, translated: [usage]) { self.readCall(attributedTo: $0) } }),
            ("a second translated carrier", .translationMismatch, { call(&$0, translated: [self.translatedReadCall(self.translatedInvocation), self.content("x")]) { self.readCall(attributedTo: $0) } }),
            ("tool result without a call", .unsupportedUserReplay, { state in
                self.driveRead(&state, through: .dispatched)
                return state.classify(envelope: self.data(self.readResult()), translated: [self.translatedReadResult(self.translatedInvocation)], turnInFlight: true)
            }),

            // The result: exact observed shape, linked by ID, metadata, path and content.
            ("is_error present", .unsupportedToolResult, { returned(&$0, self.readResult(block: ["type": "tool_result", "tool_use_id": self.readToolUseID, "content": self.readBlockOutput, "is_error": false])) }),
            ("block content array", .unsupportedToolResult, { returned(&$0, self.readResult(block: ["type": "tool_result", "tool_use_id": self.readToolUseID, "content": [["type": "text", "text": self.readBlockOutput]]])) }),
            ("replay key", .unsupportedToolResult, { state in
                var payload = self.readResult()
                payload["isReplay"] = false
                return returned(&state, payload)
            }),
            ("source attribution key", .unsupportedToolResult, { state in
                var payload = self.readResult()
                payload["user_message_uuid"] = UUID().uuidString
                return returned(&state, payload)
            }),
            ("result reuses the call entry", .unsupportedToolResult, { returned(&$0, self.readResult(entry: "c1")) }),
            ("another permission decision", .unsupportedToolResult, { state in
                var payload = self.readResult()
                payload["tool_result_meta"] = [["id": self.readToolUseID, "permission_decision": ["decision": "accept", "source": "user", "reason_type": "mode"]]]
                return returned(&state, payload)
            }),
            ("two metadata entries", .unsupportedToolResult, { state in
                var payload = self.readResult()
                let meta = (payload["tool_result_meta"] as? [Any]) ?? []
                payload["tool_result_meta"] = meta + meta
                return returned(&state, payload)
            }),
            ("boolean line count", .unsupportedToolResult, { state in
                var payload = self.readResult()
                payload["tool_use_result"] = ["type": "text", "file": ["content": self.readFileContent, "filePath": self.readPath, "numLines": true, "startLine": 1, "totalLines": 1]]
                return returned(&state, payload)
            }),
            ("a user replay instead of the result", .unsupportedToolResult, { state in
                self.driveRead(&state, through: .called)
                return state.classify(envelope: self.data(self.replay(UUID())), translated: [], turnInFlight: true)
            }),
            ("no turn in flight", .unsupportedToolResult, { returned(&$0, self.readResult(), turnInFlight: false) }),
            ("another tool use", .toolLinkMismatch, { returned(&$0, self.readResult(toolUseID: "toolu_other", metaID: "toolu_other")) }),
            ("metadata of another tool use", .toolLinkMismatch, { returned(&$0, self.readResult(metaID: "toolu_other")) }),
            ("another path", .toolLinkMismatch, { returned(&$0, self.readResult(filePath: "/fixture/other")) }),
            ("file content not in the output", .toolLinkMismatch, { returned(&$0, self.readResult(fileContent: "CHARLIE-19")) }),
            ("translated another pairing ID", .translationMismatch, { returned(&$0, self.readResult(), translated: [self.translatedReadResult(UUID())]) }),
            ("translated error status", .translationMismatch, { returned(&$0, self.readResult(), translated: [self.translatedReadResult(self.translatedInvocation, isError: false)]) }),
            ("translated other output", .translationMismatch, { returned(&$0, self.readResult(), translated: [self.translatedReadResult(self.translatedInvocation, output: self.readFileContent)]) }),
            ("no translated result", .translationMismatch, { returned(&$0, self.readResult(), translated: []) }),
            ("final text before the result", .unownedAssistant, { state in
                self.driveRead(&state, through: .called)
                return state.classify(envelope: self.data(self.readAnswer()), translated: [self.content(self.readReply)], turnInFlight: true)
            }),
            ("success before the result", .resultTextMismatch, { state in
                let outbound = self.driveRead(&state, through: .called)
                return state.classify(envelope: self.data(self.result(self.readReply, attributedTo: outbound)), translated: [], turnInFlight: true)
            }),

            // The final text: single text, never contradicting attribution.
            ("final text attributed to another message", .attributionMismatch, { answered(&$0) { _ in
                var payload = self.readAnswer()
                self.attribute(&payload, to: UUID())
                return payload
            } }),
            ("a second tool call", .unsupportedAssistant, { answered(&$0, translated: [self.translatedReadCall(UUID())]) { self.readCall(entry: "c2", attributedTo: $0) } }),
            ("final text translation", .translationMismatch, { answered(&$0, translated: [usage]) { _ in self.readAnswer() } }),

            // The success: both attributions naming exactly the outbound, the answer's text.
            ("unattributed success", .unattributedResult, { succeeded(&$0) { _ in self.result(self.readReply) } }),
            ("one success attribution field", .unattributedResult, { succeeded(&$0) { outbound in
                var payload = self.result(self.readReply, attributedTo: outbound)
                payload["user_message_uuid"] = nil
                return payload
            } }),
            ("success attributed to another message", .attributionMismatch, { succeeded(&$0) { _ in self.result(self.readReply, attributedTo: UUID()) } }),
            ("success with other text", .resultTextMismatch, { succeeded(&$0) { self.result("CHARLIE-19", attributedTo: $0) } })
        ]
        for (name, reason, classify) in cases {
            var state = eligibleState()
            XCTAssertEqual(disqualification(classify(&state)), reason, name)
            XCTAssertEqual(state.disqualification, reason, name)
            let sticky = state.classify(envelope: data(readAnswer()), translated: [content(readReply)], turnInFlight: true)
            XCTAssertEqual(disqualification(sticky), reason, "\(name): sticky")
        }
    }

    private func toolSignature(_ results: [AIStreamResult]) -> [String] {
        results.map {
            [$0.type, $0.text, $0.toolName, $0.toolArgsJSON, $0.toolResultJSON, $0.toolOutput, $0.toolIsError.map(String.init(describing:))]
                .map { $0 ?? "<nil>" }.joined(separator: "|")
        }
    }

    /// One O20 Read turn (current app shape: attributed call and success, unattributed final text)
    /// through the production payload path and the real translator.
    private func runReadTurn(_ controller: ClaudeNativeProcessSessionController) async {
        await controller.test_handleStreamPayload(systemInit())
        await controller.test_registerSyntheticDispatch()
        let outbound = UUID()
        await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
        let payloads = [
            lifecycle("started"), readCall(attributedTo: outbound), rateLimit(), readResult(), readAnswer(),
            result(readReply, attributedTo: outbound), lifecycle("completed")
        ]
        for payload in payloads {
            await controller.test_handleStreamPayload(payload)
        }
    }

    /// Step 4d5: through the controller and the real translator, gate OFF and an ineligible launch
    /// emit exactly the legacy results; an eligible launch emits the same results in the same order,
    /// with the call, result and final-text evidence attached to their one translated results (the
    /// translator keeps its own pairing ID; canonical IDs are the reader's) and the agreement as the
    /// only carrier.
    func testReadChainThroughTheControllerAttachesOnlyEvidenceAndGateOffMatchesLegacyOutput() async throws {
        func run(enabled: Bool, provenance: ClaudeNativeProcessSessionController.CommandProvenance) async throws -> [AIStreamResult] {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch(commandProvenance: provenance)
            await runReadTurn(controller)
            let results = await reader.drain()
            let state = await controller.test_liveTranscriptQualification()
            if enabled, provenance != .programmaticOverride {
                XCTAssertEqual(state?.eligibility, .eligible)
                XCTAssertNil(state?.disqualification, "the chain qualified")
            } else {
                XCTAssertNil(state, "no state for a disabled or ineligible producer")
            }
            return results
        }
        let off = try await run(enabled: false, provenance: .automaticResolved)
        XCTAssertTrue(off.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        let offCall = try XCTUnwrap(off.first { $0.type == "tool_call" })
        let offResult = try XCTUnwrap(off.first { $0.type == "tool_result" })
        XCTAssertEqual(offCall.toolInvocationID, offResult.toolInvocationID, "the translator pairs its own call and result")
        XCTAssertNil(offResult.toolIsError)
        let ineligible = try await run(enabled: true, provenance: .programmaticOverride)
        XCTAssertEqual(toolSignature(ineligible), toolSignature(off))
        XCTAssertTrue(ineligible.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })

        let eligible = try await run(enabled: true, provenance: .automaticResolved)
        let withoutCarriers = eligible.filter { !($0.type == AIStreamResult.lifecycleType && $0.text == nil && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(toolSignature(withoutCarriers), toolSignature(off), "the same results, order and payloads")
        let attached = eligible.filter { $0.type != AIStreamResult.lifecycleType && $0.claudeLiveTranscriptEvidence != nil }
        XCTAssertEqual(attached.map(\.type), ["tool_call", "tool_result", "content"])
        guard case let .readToolCall(call) = attached[0].claudeLiveTranscriptEvidence?.kind,
              case let .readToolResult(result, call: resultCall) = attached[1].claudeLiveTranscriptEvidence?.kind,
              case let .readAnswer(answer, call: answerCall, result: answerResult) = attached[2].claudeLiveTranscriptEvidence?.kind
        else { return XCTFail("expected the three Read links, got \(attached.map(\.claudeLiveTranscriptEvidence))") }
        XCTAssertEqual(resultCall, call)
        XCTAssertEqual(answerCall, call)
        XCTAssertEqual(answerResult, result)
        XCTAssertEqual(answer.text, readReply)
        XCTAssertEqual(result.payload, readBlockOutput)
        XCTAssertNotEqual(call.invocationID, attached[0].toolInvocationID, "canonical IDs never come from the translator")
        XCTAssertEqual(call.invocationID, result.invocationID)
        XCTAssertEqual(evidenceCarriers(eligible).map(\.kind), [.readAgreement(call: call, result: result, answer: answer)])
    }

    /// Step 4d5: a malformed record left in the stdout buffer after a qualified Read call is drained at
    /// EOF: the producer is refused on the events stream before it ends, and the same tail yields the
    /// same results in the same order with the gate OFF.
    func testMalformedEOFTailAfterAReadCallIsRefusedBeforeTheProducerRetires() async throws {
        func run(enabled: Bool) async throws -> (beforeEOF: [AIStreamResult], afterEOF: [AIStreamResult]) {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            let launch = await controller.test_beginSyntheticUsageLaunch()
            await controller.test_handleStreamPayload(systemInit())
            await controller.test_registerSyntheticDispatch()
            let outbound = UUID()
            await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
            await controller.test_handleStreamPayload(lifecycle("started"))
            await controller.test_handleStreamPayload(readCall(attributedTo: outbound))
            // Sorted keys: both runs feed identical bytes (the debug skip notice quotes them).
            let complete = try JSONSerialization.data(withJSONObject: readResult(), options: [.sortedKeys])
            await controller.test_handleStdoutChunk(complete.prefix(complete.count / 2), launchToken: launch.token)
            let beforeEOF = await reader.drain()
            await controller.test_handleStdoutEOF(launchToken: launch.token)
            let afterEOF = await reader.drainToEnd()
            let retired = await controller.test_liveTranscriptQualification()
            XCTAssertNil(retired, "no producer state survives its EOF drain")
            return (beforeEOF, afterEOF)
        }
        let off = try await run(enabled: false)
        XCTAssertTrue((off.beforeEOF + off.afterEOF).allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        let on = try await run(enabled: true)
        XCTAssertEqual(
            on.beforeEOF.count { if case .readToolCall = $0.claudeLiveTranscriptEvidence?.kind { true } else { false } }, 1,
            "the call qualified before EOF"
        )
        XCTAssertTrue(evidenceCarriers(on.beforeEOF).isEmpty, "the unterminated tail is not classified before EOF")
        XCTAssertEqual(evidenceCarriers(on.afterEOF).map(\.kind), [.disqualified(.malformedLine)])
        let withoutCarriers = on.afterEOF.filter { !($0.type == AIStreamResult.lifecycleType && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(toolSignature(withoutCarriers), toolSignature(off.afterEOF), "gate-off results and order")
    }
}
