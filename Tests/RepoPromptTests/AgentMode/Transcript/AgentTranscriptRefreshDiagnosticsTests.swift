@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// D0 runtime diagnostics: incremental-import rejection reasons, sanitize incremental-path reasons,
/// and process-wide bash parser cache counters. Diagnostics must never change outputs.
final class AgentTranscriptRefreshDiagnosticsTests: XCTestCase {
    // MARK: - Incremental import

    func testIncrementalImportSuccessReportsFinalTurnSizeAndMatchesWrapper() {
        let items = twoTurnItems()
        let existing = AgentTranscriptIO.buildTranscript(from: Array(items.prefix(3)), compact: false)

        let diagnostic = importDiagnostic(existing: existing, items: items, earliestChangedIndex: 3)

        guard case let .updated(transcript, finalTurnStartIndex, finalTurnItemCount) = diagnostic else {
            return XCTFail("Expected incremental update, got \(diagnostic)")
        }
        XCTAssertEqual(finalTurnStartIndex, 2)
        XCTAssertEqual(finalTurnItemCount, 2)
        XCTAssertNil(diagnostic.rejection)
        XCTAssertEqual(transcript, importWrapper(existing: existing, items: items, earliestChangedIndex: 3))
    }

    func testIncrementalImportRejectsEmptyItems() {
        let existing = AgentTranscriptIO.buildTranscript(from: twoTurnItems(), compact: false)
        assertImportRejected(existing: existing, items: [], earliestChangedIndex: 0, expected: .emptyItems)
    }

    func testIncrementalImportRejectsEmptyExistingTranscript() {
        assertImportRejected(
            existing: AgentTranscript(),
            items: twoTurnItems(),
            earliestChangedIndex: 3,
            expected: .emptyExistingTranscript
        )
    }

    func testIncrementalImportRejectsInvalidFrontier() {
        let items = twoTurnItems()
        var existing = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        existing.compactionFrontier = nil
        existing.turns[0].retentionTier = .summary
        assertImportRejected(existing: existing, items: items, earliestChangedIndex: 3, expected: .invalidFrontier)
    }

    func testIncrementalImportRejectsMissingFinalTurnStart() {
        let existing = AgentTranscriptIO.buildTranscript(from: twoTurnItems(), compact: false)
        assertImportRejected(
            existing: existing,
            items: [.assistant("Orphan answer.", sequenceIndex: 0)],
            earliestChangedIndex: 0,
            expected: .noFinalTurnStart
        )
    }

