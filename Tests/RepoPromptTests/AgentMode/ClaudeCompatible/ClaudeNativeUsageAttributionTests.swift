import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Dispatch-to-result ownership contracts of the Claude native controller (plan §3.2, gate G1).
///
/// Every case drives the production `handleStreamPayload` / `handleStdoutChunk` / `sendUserMessage`
/// paths against a synthetic launch (no `claude` binary) and reads the dedicated usage-evidence
/// stream. Ownership is fail-closed: the only attributed results are those whose `result_index`
/// equals the next launch-local dispatch ordinal on the current launch, after version and session
/// evidence, with an unseen uuid.
final class ClaudeNativeUsageAttributionTests: XCTestCase {
    private typealias Event = ClaudeNativeProcessSessionController.UsageAccountingEvent

    private func makeController() throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
    }

    /// Pulls buffered usage events. The stream is buffered, so a `.launchEnded` sentinel proves
    /// that nothing else was emitted in between.
    private final class Collector {
        private var iterator: AsyncStream<Event>.AsyncIterator

        init(_ stream: AsyncStream<Event>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async -> Event? {
            await iterator.next()
        }
    }

    private func expectNext(
        _ collector: Collector,
        _ expected: Event,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await collector.next()
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func systemInit(version: String = "2.1.268", session: String = "sess-1") -> [String: Any] {
        ["type": "system", "subtype": "init", "session_id": session, "claude_code_version": version, "tools": [], "uuid": UUID().uuidString]
    }

    private func resultPayload(
        index: Any?,
        uuid: String,
        session: String = "sess-1",
        cost: Double = 0.5,
        subtype: String = "success",
        isError: Bool = false,
        queued: Any? = 0,
        input: Int = 4,
        read: Int = 100,
        modelUsageCosts: [String: Double]? = nil,
        subagentStats: [String: Any]? = ClaudeNativeUsageAttributionTests.noChildStats
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "result", "subtype": subtype, "is_error": isError, "uuid": uuid, "session_id": session,
            "total_cost_usd": cost, "num_turns": 1,
            "usage": ["input_tokens": input, "output_tokens": 1, "cache_read_input_tokens": read, "cache_creation_input_tokens": 0],
            // Captured 2.1.268 shape: the cumulative cost equals the summed per-model cumulative costUSD.
            "modelUsage": (modelUsageCosts ?? ["claude-sonnet-5": cost]).mapValues { ["costUSD": $0, "inputTokens": input] as [String: Any] }
        ]
        if let subagentStats { payload["subagent_stats"] = subagentStats }
        if let index { payload["result_index"] = index }
        if let queued { payload["queued_turn_count"] = queued }
        return payload
    }

    /// The captured no-child `subagent_stats` schema (every counter zero, `by_type` empty).
    static let noChildStats: [String: Any] = [
        "by_type": [:] as [String: Any], "completed": 0, "failed": 0, "max_depth": 0, "spawned": 0, "spawned_by_subagents": 0, "started_in_background": 0,
        "killed": ["parent": 0, "system": 0, "user": 0], "refused": ["budget": 0, "concurrency_limit": 0, "depth_limit": 0],
        "requested": ["background": 0, "foreground": 0, "unset": 0]
    ]

    // MARK: - In-order attribution, duplicates and conflicts

    func testFreshLaunchAttributesInOrderResultsIgnoresExactDuplicateAndBlocksConflictingReuse() async throws {
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(collector, .launched(launch))

        let turn0 = await controller.test_registerSyntheticDispatch()
        let turn1 = await controller.test_registerSyntheticDispatch()
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn1, ordinal: 1))

        await controller.test_handleStreamPayload(systemInit())
        await expectNext(
            collector,
            .runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.268", providerSessionID: "sess-1")
        )
        // The first init also binds the runtime (category fields absent on this synthetic init).
        await expectNext(collector, .runtimeBinding(launchToken: launch.token, binding: .init(
            runtimeVersion: "2.1.268", apiProvider: nil, apiKeySource: nil, model: nil, permissionMode: nil
        )))
        // A repeated identical init (one follows every dispatch) is harmless and emits nothing new.
        await controller.test_handleStreamPayload(systemInit())

        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "r0", cost: 0.5))
        guard case let .resultAttributed(first)? = await collector.next() else {
            return XCTFail("expected first attributed result")
        }
        XCTAssertEqual(first.launchToken, launch.token)
        XCTAssertEqual(first.turnID, turn0)
        XCTAssertEqual(first.resultIndex, 0)
        XCTAssertEqual(first.dispatchOrdinal, 0)
        XCTAssertEqual(first.queuedTurnCount, 0)
        XCTAssertEqual(first.runtimeVersion, "2.1.268")
        XCTAssertEqual(first.providerSessionID, "sess-1")
        XCTAssertEqual(first.reportedCost, 0.5)
        XCTAssertEqual(first.turnStatus, .completed)
        XCTAssertEqual(first.observation.envelopeID, "r0")
        XCTAssertEqual(first.observation.cacheReadInputTokens, 100)

        // Lifecycle closure travels on the same ordered stream, after the attribution decision.
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn0, status: .completed))

        // Exact duplicate delivery: no-op for accounting, no ordinal advance, and not a turn
        // boundary either — the completion FIFO must not retire turn1 before its own result, so
        // nothing at all is emitted for the duplicate and turn1 is closed only after result 1.
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "r0", cost: 0.5))
        await controller.test_handleStreamPayload(resultPayload(index: 1, uuid: "r1", cost: 0.9))
        guard case let .resultAttributed(second)? = await collector.next() else {
            return XCTFail("expected second attributed result after an exact duplicate")
        }
        XCTAssertEqual(second.turnID, turn1)
        XCTAssertEqual(second.resultIndex, 1)
        XCTAssertEqual(second.reportedCost, 0.9)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn1, status: .completed))

        // Same uuid with different accounting fields is a conflict: the launch blocks and a later
        // otherwise-valid result is never attributed.
        await controller.test_handleStreamPayload(resultPayload(index: 1, uuid: "r1", cost: 1.4))
        guard case let .blocked(token, reason)? = await collector.next() else {
            return XCTFail("expected blockage after conflicting uuid reuse")
        }
        XCTAssertEqual(token, launch.token)
        XCTAssertTrue(reason.description.contains("conflicting"), reason.description)
        let turn2 = await controller.test_registerSyntheticDispatch()
        await controller.test_handleStreamPayload(resultPayload(index: 2, uuid: "r2", cost: 1.5))
        await controller.test_endSyntheticUsageLaunch()
        // The dispatch and its lifecycle closure are still reported (identity), but no attribution.
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn2, ordinal: 2))
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn2, status: .completed))
        await expectNext(collector, .launchEnded(launchToken: launch.token))
    }

    func testMainAssistantRequestUsageIsLiveOnlyMainLineAndMissingUsageIsForwarded() async throws {
        let controller = try makeController()
        let first = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(first, .launched(launch))
        let turn = await controller.test_registerSyntheticDispatch()
        await expectNext(first, .dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        await controller.test_handleStreamPayload(systemInit())
        _ = await first.next() // runtimeEvidence
        _ = await first.next() // runtimeBinding

        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-envelope-1",
            "parent_tool_use_id": NSNull(),
            "message": [
                "id": "msg-main-1",
                "role": "assistant",
                "content": [["type": "text", "text": "working"]],
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 1,
                    "cache_read_input_tokens": 90,
                    "cache_creation_input_tokens": 0
                ]
            ] as [String: Any]
        ] as [String: Any])
        guard case let .mainRequestUsageAttributed(firstRequest)? = await first.next() else {
            return XCTFail("expected main-loop request usage")
        }
        XCTAssertEqual(firstRequest.launchToken, launch.token)
        XCTAssertEqual(firstRequest.turnID, turn)
        XCTAssertEqual(firstRequest.requestID, "msg-main-1")
        XCTAssertEqual(firstRequest.observation?.source, .assistant)
        XCTAssertEqual(firstRequest.observation?.inputTokens, 10)
        XCTAssertEqual(firstRequest.observation?.cacheReadInputTokens, 90)
        XCTAssertNil(firstRequest.observation?.parentToolUseID)

        // A native child/sidechain assistant event cannot replace the main-loop request. The next
        // event is therefore the following main-line request, whose missing usage is forwarded.
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-child",
            "parent_tool_use_id": "toolu-parent",
            "message": [
                "id": "msg-child",
                "role": "assistant",
                "content": [["type": "text", "text": "child"]],
                "usage": [
                    "input_tokens": 1,
                    "output_tokens": 1,
                    "cache_read_input_tokens": 999,
                    "cache_creation_input_tokens": 0
                ]
            ] as [String: Any]
        ] as [String: Any])
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-envelope-2",
            "parent_tool_use_id": NSNull(),
            "message": [
                "id": "msg-main-2",
                "role": "assistant",
                "content": [["type": "text", "text": "done"]]
            ] as [String: Any]
        ] as [String: Any])
        guard case let .mainRequestUsageAttributed(missingRequest)? = await first.next() else {
            return XCTFail("expected missing usage for the newer main-loop request")
        }
        XCTAssertEqual(missingRequest.turnID, turn)
        XCTAssertEqual(missingRequest.requestID, "msg-main-2")
        XCTAssertNil(missingRequest.observation)

        // Replacing the subscriber replays launch ownership evidence but never transient request
        // usage, so a restored/reattached consumer cannot claim an earlier request as current.
        let second = await Collector(controller.usageAccountingEvents)
        let supersededEvent = await first.next()
        XCTAssertNil(supersededEvent)
        await expectNext(second, .launched(launch))
        await expectNext(second, .dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        guard case .runtimeEvidence? = await second.next() else {
            return XCTFail("expected replayed runtime evidence")
        }
        guard case .runtimeBinding? = await second.next() else {
            return XCTFail("expected replayed runtime binding")
        }

        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "request-result"))
        guard case .resultAttributed? = await second.next() else {
            return XCTFail("expected attributed result")
        }
        await expectNext(second, .turnClosed(launchToken: launch.token, turnID: turn, status: .completed))

        // A process replay after the owning result has closed cannot become the latest request.
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-envelope-replay",
            "parent_tool_use_id": NSNull(),
            "message": [
                "id": "msg-main-replay",
                "role": "assistant",
                "content": [["type": "text", "text": "old"]],
                "usage": [
                    "input_tokens": 1,
                    "output_tokens": 1,
                    "cache_read_input_tokens": 9,
                    "cache_creation_input_tokens": 0
                ]
            ] as [String: Any]
        ] as [String: Any])
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(second, .launchEnded(launchToken: launch.token))
    }

    func testOwnershipFailuresBlockTheLaunchWithoutResynchronizing() async throws {
        struct Scenario {
            let name: String
            let dispatches: Int
            let steps: [[String: Any]]
            let blockedReasonFragment: String
        }
        let scenarios: [Scenario] = [
            .init(
                name: "skipped index",
                dispatches: 2,
                steps: [resultPayload(index: 1, uuid: "a")],
                blockedReasonFragment: "next expected ordinal is 0"
            ),
            .init(
                name: "result with no dispatched turn (replay before dispatch)",
                dispatches: 0,
                steps: [resultPayload(index: 0, uuid: "b")],
                blockedReasonFragment: "no dispatched turn"
            ),
            .init(
                name: "missing result_index",
                dispatches: 1,
                steps: [resultPayload(index: nil, uuid: "c")],
                blockedReasonFragment: "result_index missing"
            ),
            .init(
                name: "boolean result_index decodes as missing",
                dispatches: 1,
                steps: [resultPayload(index: true, uuid: "d")],
                blockedReasonFragment: "result_index missing"
            ),
            .init(
                name: "provider session identity mismatch",
                dispatches: 1,
                steps: [resultPayload(index: 0, uuid: "e", session: "other-session")],
                blockedReasonFragment: "session identity"
            ),
            .init(
                name: "runtime version conflict within one process",
                dispatches: 1,
                steps: [systemInit(version: "2.1.999")],
                blockedReasonFragment: "claude_code_version changed"
            ),
            .init(
                name: "provider session changed within one process",
                dispatches: 1,
                steps: [systemInit(session: "sess-2")],
                blockedReasonFragment: "session identity changed"
            )
        ]
        for scenario in scenarios {
            let controller = try makeController()
            let collector = await Collector(controller.usageAccountingEvents)
            let launch = await controller.test_beginSyntheticUsageLaunch()
            _ = await collector.next()
            for _ in 0 ..< scenario.dispatches {
                _ = await controller.test_registerSyntheticDispatch()
                _ = await collector.next()
            }
            await controller.test_handleStreamPayload(systemInit())
            _ = await collector.next() // runtimeEvidence
            _ = await collector.next() // runtimeBinding
            for step in scenario.steps {
                await controller.test_handleStreamPayload(step)
            }
            guard case let .blocked(token, reason)? = await collector.next() else {
                XCTFail("\(scenario.name): expected blockage")
                continue
            }
            XCTAssertEqual(token, launch.token, scenario.name)
            XCTAssertTrue(reason.description.contains(scenario.blockedReasonFragment), "\(scenario.name): \(reason.description)")
            if scenario.name.contains("version conflict") {
                XCTAssertEqual(reason, .runtimeVersionConflict, scenario.name)
            }
            if scenario.name.contains("session changed") {
                XCTAssertEqual(reason, .providerSessionIdentityChanged, scenario.name)
            }
            // Nothing later on this launch can attribute, even a perfectly ordered result; the
            // completion lifecycle still reports closures for turns it dequeues.
            await controller.test_endSyntheticUsageLaunch()
            var sawAttribution = false
            while let event = await collector.next() {
                if case .resultAttributed = event { sawAttribution = true }
                if case .launchEnded = event { break }
            }
            XCTAssertFalse(sawAttribution, scenario.name)
        }

        // Version evidence is mandatory: a result before any system/init blocks.
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await collector.next()
        _ = await controller.test_registerSyntheticDispatch()
        _ = await collector.next()
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "early"))
        guard case let .blocked(_, reason)? = await collector.next() else {
            return XCTFail("expected blockage for result before version evidence")
        }
        XCTAssertTrue(reason.description.contains("before runtime version"), reason.description)
        // The legacy lifecycle still closes the dequeued turn on the same stream, unattributed.
        guard case .turnClosed? = await collector.next() else { return XCTFail("expected lifecycle closure") }
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(collector, .launchEnded(launchToken: launch.token))
    }

    // MARK: - Result outcome, child scope and cost shape are evidence, not ownership

    private func firstAttribution(_ collector: Collector) async -> (ClaudeNativeProcessSessionController.UsageResultAttribution?, ClaudeNativeProcessSessionController.UsageAttributionBlock?) {
        var attribution: ClaudeNativeProcessSessionController.UsageResultAttribution?
        var blocked: ClaudeNativeProcessSessionController.UsageAttributionBlock?
        while let event = await collector.next() {
            if case let .resultAttributed(value) = event, attribution == nil { attribution = value }
            if case let .blocked(_, reason) = event { blocked = reason }
            if case .launchEnded = event { break }
        }
        return (attribution, blocked)
    }

    /// Ownership is proven by dispatch/result correlation alone. Error results, local commands,
    /// missing/non-zero/unknown child statistics, a `modelUsage` aggregate that disagrees with the
    /// cumulative and even a decreasing cumulative are attributed with their evidence; core decides
    /// finalization, token scope and checkpoint acceptance (Oracle decision 2026-09-15).
    func testResultOutcomeChildStatisticsAndCostShapeAreAttributedAsEvidence() async throws {
        var stats = Self.noChildStats
        stats["spawned"] = 1
        var unknownStats = Self.noChildStats
        unknownStats["new_counter"] = 0
        var localCommand = resultPayload(index: 0, uuid: "c")
        localCommand["local_command"] = "/compact"
        var withoutModelUsage = resultPayload(index: 0, uuid: "h")
        withoutModelUsage["modelUsage"] = nil
        let scenarios: [(String, [String: Any], ClaudeNativeProcessSessionController.TurnStatus, Bool)] = [
            ("error subtype", resultPayload(index: 0, uuid: "a", subtype: "error_during_execution", isError: true), .failed, false),
            ("is_error true", resultPayload(index: 0, uuid: "b", isError: true), .failed, false),
            ("local command", localCommand, .completed, false),
            ("missing subagent_stats", resultPayload(index: 0, uuid: "d", subagentStats: nil), .completed, false),
            ("child spawned", resultPayload(index: 0, uuid: "e", subagentStats: stats), .completed, true),
            ("unknown counter", resultPayload(index: 0, uuid: "f", subagentStats: unknownStats), .completed, false),
            ("cost disagrees", resultPayload(index: 0, uuid: "g", cost: 0.5, modelUsageCosts: ["claude-sonnet-5": 0.4]), .completed, false),
            ("missing modelUsage", withoutModelUsage, .completed, false)
        ]
        for (name, payload, expectedStatus, expectedChild) in scenarios {
            let controller = try makeController()
            let collector = await Collector(controller.usageAccountingEvents)
            _ = await controller.test_beginSyntheticUsageLaunch()
            let turn = await controller.test_registerSyntheticDispatch()
            await controller.test_handleStreamPayload(systemInit())
            for _ in 0 ..< 4 {
                _ = await collector.next() // launched, dispatched, runtimeEvidence, runtimeBinding
            }
            await controller.test_handleStreamPayload(payload)
            await controller.test_endSyntheticUsageLaunch()
            let (attribution, blocked) = await firstAttribution(collector)
            XCTAssertNil(blocked, "\(name): \(String(describing: blocked))")
            XCTAssertEqual(attribution?.turnID, turn, name)
            XCTAssertEqual(attribution?.resultIndex, 0, name)
            XCTAssertEqual(attribution?.reportedCost, 0.5, name)
            XCTAssertEqual(attribution?.childActivityObserved, expectedChild, name)
            if expectedStatus == .failed {
                XCTAssertNotEqual(attribution?.turnStatus, .completed, name)
            } else {
                XCTAssertEqual(attribution?.turnStatus, expectedStatus, name)
            }
        }

        // A decreasing cumulative is reported as-is; the accumulator suspends the segment as
        // partial (never a negative interval) while the controller keeps proving ownership.
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        _ = await controller.test_beginSyntheticUsageLaunch()
        _ = await controller.test_registerSyntheticDispatch()
        _ = await controller.test_registerSyntheticDispatch()
        await controller.test_handleStreamPayload(systemInit())
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "i", cost: 0.5))
        await controller.test_handleStreamPayload(resultPayload(index: 1, uuid: "j", cost: 0.4))
        await controller.test_endSyntheticUsageLaunch()
        var costs: [Double?] = []
        var reason: ClaudeNativeProcessSessionController.UsageAttributionBlock?
        while let event = await collector.next() {
            if case let .resultAttributed(attribution) = event { costs.append(attribution.reportedCost) }
            if case let .blocked(_, r) = event { reason = r }
            if case .launchEnded = event { break }
        }
        XCTAssertEqual(costs, [0.5, 0.4])
        XCTAssertNil(reason)
    }

    /// Compaction status is reported as a counter boundary; the runtime provenance is emitted
    /// exactly once and a later init with a different model or key source never blocks; a
    /// main-line `Agent`/`Task` tool use marks the next attributed result as child-affected
    /// (sidechain tool uses do not), after which the flag is cleared.
    func testCompactionProvenanceAndChildToolUseAreEvidenceOnly() async throws {
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        await controller.test_setInitializeResponse(["account": ["apiProvider": "firstParty", "subscriptionType": "Claude Max", "email": "never-bound"]])
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await collector.next()
        var initPayload = systemInit()
        initPayload["apiKeySource"] = "none"
        initPayload["model"] = "claude-sonnet-5"
        initPayload["permissionMode"] = "auto"
        await controller.test_handleStreamPayload(initPayload)
        _ = await collector.next() // runtimeEvidence
        let expectedBinding = ClaudeNativeProcessSessionController.RuntimeBinding(
            runtimeVersion: "2.1.268", apiProvider: "firstParty", apiKeySource: "none", model: "claude-sonnet-5", permissionMode: "auto"
        )
        await expectNext(collector, .runtimeBinding(launchToken: launch.token, binding: expectedBinding))
        // A repeated identical init is silent; installed 2.1.268 emits one per turn.
        await controller.test_handleStreamPayload(initPayload)
        // Compaction reported through system/status is a counter boundary (policy lives in core).
        await controller.test_handleStreamPayload(["type": "system", "subtype": "status", "status": "compacting", "session_id": "sess-1", "uuid": "s1"])
        await expectNext(collector, .counterBoundaryObserved(launchToken: launch.token, kind: "status:compacting"))
        await controller.test_handleStreamPayload(["type": "system", "subtype": "status", "compact_error": "Not enough messages to compact.", "compact_result": "x", "session_id": "sess-1", "uuid": "s2"])
        await expectNext(collector, .counterBoundaryObserved(launchToken: launch.token, kind: "status:compact_result"))
        // A later init reporting another model is provenance drift, not a reason to stop counting.
        var drifted = initPayload
        drifted["model"] = "claude-opus-5"
        await controller.test_handleStreamPayload(drifted)

        // Sidechain tool use (non-null parent_tool_use_id) is not main-line child evidence.
        let turn0 = await controller.test_registerSyntheticDispatch()
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
        await controller.test_handleStreamPayload([
            "type": "assistant", "session_id": "sess-1", "uuid": "side", "parent_tool_use_id": "toolu_parent",
            "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Agent", "id": "t0", "input": [:] as [String: Any]]]]
        ] as [String: Any])
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "r0", cost: 0.5))
        guard case let .resultAttributed(plain)? = await collector.next() else { return XCTFail("expected attribution") }
        XCTAssertFalse(plain.childActivityObserved)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn0, status: .completed))

        // Main-line Agent tool use marks the next result; the flag then clears.
        let turn1 = await controller.test_registerSyntheticDispatch()
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn1, ordinal: 1))
        await controller.test_handleStreamPayload([
            "type": "assistant", "session_id": "sess-1", "uuid": "a1", "parent_tool_use_id": NSNull(),
            "message": ["role": "assistant", "model": "claude-sonnet-5", "content": [["type": "tool_use", "name": "Agent", "id": "t1", "input": ["subagent_type": "Explore"]]]]
        ] as [String: Any])
        guard case let .mainRequestUsageAttributed(childRequest)? = await collector.next() else {
            return XCTFail("expected main request evidence")
        }
        XCTAssertEqual(childRequest.turnID, turn1)
        XCTAssertNil(childRequest.observation, "the synthetic tool-use payload has no usage object")
        await controller.test_handleStreamPayload(resultPayload(index: 1, uuid: "r1", cost: 0.9))
        guard case let .resultAttributed(childAffected)? = await collector.next() else { return XCTFail("expected attribution") }
        XCTAssertTrue(childAffected.childActivityObserved)
        XCTAssertEqual(childAffected.reportedCost, 0.9)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn1, status: .completed))
        let turn2 = await controller.test_registerSyntheticDispatch()
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turn2, ordinal: 2))
        await controller.test_handleStreamPayload(resultPayload(index: 2, uuid: "r2", cost: 1.1))
        guard case let .resultAttributed(cleared)? = await collector.next() else { return XCTFail("expected attribution") }
        XCTAssertFalse(cleared.childActivityObserved)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn2, status: .completed))
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(collector, .launchEnded(launchToken: launch.token))

        // The Task alias is recognised too.
        let task = try makeController()
        let taskCollector = await Collector(task.usageAccountingEvents)
        let taskLaunch = await task.test_beginSyntheticUsageLaunch()
        _ = await taskCollector.next()
        let taskTurn = await task.test_registerSyntheticDispatch()
        _ = await taskCollector.next()
        await task.test_handleStreamPayload(systemInit())
        _ = await taskCollector.next()
        _ = await taskCollector.next()
        await task.test_handleStreamPayload([
            "type": "assistant", "session_id": "sess-1", "uuid": "a2",
            "message": ["role": "assistant", "content": [["type": "text", "text": "hi"], ["type": "tool_use", "name": "Task", "id": "t2", "input": [:] as [String: Any]]]]
        ] as [String: Any])
        guard case let .mainRequestUsageAttributed(taskRequest)? = await taskCollector.next() else {
            return XCTFail("expected Task request evidence")
        }
        XCTAssertEqual(taskRequest.turnID, taskTurn)
        await task.test_handleStreamPayload(resultPayload(index: 0, uuid: "t", cost: 0.2))
        guard case let .resultAttributed(taskAttribution)? = await taskCollector.next() else { return XCTFail("expected attribution") }
        XCTAssertEqual(taskAttribution.turnID, taskTurn)
        XCTAssertTrue(taskAttribution.childActivityObserved)
        XCTAssertEqual(taskLaunch.token, taskAttribution.launchToken)
    }

    /// An app-sent interrupt (real stdin write to a harmless child; the control response never
    /// arrives, so the interrupt is unacknowledged) does not end attribution: the turn's original
    /// error result is still owned and attributed with the status the runtime evidence supports
    /// (`failed`, not `cancelled`, because no acknowledgement or cancellation signal exists); an
    /// acknowledged interrupt is covered by the cancelled-result case below.
    func testInterruptDoesNotEndAttributionAndTheInterruptedTurnsResultIsStillOwned() async throws {
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        let spawned = try ProcessLauncher.spawn(command: "/bin/cat", arguments: [], environment: ["PATH": "/bin"], workingDirectory: "/tmp")
        await controller.test_attachSpawnedProcess(spawned)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await collector.next()
        let turn = await controller.test_registerSyntheticDispatch()
        _ = await collector.next()
        await controller.test_handleStreamPayload(systemInit())
        _ = await collector.next() // runtimeEvidence
        _ = await collector.next() // runtimeBinding
        let outcome = await controller.interruptTurn(reason: "cancel")
        XCTAssertNotEqual(outcome, .noTurnInFlight)
        XCTAssertNotEqual(outcome, .acknowledged, "the harmless child never acknowledges the control request")
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "abort", cost: 0.25, subtype: "error_during_execution", isError: true))
        guard case let .resultAttributed(attribution)? = await collector.next() else { return XCTFail("expected attribution after interrupt") }
        XCTAssertEqual(attribution.turnID, turn)
        XCTAssertEqual(attribution.turnStatus, .failed, "unacknowledged interrupt: the error result keeps its runtime status")
        XCTAssertEqual(attribution.reportedCost, 0.25)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn, status: .failed))
        await controller.shutdown()
    }

    // MARK: - Launch identity evidence

    /// Qualification evidence is derived from the final environment handed to the spawner, not
    /// from resolver intent: an inherited login-shell redirect, a configured override and a
    /// resolver override/removal all surface as keys, and secret values never enter the identity.
    func testLaunchIdentityEnvironmentEvidenceIsDerivedFromTheFinalChildEnvironmentWithoutSecretValues() async throws {
        typealias Controller = ClaudeNativeProcessSessionController
        let secret = "sk-ant-secret-\(UUID().uuidString)"
        let controller = try makeController() // discovery config: no configured process overrides

        // A redirect present only in the inherited environment still reaches the child unchanged.
        let inherited = await controller.test_launchEnvironmentEvidence(
            base: ["PATH": "/usr/bin", "HOME": "/Users/x", "ANTHROPIC_BASE_URL": "https://proxy.example"]
        )
        XCTAssertEqual(inherited.environmentOverrideKeys, ["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(inherited.configuredEnvironmentOverrideKeys, [])

        // Resolver overrides/removals (compatible backend) combine with inherited routing keys;
        // app-set launch-shape keys and sanitized loader keys are not evidence.
        let redirected = await controller.test_launchEnvironmentEvidence(
            base: [
                "PATH": "/usr/bin", "CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_API_KEY": secret,
                "CLAUDE_CONFIG_DIR": "/Users/x/.claude-alt", "DYLD_INSERT_LIBRARIES": "/x.dylib", "NODE_OPTIONS": "--inspect"
            ],
            resolverOverrides: ["ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic", "ANTHROPIC_AUTH_TOKEN": secret, "API_TIMEOUT_MS": "3000000"],
            resolverRemovedKeys: ["ANTHROPIC_API_KEY"]
        )
        XCTAssertEqual(
            redirected.environmentOverrideKeys,
            ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "API_TIMEOUT_MS", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CONFIG_DIR"]
        )
        XCTAssertFalse(String(reflecting: redirected).contains(secret), "identity evidence must carry keys only")
        for appSetKey in ["CLAUDE_CODE_ENTRYPOINT", "ENABLE_CLAUDEAI_MCP_SERVERS", "ENABLE_TOOL_SEARCH", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "PATH"] {
            XCTAssertFalse(redirected.environmentOverrideKeys.contains(appSetKey), appSetKey)
        }

        // A clean first-party environment yields no routing evidence, so a qualified launch is
        // reachable; the app's own launch-shape keys are present in the child but not evidence.
        let finalClean = await controller.test_effectiveLaunchEnvironment(base: ["PATH": "/usr/bin", "HOME": "/Users/x", "TERM": "xterm"])
        XCTAssertEqual(finalClean["CLAUDE_CODE_ENTRYPOINT"], "sdk-ts")
        let clean = await controller.test_launchEnvironmentEvidence(base: ["PATH": "/usr/bin", "HOME": "/Users/x", "TERM": "xterm"])
        XCTAssertEqual(clean, .init(environmentOverrideKeys: [], configuredEnvironmentOverrideKeys: []))

        // Agent Mode launches carry the app's configured MCP overrides: recorded as configured
        // launch shape (a contract must qualify the exact set), never as backend routing.
        let agentDefaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeNativeUsageAttributionTests.\(UUID().uuidString)"))
        let agentConfig = try ClaudeCodeAgentConfig.agentMode(commandName: "/usr/bin/false", defaults: agentDefaults)
        XCTAssertEqual(agentConfig.processEnvironmentOverrides.keys.sorted(), ["MAX_MCP_OUTPUT_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"])
        let agentFinal = await controller.test_effectiveLaunchEnvironment(base: ["PATH": "/usr/bin"])
            .merging(agentConfig.processEnvironmentOverrides) { _, configured in configured }
        let configured = Controller.launchEnvironmentEvidence(
            finalEnvironment: agentFinal,
            resolverOverrides: [:],
            resolverRemovedKeys: [],
            configuredOverrides: agentConfig.processEnvironmentOverrides
        )
        XCTAssertEqual(configured.environmentOverrideKeys, [])
        XCTAssertEqual(configured.configuredEnvironmentOverrideKeys, ["MAX_MCP_OUTPUT_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"])
        // A configured override that routes the backend is routing evidence as well.
        let routedConfigured = Controller.launchEnvironmentEvidence(
            finalEnvironment: agentFinal.merging(["ANTHROPIC_BASE_URL": "https://proxy.example"]) { _, new in new },
            resolverOverrides: [:],
            resolverRemovedKeys: [],
            configuredOverrides: agentConfig.processEnvironmentOverrides.merging(["ANTHROPIC_BASE_URL": "https://proxy.example"]) { _, new in new }
        )
        XCTAssertEqual(routedConfigured.environmentOverrideKeys, ["ANTHROPIC_BASE_URL"])

        // The identity bound at launch carries exactly this evidence and no values.
        let identity = await controller.test_beginSyntheticUsageLaunch(
            environmentOverrideKeys: redirected.environmentOverrideKeys,
            configuredEnvironmentOverrideKeys: configured.configuredEnvironmentOverrideKeys
        )
        XCTAssertEqual(identity.environmentOverrideKeys, redirected.environmentOverrideKeys)
        XCTAssertEqual(identity.configuredEnvironmentOverrideKeys, configured.configuredEnvironmentOverrideKeys)
        XCTAssertFalse(String(reflecting: identity).contains(secret))
        await controller.test_endSyntheticUsageLaunch()
    }

    func testDeallocatedControllerEndsItsLaunchAndFinishesTheUsageStream() async throws {
        let stream: AsyncStream<Event>
        let launch: ClaudeNativeProcessSessionController.ProcessLaunchIdentity
        do {
            // The controller lives only in this scope; leaving it deallocates the actor.
            let controller = try makeController()
            stream = await controller.usageAccountingEvents
            launch = await controller.test_beginSyntheticUsageLaunch()
            _ = await controller.test_registerSyntheticDispatch()
        }
        let collector = Collector(stream)
        await expectNext(collector, .launched(launch))
        guard case .dispatched? = await collector.next() else { return XCTFail("expected dispatch") }
        await expectNext(collector, .launchEnded(launchToken: launch.token))
        let terminal = await collector.next()
        XCTAssertNil(terminal, "deinit cleanup must finish the stream so a forwarder can terminate")
    }

    // MARK: - Cancellation, evidence and boundaries

    /// An original interrupted result that still carries usage is attributed with its cancelled
    /// status (core finalizes the turn as interrupted and keeps the accepted totals). The
    /// transcript completion lifecycle is unchanged and still closes the turn as cancelled.
    func testInterruptedErrorResultIsAttributedAsCancelledWhileTheLifecycleStillCompletesTheTurn() async throws {
        let controller = try makeController()
        let usage = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await usage.next()
        let turn = await controller.test_registerSyntheticDispatch()
        _ = await usage.next()
        await controller.test_handleStreamPayload(systemInit())
        _ = await usage.next() // runtimeEvidence
        _ = await usage.next() // runtimeBinding
        await controller.test_setTurnWasInterrupted(true)

        let lifecycle = await controller.events
        await controller.test_handleStreamPayload(resultPayload(
            index: 0, uuid: "abort", cost: 0.25, subtype: "error_during_execution", isError: true
        ))
        guard case let .resultAttributed(attribution)? = await usage.next() else { return XCTFail("expected attribution") }
        XCTAssertEqual(attribution.turnID, turn)
        XCTAssertEqual(attribution.turnStatus, .cancelled)
        XCTAssertEqual(attribution.reportedCost, 0.25)
        XCTAssertEqual(attribution.observation.resultSubtype, "error_during_execution")
        await expectNext(usage, .turnClosed(launchToken: launch.token, turnID: turn, status: .cancelled))

        // The legacy completion lifecycle still consumes the interrupt marker exactly once.
        var completedStatus: ClaudeNativeProcessSessionController.TurnStatus?
        for await event in lifecycle {
            if case let .turnCompleted(turnID, status, _) = event {
                XCTAssertEqual(turnID, turn)
                completedStatus = status
                break
            }
        }
        XCTAssertEqual(completedStatus, .cancelled)
        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight)
        let later = await controller.test_determineTurnStatus(payload: ["type": "result"])
        guard case .completed = later else { return XCTFail("interrupt marker must have been consumed by the lifecycle path") }
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(usage, .launchEnded(launchToken: launch.token))
    }

    func testCompactionBoundaryAndQueueDepthAreReportedAsEvidenceNotDecidedByTheController() async throws {
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await collector.next()
        let turn = await controller.test_registerSyntheticDispatch()
        _ = await collector.next()
        await controller.test_handleStreamPayload(systemInit())
        _ = await collector.next() // runtimeEvidence
        _ = await collector.next() // runtimeBinding
        await controller.test_handleStreamPayload([
            "type": "system", "subtype": "compact_boundary", "session_id": "sess-1",
            "compact_metadata": ["trigger": "auto", "pre_tokens": 150_000]
        ])
        await expectNext(collector, .counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "q", queued: 2))
        guard case let .resultAttributed(attribution)? = await collector.next() else {
            return XCTFail("queue depth is evidence carried on the attribution; policy lives in core")
        }
        XCTAssertEqual(attribution.turnID, turn)
        XCTAssertEqual(attribution.queuedTurnCount, 2)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(collector, .launchEnded(launchToken: launch.token))
    }

    /// Production delivery of the compaction status release (2026-10-01 compaction status plan
    /// §3.1/§4): the captured 2.1.268 `system/status` lines and a synthetic `compact_boundary`,
    /// replayed through `handleStreamPayload` mid-turn, reach the controller's transcript `events`
    /// as `status("Compacting context")`, a nil-text `status` release, then the boundary's release
    /// and its unchanged `system` row. The counter-boundary evidence kinds are unchanged, no
    /// release is a `message_stop` or usage carrier, and nothing consumes the completion FIFO:
    /// the in-flight turn is completed only by its own later result.
    func testCompactionStatusReleaseReachesControllerEventsWithUnchangedBoundaryEvidenceAndNoTurnCompletion() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeNativeUsage/2.1.268-compact.jsonl")
        let captured: [[String: Any]] = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) }
        let capturedInit = try XCTUnwrap(captured.first(where: { ($0["subtype"] as? String) == "init" }))
        let session = try XCTUnwrap(capturedInit["session_id"] as? String)
        let statusLines = captured.filter { ($0["type"] as? String) == "system" && ($0["subtype"] as? String) == "status" }
        XCTAssertEqual(statusLines.count, 2, "captured compacting status, then the terminal null-status marker payload")
        XCTAssertEqual(statusLines.first?["status"] as? String, "compacting")
        XCTAssertTrue(statusLines.last?["status"] is NSNull)

        let controller = try makeController()
        let usage = await Collector(controller.usageAccountingEvents)
        let lifecycleStream = await controller.events
        var lifecycle = lifecycleStream.makeAsyncIterator()
        let launch = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(usage, .launched(launch))
        let turn = await controller.test_registerSyntheticDispatch()
        await expectNext(usage, .dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        await controller.test_handleStreamPayload(systemInit(session: session))
        _ = await usage.next() // runtimeEvidence
        _ = await usage.next() // runtimeBinding

        for line in statusLines {
            await controller.test_handleStreamPayload(line)
        }
        await controller.test_handleStreamPayload([
            "type": "system", "subtype": "compact_boundary", "session_id": session, "uuid": "cb-synthetic",
            "compact_metadata": ["trigger": "auto", "pre_tokens": 150_000]
        ] as [String: Any])
        await expectNext(usage, .counterBoundaryObserved(launchToken: launch.token, kind: "status:compacting"))
        await expectNext(usage, .counterBoundaryObserved(launchToken: launch.token, kind: "status:compact_result"))
        await expectNext(usage, .counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        let inFlightAfterCompaction = await controller.hasTurnInFlight
        XCTAssertTrue(inFlightAfterCompaction, "status releases and the boundary never consume the completion FIFO")

        // A non-compaction sentinel status (no boundary evidence) delimits the compaction events.
        let sentinel = "sentinel status"
        await controller.test_handleStreamPayload(["type": "system", "subtype": "status", "status": sentinel, "session_id": session, "uuid": "sentinel"])
        var streamed: [AIStreamResult] = []
        var completedBeforeResult = false
        while let event = await lifecycle.next() {
            if case let .stream(result) = event {
                if result.type == "status", result.text == sentinel { break }
                streamed.append(result)
            } else if case .turnCompleted = event {
                completedBeforeResult = true
            }
        }
        XCTAssertFalse(completedBeforeResult, "no turn completes before the in-flight turn's own result")
        let statusAndRows = streamed.filter { $0.type == "status" || $0.type == "system" }
        XCTAssertEqual(statusAndRows.map(\.type), ["status", "status", "status", "system"])
        XCTAssertEqual(
            statusAndRows.map(\.text),
            ["Compacting context", nil, nil, "Context compacted — trigger: auto — at ~150000 tokens"]
        )
        XCTAssertFalse(streamed.contains { $0.type == "message_stop" || $0.type == "usage" })
        XCTAssertTrue(statusAndRows.allSatisfy { $0.usageObservation == nil && $0.stopReason == nil })

        // The same in-flight turn is still completed by its own result, exactly once.
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "r0", session: session))
        guard case let .resultAttributed(attribution)? = await usage.next() else {
            return XCTFail("the in-flight turn's result is still attributed after compaction")
        }
        XCTAssertEqual(attribution.turnID, turn)
        await expectNext(usage, .turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        var completedTurnID: UUID?
        while let event = await lifecycle.next() {
            if case let .turnCompleted(turnID, _, _) = event {
                completedTurnID = turnID
                break
            }
        }
        XCTAssertEqual(completedTurnID, turn)
        let inFlightAfterResult = await controller.hasTurnInFlight
        XCTAssertFalse(inFlightAfterResult)
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(usage, .launchEnded(launchToken: launch.token))
    }

    // MARK: - Stream lifetime and stdout generation (OracleB P1#3 / P1#4)

    /// The first subscriber gets the lifetime stream; a later subscriber (same controller re-attached
    /// after its forwarder terminated) gets a fresh stream with nothing replayed, and the previous
    /// subscriber's stream is finished rather than silently starved.
    func testUsageAccountingEventsHandsOutAFreshStreamToALaterSubscriberWithoutReplay() async throws {
        let controller = try makeController()
        let first = await Collector(controller.usageAccountingEvents)
        let launch1 = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(first, .launched(launch1))
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(first, .launchEnded(launchToken: launch1.token))

        let second = await Collector(controller.usageAccountingEvents)
        let leftover = await first.next()
        XCTAssertNil(leftover, "the superseded stream is finished")
        let launch2 = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(second, .launched(launch2), "no replay of the earlier launch")
        _ = await controller.test_registerSyntheticDispatch()
        guard case let .dispatched(dispatchedToken, _, ordinal)? = await second.next() else { return XCTFail("expected the new launch's dispatch") }
        XCTAssertEqual(dispatchedToken, launch2.token)
        XCTAssertEqual(ordinal, 0)
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(second, .launchEnded(launchToken: launch2.token))
    }

    /// Review R2 (OracleA P1#3): the next launch can begin (and dispatch) before the replacement
    /// subscriber asks for its stream. That launch's already-emitted evidence is delivered to the
    /// new subscriber first, in order, so its identity is never lost; an ended launch is never
    /// replayed, and a subscription taken during a launch with attributed results carries them.
    func testResubscribingAfterTheNextLaunchBeganDeliversThatLaunchsEvidence() async throws {
        let controller = try makeController()
        let first = await Collector(controller.usageAccountingEvents)
        let launch1 = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(first, .launched(launch1))
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(first, .launchEnded(launchToken: launch1.token))

        // Launch 2 begins and dispatches BEFORE anyone resubscribes.
        let launch2 = await controller.test_beginSyntheticUsageLaunch()
        let turn = await controller.test_registerSyntheticDispatch()
        let second = await Collector(controller.usageAccountingEvents)
        // The superseded stream is finished: whatever launch-2 evidence it still buffered (nobody
        // was consuming it) is exactly what the new subscriber is bootstrapped with, then `nil`.
        var superseded: [Event] = []
        while let event = await first.next() {
            superseded.append(event)
        }
        XCTAssertEqual(superseded, [.launched(launch2), .dispatched(launchToken: launch2.token, turnID: turn, ordinal: 0)])
        await expectNext(second, .launched(launch2), "the launch that began before the subscription is delivered first")
        await expectNext(second, .dispatched(launchToken: launch2.token, turnID: turn, ordinal: 0))
        await controller.test_handleStreamPayload(systemInit())
        guard case let .runtimeEvidence(token, _, _)? = await second.next() else { return XCTFail("live evidence follows the bootstrap") }
        XCTAssertEqual(token, launch2.token)
        _ = await second.next() // runtimeBinding
        await controller.test_handleStreamPayload(resultPayload(index: 0, uuid: "r2"))
        guard case let .resultAttributed(attribution)? = await second.next() else { return XCTFail("expected attribution on the new stream") }
        XCTAssertEqual(attribution.turnID, turn)
        await expectNext(second, .turnClosed(launchToken: launch2.token, turnID: turn, status: .completed))

        // A subscription taken mid-launch carries everything the launch already emitted, in order.
        let third = await Collector(controller.usageAccountingEvents)
        await expectNext(third, .launched(launch2))
        await expectNext(third, .dispatched(launchToken: launch2.token, turnID: turn, ordinal: 0))
        guard case .runtimeEvidence? = await third.next() else { return XCTFail("expected replayed runtime evidence") }
        guard case .runtimeBinding? = await third.next() else { return XCTFail("expected replayed runtime binding") }
        guard case let .resultAttributed(replayed)? = await third.next() else { return XCTFail("expected replayed attribution") }
        XCTAssertEqual(replayed, attribution, "replayed evidence is the identical attribution (core dedupes it by result identity)")
        await expectNext(third, .turnClosed(launchToken: launch2.token, turnID: turn, status: .completed))
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(third, .launchEnded(launchToken: launch2.token))

        // After the launch ended nothing is replayed: the next subscriber sees only launch 3.
        let fourth = await Collector(controller.usageAccountingEvents)
        let launch3 = await controller.test_beginSyntheticUsageLaunch()
        await expectNext(fourth, .launched(launch3), "an ended launch is never replayed")
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(fourth, .launchEnded(launchToken: launch3.token))
    }

    /// Stdout bytes and EOF are keyed on the process launch, not on accounting state: with the
    /// usage launch already ended, the transcript completion lifecycle still receives a result.
    func testStdoutDeliveryIsKeyedOnTheProcessLaunchNotOnUsageLaunchState() async throws {
        let controller = try makeController()
        let lifecycle = await controller.events
        let launch = await controller.test_beginSyntheticUsageLaunch()
        await controller.test_endSyntheticUsageLaunch()
        let turn = await controller.test_registerSyntheticDispatch()
        let line = Data(#"{"type":"result","subtype":"success","is_error":false,"uuid":"r0","session_id":"sess-1","result_index":0,"queued_turn_count":0,"num_turns":1,"total_cost_usd":0.5,"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}"#.utf8) + Data("\n".utf8)
        await controller.test_handleStdoutChunk(line, launchToken: launch.token)
        var completed: UUID?
        for await event in lifecycle {
            if case let .turnCompleted(turnID, _, _) = event {
                completed = turnID
                break
            }
        }
        XCTAssertEqual(completed, turn, "transcript delivery must not depend on usage accounting state")
        // A replaced launch's bytes are still discarded before framing.
        let stale = await controller.test_registerSyntheticDispatch()
        await controller.test_handleStdoutChunk(line, launchToken: UUID())
        let inFlight = await controller.hasTurnInFlight
        XCTAssertTrue(inFlight, "stale-token bytes never reach the completion lifecycle (turn \(stale) stays pending)")
    }

    // MARK: - Process-generation binding of stdout

    func testStdoutChunksAndEOFFromAReplacedLaunchAreDiscardedBeforeFramingAndAccounting() async throws {
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        let launch = await controller.test_beginSyntheticUsageLaunch()
        _ = await collector.next()
        let turn = await controller.test_registerSyntheticDispatch()
        _ = await collector.next()
        let initLine = try JSONSerialization.data(withJSONObject: systemInit()) + Data("\n".utf8)
        let resultLine = try JSONSerialization.data(withJSONObject: resultPayload(index: 0, uuid: "wire")) + Data("\n".utf8)

        // Stale generation: neither the framer/translator nor the completion FIFO may see it.
        await controller.test_handleStdoutChunk(initLine + resultLine, launchToken: UUID())
        let stillInFlight = await controller.hasTurnInFlight
        XCTAssertTrue(stillInFlight, "a straggler result from a replaced process must not complete the live turn")

        // Current generation: the same bytes go through real framing, decoding and attribution.
        await controller.test_handleStdoutChunk(initLine + resultLine, launchToken: launch.token)
        await expectNext(
            collector,
            .runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.268", providerSessionID: "sess-1")
        )
        _ = await collector.next() // runtimeBinding (first init)
        guard case let .resultAttributed(attribution)? = await collector.next() else {
            return XCTFail("expected attribution from the wire path")
        }
        XCTAssertEqual(attribution.turnID, turn)
        XCTAssertEqual(attribution.observation.resultIndex, 0)
        await expectNext(collector, .turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight)
        await controller.test_endSyntheticUsageLaunch()
        await expectNext(collector, .launchEnded(launchToken: launch.token))
    }

    // MARK: - Actual stdin writes

    func testDispatchIsRegisteredOnlyAfterAnActualSuccessfulStdinWrite() async throws {
        // Successful write: bytes reach the child's stdin pipe, then exactly one dispatch is registered.
        let cat = try ProcessLauncher.spawn(command: "/bin/cat", arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp")
        let controller = try makeController()
        let collector = await Collector(controller.usageAccountingEvents)
        await controller.test_attachSpawnedProcess(cat)
        let launch = await controller.test_beginSyntheticUsageLaunch(pid: cat.pid)
        _ = await collector.next()
        let turnID = try await controller.sendUserMessage("first")
        await expectNext(collector, .dispatched(launchToken: launch.token, turnID: turnID, ordinal: 0))
        let inFlight = await controller.hasTurnInFlight
        XCTAssertTrue(inFlight)
        // `cat` echoes stdin: the exact frame (JSON + newline) was delivered.
        let echoed = cat.stdout.availableData
        let echoedText = String(decoding: echoed, as: UTF8.self)
        XCTAssertTrue(echoedText.hasSuffix("\n"), "frame must end with a newline")
        let echoedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(echoedText.dropLast().utf8)) as? [String: Any])
        XCTAssertEqual(echoedObject["type"] as? String, "user")
        await controller.shutdown()
        await expectNext(collector, .launchEnded(launchToken: launch.token))

        // Missing stdin handle: the write fails, no turn and no dispatch are registered.
        let cat2 = try ProcessLauncher.spawn(command: "/bin/cat", arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp")
        let noStdin = SpawnedProcess(
            pid: cat2.pid,
            processGroupID: cat2.processGroupID,
            stdin: nil,
            stdinDescriptor: nil,
            stdout: cat2.stdout,
            stderr: cat2.stderr
        )
        let controller2 = try makeController()
        let collector2 = await Collector(controller2.usageAccountingEvents)
        await controller2.test_attachSpawnedProcess(noStdin)
        let launch2 = await controller2.test_beginSyntheticUsageLaunch(pid: cat2.pid)
        _ = await collector2.next()
        do {
            _ = try await controller2.sendUserMessage("never delivered")
            XCTFail("a missing stdin handle must be a failed write")
        } catch let error as ClaudeNativeProcessSessionController.ControllerError {
            guard case .inputWriteFailed = error else { return XCTFail("unexpected error \(error)") }
        }
        let inFlight2 = await controller2.hasTurnInFlight
        XCTAssertFalse(inFlight2, "no turn is tracked for a failed write")
        // The failed write schedules the existing teardown, which ends the launch with zero dispatches.
        await expectNext(collector2, .launchEnded(launchToken: launch2.token))
        cat2.stdin?.closeFile()

        // Closed stdin descriptor: the actual write throws, again with no dispatch registration.
        let cat3 = try ProcessLauncher.spawn(command: "/bin/cat", arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp")
        cat3.stdin?.closeFile()
        let controller3 = try makeController()
        let collector3 = await Collector(controller3.usageAccountingEvents)
        await controller3.test_attachSpawnedProcess(cat3)
        let launch3 = await controller3.test_beginSyntheticUsageLaunch(pid: cat3.pid)
        _ = await collector3.next()
        do {
            _ = try await controller3.sendUserMessage("closed pipe")
            XCTFail("a closed stdin must be a failed write")
        } catch let error as ClaudeNativeProcessSessionController.ControllerError {
            guard case .inputWriteFailed = error else { return XCTFail("unexpected error \(error)") }
        }
        let inFlight3 = await controller3.hasTurnInFlight
        XCTAssertFalse(inFlight3)
        await expectNext(collector3, .launchEnded(launchToken: launch3.token))
    }
}
