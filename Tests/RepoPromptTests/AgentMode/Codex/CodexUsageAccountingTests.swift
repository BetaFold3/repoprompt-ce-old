import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Codex accounting (plan §4.1): optional-preserving `thread/tokenUsage/updated` companions,
/// disjoint owned counter intervals per controller generation, pricing frozen at dispatch from
/// the OpenAI Standard/global list-price snapshot, deduplication/refinement, baselines, reroutes,
/// unmeasured dispatched work, lossless persistence and the sidebar readout. Cadence assumptions
/// are the documented rollout evidence (`total` cumulative, `last` per model response, reasoning
/// included in output). Fixtures report an explicit cache-write count of zero (the installed
/// schema default) unless a test is about the absent-count case, which prices the same way.
@MainActor
final class CodexUsageAccountingTests: XCTestCase {
    private typealias Counters = CodexUsageObservation.Counters
    private typealias Usage = AgentProviderUsageSnapshot

    private let owner = UUID()
    private let execution = UUID()
    private let start = Date(timeIntervalSince1970: 1_789_000_000)

    // Nonisolated so default-argument expressions (evaluated outside the @MainActor test class)
    // can build fixtures; every value is an immutable pricing type.
    private nonisolated static let flatRates = OpenAIPricingRates(input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10)
    private nonisolated static let shortRates = OpenAIPricingRates(input: 1.25, cachedInput: 0.125, cacheWrite: nil, output: 10)
    private nonisolated static let longRates = OpenAIPricingRates(input: 2.5, cachedInput: 0.25, cacheWrite: nil, output: 20)
    /// A model that lists a separate cache-write rate (like the official `gpt-5.6-sol` row).
    private nonisolated static let writeRates = OpenAIPricingRates(input: 4, cachedInput: Decimal(string: "0.4")!, cacheWrite: 5, output: 20)

    private nonisolated static func snapshot(
        model: String = "gpt-5.3-codex",
        bands: [OpenAIPricingContextBand] = [.init(kind: .all, rates: flatRates)],
        threshold: Int? = nil,
        aliases: [OpenAIPricingAlias] = [],
        capturedAt: Date = Date(timeIntervalSince1970: 0),
        validatedAt: Date = Date(timeIntervalSince1970: 0),
        isStale: Bool = false
    ) -> OpenAIPricingSnapshot {
        let pricing = OpenAIModelPricing(modelID: model, bands: bands, contextThresholdTokens: threshold)
        return OpenAIPricingSnapshot(
            catalog: OpenAIPricingCatalog(models: [pricing], aliases: aliases),
            sourceKind: .bundledSeed,
            capturedAt: capturedAt,
            validatedAt: validatedAt,
            isStale: isStale
        )
    }

    private nonisolated static let bandedSnapshot = snapshot(
        bands: [.init(kind: .shortContext, rates: shortRates), .init(kind: .longContext, rates: longRates)],
        threshold: 272_000
    )

    private nonisolated static let writeSnapshot = snapshot(model: "gpt-w", bands: [.init(kind: .all, rates: writeRates)])

    private func counters(_ input: Int?, _ cached: Int?, _ output: Int?, reasoning: Int? = 0, cacheWrite: Int? = 0) -> Counters {
        Counters(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: cacheWrite, outputTokens: output, reasoningOutputTokens: reasoning, totalTokens: (input ?? 0) + (output ?? 0))
    }

    private func observation(
        _ ordinal: Int,
        turn: String? = "t1",
        attribution: CodexUsageObservation.TurnAttribution = .notified,
        total: Counters,
        last: Counters? = nil,
        window: Int? = 258_400
    ) -> CodexUsageObservation {
        .init(threadID: "thread-1", turnID: turn, turnAttribution: attribution, ordinal: ordinal, last: last ?? total, total: total, modelContextWindow: window)
    }