    func testIncrementalImportRejectsChangeBeforeFinalTurnWithBoundaries() {
        let items = twoTurnItems()
        let existing = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 1,
            expected: .changeBeforeFinalTurn(earliestChangedIndex: 1, finalTurnStartIndex: 2, finalTurnItemCount: 2)
        )
    }

    func testIncrementalImportRejectsSuffixThatRebuildsIntoMultipleTurns() {
        // The suffix's assistant row sorts before its user row, so the suffix rebuilds into two turns.
        let items: [AgentChatItem] = [
            .user("First question", sequenceIndex: 0),
            .assistant("First answer.", sequenceIndex: 1),
            .user("Second question", sequenceIndex: 5),
            .assistant("Out of order answer.", sequenceIndex: 3)
        ]
        let existing = AgentTranscriptIO.buildTranscript(from: Array(items.prefix(2)), compact: false)
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 3,
            expected: .suffixTurnCountMismatch(suffixTurnCount: 2, finalTurnStartIndex: 2, finalTurnItemCount: 2)
        )
    }

    func testIncrementalImportRejectsRequestIDMismatch() {
        let existing = AgentTranscriptIO.buildTranscript(
            from: [.user("Question", sequenceIndex: 0), .assistant("Answer.", sequenceIndex: 1)],
            compact: false
        )
        let items: [AgentChatItem] = [
            .user("Question", sequenceIndex: 0),
            .assistant("Answer.", sequenceIndex: 1)
        ]
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 1,
            expected: .requestIDMismatch(finalTurnStartIndex: 0, finalTurnItemCount: 2)
        )
    }

    // MARK: - Sanitize incremental path

    func testSanitizeActivitySuffixSuccessReason() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[3] = makeReadFileActivity(id: activities[3].id, sequenceIndex: 3, marker: "after")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .activitySuffixSuccess)
    }

    func testSanitizePersistencePurposeReportsNotRuntimePresentation() {
        let fixture = SanitizeFixture()
        let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(fixture.previousRaw)
        XCTAssertEqual(metrics.incrementalPathReason, .notRuntimePresentation)
    }

    func testSanitizeReportsTrustedSuffixUnavailable() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: fixture.previousSanitized, start: nil, expected: .trustedSuffixUnavailable)
    }

    func testSanitizeReportsPreviousSanitizedTranscriptUnavailable() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: nil, start: 3, expected: .previousSanitizedTranscriptUnavailable)
    }

    func testSanitizeReportsTurnCountMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns.insert(fixture.turn(id: UUID(), activities: [fixture.activities[0]]), at: 0)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .turnCountMismatch)
    }

    func testSanitizeReportsReusedPrefixMismatch() {
        let fixture = SanitizeFixture()
        let prefixTurn = fixture.turn(id: UUID(), activities: [makeReadFileActivity(id: UUID(), sequenceIndex: 0, marker: "prefix")])
        var previousRaw = fixture.previousRaw
        previousRaw.turns.insert(prefixTurn, at: 0)
        let previousSanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(previousRaw).transcript
        assertSanitizeReason(previousRaw, previous: previousSanitized, start: 3, expected: .reusedPrefixMismatch)
    }

    func testSanitizeReportsFinalTurnMissing() {
        assertSanitizeReason(AgentTranscript(), previous: AgentTranscript(), start: 0, expected: .finalTurnMissing)
    }

    func testSanitizeReportsFinalTurnIdentityMismatch() {
        let fixture = SanitizeFixture()
        let updated = AgentTranscript(turns: [fixture.turn(id: UUID(), activities: fixture.activities)], nextSequenceIndex: 4)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .finalTurnIdentityMismatch)
    }

    func testSanitizeReportsRequestMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].request = AgentTranscriptRequestAnchor(from: .user("Different request"))
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .requestMismatch)
    }

    func testSanitizeReportsSpanCountMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].responseSpans.append(
            AgentTranscriptProviderResponseSpan(startedAt: fixture.startedAt, activities: [])
        )
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .spanCountMismatch)
    }

    func testSanitizeReportsSpanIdentityMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].responseSpans = [
            AgentTranscriptProviderResponseSpan(id: UUID(), startedAt: fixture.startedAt, activities: fixture.activities)
        ]
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .spanIdentityMismatch)
    }

    func testSanitizeReportsUnchangedSpanMismatch() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[3] = makeReadFileActivity(id: UUID(), sequenceIndex: 3, marker: "replaced")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 10, expected: .unchangedSpanMismatch)
    }

    func testSanitizeReportsChangedActivityIndexOutOfRange() {
        let fixture = SanitizeFixture()
        let appended = (4 ..< 7).map { makeReadFileActivity(id: UUID(), sequenceIndex: $0, marker: "appended-\($0)") }
        let updated = fixture.transcript(activities: fixture.activities + appended)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 5, expected: .changedActivityIndexOutOfRange)
    }

    func testSanitizeReportsPrefixBoundaryMismatch() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[2] = makeReadFileActivity(id: UUID(), sequenceIndex: 2, marker: "replaced")
        activities[3] = makeReadFileActivity(id: activities[3].id, sequenceIndex: 3, marker: "after")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .prefixBoundaryMismatch)
    }

    func testSanitizeReportsChangedSuffixNotFound() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: fixture.previousSanitized, start: 10, expected: .changedSuffixNotFound)
    }

    // MARK: - Interrupted final-turn envelope through a rebuild

    /// A cold-cancelled (and an explicitly failed) final turn keeps its terminal envelope through an
    /// idle or unspecified rebuild with an unchanged source extent, on the full and incremental paths;
    /// a content-only repair of an existing row is applied without losing the envelope.
    func testRebuildPreservesInterruptedFinalTurnEnvelopeWhenSourceExtentIsUnchanged() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinal = try XCTUnwrap(existing.turns.last)
        XCTAssertEqual(existingFinal.terminalState, .cancelled)
        XCTAssertEqual(existingFinal.responseSpans.map(\.lifecycle), [.cancelled])
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        // Baseline the guard exists for: a fresh import at the restored idle state loses cancellation.
        let freshFinal = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: workingItems, terminalState: .idle).turns.last)
        XCTAssertEqual(freshFinal.terminalState, .idle)
        XCTAssertEqual(freshFinal.responseSpans.map(\.lifecycle), [.completed])

        let cases: [(label: String, terminalState: AgentSessionRunState?, earliestChangedIndex: Int?)] = [
            ("idle full", .idle, nil),
            ("unspecified full", nil, nil),
            ("idle incremental", .idle, 4),
            ("equal explicit", .cancelled, nil)
        ]
        for (label, terminalState, earliestChangedIndex) in cases {
            let rebuilt = rebuild(existing, items: workingItems, terminalState: terminalState, earliestChangedIndex: earliestChangedIndex)
            let final = try XCTUnwrap(rebuilt.turns.last, label)
            XCTAssertEqual(final.id, existingFinal.id, label)
            XCTAssertEqual(final.terminalState, .cancelled, label)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.cancelled], label)
            XCTAssertEqual(final.responseSpans.map(\.completedAt), existingFinal.responseSpans.map(\.completedAt), label)
            XCTAssertEqual(final.completedAt, existingFinal.completedAt, label)
            XCTAssertEqual(rebuilt.turns.first?.terminalState, existing.turns.first?.terminalState, label)
        }

        // A content repair of an existing row (same IDs) is not new source activity.
        var repairedItems = workingItems
        let resultIndex = try XCTUnwrap(repairedItems.lastIndex { $0.kind == .toolResult })
        repairedItems[resultIndex].toolResultJSON = #"{"output":"repaired"}"#
        repairedItems[resultIndex].text = #"{"output":"repaired"}"#
        let repaired = try XCTUnwrap(rebuild(existing, items: repairedItems, terminalState: .idle).turns.last)
        XCTAssertEqual(repaired.terminalState, .cancelled)
        XCTAssertEqual(repaired.responseSpans.map(\.lifecycle), [.cancelled])
        XCTAssertTrue(repaired.allActivities.contains { $0.toItem().toolResultJSON?.contains("repaired") == true })

        // An explicitly failed final turn is an interrupted envelope too.
        let failed = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .failed,
            nextSequenceIndex: items.count,
            compact: false
        )
        let failedFinal = try XCTUnwrap(failed.turns.last)
        XCTAssertEqual(failedFinal.terminalState, .failed)
        let rebuiltFailed = try XCTUnwrap(rebuild(failed, items: items, terminalState: .idle).turns.last)
        XCTAssertEqual(rebuiltFailed.terminalState, .failed)
        XCTAssertEqual(rebuiltFailed.responseSpans.map(\.lifecycle), failedFinal.responseSpans.map(\.lifecycle))
    }

    /// A turn interrupted mid-tool (its final `toolCall` has no `toolResult`, e.g. bash was running
    /// when the app quit) keeps its cancelled envelope through the real sequence: a session persisted
    /// while running → the data service's load normalization (cold-restore sanitize) → the VM save's
    /// pending-tool repair at the restored idle state → the save's rebuild at idle. The repair turns the
    /// unmatched `toolCall` row into a `toolResult` in place (same ID), so the source extent is unchanged.
    ///
    /// Two writers: the live transcript a running VM persists (built at `.running`, open spans, which
    /// sanitize closes as cancelled), and an item-only session whose transcript was built without a run
    /// state (closed `.completed` spans; sanitize cancels the turn for its pending tool but leaves the
    /// already-closed spans). The rebuild keeps whatever envelope the restore produced.
    func testMidToolInterruptedTurnKeepsCancelledEnvelopeThroughLoadRepairAndSaveRebuild() async throws {
        let invocation = UUID()
        let items: [AgentChatItem] = [
            .user("First request", sequenceIndex: 0),
            .assistant("First reply", sequenceIndex: 1),
            .user("Second request", sequenceIndex: 2),
            .assistant("Running it.", sequenceIndex: 3),
            .toolCall(name: "bash", invocationID: invocation, argsJSON: #"{"command":"sleep 60"}"#, sequenceIndex: 4)
        ]
        let pendingCallID = try XCTUnwrap(items.last?.id)
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTranscriptRefreshDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let workspace = WorkspaceModel(id: UUID(), name: "Mid-tool interruption", repoPaths: ["/tmp/repo"], customStoragePath: storage)
        let liveRunningTranscript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .running,
            nextSequenceIndex: items.count,
            policy: .liveSession(hidePendingQuestionToolCall: false)
        )
        let writers: [(label: String, transcript: AgentTranscript?, restoredSpans: [AgentTranscriptSpanLifecycle])] = [
            ("live running transcript", liveRunningTranscript, [.cancelled]),
            ("item-only transcript", nil, [.completed])
        ]
        for writer in writers {
            let label = writer.label
            var persisted = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: label).withItems(items)
            if let transcript = writer.transcript {
                persisted.transcript = transcript
            }
            persisted.lastRunState = AgentSessionRunState.running.rawValue
            let fileURL = try await AgentSessionDataService().saveAgentSession(persisted, for: workspace)

            // Load normalization, including the cold-restore sanitize (F-7: a cold-restore load; the
            // generic loader is a storage mutation and never sanitizes).
            XCTAssertEqual(fileURL.lastPathComponent, "AgentSession-\(persisted.id.uuidString).json", label)
            let coldLoad = try await AgentSessionDataService().loadAgentSessionForEditing(id: persisted.id, for: workspace)
            let loaded = try XCTUnwrap(coldLoad, label).session
            XCTAssertEqual(loaded.lastRunState, AgentSessionRunState.idle.rawValue, label)
            let restored = try XCTUnwrap(loaded.transcript, label)
            let restoredFinal = try XCTUnwrap(restored.turns.last, label)
            XCTAssertEqual(restoredFinal.terminalState, .cancelled, label)
            XCTAssertEqual(restoredFinal.responseSpans.map(\.lifecycle), writer.restoredSpans, label)
            var workingItems = loaded.items.map { $0.toItem() }
            let restoredCall = try XCTUnwrap(workingItems.last, label)
            XCTAssertEqual(restoredCall.id, pendingCallID, label)
            XCTAssertEqual(restoredCall.kind, .toolCall, "\(label): the restored turn still ends in the unmatched call")

            // The VM save's pending-tool repair at the restored idle state.
            let repairedCount = AgentTranscriptIO.finalizePendingToolCalls(
                in: &workingItems,
                terminalState: .idle,
                includeExplicitRepoPromptToolCalls: false,
                nonToolBoundary: 200
            )
            XCTAssertEqual(repairedCount, 1, label)
            let repairedRow = try XCTUnwrap(workingItems.last, label)
            XCTAssertEqual(repairedRow.id, pendingCallID, "\(label): the repair converts the row in place")
            XCTAssertEqual(repairedRow.kind, .toolResult, label)
            XCTAssertEqual(workingItems.count, items.count, label)

            // The save's rebuild at idle, with the live-session policy the VM save uses.
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: restored,
                workingItems: workingItems,
                terminalState: .idle,
                nextSequenceIndex: (workingItems.map(\.sequenceIndex).max() ?? -1) + 1,
                policy: .liveSession(hidePendingQuestionToolCall: false)
            )
            let final = try XCTUnwrap(rebuilt.turns.last, label)
            XCTAssertEqual(final.id, restoredFinal.id, label)
            XCTAssertEqual(final.terminalState, .cancelled, "\(label): the mid-tool interrupted turn stays cancelled")
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), writer.restoredSpans, label)
            XCTAssertEqual(final.completedAt, restoredFinal.completedAt, label)
            XCTAssertTrue(final.allActivities.contains { $0.id == pendingCallID && $0.itemKind == .toolResult }, label)
        }
    }

    /// New source activity in the interrupted turn takes the normal rebuild.
    func testRebuildDropsInterruptedEnvelopeWhenSourceExtentChanges() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinalID = try XCTUnwrap(existing.turns.last?.id)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        let appended = workingItems + [.assistant("Late reply", sequenceIndex: items.count)]
        for earliestChangedIndex in [Int?.none, appended.count - 1] {
            let label = "appended activity, incremental: \(earliestChangedIndex != nil)"
            let final = try XCTUnwrap(rebuild(existing, items: appended, terminalState: .idle, earliestChangedIndex: earliestChangedIndex).turns.last, label)
            XCTAssertEqual(final.id, existingFinalID, label)
            XCTAssertEqual(final.terminalState, .idle, label)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.completed], label)
        }

        // A non-final interrupted turn whose extent changes takes the normal rebuild too.
        let lateRow = AgentChatItem.assistant("Late reply", sequenceIndex: items.count)
        let changedThenNextTurn = workingItems + [lateRow, .user("Third request", sequenceIndex: items.count + 1)]
        let rebuilt = rebuild(existing, items: changedThenNextTurn, terminalState: .idle)
        XCTAssertEqual(rebuilt.turns.count, 3)
        let formerFinal = try XCTUnwrap(rebuilt.turns.first { $0.id == existingFinalID })
        XCTAssertNil(formerFinal.terminalState, "a changed non-final turn takes the normal rebuild")
        XCTAssertEqual(formerFinal.responseSpans.map(\.lifecycle), [.completed])
    }

    /// After a new turn, the former final interrupted turn keeps its envelope on the full path as the
    /// incremental path already does: no supplied state applies to a non-final turn, so it is kept for
    /// active, idle and explicit terminal states alike, while the new final turn takes the supplied state.
    func testRebuildPreservesEarlierInterruptedTurnEnvelopesAfterANewTurn() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinal = try XCTUnwrap(existing.turns.last)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)
        let nextTurn = workingItems + [.user("Third request", sequenceIndex: items.count)]

        let cases: [(label: String, terminalState: AgentSessionRunState?, earliestChangedIndex: Int?)] = [
            ("idle full", .idle, nil),
            ("running full", .running, nil),
            ("completed full", .completed, nil),
            ("idle incremental", .idle, nextTurn.count - 1),
            ("running incremental", .running, nextTurn.count - 1)
        ]
        for (label, terminalState, earliestChangedIndex) in cases {
            let rebuilt = rebuild(existing, items: nextTurn, terminalState: terminalState, earliestChangedIndex: earliestChangedIndex)
            XCTAssertEqual(rebuilt.turns.count, 3, label)
            let formerFinal = try XCTUnwrap(rebuilt.turns.first { $0.id == existingFinal.id }, label)
            XCTAssertEqual(formerFinal.terminalState, .cancelled, "\(label): the earlier interrupted turn stays cancelled")
            XCTAssertEqual(formerFinal.responseSpans.map(\.lifecycle), [.cancelled], label)
            XCTAssertEqual(formerFinal.completedAt, existingFinal.completedAt, label)
            XCTAssertEqual(rebuilt.turns.last?.terminalState, terminalState, label)
            XCTAssertEqual(rebuilt.turns.first?.terminalState, existing.turns.first?.terminalState, label)
        }
    }

    /// An active run never keeps the interrupted envelope, and a different explicit terminal state wins.
    func testRebuildIgnoresInterruptedEnvelopeForActiveRunsAndDifferentExplicitTerminalStates() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        for activeState in [AgentSessionRunState.running, .waitingForUser, .waitingForQuestion, .waitingForApproval] {
            let final = try XCTUnwrap(rebuild(existing, items: workingItems, terminalState: activeState).turns.last)
            XCTAssertEqual(final.terminalState, activeState, activeState.rawValue)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.open], activeState.rawValue)
            XCTAssertNil(final.completedAt, activeState.rawValue)
        }
        for explicitState in [AgentSessionRunState.completed, .failed] {
            let final = try XCTUnwrap(rebuild(existing, items: workingItems, terminalState: explicitState).turns.last)
            XCTAssertEqual(final.terminalState, explicitState, explicitState.rawValue)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.completed], explicitState.rawValue)
        }
    }

    // MARK: - Bash parser cache counters

    #if DEBUG || EDIT_FLOW_PERF
        func testBashParserCacheCountersTrackHitsMissesAndEvictionsWithoutChangingOutput() {
            let token = UUID().uuidString
            let raw = #"{"status":"completed","exit_code":0,"output":"\#(token)"}"#
            let argsJSON = #"{"command":"echo \#(token)"}"#

            let beforeMetadata = BashToolResultParser.cacheCountersSnapshot()
            let firstMetadata = BashToolResultParser.parseMetadata(raw: raw)
            let afterMetadataMiss = BashToolResultParser.cacheCountersSnapshot()
            let secondMetadata = BashToolResultParser.parseMetadata(raw: raw)
            let afterMetadataHit = BashToolResultParser.cacheCountersSnapshot()
            XCTAssertEqual(firstMetadata, secondMetadata)
            XCTAssertEqual(firstMetadata, BashToolResultParser.parseLivenessMetadata(raw: raw))
            XCTAssertGreaterThanOrEqual(afterMetadataMiss.metadata.missCount - beforeMetadata.metadata.missCount, 1)
            XCTAssertGreaterThanOrEqual(afterMetadataHit.metadata.hitCount - afterMetadataMiss.metadata.hitCount, 1)

            let firstParsed = BashToolResultParser.parse(raw: raw, argsJSON: argsJSON)
            let afterParsedMiss = BashToolResultParser.cacheCountersSnapshot()
            let secondParsed = BashToolResultParser.parse(raw: raw, argsJSON: argsJSON)
            let afterParsedHit = BashToolResultParser.cacheCountersSnapshot()
            XCTAssertEqual(firstParsed, secondParsed)
            XCTAssertGreaterThanOrEqual(afterParsedMiss.parsed.missCount - afterMetadataHit.parsed.missCount, 1)
            XCTAssertGreaterThanOrEqual(afterParsedHit.parsed.hitCount - afterParsedMiss.parsed.hitCount, 1)

            // Eviction is two-generation (D3); exercise it on a small isolated cache so the
            // process-wide table's larger working set does not hide the counters.
            let smallCache = BashToolResultParser.Cache(
                limits: .init(maxEntriesPerGeneration: 128, maxBytesPerTable: 16 * 1024 * 1024)
            )
            for index in 0 ..< 300 {
                let indexedRaw = #"{"status":"completed","output":"\#(token)-\#(index)"}"#
                _ = smallCache.metadata(raw: indexedRaw) { BashToolResultParser.parseLivenessMetadata(raw: indexedRaw) }
            }
            let afterEviction = smallCache.countersSnapshot().metadata
            XCTAssertEqual(afterEviction.missCount, 300)
            XCTAssertEqual(afterEviction.evictedEntryCount, 128)
            XCTAssertEqual(afterEviction.currentEntryCount, 172)
        }
    #endif

    // MARK: - Helpers

    private func twoTurnItems() -> [AgentChatItem] {
        [
            .user("First question", sequenceIndex: 0),
            .assistant("First answer.", sequenceIndex: 1),
            .user("Second question", sequenceIndex: 2),
            .assistant("Second answer.", sequenceIndex: 3)
        ]
    }

    /// Two bash turns; the final turn is the one a cold restore interrupts.
    private func interruptedTwoTurnItems() -> [AgentChatItem] {
        let firstInvocation = UUID()
        let secondInvocation = UUID()
        return [
            .user("First request", sequenceIndex: 0),
            .toolCall(name: "bash", invocationID: firstInvocation, argsJSON: #"{"command":"echo 0"}"#, sequenceIndex: 1),
            .toolResult(name: "bash", invocationID: firstInvocation, resultJSON: #"{"output":"0"}"#, sequenceIndex: 2),
            .assistant("First reply", sequenceIndex: 3),
            .user("Second request", sequenceIndex: 4),
            .toolCall(name: "bash", invocationID: secondInvocation, argsJSON: #"{"command":"echo 1"}"#, sequenceIndex: 5),
            .toolResult(name: "bash", invocationID: secondInvocation, resultJSON: #"{"output":"1"}"#, sequenceIndex: 6),
            .assistant("Second reply", sequenceIndex: 7)
        ]
    }

    /// The transcript a cold restore produces for a session persisted while running.
    private func coldCancelledTranscript(from items: [AgentChatItem]) -> AgentTranscript {
        AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
            AgentTranscriptIO.buildTranscript(
                from: items,
                terminalState: .running,
                nextSequenceIndex: items.count,
                compact: false
            ),
            protectedItemIDs: []
        )
    }

    private func rebuild(
        _ existing: AgentTranscript,
        items: [AgentChatItem],
        terminalState: AgentSessionRunState?,
        earliestChangedIndex: Int? = nil
    ) -> AgentTranscript {
        AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existing,
            workingItems: items,
            earliestChangedIndex: earliestChangedIndex,
            terminalState: terminalState,
            nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1
        )
    }

    private func importDiagnostic(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int
    ) -> AgentTranscriptIncrementalImportResult {
        AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics(
            existingTranscript: existing,
            items: items,
            earliestChangedIndex: earliestChangedIndex,
            nextSequenceIndex: items.count
        )
    }

    private func importWrapper(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int
    ) -> AgentTranscript? {
        AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
            existingTranscript: existing,
            items: items,
            earliestChangedIndex: earliestChangedIndex,
            nextSequenceIndex: items.count
        )
    }

    private func assertImportRejected(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int,
        expected: AgentTranscriptIncrementalImportRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostic = importDiagnostic(existing: existing, items: items, earliestChangedIndex: earliestChangedIndex)
        XCTAssertEqual(diagnostic, .rejected(expected), file: file, line: line)
        XCTAssertNil(diagnostic.transcript, file: file, line: line)
        XCTAssertEqual(diagnostic.finalTurnItemCount, expected.finalTurnItemCount, file: file, line: line)
        XCTAssertNil(importWrapper(existing: existing, items: items, earliestChangedIndex: earliestChangedIndex), file: file, line: line)
    }

    /// Asserts the reason and that the result equals full sanitization (diagnostics never change output).
    private func assertSanitizeReason(
        _ transcript: AgentTranscript,
        previous: AgentTranscript?,
        start: Int?,
        expected: AgentSanitizeIncrementalPathReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previous,
            trustedReusablePrefixTurnCount: 0,
            trustedIncrementalFinalTurnStartSequenceIndex: start
        )
        XCTAssertEqual(metrics.incrementalPathReason, expected, file: file, line: line)
        XCTAssertEqual(
            metrics.transcript,
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(transcript).transcript,
            file: file,
            line: line
        )
    }

    private struct SanitizeFixture {
        let turnID = UUID()
        let spanID = UUID()
        let request = AgentTranscriptRequestAnchor(from: .user("Request"))
        let startedAt = Date(timeIntervalSinceReferenceDate: 1)
        let activities: [AgentTranscriptActivity] = (0 ..< 4).map {
            makeReadFileActivity(id: UUID(), sequenceIndex: $0, marker: "before-\($0)")
        }

        var previousRaw: AgentTranscript {
            transcript(activities: activities)
        }

        var previousSanitized: AgentTranscript {
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(previousRaw).transcript
        }

        func turn(id: UUID, activities: [AgentTranscriptActivity]) -> AgentTranscriptTurn {
            AgentTranscriptTurn(
                id: id,
                request: request,
                responseSpans: [
                    AgentTranscriptProviderResponseSpan(id: spanID, startedAt: startedAt, activities: activities)
                ],
                startedAt: startedAt
            )
        }

        func transcript(activities: [AgentTranscriptActivity]) -> AgentTranscript {
            AgentTranscript(turns: [turn(id: turnID, activities: activities)], nextSequenceIndex: 100)
        }
    }
}