    private func makeAccumulator(origin: CodexThreadOrigin = .fresh) -> AgentUsageAccumulator {
        var accumulator = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .productionClaude)
        accumulator.beginCodexExecution(executionID: execution, threadOrigin: origin)
        return accumulator
    }

    private func dispatch(_ accumulator: inout AgentUsageAccumulator, turn: String, model: String? = "gpt-5.3-codex", snapshot: OpenAIPricingSnapshot = CodexUsageAccountingTests.snapshot()) {
        accumulator.registerCodexDispatch(executionID: execution, requestedModelID: model, pricing: snapshot)
        accumulator.bindCodexTurn(executionID: execution, turnID: turn)
    }

    private func observe(_ accumulator: inout AgentUsageAccumulator, _ observation: CodexUsageObservation) -> AgentUsageIngestOutcome {
        accumulator.observeCodexUsage(observation, executionID: execution, at: start)
    }

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text)!
    }

    private func project(_ accumulator: AgentUsageAccumulator) -> Usage {
        Usage.projected(selectedAgent: .codexExec, accounting: accumulator, expectedOwnerSessionID: owner)
    }

    // MARK: - Controller companion parsing

    func testControllerCompanionPreservesOptionalCountersAndTurnIdentityProvenance() throws {
        let params: [String: Any] = [
            "threadId": "thread-1",
            "turnId": "turn-7",
            "tokenUsage": [
                "last": ["inputTokens": 21498, "cachedInputTokens": 1408, "outputTokens": 90, "reasoningOutputTokens": 30, "totalTokens": 21588],
                "total": ["inputTokens": 39672, "cachedInputTokens": 2816, "outputTokens": 631, "reasoningOutputTokens": 419, "totalTokens": 40303, "cacheWriteInputTokens": 0],
                "modelContextWindow": 258_400
            ]
        ]
        let notified = try XCTUnwrap(CodexNativeSessionController.test_parseUsageObservation(from: params, routingCurrentTurnID: "stale", ordinal: 3))
        XCTAssertEqual(notified.threadID, "thread-1")
        XCTAssertEqual(notified.turnID, "turn-7")
        XCTAssertEqual(notified.turnAttribution, .notified)
        XCTAssertEqual(notified.ordinal, 3)
        XCTAssertEqual(notified.modelContextWindow, 258_400)
        XCTAssertEqual(notified.last, counters(21498, 1408, 90, reasoning: 30, cacheWrite: nil), "cacheWriteInputTokens absent stays nil")
        XCTAssertNil(notified.last?.cacheWriteInputTokens)
        XCTAssertEqual(notified.total?.cacheWriteInputTokens, 0, "an explicit zero is preserved as zero")
        XCTAssertEqual(notified.total?.totalTokens, 40303)

        var withoutTurn = params
        withoutTurn["turnId"] = nil
        let inferred = try XCTUnwrap(CodexNativeSessionController.test_parseUsageObservation(from: withoutTurn, routingCurrentTurnID: "routing-turn", ordinal: 4))
        XCTAssertEqual(inferred.turnID, "routing-turn")
        XCTAssertEqual(inferred.turnAttribution, .inferredCurrentTurn)
        let unknown = try XCTUnwrap(CodexNativeSessionController.test_parseUsageObservation(from: withoutTurn, routingCurrentTurnID: nil, ordinal: 5))
        XCTAssertNil(unknown.turnID)
        XCTAssertEqual(unknown.turnAttribution, .unknown)

        // Non-integral, boolean or non-numeric counters are missing, never zero.
        let malformed: [String: Any] = [
            "threadId": "thread-1", "turnId": "turn-8",
            "tokenUsage": ["total": ["inputTokens": 1.5, "cachedInputTokens": true, "outputTokens": "x", "reasoningOutputTokens": NSNull()]]
        ]
        let parsed = try XCTUnwrap(CodexNativeSessionController.test_parseUsageObservation(from: malformed))
        XCTAssertEqual(parsed.total, Counters())
        XCTAssertNil(parsed.last)
        XCTAssertNil(CodexNativeSessionController.test_parseUsageObservation(from: ["threadId": "thread-1", "turnId": "turn-9"]))

        let reroute = try XCTUnwrap(CodexNativeSessionController.test_parseModelReroute(from: [
            "threadId": "thread-1", "turnId": "turn-7", "fromModel": "gpt-5.3-codex", "toModel": "gpt-5.6-cyber", "reason": "highRiskCyberActivity"
        ]))
        XCTAssertEqual(reroute, .init(threadID: "thread-1", turnID: "turn-7", fromModel: "gpt-5.3-codex", toModel: "gpt-5.6-cyber", reason: "highRiskCyberActivity"))
        XCTAssertNil(CodexNativeSessionController.test_parseModelReroute(from: ["threadId": "thread-1", "fromModel": "a"]))
    }

    func testDecodedWireBooleansNegativesAndInconsistentSubsetsNeverBecomeAuthority() throws {
        // Real decoded JSON: booleans arrive as CFBoolean NSNumbers that would bridge to 1/0.
        let bytes = Data(#"{"threadId":"thread-1","turnId":"t","tokenUsage":{"total":{"inputTokens":true,"cachedInputTokens":false,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0,"totalTokens":10},"modelContextWindow":true}}"#.utf8)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let parsed = try XCTUnwrap(CodexNativeSessionController.test_parseUsageObservation(from: decoded))
        XCTAssertNil(parsed.total?.inputTokens)
        XCTAssertNil(parsed.total?.cachedInputTokens)
        XCTAssertEqual(parsed.total?.cacheWriteInputTokens, 0)
        XCTAssertEqual(parsed.total?.outputTokens, 10)
        XCTAssertNil(parsed.modelContextWindow)
        XCTAssertNil(CodexUsageObservationParser.integer(true))
        XCTAssertNil(CodexUsageObservationParser.integer(NSNumber(value: false)))
        XCTAssertEqual(CodexUsageObservationParser.integer(NSNumber(value: 7)), 7)

        // A negative absolute checkpoint is not accounting authority and cannot become a baseline.
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(-1, 0, 0))), .rejected(.unidentifiedObservation))
        XCTAssertNil(accumulator.record)
        XCTAssertEqual(observe(&accumulator, observation(2, total: counters(5, 0, 0))), .accepted)
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.inputTokens, 5, "no manufactured delta from a rejected negative baseline")

        // Cached input exceeding input keeps the owned counts but is excluded from CH and unpriced.
        var inconsistent = makeAccumulator()
        dispatch(&inconsistent, turn: "t1")
        XCTAssertEqual(observe(&inconsistent, observation(1, total: counters(100, 10, 0))), .accepted)
        dispatch(&inconsistent, turn: "t2")
        XCTAssertEqual(observe(&inconsistent, observation(2, turn: "t2", total: counters(110, 40, 0))), .accepted)
        let record = try XCTUnwrap(inconsistent.record)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 10)
        XCTAssertEqual(record.codexIntervals?.last?.cachedInputTokens, 30)
        XCTAssertNil(record.codexIntervals?.last?.estimatedCostLowerUSD)
        XCTAssertEqual(record.codexIntervals?.last?.coverage, .partial)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?.last?.diagnostic).contains("exceed input"))
        XCTAssertEqual(inconsistent.codexCacheHitShare, .init(ratio: Decimal(10) / Decimal(100), coverage: .partial), "only the consistent interval contributes, and coverage is partial")
        XCTAssertEqual(inconsistent.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertEqual(inconsistent.codexUnpricedIntervalCount, 1)

        var onlyInconsistent = makeAccumulator()
        dispatch(&onlyInconsistent, turn: "t1")
        XCTAssertEqual(observe(&onlyInconsistent, observation(1, total: counters(10, 20, 0))), .accepted)
        XCTAssertNil(onlyInconsistent.codexCacheHitShare, "a 200% share is never displayed")
    }

    // MARK: - Owned intervals, cadence, deduplication and refinement

    func testFreshThreadChargesDisjointIntervalsDedupesDuplicatesAndUpsertsNotifiedRefinements() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        // Rollout cadence: the first event carries total == last.
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(18174, 1408, 541, reasoning: 389))), .accepted)
        let firstRevision = accumulator.ownedRevision
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 1)
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 18174)
        XCTAssertEqual(record.codexIntervals?.first?.cachedInputTokens, 1408)
        XCTAssertEqual(record.codexIntervals?.first?.cacheWriteInputTokens, 0)
        XCTAssertEqual(record.codexIntervals?.first?.outputTokens, 541)
        XCTAssertEqual(record.codexIntervals?.first?.reasoningOutputTokens, 389)
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostLowerUSD, decimal("0.0265435"))
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostUpperUSD, decimal("0.0265435"))
        XCTAssertEqual(record.codexIntervals?.first?.bandKind, "all")
        XCTAssertEqual(record.codexIntervals?.first?.requestedModelID, "gpt-5.3-codex")
        XCTAssertEqual(record.codexIntervals?.first?.coverage, .complete)
        XCTAssertNil(record.codexIntervals?.first?.diagnostic)

        // An exact duplicate total is a no-op; a stale ordinal and a foreign execution are rejected.
        XCTAssertEqual(observe(&accumulator, observation(2, total: counters(18174, 1408, 541, reasoning: 389))), .accepted)
        XCTAssertEqual(accumulator.ownedRevision, firstRevision)
        XCTAssertEqual(observe(&accumulator, observation(2, total: counters(1, 0, 1))), .rejected(.duplicateResult))
        XCTAssertEqual(accumulator.observeCodexUsage(observation(9, total: counters(1, 0, 1)), executionID: UUID(), at: start), .rejected(.disposedExecution))
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 1)

        // A later total for the same notified turn refines that turn's interval from the turn baseline.
        XCTAssertEqual(observe(&accumulator, observation(3, total: counters(39672, 20000, 631, reasoning: 419))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 1)
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 39672)
        XCTAssertEqual(record.codexIntervals?.first?.cachedInputTokens, 20000)
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostLowerUSD, decimal("0.0334"))

        // The next dispatched turn starts a new disjoint interval from the previous checkpoint.
        dispatch(&accumulator, turn: "t2")
        XCTAssertEqual(observe(&accumulator, observation(4, turn: "t2", total: counters(40672, 20500, 700, reasoning: 450))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.codexIntervals?.count, 2)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 1000)
        XCTAssertEqual(record.codexIntervals?.last?.cachedInputTokens, 500)
        XCTAssertEqual(record.codexIntervals?.last?.outputTokens, 69)
        XCTAssertEqual(record.codexIntervals?.last?.estimatedCostLowerUSD, decimal("0.0013775"))
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertEqual(accumulator.codexSessionCostEstimate, .init(amount: decimal("0.0347775"), currency: "USD", coverage: .complete))
        XCTAssertEqual(accumulator.codexCacheHitShare, .init(ratio: Decimal(20500) / Decimal(40672), coverage: .complete))
        XCTAssertEqual(accumulator.codexUnpricedIntervalCount, 0)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 0)

        let projection = project(accumulator)
        XCTAssertEqual(projection.scope, .codex)
        XCTAssertNil(projection.unavailableReason)
        XCTAssertNil(projection.coverageDetail)
        XCTAssertEqual(projection.presentation.cacheHitRatioLabel, "Cache Hit Ratio")
        XCTAssertEqual(projection.presentation.cacheHitRatioValue, "50.4%")
        XCTAssertEqual(projection.presentation.costEstimateLabel, "API Cost Estimates")
        XCTAssertEqual(projection.presentation.costEstimateValue, "$0.03")
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: 50.4% · API Cost Estimates: $0.03")
        XCTAssertTrue(projection.presentation.detailText.contains("Standard/global list prices"))
        XCTAssertTrue(projection.presentation.detailText.contains("pricing version"))
        for forbidden in ["invoice", "subscription", "grand total", "≥"] {
            XCTAssertFalse(projection.presentation.detailText.contains(forbidden), forbidden)
        }
        XCTAssertNil(Usage.projected(selectedAgent: .claudeCode, accounting: accumulator, expectedOwnerSessionID: owner).cacheHitShare, "Codex intervals never feed the Claude readout")
    }

    func testRollbackAndOlderTurnReplayNeverRefundOrDoubleCount() throws {
        // Trigger A: the same notified turn reports 100 then 80. The accepted interval is kept,
        // nothing is refunded, and tracking resumes prospectively from 80.
        var rollback = makeAccumulator()
        dispatch(&rollback, turn: "t1")
        XCTAssertEqual(observe(&rollback, observation(1, total: counters(100, 0, 0))), .accepted)
        XCTAssertEqual(observe(&rollback, observation(2, total: counters(80, 0, 0))), .acceptedWithMonetaryRejection(.unexplainedDecrease))
        var record = try XCTUnwrap(rollback.record)
        XCTAssertEqual(record.codexIntervals?.count, 2)
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 100)
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostLowerUSD, decimal("0.000125"), "the accepted amount is never overwritten with a smaller one")
        XCTAssertEqual(record.codexIntervals?.first?.coverage, .complete)
        XCTAssertNil(record.codexIntervals?.last?.inputTokens)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?.last?.diagnostic).contains("decreased"))
        XCTAssertTrue(record.hasUnmeasuredHistory)
        XCTAssertEqual(rollback.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertEqual(observe(&rollback, observation(3, total: counters(120, 0, 0))), .accepted)
        record = try XCTUnwrap(rollback.record)
        XCTAssertEqual(record.codexIntervals?.count, 3)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 40, "prospective baseline is the decreased checkpoint")
        XCTAssertNil(record.semanticViolation)

        // Trigger B: t1=100, t2=200, a replay of t1=100 with a newer delivery ordinal, then t2=220.
        var replay = makeAccumulator()
        dispatch(&replay, turn: "t1")
        XCTAssertEqual(observe(&replay, observation(1, total: counters(100, 0, 0))), .accepted)
        dispatch(&replay, turn: "t2")
        XCTAssertEqual(observe(&replay, observation(2, turn: "t2", total: counters(200, 0, 0))), .accepted)
        let revisionBeforeReplay = replay.ownedRevision
        XCTAssertEqual(observe(&replay, observation(3, turn: "t1", total: counters(100, 0, 0))), .rejected(.replayedOrSynthetic))
        XCTAssertEqual(replay.ownedRevision, revisionBeforeReplay)
        XCTAssertEqual(replay.record?.codexIntervals?.count, 2)
        XCTAssertFalse(try XCTUnwrap(replay.record?.hasUnmeasuredHistory), "an older-turn replay never rebaselines")
        XCTAssertEqual(observe(&replay, observation(4, turn: "t2", total: counters(220, 0, 0))), .accepted)
        record = try XCTUnwrap(replay.record)
        XCTAssertEqual(record.codexIntervals?.map(\.inputTokens), [100, 120], "220 counted once, not 320")
        XCTAssertEqual(replay.codexSessionCostEstimate, .init(amount: decimal("0.000275"), currency: "USD", coverage: .complete))
        XCTAssertEqual(replay.codexCacheHitShare, .init(ratio: 0, coverage: .complete))
        XCTAssertEqual(observe(&replay, observation(5, turn: "t2", total: counters(220, 0, 0))), .accepted, "an exact duplicate of the current checkpoint is a no-op")
        XCTAssertEqual(replay.record?.codexIntervals?.count, 2)
    }

    /// Review R2 (OracleA P0#1): an older bound turn whose *first* usage report arrives late is
    /// rejected by binding order, never rebaselined. t1 bound and closed without usage, t2=200,
    /// delayed t1=100, t3=300 must count 300 once (200 + 100), not 400 (200 + 200).
    func testDelayedFirstReportOfAnOlderBoundTurnIsRejectedNotRebaselined() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        accumulator.closeCodexTurn(executionID: execution, turnID: "t1")
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 1)
        dispatch(&accumulator, turn: "t2")
        XCTAssertEqual(observe(&accumulator, observation(1, turn: "t2", total: counters(200, 0, 0))), .accepted)
        XCTAssertEqual(accumulator.record?.codexIntervals?.map(\.inputTokens), [nil, 200])

        let revisionBeforeLateReport = accumulator.ownedRevision
        XCTAssertEqual(
            observe(&accumulator, observation(2, turn: "t1", total: counters(100, 0, 0))),
            .rejected(.replayedOrSynthetic),
            "t1 was bound before the turn owning the latest checkpoint: its late first report is demonstrably older"
        )
        XCTAssertEqual(accumulator.ownedRevision, revisionBeforeLateReport, "a rejected older report changes no state")
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 2)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 1, "t1 stays unmeasured rather than becoming a refund or a second baseline")
        XCTAssertFalse(try XCTUnwrap(accumulator.record?.hasUnmeasuredHistory), "no prospective rebaseline happened")

        dispatch(&accumulator, turn: "t3")
        XCTAssertEqual(observe(&accumulator, observation(3, turn: "t3", total: counters(300, 0, 0))), .accepted)
        let record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.map(\.inputTokens), [nil, 200, 100], "300 counted once: t1's work is inside t2's accepted interval")
        XCTAssertEqual(record.codexIntervals?.compactMap(\.inputTokens).reduce(0, +), 300)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.amount, decimal("0.000375"))
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .partial, "t1's marker keeps coverage honest; nothing overlaps")
        XCTAssertNil(record.semanticViolation)

        // The same ordering without any marker (t1 bound, never closed, first report late).
        var unclosed = makeAccumulator()
        dispatch(&unclosed, turn: "t1")
        dispatch(&unclosed, turn: "t2")
        XCTAssertEqual(observe(&unclosed, observation(1, turn: "t2", total: counters(200, 0, 0))), .accepted)
        XCTAssertEqual(observe(&unclosed, observation(2, turn: "t1", total: counters(100, 0, 0))), .rejected(.replayedOrSynthetic))
        dispatch(&unclosed, turn: "t3")
        XCTAssertEqual(observe(&unclosed, observation(3, turn: "t3", total: counters(300, 0, 0))), .accepted)
        XCTAssertEqual(unclosed.record?.codexIntervals?.map(\.inputTokens), [200, 100])
        unclosed.endCodexExecution(executionID: execution)
        XCTAssertEqual(unclosed.codexUnmeasuredWorkCount, 1, "t1 never produced an accepted report and is marked at execution end")
    }

    /// Review R2 (OracleA P1#4, fix-induced): closing another turn without usage creates a marker
    /// but never revokes the open turn's refinement ownership. t1=100, t2 dispatched and closed,
    /// delayed monotone refinement t1=120 still refines t1's interval; a late t2 report then
    /// upserts t2's marker from the refined checkpoint.
    func testClosingAnUnmeasuredTurnKeepsTheOpenTurnRefinableAndLateUsageUpsertsItsMarker() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(100, 0, 0))), .accepted)
        dispatch(&accumulator, turn: "t2")
        accumulator.closeCodexTurn(executionID: execution, turnID: "t2")
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 2)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 1)

        XCTAssertEqual(observe(&accumulator, observation(2, turn: "t1", total: counters(120, 0, 0))), .accepted, "t1 still owns the latest checkpoint")
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 2, "the refinement upserts t1's interval; nothing is appended")
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 120)
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostLowerUSD, decimal("0.00015"))
        XCTAssertEqual(record.codexIntervals?.last?.coverage, .unavailable, "t2's marker is untouched by t1's refinement")
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 1)

        XCTAssertEqual(observe(&accumulator, observation(3, turn: "t2", total: counters(150, 0, 0))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 2, "the late t2 report replaces its marker in place")
        XCTAssertEqual(record.codexIntervals?.map(\.inputTokens), [120, 30], "t2 is priced from the refined checkpoint; 150 counted once")
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 0)
        XCTAssertEqual(accumulator.codexSessionCostEstimate, .init(amount: decimal("0.0001875"), currency: "USD", coverage: .complete))
        XCTAssertEqual(observe(&accumulator, observation(4, turn: "t1", total: counters(130, 0, 0))), .rejected(.replayedOrSynthetic), "t1 is no longer the checkpoint owner")
        XCTAssertNil(record.semanticViolation)
    }

    /// Review R2 (OracleA P1#2 / OracleB N1, N2): dispatch tracking is independent of the optional
    /// pricing snapshot, and a dispatch whose local send failed is withdrawn without a marker;
    /// a completion without any turn identity marks outstanding dispatched work.
    func testDispatchTrackingIsIndependentOfPricingAndWithdrawnSendsLeaveNoMarker() throws {
        // Unpriced dispatch: bound, awaited, marked unmeasured on closure; late usage counts but is unpriced.
        var unpriced = makeAccumulator()
        let ticket = unpriced.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: nil)
        XCTAssertNotNil(ticket)
        unpriced.bindCodexTurn(executionID: execution, turnID: "t1")
        unpriced.closeCodexTurn(executionID: execution, turnID: "t1")
        var record = try XCTUnwrap(unpriced.record)
        XCTAssertEqual(record.codexIntervals?.map(\.turnID), ["t1"])
        XCTAssertEqual(record.codexIntervals?.first?.coverage, .unavailable)
        XCTAssertEqual(unpriced.codexUnmeasuredWorkCount, 1, "an unpriced dispatch that ends without usage is still unmeasured work")
        XCTAssertEqual(observe(&unpriced, observation(1, total: counters(100, 0, 0))), .accepted)
        record = try XCTUnwrap(unpriced.record)
        XCTAssertEqual(record.codexIntervals?.count, 1, "late usage upserts the marker")
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 100)
        XCTAssertNil(record.codexIntervals?.first?.estimatedCostLowerUSD, "no pricing basis: counted, not priced")
        XCTAssertEqual(record.codexIntervals?.first?.diagnostic, "no dispatch pricing basis bound to this turn")
        XCTAssertEqual(unpriced.codexUnmeasuredWorkCount, 0)
        unpriced.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: nil)
        unpriced.endCodexExecution(executionID: execution)
        XCTAssertEqual(unpriced.record?.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic, "an unbound unpriced dispatch is marked at execution end")

        // Withdrawn dispatch: no marker now, none on the next dispatch, none at execution end.
        var withdrawn = makeAccumulator()
        let failed = withdrawn.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        withdrawn.withdrawCodexDispatch(failed)
        XCTAssertEqual(withdrawn.codexIntervalCount, 0)
        let accepted = withdrawn.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        XCTAssertEqual(withdrawn.codexIntervalCount, 0, "a withdrawn dispatch is not 'never bound' work")
        withdrawn.bindCodexTurn(executionID: execution, turnID: "t1")
        withdrawn.withdrawCodexDispatch(accepted)
        withdrawn.closeCodexTurn(executionID: execution, turnID: "t1")
        XCTAssertEqual(withdrawn.codexUnmeasuredWorkCount, 1, "withdrawing an already bound ticket is a no-op; the bound turn stays awaited")
        withdrawn.withdrawCodexDispatch(failed)
        withdrawn.withdrawCodexDispatch(CodexDispatchTicket(executionID: UUID(), serial: 0))
        withdrawn.endCodexExecution(executionID: execution)
        XCTAssertEqual(withdrawn.codexUnmeasuredWorkCount, 1)

        // Presentation binding also requires a live pending ticket. A withdrawn dispatch cannot be
        // rebound by a repeated old start or by a newly observed turn that had no dispatch.
        var rebound = makeAccumulator()
        dispatch(&rebound, turn: "old")
        XCTAssertEqual(
            observe(&rebound, observation(1, turn: "old", total: counters(100, 20, 1), last: counters(10, 2, 1))),
            .accepted
        )
        let rejectedTicket = rebound.registerCodexDispatch(
            executionID: execution,
            requestedModelID: "gpt-5.3-codex",
            pricing: Self.snapshot()
        )
        rebound.withdrawCodexDispatch(rejectedTicket)
        let definitivelyWithdrawn = try XCTUnwrap(rebound.latestRequestCacheHit(for: .codexLast))
        XCTAssertNil(definitivelyWithdrawn.turnID)
        XCTAssertNil(definitivelyWithdrawn.share)
        XCTAssertTrue(definitivelyWithdrawn.detail.contains("definitively not submitted"))

        rebound.bindCodexTurn(executionID: execution, turnID: "old")
        XCTAssertEqual(
            observe(&rebound, observation(2, turn: "old", total: counters(100, 20, 1), last: counters(10, 9, 1))),
            .accepted,
            "the prior checkpoint owner remains refinable for accounting, but has no ticket to bind presentation"
        )
        XCTAssertNil(rebound.latestRequestCacheHit(for: .codexLast)?.turnID)
        XCTAssertNil(rebound.latestRequestCacheHit(for: .codexLast)?.share)

        rebound.bindCodexTurn(executionID: execution, turnID: "unbound")
        XCTAssertEqual(
            observe(&rebound, observation(3, turn: "unbound", total: counters(150, 30, 2), last: counters(10, 8, 1))),
            .accepted
        )
        XCTAssertNil(rebound.latestRequestCacheHit(for: .codexLast)?.turnID)
        XCTAssertNil(rebound.latestRequestCacheHit(for: .codexLast)?.share)

        rebound.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        rebound.bindCodexTurn(executionID: execution, turnID: "owned")
        XCTAssertEqual(
            observe(&rebound, observation(4, turn: "owned", total: counters(200, 40, 3), last: counters(10, 7, 1))),
            .accepted
        )
        XCTAssertEqual(rebound.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.7"))

        // Acceptance is independent of optional turn identity. An exact accepted ticket cannot be
        // withdrawn by a later contradictory error; stale tickets cannot mutate its obligation.
        var acceptedAnonymous = makeAccumulator()
        let acceptedAnonymousTicket = try XCTUnwrap(acceptedAnonymous.registerCodexDispatch(
            executionID: execution,
            requestedModelID: "gpt-5.3-codex",
            pricing: nil
        ))
        acceptedAnonymous.acceptCodexDispatch(acceptedAnonymousTicket)
        acceptedAnonymous.withdrawCodexDispatch(CodexDispatchTicket(
            executionID: execution,
            serial: acceptedAnonymousTicket.serial &+ 1
        ))
        acceptedAnonymous.withdrawCodexDispatch(acceptedAnonymousTicket)
        acceptedAnonymous.endCodexExecution(executionID: execution)
        XCTAssertEqual(acceptedAnonymous.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(acceptedAnonymous.record?.codexIntervals?.count, 1)
        XCTAssertEqual(
            acceptedAnonymous.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )

        // Unidentified completion: outstanding dispatched work becomes unmeasured; nothing outstanding is a no-op.
        var anonymous = makeAccumulator()
        anonymous.closeUnidentifiedCodexTurn(executionID: execution)
        XCTAssertEqual(anonymous.codexIntervalCount, 0)
        anonymous.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        anonymous.closeUnidentifiedCodexTurn(executionID: execution)
        record = try XCTUnwrap(anonymous.record)
        XCTAssertEqual(record.codexIntervals?.count, 1)
        XCTAssertNil(record.codexIntervals?.first?.turnID)
        XCTAssertEqual(record.codexIntervals?.first?.diagnostic, AgentUsageAccumulator.codexUnmeasuredAnonymousTurnDiagnostic)
        anonymous.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        XCTAssertEqual(anonymous.codexIntervalCount, 1, "the anonymous dispatch was consumed by its marker; no second marker")
        anonymous.bindCodexTurn(executionID: execution, turnID: "t2")
        anonymous.closeUnidentifiedCodexTurn(executionID: execution)
        XCTAssertEqual(anonymous.record?.codexIntervals?.map(\.turnID), [nil, "t2"])
        XCTAssertEqual(observe(&anonymous, observation(1, turn: "t2", total: counters(100, 0, 0))), .accepted)
        XCTAssertEqual(anonymous.record?.codexIntervals?.count, 2, "a provably owned late report upserts the bound turn's marker")
        XCTAssertEqual(anonymous.codexUnmeasuredWorkCount, 1)
        XCTAssertNil(anonymous.record?.semanticViolation)
    }

    func testResumedThreadStartsProspectivelyAndUnattributedOrRebaselinedIntervalsStayUnpriced() throws {
        var accumulator = makeAccumulator(origin: .resumed)
        dispatch(&accumulator, turn: "t1")
        // Inherited usage: the first checkpoint is not charged and marks unmeasured history.
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(50000, 10000, 2000))), .accepted)
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertTrue(record.hasUnmeasuredHistory)
        XCTAssertEqual(record.codexIntervals?.count, 1)
        XCTAssertNil(record.codexIntervals?.first?.inputTokens)
        XCTAssertNil(record.codexIntervals?.first?.estimatedCostLowerUSD)
        XCTAssertEqual(record.codexIntervals?.first?.coverage, .partial)
        XCTAssertNil(accumulator.codexSessionCostEstimate)
        XCTAssertNil(accumulator.codexCacheHitShare)

        // The next checkpoint charges only the owned delta; coverage stays partial.
        XCTAssertEqual(observe(&accumulator, observation(2, total: counters(51000, 10500, 2010))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 1000)
        XCTAssertEqual(record.codexIntervals?.last?.cachedInputTokens, 500)
        XCTAssertEqual(record.codexIntervals?.last?.estimatedCostLowerUSD, decimal("0.0007875"))
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertEqual(accumulator.codexCacheHitShare?.coverage, .partial)

        // Inferred turn identity is diagnostic only: counted for CH, never priced.
        XCTAssertEqual(observe(&accumulator, observation(3, turn: "guess", attribution: .inferredCurrentTurn, total: counters(52000, 11500, 2020))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 3)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 1000)
        XCTAssertNil(record.codexIntervals?.last?.estimatedCostLowerUSD)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?.last?.diagnostic).contains("inferred"))
        XCTAssertEqual(accumulator.codexUnpricedIntervalCount, 2)
        XCTAssertEqual(accumulator.codexCacheHitShare?.ratio, Decimal(1500) / Decimal(2000))

        // A decrease rebaselines prospectively without a negative interval or an inferred reset.
        dispatch(&accumulator, turn: "t4")
        XCTAssertEqual(
            observe(&accumulator, observation(4, turn: "t4", total: counters(1000, 100, 10))),
            .acceptedWithMonetaryRejection(.unexplainedDecrease)
        )
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 4)
        XCTAssertNil(record.codexIntervals?.last?.inputTokens)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?.last?.diagnostic).contains("decreased"))
        XCTAssertEqual(observe(&accumulator, observation(5, turn: "t4", total: counters(1500, 200, 15))), .accepted)
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.inputTokens, 500, "prospective baseline is the decreased total")
        XCTAssertNil(accumulator.record?.semanticViolation)

        let projection = project(accumulator)
        XCTAssertEqual(projection.costEstimate?.coverage, .partial)
        XCTAssertFalse(projection.presentation.costEstimateValue.contains("partial"), "coverage lives in the details only")
        XCTAssertTrue(projection.presentation.detailText.contains("(partial coverage)"))
        XCTAssertTrue(try XCTUnwrap(projection.coverageDetail).contains("inherited usage baseline unknown"))
        XCTAssertTrue(try XCTUnwrap(projection.coverageDetail).contains("turn identity inferred from routing state only"))

        // A new controller generation is a new execution; the old one is disposed.
        let next = UUID()
        accumulator.beginCodexExecution(executionID: next, threadOrigin: .resumed)
        XCTAssertEqual(observe(&accumulator, observation(6, total: counters(1, 0, 1))), .rejected(.disposedExecution))
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 5)
    }

    func testReroutesUnlistedModelsAndMissingBasisAreUnpricedWhileCountsStayOwned() throws {
        var accumulator = makeAccumulator()
        // Reroute known before the usage lands: the turn's cost is partial, its counts are owned.
        dispatch(&accumulator, turn: "t1")
        accumulator.noteCodexReroute(executionID: execution, reroute: .init(threadID: "thread-1", turnID: "t1", fromModel: "gpt-5.3-codex", toModel: "gpt-5.6-cyber", reason: "highRiskCyberActivity"))
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 100, 10))), .accepted)
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 1000)
        XCTAssertNil(record.codexIntervals?.first?.estimatedCostLowerUSD)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?.first?.diagnostic).contains("rerouted to gpt-5.6-cyber"))

        // Reroute after the interval was priced retracts the estimate for that turn only.
        dispatch(&accumulator, turn: "t2")
        XCTAssertEqual(observe(&accumulator, observation(2, turn: "t2", total: counters(2000, 200, 20))), .accepted)
        XCTAssertNotNil(accumulator.record?.codexIntervals?.last?.estimatedCostLowerUSD)
        accumulator.noteCodexReroute(executionID: execution, reroute: .init(threadID: "thread-1", turnID: "t2", fromModel: "gpt-5.3-codex", toModel: "gpt-5.6-cyber", reason: nil))
        record = try XCTUnwrap(accumulator.record)
        XCTAssertNil(record.codexIntervals?.last?.estimatedCostLowerUSD)
        XCTAssertEqual(record.codexIntervals?.last?.coverage, .partial)
        XCTAssertEqual(record.codexIntervals?.first?.inputTokens, 1000, "the earlier interval is untouched")

        // Unlisted requested model (never inferred from a family name) and an unbound turn stay unpriced.
        dispatch(&accumulator, turn: "t3", model: "gpt-5.6-sol")
        XCTAssertEqual(observe(&accumulator, observation(3, turn: "t3", total: counters(3000, 300, 30))), .accepted)
        XCTAssertTrue(try XCTUnwrap(accumulator.record?.codexIntervals?.last?.diagnostic).contains("no Standard/global list price"))
        XCTAssertEqual(observe(&accumulator, observation(4, turn: "never-dispatched", total: counters(4000, 400, 40))), .accepted)
        XCTAssertTrue(try XCTUnwrap(accumulator.record?.codexIntervals?.last?.diagnostic).contains("no dispatch pricing basis"))

        // A reviewed alias resolves to the exact priced ID and records both.
        let aliased = Self.snapshot(model: "gpt-5.3-codex", aliases: [.init(alias: "codex-latest", targetModelID: "gpt-5.3-codex")])
        dispatch(&accumulator, turn: "t5", model: "codex-latest", snapshot: aliased)
        XCTAssertEqual(observe(&accumulator, observation(5, turn: "t5", total: counters(5000, 500, 50))), .accepted)
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.requestedModelID, "codex-latest")
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.resolvedModelID, "gpt-5.3-codex")
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.estimatedCostLowerUSD, decimal("0.0012375"))
        XCTAssertEqual(accumulator.codexUnpricedIntervalCount, 4)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertNil(accumulator.record?.semanticViolation)
    }

    func testLateRerouteUnpricesEveryIntervalOfTheNamedTurnOnly() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(100, 0, 0))), .accepted)
        // A rollback splits t1 into two owned intervals around a prospective marker.
        XCTAssertEqual(observe(&accumulator, observation(2, total: counters(80, 0, 0))), .acceptedWithMonetaryRejection(.unexplainedDecrease))
        XCTAssertEqual(observe(&accumulator, observation(3, total: counters(120, 0, 0))), .accepted)
        dispatch(&accumulator, turn: "t2")
        XCTAssertEqual(observe(&accumulator, observation(4, turn: "t2", total: counters(200, 0, 0))), .accepted)
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.map { $0.estimatedCostLowerUSD != nil }, [true, false, true, true])
        XCTAssertNotNil(record.codexIntervals?[0].appliedPricing)

        // The reroute for t1 arrives after t2 is already open: every priced t1 interval is withdrawn.
        accumulator.noteCodexReroute(executionID: execution, reroute: .init(threadID: "thread-1", turnID: "t1", fromModel: "gpt-5.3-codex", toModel: "gpt-5.6-cyber", reason: "highRiskCyberActivity"))
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.map { $0.estimatedCostLowerUSD != nil }, [false, false, false, true])
        XCTAssertEqual(record.codexIntervals?[0].coverage, .partial)
        XCTAssertNil(record.codexIntervals?[0].appliedPricing)
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?[0].diagnostic).contains("rerouted to gpt-5.6-cyber"))
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?[2].diagnostic).contains("rerouted to gpt-5.6-cyber"))
        XCTAssertTrue(try XCTUnwrap(record.codexIntervals?[1].diagnostic).contains("decreased"), "the prospective marker keeps its own diagnostic")
        XCTAssertEqual(record.codexIntervals?.map(\.inputTokens), [100, nil, 40, 80], "token counts stay owned")
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.amount, decimal("0.0001"), "only t2 remains priced")

        // A reroute without a turn identity withdraws the open turn and applies to the next bound turn.
        accumulator.noteCodexReroute(executionID: execution, reroute: .init(threadID: "thread-1", turnID: nil, fromModel: "gpt-5.3-codex", toModel: "gpt-x", reason: nil))
        XCTAssertNil(accumulator.record?.codexIntervals?[3].estimatedCostLowerUSD)
        dispatch(&accumulator, turn: "t3")
        XCTAssertEqual(observe(&accumulator, observation(5, turn: "t3", total: counters(300, 0, 0))), .accepted)
        XCTAssertTrue(try XCTUnwrap(accumulator.record?.codexIntervals?.last?.diagnostic).contains("rerouted to gpt-x"))
        XCTAssertNil(accumulator.codexSessionCostEstimate)
        XCTAssertNil(accumulator.record?.semanticViolation)
    }

    // MARK: - Dispatched work without usage

    func testDispatchedWorkEndingWithoutUsageIsUnmeasuredNotZero() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 100, 10))), .accepted)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .complete)

        // t2 is dispatched and bound, then reported terminal without any usage notification.
        dispatch(&accumulator, turn: "t2")
        accumulator.closeCodexTurn(executionID: execution, turnID: "t2")
        var record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 2)
        XCTAssertEqual(record.codexIntervals?.last?.coverage, .unavailable)
        XCTAssertEqual(record.codexIntervals?.last?.turnID, "t2")
        XCTAssertEqual(record.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accumulator.codexUnpricedIntervalCount, 0)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.amount, decimal("0.0012375"), "accepted amounts are retained")
        XCTAssertEqual(accumulator.codexCacheHitShare?.coverage, .partial)
        var projection = project(accumulator)
        XCTAssertEqual(projection.costEstimate?.coverage, .partial)
        XCTAssertEqual(projection.presentation.costEstimateValue, "<$0.01", "no partial suffix on the value")
        XCTAssertTrue(
            try XCTUnwrap(projection.sessionCostCoverageDetail)
                .contains(AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        )
        accumulator.closeCodexTurn(executionID: execution, turnID: "never-dispatched")
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 2, "closing an unknown turn is a no-op")

        // A provably owned late observation for t2 replaces the marker with the measured interval.
        XCTAssertEqual(observe(&accumulator, observation(2, turn: "t2", total: counters(2000, 200, 20))), .accepted)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 2)
        XCTAssertEqual(record.codexIntervals?.last?.inputTokens, 1000)
        XCTAssertEqual(record.codexIntervals?.last?.coverage, .complete)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 0)
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.coverage, .complete)

        // Execution end: a bound turn without usage and a dispatch never bound to a turn are both unmeasured.
        dispatch(&accumulator, turn: "t3")
        accumulator.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        accumulator.endCodexExecution(executionID: execution)
        record = try XCTUnwrap(accumulator.record)
        XCTAssertEqual(record.codexIntervals?.count, 4)
        XCTAssertEqual(record.codexIntervals?[2].turnID, "t3")
        XCTAssertEqual(record.codexIntervals?[2].coverage, .unavailable)
        XCTAssertNil(record.codexIntervals?[3].turnID)
        XCTAssertEqual(record.codexIntervals?[3].turnAttribution, "unknown")
        XCTAssertEqual(record.codexIntervals?[3].diagnostic, AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic)
        XCTAssertEqual(accumulator.codexUnmeasuredWorkCount, 2)
        XCTAssertNil(record.semanticViolation)
        accumulator.endCodexExecution(executionID: execution)
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 4, "ending twice adds nothing")
        projection = project(accumulator)
        let endedCoverage = try XCTUnwrap(projection.sessionCostCoverageDetail)
        XCTAssertTrue(endedCoverage.contains(AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic))
        XCTAssertTrue(endedCoverage.contains(AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic))

        // Ending presentation does not dispose or reset accounting ownership. Re-beginning the
        // same controller generation is idempotent, and the next interval uses the prior total.
        var sameGeneration = makeAccumulator()
        dispatch(&sameGeneration, turn: "t1")
        XCTAssertEqual(observe(&sameGeneration, observation(1, total: counters(1000, 100, 10))), .accepted)
        let beforeEnd = sameGeneration.record
        let ownedRevisionBeforeEnd = sameGeneration.ownedRevision
        sameGeneration.endCodexExecution(executionID: execution)
        XCTAssertNil(sameGeneration.latestRequestCacheHit(for: .codexLast))
        XCTAssertEqual(sameGeneration.record, beforeEnd)
        XCTAssertEqual(sameGeneration.ownedRevision, ownedRevisionBeforeEnd)
        sameGeneration.beginCodexExecution(executionID: execution, threadOrigin: .fresh)
        XCTAssertEqual(sameGeneration.record, beforeEnd, "same-generation begin must not reset the cumulative baseline")
        XCTAssertEqual(sameGeneration.ownedRevision, ownedRevisionBeforeEnd)
        dispatch(&sameGeneration, turn: "t2")
        XCTAssertEqual(observe(&sameGeneration, observation(2, turn: "t2", total: counters(1500, 150, 15))), .accepted)
        XCTAssertEqual(sameGeneration.record?.codexIntervals?.compactMap(\.inputTokens), [1000, 500])
        XCTAssertEqual(sameGeneration.record?.codexIntervals?.compactMap(\.cachedInputTokens), [100, 50])

        // Replacing the execution marks the previous generation's uncovered work as well.
        var replaced = makeAccumulator()
        dispatch(&replaced, turn: "t1")
        replaced.beginCodexExecution(executionID: UUID(), threadOrigin: .fresh)
        XCTAssertEqual(replaced.codexUnmeasuredWorkCount, 1)

        // A second dispatch before the first was bound to a turn marks the first as unmeasured.
        var redispatched = makeAccumulator()
        redispatched.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        redispatched.registerCodexDispatch(executionID: execution, requestedModelID: "gpt-5.3-codex", pricing: Self.snapshot())
        XCTAssertEqual(redispatched.codexUnmeasuredWorkCount, 1)
    }

    // MARK: - Arithmetic

    func testPricingArithmeticUsesOneBandPerRequestAndNeverTreatsMissingRatesAsFree() throws {
        let flat = try XCTUnwrap(Self.snapshot().rates(forModelID: " GPT-5.3-Codex "))
        let flatApplied = CodexUsagePricing.estimate(.init(input: 1000, cached: 200, cacheWrite: 0, output: 10, reasoningOutput: 5), resolution: flat)
        XCTAssertEqual(flatApplied.estimate, .point(decimal("0.001125")))
        XCTAssertEqual(flatApplied.bandKind, "all")
        XCTAssertEqual(flatApplied.appliedRates, Self.flatRates)
        XCTAssertNil(flatApplied.assumption)
        let banded = try XCTUnwrap(Self.bandedSnapshot.rates(forModelID: "gpt-5.3-codex"))
        let summed = CodexUsagePricing.Delta(input: 300_000, cached: 0, cacheWrite: 0, output: 10, reasoningOutput: 0)
        let small = CodexUsagePricing.Delta(input: 1000, cached: 0, cacheWrite: 0, output: 10, reasoningOutput: 0)

        // No window proof and no request size: the summed interval (300K, above the threshold)
        // never decides the band; standard-context rates apply and the assumption is named.
        for missing: Int64? in [nil, 0, -1] {
            let unknown = CodexUsagePricing.estimate(summed, requestContextTokens: missing, resolution: banded)
            XCTAssertEqual(unknown.estimate, .point(decimal("0.3751")), "request size \(String(describing: missing)) is missing")
            XCTAssertEqual(unknown.bandKind, "shortContext")
            XCTAssertEqual(unknown.appliedRates, Self.shortRates)
            XCTAssertEqual(unknown.assumption, "latest request size unavailable; standard-context rates applied")
        }

        // The latest request decides; the summed interval made of small requests stays short.
        let perRequest = CodexUsagePricing.estimate(summed, requestContextTokens: 100_000, resolution: banded)
        XCTAssertEqual(perRequest.estimate, .point(decimal("0.3751")))
        XCTAssertEqual(perRequest.bandKind, "shortContext")
        XCTAssertNil(perRequest.assumption)
        let long = CodexUsagePricing.estimate(summed, requestContextTokens: 300_000, resolution: banded)
        XCTAssertEqual(long.estimate, .point(decimal("0.7502")))
        XCTAssertEqual(long.bandKind, "longContext")
        XCTAssertEqual(long.appliedRates, Self.longRates)
        XCTAssertNil(long.assumption)
        let belowThreshold = CodexUsagePricing.estimate(small, requestContextTokens: 271_999, resolution: banded)
        XCTAssertEqual(belowThreshold.bandKind, "shortContext")
        XCTAssertEqual(belowThreshold.estimate, .point(decimal("0.00135")))
        let atThreshold = CodexUsagePricing.estimate(small, requestContextTokens: 272_000, resolution: banded)
        XCTAssertEqual(atThreshold.bandKind, "longContext", "a request at the threshold is long-context even when the interval delta is small")
        XCTAssertEqual(atThreshold.estimate, .point(decimal("0.0027")))

        // A context window below the threshold proves the short band whatever the request says.
        let windowProof = CodexUsagePricing.estimate(summed, requestContextTokens: 1_000_000, modelContextWindow: 258_400, resolution: banded)
        XCTAssertEqual(windowProof.bandKind, "shortContext")
        XCTAssertEqual(windowProof.estimate, .point(decimal("0.3751")))
        XCTAssertNil(windowProof.assumption)
        XCTAssertEqual(
            CodexUsagePricing.estimate(summed, modelContextWindow: 258_400, resolution: banded).assumption,
            nil,
            "the window proof needs no request size"
        )
        XCTAssertEqual(
            CodexUsagePricing.estimate(summed, requestContextTokens: 300_000, modelContextWindow: 1_000_000, resolution: banded).bandKind,
            "longContext",
            "a window at or above the threshold proves nothing; the request decides"
        )
        // A turn already priced long never drops back to the short band.
        let floored = CodexUsagePricing.estimate(summed, requestContextTokens: 100_000, minimumBand: .longContext, resolution: banded)
        XCTAssertEqual(floored.bandKind, "longContext")
        XCTAssertEqual(floored.estimate, .point(decimal("0.7502")))

        let unattributable = OpenAIModelPricing(modelID: "m", bands: [.init(kind: .shortContext, rates: Self.shortRates), .init(kind: .longContext, rates: Self.longRates)], contextThresholdTokens: nil)
        let unattributableResolution = try XCTUnwrap(OpenAIPricingSnapshot(catalog: .init(models: [unattributable], aliases: []), sourceKind: .bundledSeed, capturedAt: Date(timeIntervalSince1970: 0), validatedAt: Date(timeIntervalSince1970: 0), isStale: false).rates(forModelID: "m"))
        let unstated = CodexUsagePricing.estimate(
            .init(input: 10, cached: 0, cacheWrite: 0, output: 0, reasoningOutput: 0),
            requestContextTokens: 1_000_000,
            resolution: unattributableResolution
        )
        XCTAssertEqual(unstated.estimate, .point(decimal("0.0000125")), "no stated threshold: standard-context rates, one point")
        XCTAssertEqual(unstated.bandKind, "shortContext")
        XCTAssertEqual(unstated.assumption, "long-context qualifier not stated; standard-context rates applied")

        // Only a standard band and no threshold: nothing is assumed.
        let onlyStandard = OpenAIModelPricing(modelID: "o", bands: [.init(kind: .shortContext, rates: Self.shortRates)], contextThresholdTokens: nil)
        let onlyStandardResolution = try XCTUnwrap(OpenAIPricingSnapshot(catalog: .init(models: [onlyStandard], aliases: []), sourceKind: .bundledSeed, capturedAt: Date(timeIntervalSince1970: 0), validatedAt: Date(timeIntervalSince1970: 0), isStale: false).rates(forModelID: "o"))
        let standardOnly = CodexUsagePricing.estimate(
            .init(input: 10, cached: 0, cacheWrite: 0, output: 0, reasoningOutput: 0),
            requestContextTokens: 1_000_000,
            resolution: onlyStandardResolution
        )
        XCTAssertEqual(standardOnly.estimate, .point(decimal("0.0000125")))
        XCTAssertEqual(standardOnly.bandKind, "shortContext")
        XCTAssertNil(standardOnly.assumption)

        let shortOnly = OpenAIModelPricing(modelID: "s", bands: [.init(kind: .shortContext, rates: Self.shortRates)], contextThresholdTokens: 128_000)
        let shortOnlyResolution = try XCTUnwrap(OpenAIPricingSnapshot(catalog: .init(models: [shortOnly], aliases: []), sourceKind: .bundledSeed, capturedAt: Date(timeIntervalSince1970: 0), validatedAt: Date(timeIntervalSince1970: 0), isStale: false).rates(forModelID: "s"))
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 10, cached: 0, cacheWrite: 0, output: 0, reasoningOutput: 0), requestContextTokens: 128_000, resolution: shortOnlyResolution).estimate,
            .unavailable("no listed rates for the request's context band"),
            "an unlisted long band is unavailable, never the cheaper band"
        )

        let missingCached = try XCTUnwrap(Self.snapshot(bands: [.init(kind: .all, rates: .init(input: 1, cachedInput: nil, cacheWrite: nil, output: 1))]).rates(forModelID: "gpt-5.3-codex"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: 10, cached: 5, cacheWrite: 0, output: 1, reasoningOutput: 0), resolution: missingCached).estimate, .unavailable("cached input rate not listed"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: 10, cached: 0, cacheWrite: 0, output: 1, reasoningOutput: 0), resolution: missingCached).estimate, .point(decimal("0.000011")))
        let writeWithoutCachedRate = try XCTUnwrap(Self.snapshot(bands: [.init(kind: .all, rates: .init(input: 1, cachedInput: nil, cacheWrite: 2, output: 1))]).rates(forModelID: "gpt-5.3-codex"))
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 10, cached: 0, cacheWrite: 2, output: 1, reasoningOutput: 0), resolution: writeWithoutCachedRate).estimate,
            .point(decimal("0.000013")),
            "8 × 1 + 2 × 2 + 1 × 1 per million: a missing cached rate is only needed for cached tokens"
        )
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: 10, cached: 0, cacheWrite: 2, output: 1, reasoningOutput: 0), resolution: flat).estimate, .unavailable("cache write rate not listed"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: 10, cached: 8, cacheWrite: 3, output: 1, reasoningOutput: 0), resolution: flat).estimate, .unavailable("cached and cache-write input exceed input"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: nil, cached: 0, cacheWrite: 0, output: 1, reasoningOutput: 0), resolution: flat).estimate, .unavailable("input or output count missing"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: 10, cached: nil, cacheWrite: 0, output: 1, reasoningOutput: 0), resolution: flat).estimate, .unavailable("cached input count missing"))
        XCTAssertEqual(CodexUsagePricing.estimate(.init(input: -1, cached: 0, cacheWrite: 0, output: 1, reasoningOutput: 0), resolution: flat).estimate, .unavailable("negative counter"))
        XCTAssertNil(CodexUsagePricing.delta(from: counters(Int(Int64.min), 0, 0), to: counters(1, 0, 0)), "overflowing arithmetic is unavailable")
    }

    func testCacheWriteCountFirstReportedMidSessionUsesAZeroBaseline() throws {
        let started = try XCTUnwrap(CodexUsagePricing.delta(from: counters(1000, 0, 10, cacheWrite: nil), to: counters(3000, 500, 30, cacheWrite: 400)))
        XCTAssertEqual(started.cacheWrite, 400, "an absent baseline count is the schema default zero")
        XCTAssertEqual(started.input, 2000)
        let stopped = try XCTUnwrap(CodexUsagePricing.delta(from: counters(1000, 0, 10, cacheWrite: 100), to: counters(3000, 500, 30, cacheWrite: nil)))
        XCTAssertNil(stopped.cacheWrite, "a currently absent count stays absent")
        let neither = try XCTUnwrap(CodexUsagePricing.delta(from: counters(1000, 0, 10, cacheWrite: nil), to: counters(3000, 500, 30, cacheWrite: nil)))
        XCTAssertNil(neither.cacheWrite)

        // Accumulator level: the first-reported writes are priced at the write rate.
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", model: "gpt-w", snapshot: Self.writeSnapshot)
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 0, 0, cacheWrite: nil))), .accepted)
        dispatch(&accumulator, turn: "t2", model: "gpt-w", snapshot: Self.writeSnapshot)
        XCTAssertEqual(
            observe(&accumulator, observation(2, turn: "t2", total: counters(2000, 0, 0, cacheWrite: 200), last: counters(1000, 0, 0, cacheWrite: 200))),
            .accepted
        )
        let interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.cacheWriteInputTokens, 200)
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.0042"), "800 × 4 + 200 × 5 per million")
        XCTAssertEqual(interval.coverage, .complete)
    }

    func testAbsentCacheWriteCountIsPricedAsOrdinaryInput() throws {
        // The installed v2 schema defaults an absent cache-write count to zero, so I − C is
        // ordinary input at the input rate whether or not a write rate is listed.
        let write = try XCTUnwrap(Self.writeSnapshot.rates(forModelID: "gpt-w"))
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 1000, cached: 0, cacheWrite: nil, output: 0, reasoningOutput: 0), resolution: write).estimate,
            .point(decimal("0.004"))
        )
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 1000, cached: 1000, cacheWrite: nil, output: 0, reasoningOutput: 0), resolution: write).estimate,
            .point(decimal("0.0004"))
        )
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 1000, cached: 0, cacheWrite: 200, output: 0, reasoningOutput: 0), resolution: write).estimate,
            .point(decimal("0.0042")),
            "a reported write count is priced at the write rate"
        )

        let flat = try XCTUnwrap(Self.snapshot().rates(forModelID: "gpt-5.3-codex"))
        let absent = CodexUsagePricing.estimate(.init(input: 1000, cached: 200, cacheWrite: nil, output: 10, reasoningOutput: 0), resolution: flat)
        XCTAssertEqual(absent.estimate, .point(decimal("0.001125")), "800 × 1.25 + 200 × 0.125 + 10 × 10 per million")
        XCTAssertEqual(
            absent,
            CodexUsagePricing.estimate(.init(input: 1000, cached: 200, cacheWrite: 0, output: 10, reasoningOutput: 0), resolution: flat),
            "absent and an explicit zero price identically"
        )
        XCTAssertEqual(
            CodexUsagePricing.estimate(.init(input: 1000, cached: 900, cacheWrite: 200, output: 10, reasoningOutput: 0), resolution: write).estimate,
            .unavailable("cached and cache-write input exceed input")
        )

        // Accumulator level: the absent count stays absent in the record, and the interval is a
        // complete point with no diagnostic.
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 200, 10, cacheWrite: nil))), .accepted)
        let record = try XCTUnwrap(accumulator.record)
        XCTAssertNil(record.codexIntervals?.first?.cacheWriteInputTokens)
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostLowerUSD, decimal("0.001125"))
        XCTAssertEqual(record.codexIntervals?.first?.estimatedCostUpperUSD, decimal("0.001125"))
        XCTAssertEqual(record.codexIntervals?.first?.coverage, .complete)
        XCTAssertNil(record.codexIntervals?.first?.diagnostic)
        XCTAssertEqual(accumulator.codexSessionCostEstimate, .init(amount: decimal("0.001125"), currency: "USD", coverage: .complete))
        let projection = project(accumulator)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: 20.0% · API Cost Estimates: <$0.01")
        XCTAssertNil(record.semanticViolation)

        var writeModel = makeAccumulator()
        dispatch(&writeModel, turn: "t1", model: "gpt-w", snapshot: Self.writeSnapshot)
        XCTAssertEqual(observe(&writeModel, observation(1, total: counters(1000, 0, 0, cacheWrite: nil))), .accepted)
        XCTAssertEqual(writeModel.codexSessionCostEstimate, .init(amount: decimal("0.004"), currency: "USD", coverage: .complete))
        let applied = try XCTUnwrap(writeModel.record?.codexIntervals?.first?.appliedPricing)
        XCTAssertEqual(applied.inputRateLowerUSD, applied.inputRateUpperUSD)
        XCTAssertEqual(applied.cacheWriteRateLowerUSD, applied.cacheWriteRateUpperUSD)
    }

    func testContextBandFollowsTheLatestRequestNotTheSummedInterval() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 0, 10))), .accepted)
        XCTAssertEqual(accumulator.record?.codexIntervals?.last?.estimatedCostLowerUSD, decimal("0.00135"))

        // The remaining turns report a 1M context window, so the window proves nothing and the
        // latest request decides. The summed interval (300K input) is above the 272K threshold,
        // but the latest request's prompt (150K) is below it: the short band applies.
        dispatch(&accumulator, turn: "t2", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(
            observe(&accumulator, observation(2, turn: "t2", total: counters(301_000, 0, 20), last: counters(150_000, 0, 10), window: 1_000_000)),
            .accepted
        )
        var interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.inputTokens, 300_000)
        XCTAssertEqual(interval.bandKind, "shortContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.3751"))
        XCTAssertEqual(interval.estimatedCostUpperUSD, decimal("0.3751"))
        XCTAssertEqual(interval.appliedPricing?.inputRateLowerUSD, decimal("1.25"))
        XCTAssertEqual(interval.appliedPricing?.inputRateUpperUSD, decimal("1.25"))
        XCTAssertEqual(interval.coverage, .complete)

        // One cache-heavy 280K request (at or above the threshold) is the whole t3 interval:
        // 10K uncached + 270K cached at long-context rates.
        dispatch(&accumulator, turn: "t3", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(
            observe(
                &accumulator,
                observation(3, turn: "t3", total: counters(581_000, 270_000, 20), last: counters(280_000, 270_000, 0), window: 1_000_000)
            ),
            .accepted
        )
        interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.inputTokens, 280_000)
        XCTAssertEqual(interval.bandKind, "longContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.0925"), "10K × 2.5 + 270K × 0.25 per million")

        // Without observation.last or a window proof the summed 300K interval is not used to
        // pick the band: standard-context rates with a named assumption, coverage still complete.
        dispatch(&accumulator, turn: "t4", snapshot: Self.bandedSnapshot)
        let withoutLast = CodexUsageObservation(
            threadID: "thread-1",
            turnID: "t4",
            turnAttribution: .notified,
            ordinal: 4,
            last: nil,
            total: counters(881_000, 270_000, 30),
            modelContextWindow: nil
        )
        XCTAssertEqual(observe(&accumulator, withoutLast), .accepted)
        interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.inputTokens, 300_000)
        XCTAssertEqual(interval.bandKind, "shortContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.3751"))
        XCTAssertEqual(interval.coverage, .complete)
        XCTAssertEqual(interval.diagnostic, "latest request size unavailable; standard-context rates applied")

        XCTAssertEqual(accumulator.codexSessionCostEstimate, .init(amount: decimal("0.84405"), currency: "USD", coverage: .complete))
        let projection = project(accumulator)
        XCTAssertEqual(projection.presentation.costEstimateValue, "$0.84")
        XCTAssertFalse(projection.presentation.detailText.contains("–"), "no range wording")
        XCTAssertNil(projection.coverageDetail, "a stated assumption is not a coverage problem")
        XCTAssertTrue(try XCTUnwrap(projection.sessionCostCoverageDetail).hasPrefix("Complete:"))
        XCTAssertTrue(try XCTUnwrap(projection.sessionCostCoverageDetail).contains("Pricing assumption: latest request size unavailable"))

        // Two bands without a stated qualifier: standard-context rates, complete coverage, and the
        // assumption is named in the cost details.
        let unstated = Self.snapshot(
            bands: [.init(kind: .shortContext, rates: Self.shortRates), .init(kind: .longContext, rates: Self.longRates)],
            threshold: nil
        )
        var assumed = makeAccumulator()
        dispatch(&assumed, turn: "t1", snapshot: unstated)
        XCTAssertEqual(observe(&assumed, observation(1, total: counters(400_000, 0, 0))), .accepted)
        let assumedInterval = try XCTUnwrap(assumed.record?.codexIntervals?.first)
        XCTAssertEqual(assumedInterval.bandKind, "shortContext")
        XCTAssertEqual(assumedInterval.estimatedCostLowerUSD, decimal("0.5"))
        XCTAssertEqual(assumedInterval.coverage, .complete)
        XCTAssertEqual(assumedInterval.diagnostic, "long-context qualifier not stated; standard-context rates applied")
        let assumedProjection = project(assumed)
        XCTAssertEqual(assumedProjection.costEstimate?.coverage, .complete)
        XCTAssertNil(assumedProjection.coverageDetail)
        XCTAssertTrue(try XCTUnwrap(assumedProjection.sessionCostCoverageDetail).contains("Pricing assumption: long-context qualifier not stated"))
        XCTAssertTrue(assumedProjection.presentation.detailText.contains("standard-context rates applied"))
    }

    func testContextBandIsMonotonicWithinAnOpenTurn() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", snapshot: Self.bandedSnapshot)
        // Refinement 1: one 100K request → short.
        XCTAssertEqual(
            observe(&accumulator, observation(1, total: counters(100_000, 0, 0), window: 1_000_000)),
            .accepted
        )
        var interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.bandKind, "shortContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.125"))

        // Refinement 2: the latest request reaches 300K → the whole turn upgrades to long.
        XCTAssertEqual(
            observe(&accumulator, observation(2, total: counters(400_000, 0, 0), last: counters(300_000, 0, 0), window: 1_000_000)),
            .accepted
        )
        interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.bandKind, "longContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("1"))

        // Refinement 3: the latest request is small again, but the turn never downgrades and
        // its amount never decreases.
        XCTAssertEqual(
            observe(&accumulator, observation(3, total: counters(450_000, 0, 0), last: counters(50000, 0, 0), window: 1_000_000)),
            .accepted
        )
        interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(accumulator.record?.codexIntervals?.count, 1, "refinements upsert the turn's interval")
        XCTAssertEqual(interval.bandKind, "longContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("1.125"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(interval.estimatedCostLowerUSD), decimal("1"))

        // The floor belongs to the turn: the next turn starts from the evidence again.
        dispatch(&accumulator, turn: "t2", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(
            observe(&accumulator, observation(4, turn: "t2", total: counters(460_000, 0, 0), last: counters(10000, 0, 0), window: 1_000_000)),
            .accepted
        )
        interval = try XCTUnwrap(accumulator.record?.codexIntervals?.last)
        XCTAssertEqual(interval.bandKind, "shortContext")
        XCTAssertEqual(interval.estimatedCostLowerUSD, decimal("0.0125"))
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.amount, decimal("1.1375"))
    }

    func testLegacyRangedIntervalProjectsItsLowerBound() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 0, 10))), .accepted)
        // Shape an interval as an older build persisted it: an envelope with short/long rate sets.
        var legacy = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        legacy.codexIntervals?[0].bandKind = "envelope"
        legacy.codexIntervals?[0].estimatedCostLowerUSD = decimal("1.234")
        legacy.codexIntervals?[0].estimatedCostUpperUSD = decimal("2.468")
        legacy.codexIntervals?[0].appliedPricing?.inputRateUpperUSD = decimal("2.5")
        legacy.codexIntervals?[0].appliedPricing?.outputRateUpperUSD = 20
        XCTAssertNil(legacy.semanticViolation)
        let raw = try AgentProviderUsageRawValue(validating: JSONEncoder().encode(legacy))
        XCTAssertEqual(raw.losslessRecord(), legacy, "the persisted schema still decodes ranged intervals")

        let hydrated = AgentUsageAccumulator(ownerSessionID: owner, persisted: .opaque(raw), hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(hydrated.eligibility, .eligible)
        XCTAssertEqual(hydrated.codexSessionCostEstimate, .init(amount: decimal("1.234"), currency: "USD", coverage: .complete))
        let projection = project(hydrated)
        XCTAssertEqual(projection.costEstimate?.amount, decimal("1.234"))
        XCTAssertEqual(projection.presentation.costEstimateValue, "$1.23")
        XCTAssertTrue(
            try XCTUnwrap(projection.sessionCostCoverageDetail)
                .contains("1 earlier interval(s) were priced as a range by an older build; the lower bound is shown.")
        )
        XCTAssertEqual(hydrated.persistedRepresentation, .opaque(raw), "projection never rewrites the stored range")

        // A session mixing the legacy range with a current point interval sums lower + point.
        var mixed = hydrated
        mixed.beginCodexExecution(executionID: execution, threadOrigin: .fresh)
        dispatch(&mixed, turn: "t2")
        XCTAssertEqual(observe(&mixed, observation(1, turn: "t2", total: counters(1000, 200, 10))), .accepted)
        XCTAssertEqual(mixed.record?.codexIntervals?.count, 2)
        XCTAssertEqual(mixed.codexSessionCostEstimate, .init(amount: decimal("1.235125"), currency: "USD", coverage: .complete))
        let mixedProjection = project(mixed)
        XCTAssertEqual(mixedProjection.presentation.costEstimateValue, "$1.24")
        XCTAssertTrue(try XCTUnwrap(mixedProjection.sessionCostCoverageDetail).contains("1 earlier interval(s) were priced as a range"))
    }

    func testLegacyPartialSubtotalIntervalStaysPartialAndExplainsItself() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 0, 10))), .accepted)
        // An older build persisted a priced subtotal that it marked partial.
        var legacy = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        legacy.codexIntervals?[0].bandKind = "envelope"
        legacy.codexIntervals?[0].estimatedCostLowerUSD = decimal("0.5")
        legacy.codexIntervals?[0].estimatedCostUpperUSD = decimal("0.9")
        legacy.codexIntervals?[0].coverage = .partial
        legacy.codexIntervals?[0].diagnostic = "partial subtotal: cache-write rate not listed for the long band"
        XCTAssertNil(legacy.semanticViolation)
        let raw = try AgentProviderUsageRawValue(validating: JSONEncoder().encode(legacy))

        let hydrated = AgentUsageAccumulator(ownerSessionID: owner, persisted: .opaque(raw), hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(hydrated.codexSessionCostEstimate, .init(amount: decimal("0.5"), currency: "USD", coverage: .partial))
        let projection = project(hydrated)
        let costDetail = try XCTUnwrap(projection.sessionCostCoverageDetail)
        XCTAssertTrue(costDetail.hasPrefix("Partial:"))
        XCTAssertTrue(costDetail.contains("partial subtotal: cache-write rate not listed for the long band"))
        XCTAssertTrue(costDetail.contains("1 earlier interval(s) were priced as a range by an older build"))
        XCTAssertTrue(try XCTUnwrap(projection.coverageDetail).contains("partial subtotal"), "a partial interval is a coverage problem")
        XCTAssertEqual(projection.presentation.costEstimateValue, "$0.50")
        XCTAssertFalse(projection.presentation.readoutText.contains("partial"), "coverage lives in the details only")
        XCTAssertTrue(projection.presentation.detailText.contains("(partial coverage)"))
    }

    func testCostDisplayUsesTwoDecimalsHalfUpAndTinyAmountsNeverMasqueradeAsZero() {
        XCTAssertEqual(Usage.usdAmount(decimal("206.697")), "$206.70")
        XCTAssertEqual(Usage.usdAmount(decimal("105.305")), "$105.31", "half-up")
        XCTAssertEqual(Usage.usdAmount(decimal("0.375")), "$0.38")
        XCTAssertEqual(Usage.usdAmount(decimal("0.005")), "$0.01")
        XCTAssertEqual(Usage.usdAmount(decimal("0.0049")), "<$0.01", "a positive amount that rounds to zero")
        XCTAssertEqual(Usage.usdAmount(decimal("0.0000125")), "<$0.01")
        XCTAssertEqual(Usage.usdAmount(0), "$0.00")
    }

    func testLatestCodexRequestUsesLastWhileSessionAggregateAndCostStayCumulative() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertNil(accumulator.latestRequestCacheHit(for: .codexLast)?.share)
        XCTAssertEqual(
            observe(
                &accumulator,
                observation(
                    1,
                    total: counters(1000, 200, 100),
                    last: counters(100, 20, 10)
                )
            ),
            .accepted
        )
        XCTAssertEqual(accumulator.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.2"))
        XCTAssertEqual(accumulator.codexCacheHitShare?.ratio, decimal("0.2"))

        dispatch(&accumulator, turn: "t2")
        XCTAssertNil(
            accumulator.latestRequestCacheHit(for: .codexLast)?.share,
            "a newly dispatched request cannot retain the prior observation.last"
        )
        XCTAssertEqual(
            observe(
                &accumulator,
                observation(
                    2,
                    turn: "t2",
                    total: counters(3000, 1200, 200),
                    last: counters(50, 40, 5)
                )
            ),
            .accepted
        )
        XCTAssertEqual(
            accumulator.latestRequestCacheHit(for: .codexLast)?.share?.ratio,
            decimal("0.8"),
            "latest request is observation.last, not the cumulative total delta"
        )
        XCTAssertEqual(accumulator.codexCacheHitShare?.ratio, decimal("0.4"), "session average remains total-based")
        XCTAssertEqual(accumulator.codexSessionCostEstimate?.amount, decimal("0.0044"))

        dispatch(&accumulator, turn: "t3")
        let withoutLast = CodexUsageObservation(
            threadID: "thread-1",
            turnID: "t3",
            turnAttribution: .notified,
            ordinal: 3,
            last: nil,
            total: counters(4000, 1300, 250),
            modelContextWindow: 258_400
        )
        XCTAssertEqual(observe(&accumulator, withoutLast), .accepted)
        let missing = try XCTUnwrap(accumulator.latestRequestCacheHit(for: .codexLast))
        XCTAssertNil(missing.share)
        XCTAssertTrue(missing.detail.contains("omitted observation.last"))
        XCTAssertEqual(accumulator.codexCacheHitShare?.ratio, decimal("0.325"))
        XCTAssertEqual(
            accumulator.codexSessionCostEstimate?.amount,
            decimal("0.0060375"),
            "missing request-level counters do not alter cumulative pricing"
        )

        let old = observation(
            4,
            turn: "t2",
            total: counters(3000, 1200, 200),
            last: counters(100, 100, 0)
        )
        XCTAssertEqual(observe(&accumulator, old), .rejected(.replayedOrSynthetic))
        XCTAssertNil(accumulator.latestRequestCacheHit(for: .codexLast)?.share)

        accumulator.endCodexExecution(executionID: execution)
        XCTAssertNil(accumulator.latestRequestCacheHit(for: .codexLast))
        let persisted = try XCTUnwrap(accumulator.persistedRepresentation)
        let restored = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: persisted,
            hasPriorHistory: true,
            qualification: .productionClaude
        )
        XCTAssertNil(restored.latestRequestCacheHit(for: .codexLast))
        XCTAssertEqual(restored.codexCacheHitShare?.ratio, decimal("0.325"))
        XCTAssertEqual(restored.codexSessionCostEstimate?.amount, decimal("0.0060375"))
        XCTAssertEqual(project(restored).presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.01")

        // Provider lifecycles overlap while an old launch drains. Each source keeps its own slot,
        // so a Claude dispatch/event cannot erase Codex and a later Codex update cannot erase Claude.
        let claudeExecution = UUID()
        let claudeTurn = UUID()
        var interleaved = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: nil,
            hasPriorHistory: false,
            qualification: .qualified(contractID: "interleaved-test")
        )
        interleaved.beginExecution(
            executionID: claudeExecution,
            providerSessionID: "claude-session",
            baseline: .verifiedZero,
            at: start
        )
        interleaved.beginCodexExecution(executionID: execution, threadOrigin: .fresh)
        dispatch(&interleaved, turn: "codex-live")
        XCTAssertEqual(
            observe(&interleaved, observation(
                1,
                turn: "codex-live",
                total: counters(1000, 200, 10),
                last: counters(100, 80, 1)
            )),
            .accepted
        )
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.8"))

        XCTAssertEqual(interleaved.registerTurn(claudeTurn, executionID: claudeExecution), .accepted)
        XCTAssertNil(interleaved.latestRequestCacheHit(for: .claudeAssistant)?.share)
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.8"))
        XCTAssertEqual(
            interleaved.observeLatestClaudeRequest(
                observation: .init(
                    source: .assistant,
                    inputTokens: 10,
                    outputTokens: 1,
                    cacheReadInputTokens: 90,
                    cacheCreationInputTokens: 0,
                    requestID: "claude-live"
                ),
                requestID: "claude-live",
                executionID: claudeExecution,
                turnID: claudeTurn
            ),
            .accepted
        )
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, decimal("0.9"))
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.8"))
        XCTAssertEqual(
            observe(&interleaved, observation(
                2,
                turn: "codex-live",
                total: counters(1000, 200, 10),
                last: counters(100, 60, 1)
            )),
            .accepted
        )
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .codexLast)?.share?.ratio, decimal("0.6"))
        XCTAssertEqual(interleaved.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, decimal("0.9"))

        dispatch(&interleaved, turn: "codex-inconsistent")
        XCTAssertEqual(
            observe(&interleaved, observation(
                3,
                turn: "codex-inconsistent",
                total: counters(1100, 220, 11),
                last: counters(100, 20, 1, cacheWrite: 90)
            )),
            .accepted
        )
        let inconsistent = try XCTUnwrap(interleaved.latestRequestCacheHit(for: .codexLast))
        XCTAssertNil(inconsistent.share)
        XCTAssertTrue(inconsistent.detail.contains("cached-input and cache-write subsets"))
        XCTAssertTrue(inconsistent.detail.contains("combined count exceeds total input"))
    }

    // MARK: - Persistence and provenance

    func testCodexIntervalsPersistLosslesslyAndRecordsWithoutThemStayByteIdentical() throws {
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1")
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 100, 10))), .accepted)
        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        let encoded = try JSONEncoder().encode(record)
        let raw = try AgentProviderUsageRawValue(validating: encoded)
        XCTAssertEqual(raw.losslessRecord(), record, "typed Codex intervals round-trip lexeme-exactly")
        XCTAssertTrue(raw.text.contains("\"codexIntervals\""))
        XCTAssertTrue(raw.text.contains("\"estimatedCostLowerUSD\":0.0012375"))
        XCTAssertTrue(raw.text.contains("\"appliedPricing\""))

        let hydrated = AgentUsageAccumulator(ownerSessionID: owner, persisted: .opaque(raw), hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(hydrated.eligibility, .eligible)
        XCTAssertEqual(hydrated.codexIntervalCount, 1)
        XCTAssertEqual(hydrated.codexSessionCostEstimate?.amount, decimal("0.0012375"))
        XCTAssertEqual(hydrated.persistedRepresentation, .opaque(raw), "restored bytes stay authoritative until an owned mutation")

        // Intervals written before applied pricing existed (no `appliedPricing` member) stay lossless.
        var legacy = record
        legacy.codexIntervals?[0].appliedPricing = nil
        let legacyRaw = try AgentProviderUsageRawValue(validating: JSONEncoder().encode(legacy))
        XCTAssertFalse(legacyRaw.text.contains("appliedPricing"))
        XCTAssertEqual(legacyRaw.losslessRecord(), legacy)

        let claudeOnly = AgentProviderUsageRecord(originSessionID: owner, trackingStartedAt: start, hasUnmeasuredHistory: false)
        let claudeOnlyText = try String(decoding: JSONEncoder().encode(claudeOnly), as: UTF8.self)
        XCTAssertFalse(claudeOnlyText.contains("codexIntervals"), "absent stays absent")
        XCTAssertNil(try AgentProviderUsageRawValue(validating: claudeOnlyText).losslessRecord()?.codexIntervals)

        var invalid = record
        invalid.codexIntervals?[0].turnAttribution = "guessed"
        XCTAssertEqual(invalid.semanticViolation, "codexIntervals[0] has unknown turnAttribution 'guessed'")
        invalid = record
        invalid.codexIntervals?[0].estimatedCostUpperUSD = nil
        XCTAssertEqual(invalid.semanticViolation, "codexIntervals[0] has only one cost bound")
        invalid = record
        invalid.codexIntervals?[0].inputTokens = -1
        XCTAssertEqual(invalid.semanticViolation, "codexIntervals[0] has a negative inputTokens")
        invalid = record
        invalid.codexIntervals?[0].appliedPricing?.inputRateLowerUSD = -1
        XCTAssertEqual(invalid.semanticViolation, "codexIntervals[0] has an invalid inputRateLowerUSD")
        invalid = record
        invalid.codexIntervals?[0].estimatedCostLowerUSD = nil
        invalid.codexIntervals?[0].estimatedCostUpperUSD = nil
        XCTAssertEqual(invalid.semanticViolation, "codexIntervals[0] has applied pricing without a cost")
    }

    func testAppliedPricingProvenancePersistsAndSurfacesStaleness() throws {
        let captured = Date(timeIntervalSince1970: 1_789_438_877)
        let validated = Date(timeIntervalSince1970: 1_789_500_000)
        let stale = Self.snapshot(capturedAt: captured, validatedAt: validated, isStale: true)
        var accumulator = makeAccumulator()
        dispatch(&accumulator, turn: "t1", snapshot: stale)
        XCTAssertEqual(observe(&accumulator, observation(1, total: counters(1000, 100, 10))), .accepted)
        let applied = try XCTUnwrap(accumulator.record?.codexIntervals?.first?.appliedPricing)
        XCTAssertEqual(applied.basis, OpenAIPricingBasis.standardGlobalListPriceUSDPerMillionTokens.rawValue)
        XCTAssertEqual(applied.sourceKind, "bundledSeed")
        XCTAssertEqual(applied.capturedAt, captured)
        XCTAssertEqual(applied.validatedAt, validated)
        XCTAssertTrue(applied.wasStale)
        XCTAssertEqual(applied.inputRateLowerUSD, decimal("1.25"))
        XCTAssertEqual(applied.inputRateUpperUSD, decimal("1.25"))
        XCTAssertEqual(applied.cachedInputRateLowerUSD, decimal("0.125"))
        XCTAssertNil(applied.cacheWriteRateLowerUSD)
        XCTAssertEqual(applied.outputRateUpperUSD, 10)

        let provenance = try XCTUnwrap(accumulator.codexPricingProvenance)
        XCTAssertEqual(provenance.pricingVersions, [stale.pricingVersion])
        XCTAssertEqual(provenance.earliestCapturedAt, captured)
        XCTAssertEqual(provenance.latestCapturedAt, captured)
        XCTAssertEqual(provenance.latestValidatedAt, validated)
        XCTAssertEqual(provenance.staleIntervalCount, 1)
        let projection = project(accumulator)
        XCTAssertTrue(projection.presentation.detailText.contains("stale at dispatch for 1 interval"))
        XCTAssertTrue(projection.presentation.detailText.contains("price list dated"))
        XCTAssertTrue(projection.presentation.detailText.contains("last validated"))

        // The one applied rate set is recorded in both persisted slots (the long band here).
        dispatch(&accumulator, turn: "t2", snapshot: Self.bandedSnapshot)
        XCTAssertEqual(observe(&accumulator, observation(2, turn: "t2", total: counters(301_000, 100, 20), window: 1_000_000)), .accepted)
        let banded = try XCTUnwrap(accumulator.record?.codexIntervals?.last?.appliedPricing)
        XCTAssertEqual(banded.inputRateLowerUSD, decimal("2.5"))
        XCTAssertEqual(banded.inputRateUpperUSD, decimal("2.5"))
        XCTAssertFalse(banded.wasStale)
        XCTAssertEqual(accumulator.codexPricingProvenance?.staleIntervalCount, 1)

        // Persisted provenance survives a lossless round-trip and is never repriced on hydration.
        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        let raw = try AgentProviderUsageRawValue(validating: JSONEncoder().encode(record))
        XCTAssertEqual(raw.losslessRecord(), record)
        let hydrated = AgentUsageAccumulator(ownerSessionID: owner, persisted: .opaque(raw), hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(hydrated.codexPricingProvenance, accumulator.codexPricingProvenance)
        XCTAssertEqual(hydrated.codexPricingProvenance?.pricingVersions, [stale.pricingVersion, Self.bandedSnapshot.pricingVersion].sorted())
        XCTAssertEqual(hydrated.record?.codexIntervals?.first?.appliedPricing, applied)
    }
}