private func makeReadFileActivity(id: UUID, sequenceIndex: Int, marker: String) -> AgentTranscriptActivity {
    let invocationID = UUID()
    let argsJSON = diagnosticsJSONString(["path": "/tmp/\(marker).txt"])
    let resultJSON = diagnosticsJSONString([
        "path": "/tmp/\(marker).txt",
        "content": String(repeating: "\(marker) payload ", count: 80)
    ])
    let execution = AgentTranscriptToolExecution(
        stableExecutionID: invocationID.uuidString,
        toolName: "read_file",
        invocationID: invocationID,
        argsJSON: argsJSON,
        resultJSON: resultJSON,
        toolIsError: false,
        status: .success
    )
    return AgentTranscriptActivity(
        id: id,
        timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
        sequenceIndex: sequenceIndex,
        role: .toolExecution,
        itemKind: .toolResult,
        text: resultJSON,
        toolExecution: execution
    )
}

private func diagnosticsJSONString(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - O11 saved input relocation

/// O11: the same conclusively unsent saved input is placed at the execution end in a distinct clean
/// turn E; its historical envelope H and every other turn keep their IDs, order, and evidence
/// through refresh, incremental import, serialization, and a cold-restore rebuild.
extension AgentTranscriptRefreshDiagnosticsTests {
    private func relocate(
        _ transcript: AgentTranscript,
        items: [AgentChatItem],
        saved: AgentChatItem,
        referenced: Set<UUID> = [],
        consistent: Bool = true,
        executionTurnID: UUID = UUID()
    ) -> AgentTranscriptSavedInputRelocation {
        AgentTranscriptIO.relocatingSavedInput(
            in: transcript,
            workingItems: items,
            savedItem: saved,
            isConsistentOccurrence: { consistent && $0.text == saved.text },
            referencedTurnIDs: referenced,
            terminalState: nil,
            nextSequenceIndex: transcript.nextSequenceIndex,
            proposedExecutionTurnID: executionTurnID
        )
    }

    private func refusal(_ relocation: AgentTranscriptSavedInputRelocation) -> AgentTranscriptSavedInputRelocationRefusal? {
        if case let .refused(refusal) = relocation { return refusal }
        return nil
    }

    private func assertRelocatedGraph(
        _ transcript: AgentTranscript,
        original: AgentTranscript,
        saved: AgentChatItem,
        executionTurnID: UUID,
        interruption: AgentTranscriptTurnInterruption?,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(transcript.turns.map(\.id), original.turns.map(\.id) + [executionTurnID], "\(label): IDs and order", file: file, line: line)
        let historicalBefore = original.turns.first { $0.request?.id == saved.id }
        let historical = transcript.turns.first { $0.id == historicalBefore?.id }
        XCTAssertNil(historical?.request, "\(label): H no longer carries the request", file: file, line: line)
        XCTAssertEqual(
            historical?.allActivities.map(\.id),
            historicalBefore?.allActivities.map(\.id),
            "\(label): H keeps its evidence",
            file: file,
            line: line
        )
        XCTAssertEqual(historical?.interruption, interruption, "\(label): H keeps its interruption", file: file, line: line)
        for turn in original.turns where turn.id != historicalBefore?.id {
            let kept = transcript.turns.first { $0.id == turn.id }
            XCTAssertEqual(kept?.request?.id, turn.request?.id, "\(label): other turns keep their request", file: file, line: line)
            XCTAssertEqual(kept?.allActivities.map(\.id), turn.allActivities.map(\.id), "\(label): other turns keep their evidence", file: file, line: line)
        }
        let execution = transcript.turns.last
        XCTAssertEqual(execution?.request?.id, saved.id, "\(label): E's request is the same A", file: file, line: line)
        XCTAssertEqual(execution?.request?.timestamp, saved.timestamp, "\(label): A keeps its saved chronology", file: file, line: line)
        XCTAssertEqual(execution?.allActivities.isEmpty, true, "\(label): E inherits no evidence", file: file, line: line)
        XCTAssertNil(execution?.interruption, "\(label): E inherits no interruption", file: file, line: line)
    }

    func testSavedInputRelocationKeepsTheHistoricalEnvelopeThroughRefreshSaveAndRestore() throws {
        let savedAt = Date(timeIntervalSince1970: 1000)
        let saved = AgentChatItem.user("saved message", sequenceIndex: 2).replacingTimestamp(savedAt)
        let items: [AgentChatItem] = [
            .user("Earlier turn", sequenceIndex: 0),
            .assistant("Earlier reply.", sequenceIndex: 1),
            saved,
            .assistant("A partial reply.", sequenceIndex: 3),
            .user("a newer message", sequenceIndex: 4),
            .assistant("The newer reply.", sequenceIndex: 5)
        ]
        var transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        XCTAssertEqual(transcript.turns.map(\.id), [items[0].id, saved.id, items[4].id])
        let interruption = AgentTranscriptTurnInterruption(reason: .appQuit, observedAt: Date(timeIntervalSince1970: 2000))
        transcript.turns[1].interruption = interruption
        transcript.turns[1].conclusionActivityID = saved.id
        let executionTurnID = UUID()

        guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, executionTurnID: executionTurnID) else {
            return XCTFail("a request followed by newer turns is relocated")
        }
        XCTAssertEqual(candidate.executionTurnID, executionTurnID)
        XCTAssertEqual(candidate.historicalTurnID, saved.id)
        XCTAssertEqual(candidate.userItem.id, saved.id)
        XCTAssertEqual(candidate.userItem.timestamp, savedAt)
        XCTAssertEqual(
            candidate.workingItems.map(\.id),
            [items[0].id, items[1].id, items[3].id, items[4].id, items[5].id, saved.id],
            "only A moves, to the end"
        )
        XCTAssertGreaterThan(candidate.userItem.sequenceIndex, 5)
        XCTAssertGreaterThan(candidate.nextSequenceIndex, candidate.userItem.sequenceIndex)
        XCTAssertNotEqual(
            candidate.transcript.turns[1].conclusionActivityID,
            saved.id,
            "a conclusion naming the moved request is cleared (and re-derived from H's own evidence)"
        )
        assertRelocatedGraph(candidate.transcript, original: transcript, saved: saved, executionTurnID: executionTurnID, interruption: interruption, label: "prepared")
        XCTAssertEqual(candidate.transcript.executionTurnID(forUserItemID: saved.id), executionTurnID)

        // A full refresh from the working items keeps the graph (no regrouping into the earlier turn).
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: candidate.transcript,
            workingItems: candidate.workingItems,
            nextSequenceIndex: candidate.nextSequenceIndex
        )
        assertRelocatedGraph(rebuilt, original: transcript, saved: saved, executionTurnID: executionTurnID, interruption: interruption, label: "full refresh")

        // The incremental final-turn path: E's reply lands in E only.
        let reply = AgentChatItem.assistant("The saved reply.", sequenceIndex: candidate.nextSequenceIndex)
        let grown = candidate.workingItems + [reply]
        let incremental = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: rebuilt,
            workingItems: grown,
            earliestChangedIndex: grown.count - 1,
            nextSequenceIndex: candidate.nextSequenceIndex + 1
        )
        XCTAssertEqual(incremental.turns.map(\.id), rebuilt.turns.map(\.id))
        XCTAssertEqual(incremental.turns.last?.request?.id, saved.id)
        XCTAssertEqual(incremental.turns.last?.allActivities.map(\.id), [reply.id])
        XCTAssertEqual(incremental.turns[1].allActivities.map(\.id), [items[3].id])
        XCTAssertNil(incremental.turns[1].request)

        // Serialization, then a cold-restore rebuild from the persisted items, reads the same graph.
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(incremental))
        XCTAssertEqual(decoded.turns.map(\.id), incremental.turns.map(\.id))
        XCTAssertEqual(decoded.turns.map { $0.request?.id }, incremental.turns.map { $0.request?.id })
        XCTAssertEqual(decoded.executionTurnID(forUserItemID: saved.id), executionTurnID)
        let restored = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: decoded,
            workingItems: grown,
            nextSequenceIndex: candidate.nextSequenceIndex + 1
        )
        XCTAssertEqual(restored.turns.map(\.id), incremental.turns.map(\.id))
        XCTAssertEqual(restored.turns.map { $0.request?.id }, incremental.turns.map { $0.request?.id })
        XCTAssertEqual(restored.turns.map { $0.allActivities.map(\.id) }, incremental.turns.map { $0.allActivities.map(\.id) })
        XCTAssertEqual(restored.turns[1].interruption, interruption)
    }

    func testSavedInputRelocationMovesAMidTurnUserActivityOnly() {
        let first = AgentChatItem.user("Earlier turn", sequenceIndex: 0)
        let saved = AgentChatItem.user("saved message", sequenceIndex: 1)
        let reply = AgentChatItem.assistant("Reply.", sequenceIndex: 2)
        var transcript = AgentTranscriptIO.buildTranscript(from: [first, reply], compact: false)
        transcript.turns[0].responseSpans[0].activities.insert(AgentTranscriptActivity(from: saved), at: 0)
        let executionTurnID = UUID()

        guard case let .prepared(candidate) = relocate(
            transcript,
            items: [first, saved, reply],
            saved: saved,
            executionTurnID: executionTurnID
        ) else {
            return XCTFail("a mid-turn occurrence is relocated")
        }
        XCTAssertEqual(candidate.historicalTurnID, first.id)
        XCTAssertEqual(candidate.transcript.turns.map(\.id), [first.id, executionTurnID])
        XCTAssertEqual(candidate.transcript.turns[0].request?.id, first.id, "H keeps its own request")
        XCTAssertEqual(candidate.transcript.turns[0].allActivities.map(\.id), [reply.id], "H keeps its other evidence")
        XCTAssertEqual(candidate.transcript.turns[1].request?.id, saved.id)
        XCTAssertEqual(candidate.workingItems.map(\.id), [first.id, reply.id, saved.id])
    }

    func testSavedInputRelocationReconstructsAnErasedInputBesideItsRetainedEvidenceTurn() {
        let savedAt = Date(timeIntervalSince1970: 1000)
        let saved = AgentChatItem.user("saved message", sequenceIndex: 2).replacingTimestamp(savedAt)
        let earlier: [AgentChatItem] = [.user("Earlier turn", sequenceIndex: 0), .assistant("Earlier reply.", sequenceIndex: 1)]
        let evidence = AgentChatItem.assistant("Partial output.", sequenceIndex: 3)
        // An evidence-only turn retained under A's ID after its request was erased (as finalized
        // removal leaves it: import-shaped, request cleared, its own output kept).
        var transcript = AgentTranscriptIO.buildTranscript(from: earlier + [saved, evidence], compact: false)
        let interruption = AgentTranscriptTurnInterruption(reason: .appCrash, observedAt: Date(timeIntervalSince1970: 1500))
        transcript.turns[1].request = nil
        transcript.turns[1].interruption = interruption
        let items = earlier + [evidence]
        let executionTurnID = UUID()

        guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, executionTurnID: executionTurnID) else {
            return XCTFail("an erased saved input is reconstructed")
        }
        XCTAssertNil(candidate.historicalTurnID, "no occurrence survived")
        XCTAssertEqual(candidate.transcript.turns.map(\.id), transcript.turns.map(\.id) + [executionTurnID])
        XCTAssertEqual(candidate.transcript.turns[1], transcript.turns[1], "the retained evidence turn is untouched")
        XCTAssertEqual(candidate.transcript.turns.last?.request?.id, saved.id)
        XCTAssertEqual(candidate.userItem.timestamp, savedAt, "reconstructed under its durable creation time")
        XCTAssertEqual(candidate.workingItems.map(\.id), items.map(\.id) + [saved.id])
        XCTAssertEqual(
            refusal(relocate(transcript, items: items, saved: saved, executionTurnID: saved.id)),
            .destinationCollision,
            "E never reuses A's ID"
        )

        // The retained envelope survives the existing reconciliation beside E.
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: candidate.transcript,
            workingItems: candidate.workingItems,
            nextSequenceIndex: candidate.nextSequenceIndex
        )
        XCTAssertEqual(rebuilt.turns.map(\.id), candidate.transcript.turns.map(\.id))
        XCTAssertNil(rebuilt.turns[1].request)
        XCTAssertEqual(rebuilt.turns[1].allActivities.map(\.id), [evidence.id])
        XCTAssertEqual(rebuilt.turns[1].interruption, interruption)
        XCTAssertEqual(rebuilt.turns.last?.request?.id, saved.id)
    }

    /// The reconciliation keeps only import-shaped full envelopes (one span under the turn's own
    /// deterministic span ID). A placement that would leave a multi-span, span-less, or
    /// non-deterministic-span full envelope behind (the occurrence's own turn, or a retained turn
    /// under A's ID) is refused before any mutation: the full graph and the working items are
    /// unchanged, and no candidate exists.
    func testSavedInputRelocationRefusesNonReconcilableHistoricalEnvelopesBeforeMutation() {
        let saved = AgentChatItem.user("saved message", sequenceIndex: 2)
        let items: [AgentChatItem] = [
            .user("Earlier turn", sequenceIndex: 0),
            .assistant("Earlier reply.", sequenceIndex: 1),
            saved,
            .assistant("A partial reply.", sequenceIndex: 3),
            .user("a newer message", sequenceIndex: 4)
        ]
        let base = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        XCTAssertEqual(base.turns[1].id, saved.id)
        guard case let .prepared(placed) = relocate(base, items: items, saved: saved) else {
            return XCTFail("the import-shaped envelope relocates")
        }
        guard case .unchanged = relocate(placed.transcript, items: placed.workingItems, saved: saved) else {
            return XCTFail("the import-shaped clean execution turn is reused")
        }
        func assertRefusedUnchanged(_ transcript: AgentTranscript, items: [AgentChatItem], _ label: String, line: UInt = #line) {
            let before = transcript
            let itemsBefore = items
            let result = relocate(transcript, items: items, saved: saved)
            XCTAssertEqual(refusal(result), .historicalEnvelopeNotReconcilable, label, line: line)
            XCTAssertEqual(transcript, before, "\(label): graph unchanged", line: line)
            XCTAssertEqual(items, itemsBefore, "\(label): items unchanged", line: line)
        }

        var multiSpan = base
        multiSpan.turns[1].responseSpans.append(AgentTranscriptProviderResponseSpan(
            runID: UUID(),
            lifecycle: .completed,
            startedAt: Date(timeIntervalSince1970: 50)
        ))
        assertRefusedUnchanged(multiSpan, items: items, "multi-span H")

        var nondeterministic = base
        let span = base.turns[1].responseSpans[0]
        nondeterministic.turns[1].responseSpans = [AgentTranscriptProviderResponseSpan(
            id: UUID(),
            providerTurnID: span.providerTurnID,
            runID: span.runID,
            lifecycle: span.lifecycle,
            startedAt: span.startedAt,
            lastActivityAt: span.lastActivityAt,
            completedAt: span.completedAt,
            activities: span.activities
        )]
        assertRefusedUnchanged(nondeterministic, items: items, "non-deterministic single-span H")

        var spanless = base
        spanless.turns[1].responseSpans = []
        assertRefusedUnchanged(spanless, items: items.filter { $0.id != items[3].id }, "span-less H")

        // A mid-turn occurrence whose own envelope is multi-span.
        let first = items[0]
        let reply = items[1]
        var midTurn = AgentTranscriptIO.buildTranscript(from: [first, reply], compact: false)
        midTurn.turns[0].responseSpans[0].activities.insert(AgentTranscriptActivity(from: saved), at: 0)
        midTurn.turns[0].responseSpans.append(AgentTranscriptProviderResponseSpan(startedAt: Date(timeIntervalSince1970: 60)))
        assertRefusedUnchanged(midTurn, items: [first, saved, reply], "multi-span mid-turn H")

        // The reuse (`unchanged`, forced owner save) path: a clean final request under a distinct
        // turn ID with an extra span, or under its own ID with a non-deterministic span, is
        // refused rather than reused.
        var multiSpanExecution = placed.transcript
        multiSpanExecution.turns[multiSpanExecution.turns.count - 1].responseSpans.append(
            AgentTranscriptProviderResponseSpan(startedAt: Date(timeIntervalSince1970: 80))
        )
        assertRefusedUnchanged(multiSpanExecution, items: placed.workingItems, "multi-span clean distinct-ID final turn")
        let finalItems = Array(items.prefix(2)) + [saved]
        var nondeterministicFinal = AgentTranscriptIO.buildTranscript(from: finalItems, compact: false)
        guard case .unchanged = relocate(nondeterministicFinal, items: finalItems, saved: saved) else {
            return XCTFail("the import-shaped clean final request is reused")
        }
        let finalIndex = nondeterministicFinal.turns.count - 1
        XCTAssertEqual(nondeterministicFinal.turns[finalIndex].responseSpans.count, 1)
        nondeterministicFinal.turns[finalIndex].responseSpans = [AgentTranscriptProviderResponseSpan(
            startedAt: nondeterministicFinal.turns[finalIndex].responseSpans[0].startedAt
        )]
        assertRefusedUnchanged(nondeterministicFinal, items: finalItems, "non-deterministic clean own-ID final turn")

        // Another retained full turn carrying a mid-turn user row (not A) the importer would split.
        var foreignUserRow = base
        let other = AgentChatItem.user("a steered message", sequenceIndex: 1)
        foreignUserRow.turns[0].responseSpans[0].activities.append(AgentTranscriptActivity(from: other))
        assertRefusedUnchanged(foreignUserRow, items: items, "another turn's mid-turn user row")

        // An erased input beside a span-less retained turn under its own ID.
        var retained = AgentTranscriptIO.buildTranscript(from: [first, reply], compact: false)
        retained.turns.append(AgentTranscriptTurn(id: saved.id, terminalState: .cancelled, startedAt: Date(timeIntervalSince1970: 70)))
        assertRefusedUnchanged(retained, items: [first, reply], "span-less retained turn under A's ID")
    }

    func testSavedInputRelocationOfACanonicalOnlyCompactedOccurrenceKeepsItsTier() {
        let savedAt = Date(timeIntervalSince1970: 1000)
        let saved = AgentChatItem.user("saved message", sequenceIndex: 0).replacingTimestamp(savedAt)
        let items: [AgentChatItem] = [.user("Later turn", sequenceIndex: 1), .assistant("Later reply.", sequenceIndex: 2)]
        var transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        transcript.turns.insert(AgentTranscriptTurn(
            id: saved.id,
            request: AgentTranscriptRequestAnchor(from: saved),
            retentionTier: .summary,
            terminalState: .completed,
            startedAt: savedAt
        ), at: 0)
        let executionTurnID = UUID()

        guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, executionTurnID: executionTurnID) else {
            return XCTFail("a canonical-only occurrence is relocated")
        }
        XCTAssertEqual(candidate.historicalTurnID, saved.id)
        XCTAssertEqual(candidate.transcript.turns.map(\.id), transcript.turns.map(\.id) + [executionTurnID])
        XCTAssertEqual(candidate.transcript.turns[0].retentionTier, .summary, "never retiered")
        XCTAssertNil(candidate.transcript.turns[0].request)
        XCTAssertEqual(candidate.transcript.turns.last?.retentionTier, .full)
        XCTAssertEqual(candidate.transcript.turns.last?.request?.id, saved.id)
        XCTAssertEqual(candidate.workingItems.map(\.id), items.map(\.id) + [saved.id])
    }

    func testSavedInputRelocationIsIdempotentForACleanFinalRequestAndRefusesUnsafeShapes() {
        let saved = AgentChatItem.user("saved message", sequenceIndex: 2)
        let items: [AgentChatItem] = [.user("Earlier turn", sequenceIndex: 0), .assistant("Earlier reply.", sequenceIndex: 1), saved]
        let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)

        guard case let .unchanged(item, turnID) = relocate(transcript, items: items, saved: saved) else {
            return XCTFail("a clean final request that is the last item is reused")
        }
        XCTAssertEqual(item.id, saved.id)
        XCTAssertEqual(turnID, saved.id)
        XCTAssertEqual(transcript.executionTurnID(forUserItemID: saved.id), saved.id)

        // A turn an attempt already joins is historical: a new E, then repeated preparation reuses it.
        let executionTurnID = UUID()
        guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, referenced: [saved.id], executionTurnID: executionTurnID) else {
            return XCTFail("a referenced turn is never reused")
        }
        XCTAssertEqual(candidate.transcript.turns.map(\.id), [items[0].id, saved.id, executionTurnID])
        guard case let .unchanged(_, again) = relocate(
            candidate.transcript,
            items: candidate.workingItems,
            saved: saved,
            referenced: [saved.id]
        ) else {
            return XCTFail("repeated preparation is idempotent")
        }
        XCTAssertEqual(again, executionTurnID)
        // ...until E itself is referenced by an attempt: then the next preparation allocates anew.
        let nextID = UUID()
        guard case let .prepared(next) = relocate(
            candidate.transcript,
            items: candidate.workingItems,
            saved: saved,
            referenced: [saved.id, executionTurnID],
            executionTurnID: nextID
        ) else {
            return XCTFail("a referenced execution turn is historical")
        }
        XCTAssertEqual(next.transcript.turns.map(\.id), [items[0].id, saved.id, executionTurnID, nextID])

        // A final turn with provider execution evidence is not clean.
        var executed = transcript
        XCTAssertEqual(executed.turns[1].responseSpans.count, 1)
        executed.turns[1].responseSpans[0].providerTurnID = "provider-turn"
        guard case .prepared = relocate(executed, items: items, saved: saved) else {
            return XCTFail("an executed turn is never reused")
        }

        XCTAssertEqual(refusal(relocate(transcript, items: items + [saved], saved: saved)), .conflictingOccurrences)
        XCTAssertEqual(refusal(relocate(transcript, items: items, saved: saved, consistent: false)), .inconsistentOccurrence)
        XCTAssertEqual(refusal(relocate(transcript, items: Array(items.dropLast()), saved: saved)), .unsynchronizedWorkingItems)
        XCTAssertEqual(
            refusal(relocate(transcript, items: items, saved: saved, referenced: [saved.id], executionTurnID: items[0].id)),
            .destinationCollision
        )
        XCTAssertNil(refusal(relocate(transcript, items: items, saved: saved, referenced: [saved.id])))
    }

    /// The existing reconciliation keeps an unrelated full requestless span-less envelope X after T
    /// (positional fallback with nothing left to substitute). Appending E behind X would let that
    /// fallback consume E as X's replacement and lose X's interruption, so the relocation of an
    /// absent saved input is refused before any mutation.
    func testSavedInputRelocationRefusesWhenAnyRetainedEnvelopeWouldBeSubstituted() {
        let first = AgentChatItem.user("Earlier turn", sequenceIndex: 0)
        let reply = AgentChatItem.assistant("Earlier reply.", sequenceIndex: 1)
        let items = [first, reply]
        var transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        let interruption = AgentTranscriptTurnInterruption(reason: .appCrash, observedAt: Date(timeIntervalSince1970: 1500))
        let retained = AgentTranscriptTurn(
            terminalState: .cancelled,
            startedAt: Date(timeIntervalSince1970: 1400),
            interruption: interruption
        )
        transcript.turns.append(retained)

        // Baseline: the existing reconciliation keeps X with its evidence.
        let baseline = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: transcript,
            workingItems: items,
            nextSequenceIndex: transcript.nextSequenceIndex
        )
        XCTAssertEqual(baseline.turns.map(\.id), [first.id, retained.id])
        XCTAssertEqual(baseline.turns.last?.interruption, interruption)

        let saved = AgentChatItem.user("saved message", sequenceIndex: 2).replacingTimestamp(Date(timeIntervalSince1970: 1000))
        let before = transcript
        XCTAssertEqual(refusal(relocate(transcript, items: items, saved: saved)), .historicalEnvelopeNotReconcilable)
        XCTAssertEqual(transcript, before, "nothing changed")
    }

    /// Item 3: relocation keeps H's recorded terminal state and completion exactly
    /// (`finalizeTurn` keeps them when given `nil`); a closed unchanged explicit H then keeps its
    /// full recorded envelope through a normal rebuild, serialization, and reload rebuild, for a
    /// completed, cancelled (interrupted), and failed H. E is never frozen: a live run reopens it.
    func testSavedInputRelocationPreservesHistoricalCompletionMetadataThroughRebuildAndReload() throws {
        for state in [AgentSessionRunState.completed, .cancelled, .failed] {
            let label = "\(state)"
            let saved = AgentChatItem.user("saved message", sequenceIndex: 2).replacingTimestamp(Date(timeIntervalSince1970: 1000))
            let partial = AgentChatItem.assistant("A partial reply.", sequenceIndex: 3).replacingTimestamp(Date(timeIntervalSince1970: 1010))
            let items: [AgentChatItem] = [
                .user("Earlier turn", sequenceIndex: 0).replacingTimestamp(Date(timeIntervalSince1970: 900)),
                .assistant("Earlier reply.", sequenceIndex: 1).replacingTimestamp(Date(timeIntervalSince1970: 910)),
                saved,
                partial,
                .user("a newer message", sequenceIndex: 4).replacingTimestamp(Date(timeIntervalSince1970: 1100)),
                .assistant("The newer reply.", sequenceIndex: 5).replacingTimestamp(Date(timeIntervalSince1970: 1110))
            ]
            var transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
            XCTAssertEqual(transcript.turns[1].id, saved.id, label)
            // Recorded completion later than the last activity, with execution evidence.
            transcript.turns[1].terminalState = state
            transcript.turns[1].lastActivityAt = Date(timeIntervalSince1970: 1050)
            transcript.turns[1].completedAt = Date(timeIntervalSince1970: 1060)
            transcript.turns[1].responseSpans[0].lifecycle = switch state {
            case .cancelled: .cancelled
            case .failed: .failed
            default: .completed
            }
            transcript.turns[1].responseSpans[0].lastActivityAt = Date(timeIntervalSince1970: 1040)
            transcript.turns[1].responseSpans[0].completedAt = Date(timeIntervalSince1970: 1055)
            transcript.turns[1].responseSpans[0].runID = UUID()
            transcript.turns[1].responseSpans[0].providerTurnID = "provider-turn"
            if state == .cancelled {
                transcript.turns[1].interruption = AgentTranscriptTurnInterruption(reason: .appQuit, observedAt: Date(timeIntervalSince1970: 1070))
            }
            let recorded = transcript.turns[1]
            let executionTurnID = UUID()

            guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, executionTurnID: executionTurnID) else {
                XCTFail("\(label): relocates")
                continue
            }
            let historical = candidate.transcript.turns[1]
            XCTAssertEqual(historical.terminalState, state, "\(label): relocation keeps H's terminal state")
            XCTAssertEqual(historical.completedAt, recorded.completedAt, "\(label): relocation keeps H's completion")
            XCTAssertEqual(historical.lastActivityAt, recorded.lastActivityAt, label)
            XCTAssertEqual(historical.interruption, recorded.interruption, label)
            assertEnvelope(historical, equals: recorded, ignoringRequest: true, label: "\(label) relocated")

            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: candidate.transcript,
                workingItems: candidate.workingItems,
                nextSequenceIndex: candidate.nextSequenceIndex
            )
            XCTAssertEqual(rebuilt.turns.map(\.id), candidate.transcript.turns.map(\.id), label)
            assertEnvelope(rebuilt.turns[1], equals: historical, ignoringRequest: false, label: "\(label) rebuilt")

            let reloaded = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(rebuilt))
            assertEnvelope(reloaded.turns[1], equals: historical, ignoringRequest: false, label: "\(label) decoded")
            let reloadRebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: reloaded,
                workingItems: candidate.workingItems,
                nextSequenceIndex: candidate.nextSequenceIndex
            )
            assertEnvelope(reloadRebuilt.turns[1], equals: historical, ignoringRequest: false, label: "\(label) reload rebuild")

            // E is not frozen: a live run with new output reopens and changes it.
            let streaming = AgentChatItem.assistant("Working", sequenceIndex: candidate.nextSequenceIndex, isStreaming: true)
            let live = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: rebuilt,
                workingItems: candidate.workingItems + [streaming],
                terminalState: .running,
                nextSequenceIndex: candidate.nextSequenceIndex + 1
            )
            let liveExecution = try XCTUnwrap(live.turns.last, label)
            XCTAssertEqual(liveExecution.id, executionTurnID, label)
            XCTAssertNil(liveExecution.completedAt, "\(label): E stays live")
            XCTAssertEqual(liveExecution.responseSpans.map(\.lifecycle), [.open], label)
            XCTAssertEqual(liveExecution.allActivities.map(\.id), [streaming.id], label)
            assertEnvelope(live.turns[1], equals: historical, ignoringRequest: false, label: "\(label) beside a live E")
        }
    }

    /// Item 5: the incremental final-turn path takes ownership and envelope context from the final
    /// full working turn only, and reuses every earlier turn (including an explicit H) unchanged.
    func testIncrementalFinalTurnUpdateUsesOnlyTheFinalWorkingTurnOwnership() {
        let saved = AgentChatItem.user("saved message", sequenceIndex: 2)
        let items: [AgentChatItem] = [
            .user("Earlier turn", sequenceIndex: 0),
            .assistant("Earlier reply.", sequenceIndex: 1),
            saved,
            .assistant("A partial reply.", sequenceIndex: 3),
            .user("a newer message", sequenceIndex: 4)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        let executionTurnID = UUID()
        guard case let .prepared(candidate) = relocate(transcript, items: items, saved: saved, executionTurnID: executionTurnID) else {
            return XCTFail("relocates")
        }
        XCTAssertEqual(AgentTranscriptIO.explicitWorkingTurnOwnership(in: candidate.transcript).explicitTurnIDs, [saved.id, executionTurnID])
        let finalOwnership = AgentTranscriptIO.explicitFinalWorkingTurnOwnership(in: candidate.transcript)
        XCTAssertEqual(finalOwnership.explicitTurnIDs, [executionTurnID], "only the final working turn")
        XCTAssertEqual(finalOwnership.turnIDByItemID, [saved.id: executionTurnID])

        let reply = AgentChatItem.assistant("The saved reply.", sequenceIndex: candidate.nextSequenceIndex)
        let grown = candidate.workingItems + [reply]
        let diagnostic = importDiagnostic(existing: candidate.transcript, items: grown, earliestChangedIndex: grown.count - 1)
        guard case let .updated(updated, finalTurnStartIndex, finalTurnItemCount) = diagnostic else {
            return XCTFail("the explicit final turn updates incrementally, got \(diagnostic)")
        }
        XCTAssertEqual(finalTurnStartIndex, grown.count - 2)
        XCTAssertEqual(finalTurnItemCount, 2)
        XCTAssertEqual(updated.turns.map(\.id), candidate.transcript.turns.map(\.id))
        // Earlier turns are reused (the existing compactor may refresh derived caches only).
        for (after, before) in zip(updated.turns.dropLast(), candidate.transcript.turns.dropLast()) {
            assertEnvelope(after, equals: before, ignoringRequest: false, label: "earlier turn reused")
        }
        XCTAssertEqual(updated.turns.last?.request?.id, saved.id)
        XCTAssertEqual(updated.turns.last?.allActivities.map(\.id), [reply.id])

        // A normal final turn after an explicit H has no explicit ownership in the incremental path.
        let plain = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        XCTAssertTrue(AgentTranscriptIO.explicitFinalWorkingTurnOwnership(in: plain).explicitTurnIDs.isEmpty)
    }

    private func assertEnvelope(
        _ actual: AgentTranscriptTurn,
        equals expected: AgentTranscriptTurn,
        ignoringRequest: Bool,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, "\(label): id", file: file, line: line)
        if !ignoringRequest {
            XCTAssertEqual(actual.request?.id, expected.request?.id, "\(label): request", file: file, line: line)
        }
        XCTAssertEqual(actual.retentionTier, expected.retentionTier, "\(label): tier", file: file, line: line)
        XCTAssertEqual(actual.terminalState, expected.terminalState, "\(label): terminal state", file: file, line: line)
        XCTAssertEqual(actual.startedAt, expected.startedAt, "\(label): startedAt", file: file, line: line)
        XCTAssertEqual(actual.lastActivityAt, expected.lastActivityAt, "\(label): lastActivityAt", file: file, line: line)
        XCTAssertEqual(actual.completedAt, expected.completedAt, "\(label): completedAt", file: file, line: line)
        XCTAssertEqual(actual.interruption, expected.interruption, "\(label): interruption", file: file, line: line)
        XCTAssertEqual(actual.recoveredOutcome, expected.recoveredOutcome, "\(label): recovered outcome", file: file, line: line)
        XCTAssertEqual(actual.responseSpans.count, expected.responseSpans.count, "\(label): span count", file: file, line: line)
        for (spanA, spanE) in zip(actual.responseSpans, expected.responseSpans) {
            XCTAssertEqual(spanA.id, spanE.id, "\(label): span id", file: file, line: line)
            XCTAssertEqual(spanA.lifecycle, spanE.lifecycle, "\(label): span lifecycle", file: file, line: line)
            XCTAssertEqual(spanA.startedAt, spanE.startedAt, "\(label): span startedAt", file: file, line: line)
            XCTAssertEqual(spanA.lastActivityAt, spanE.lastActivityAt, "\(label): span lastActivityAt", file: file, line: line)
            XCTAssertEqual(spanA.completedAt, spanE.completedAt, "\(label): span completedAt", file: file, line: line)
            XCTAssertEqual(spanA.runID, spanE.runID, "\(label): span runID", file: file, line: line)
            XCTAssertEqual(spanA.providerTurnID, spanE.providerTurnID, "\(label): span providerTurnID", file: file, line: line)
            XCTAssertEqual(spanA.activities, spanE.activities, "\(label): span activities", file: file, line: line)
        }
    }
}
