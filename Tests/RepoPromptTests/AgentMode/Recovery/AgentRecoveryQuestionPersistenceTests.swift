@testable import RepoPromptAgentCore
import XCTest

/// MainActor-confined flag shared between a test and its write seam.
@MainActor
private final class HandOverFlag {
    var value = false
}

/// Live pending-question persistence (lossless restart Phase 2, plan §E): the lane-owned question
/// controller against a real store with a manual sleep seam, the store's in-place upsert, and the
/// per-interaction snapshot builder.
@MainActor
final class AgentRecoveryQuestionPersistenceTests: XCTestCase {
    private typealias Support = RecoveryTestSupport
    private typealias Controller = AgentRecoveryQuestionPersistenceController

    private var root: URL!
    private var failures: RecoveryStoreWriteFailureSwitch!
    private var store: AgentRecoveryStore!
    private var sleeper: RecoveryManualSleeper!
    private var clock: RecoveryTestClock!
    private var binding: AgentRecoveryLifecycleBinding!
    private var writes: [AgentRecoveryStore.QuestionSnapshotUpdate] = []
    private var writeLatch: RecoveryGateLatch?

    override func setUp() async throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryQuestionPersistenceTests")
        failures = RecoveryStoreWriteFailureSwitch()
        store = AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            appInstanceID: UUID(),
            fileOperations: failures.fileOperations()
        )
        sleeper = RecoveryManualSleeper()
        clock = RecoveryTestClock()
        binding = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        writes = []
        writeLatch = nil
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeController() -> Controller {
        let sleeper = sleeper!
        let clock = clock!
        return Controller(
            write: { [weak self] update in
                guard let self else { return .failure(.retired) }
                return await write(update)
            },
            sleep: { try await sleeper.sleep(until: $0) },
            clockNow: { clock.now }
        )
    }

    private func write(
        _ update: AgentRecoveryStore.QuestionSnapshotUpdate
    ) async -> Result<AgentRecoveryStore.QuestionSnapshotUpdateReceipt, AgentRecoveryControllerFailure> {
        if let writeLatch {
            await writeLatch.pause()
        }
        writes.append(update)
        let store = store!
        let binding = binding!
        do {
            return try await .success(store.updateQuestionSnapshots(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                update: update
            ))
        } catch let error as AgentRecoveryStoreError {
            return .failure(.store(error))
        } catch {
            return .failure(.lifecycleRejected(String(describing: error)))
        }
    }

    private func stored() async -> [AgentRecoveryQuestionSnapshot] {
        await store.read(sessionID: binding.sessionID).record?.questions ?? []
    }

    private func assertEventually(
        _ message: String = "condition not reached",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let reached = await Support.eventually(condition)
        XCTAssertTrue(reached, message, file: file, line: line)
    }

    private static let appInstanceID = UUID()

    private static func snapshot(
        _ id: UUID,
        answer: String? = nil,
        askedAt: Int64 = 1000,
        extras: AgentRecoveryExtras = [:]
    ) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: id,
            kind: .askUser,
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: appInstanceID,
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: askedAt),
            title: "Question",
            message: nil,
            items: [AgentRecoveryQuestionItem(questionID: "target", header: nil, text: "Which environment?", options: [], isSecret: false, answer: answer)],
            extras: extras
        )
    }

    // MARK: - Creation

    func testCreationIsWrittenImmediatelyWithoutADebounce() async {
        let controller = makeController()
        let id = UUID()
        let result = await controller.commitCreation(Self.snapshot(id))
        guard case .success = result else { return XCTFail("\(result)") }
        let ids = await stored().map(\.interactionID)
        XCTAssertEqual(ids, [id])
        XCTAssertEqual(controller.committedInteractionIDs, [id])
        let deadlines = await sleeper.pendingDeadlines
        XCTAssertTrue(deadlines.isEmpty, "no timer is involved in creation")
    }

    func testFailedCreationStaysUnsavedUntilForgotten() async {
        let controller = makeController()
        let id = UUID()
        failures.shouldFailWrites = true
        let result = await controller.commitCreation(Self.snapshot(id))
        guard case .failure = result else { return XCTFail("a failed write is reported") }
        XCTAssertTrue(controller.hasUnsavedSnapshot(id))
        XCTAssertNotNil(controller.lastWriteFailure)
        controller.forget(id)
        XCTAssertFalse(controller.hasPendingWork, "a never-stored question owes nothing")
        failures.shouldFailWrites = false
        controller.draftDidChange(Self.snapshot(id, answer: "late"))
        XCTAssertFalse(controller.hasPendingWork, "a forgotten interaction is never written by a draft")
    }

    // MARK: - Drafts

    func testDraftsCoalesceWithTheDebounceAndTheMaximumDelay() async {
        let controller = makeController()
        let id = UUID()
        _ = await controller.commitCreation(Self.snapshot(id))
        let writesAfterCreation = writes.count
        let t0 = clock.now

        controller.draftDidChange(Self.snapshot(id, answer: "s"))
        await assertEventually { await self.sleeper.pendingDeadlines == [t0 + Controller.debounce, t0 + Controller.maximumDelay] }
        clock.advance(by: .milliseconds(1500))
        controller.draftDidChange(Self.snapshot(id, answer: "staging"))
        await assertEventually { await self.sleeper.pendingDeadlines == [t0 + .milliseconds(1800), t0 + Controller.maximumDelay] }
        XCTAssertEqual(writes.count, writesAfterCreation, "nothing written before a deadline")

        await sleeper.fire(through: t0 + Controller.maximumDelay)
        await assertEventually { await self.stored().first?.items.first?.answer == "staging" }
        XCTAssertEqual(writes.count, writesAfterCreation + 1, "one coalesced write")
        XCTAssertFalse(controller.hasPendingWork)

        // An unchanged snapshot is not rewritten.
        controller.draftDidChange(Self.snapshot(id, answer: "staging"))
        XCTAssertFalse(controller.hasPendingWork)
    }

    func testDraftOfAQuestionThisControllerNeverCreatedIsIgnored() async {
        let controller = makeController()
        controller.draftDidChange(Self.snapshot(UUID(), answer: "untracked"))
        XCTAssertFalse(controller.hasPendingWork)
        let deadlines = await sleeper.pendingDeadlines
        XCTAssertTrue(deadlines.isEmpty)
    }

    // MARK: - Ending

    func testEndingRemovesExactlyThatInteractionAndLateEditsNeverResurrectIt() async {
        let controller = makeController()
        let answered = UUID()
        let other = UUID()
        _ = await controller.commitCreation(Self.snapshot(answered))
        _ = await controller.commitCreation(Self.snapshot(other))
        controller.draftDidChange(Self.snapshot(answered, answer: "unsaved"))

        controller.end([answered], preserving: false)
        XCTAssertFalse(controller.hasUnsavedSnapshot(answered), "its coalesced upsert is cancelled")
        await assertEventually { await self.stored().map(\.interactionID) == [other] }
        XCTAssertFalse(writes.contains { $0.upserting.contains { $0.interactionID == answered && $0.items.first?.answer == "unsaved" } })

        controller.draftDidChange(Self.snapshot(answered, answer: "late edit"))
        XCTAssertFalse(controller.hasPendingWork, "a late edit never resurrects an ended question")
        let ids = await stored().map(\.interactionID)
        XCTAssertEqual(ids, [other])
    }

    func testFailedRemovalIsOwedAndRetriedByTheNextWrite() async {
        let controller = makeController()
        let answered = UUID()
        let other = UUID()
        _ = await controller.commitCreation(Self.snapshot(answered))
        _ = await controller.commitCreation(Self.snapshot(other))

        failures.shouldFailWrites = true
        controller.end([answered], preserving: false)
        await assertEventually { controller.lastWriteFailure != nil }
        XCTAssertEqual(controller.owedRemovals, [answered])
        var ids = await stored().map(\.interactionID)
        XCTAssertEqual(ids, [answered, other], "the failed removal kept the snapshot")
        let drained = await controller.drain()
        guard case .failed = drained else { return XCTFail("drain reports the owed removal") }

        failures.shouldFailWrites = false
        let t0 = clock.now
        controller.draftDidChange(Self.snapshot(other, answer: "next"))
        await assertEventually { await self.sleeper.pendingDeadlines.contains(t0 + Controller.debounce) }
        await sleeper.fire(through: t0 + Controller.debounce)
        await assertEventually { controller.owedRemovals.isEmpty }
        ids = await stored().map(\.interactionID)
        XCTAssertEqual(ids, [other], "retried with the next write")
        XCTAssertNil(controller.lastWriteFailure)
    }

    func testPreservingEndKeepsTheLatestSnapshot() async {
        let controller = makeController()
        let id = UUID()
        _ = await controller.commitCreation(Self.snapshot(id))
        controller.draftDidChange(Self.snapshot(id, answer: "preserved"))
        controller.end([id], preserving: true)
        await assertEventually { await self.stored().first?.items.first?.answer == "preserved" }
        controller.draftDidChange(Self.snapshot(id, answer: "after close"))
        XCTAssertFalse(controller.hasPendingWork, "edits after the preserving end are ignored")
        let drained = await controller.drain()
        XCTAssertEqual(drained, .nothingPending)
        let answer = await stored().first?.items.first?.answer
        XCTAssertEqual(answer, "preserved")
    }

    // MARK: - Bounded retry and hand-over

    /// Review B F2: a failed write is retried automatically, spaced by the maximum draft delay, at
    /// most `automaticRetryLimit` times (no hot loop); an explicit flush or a later edit always
    /// writes again, and a successful write clears the save error.
    func testFailedWritesRetryAutomaticallyAtMostTheBoundThenOnlyOnDemand() async {
        let controller = makeController()
        let id = UUID()
        _ = await controller.commitCreation(Self.snapshot(id))
        failures.shouldFailWrites = true
        let before = writes.count
        let t0 = clock.now
        controller.draftDidChange(Self.snapshot(id, answer: "unsaved"))
        await assertEventually { await self.sleeper.pendingDeadlines.contains(t0 + Controller.debounce) }
        await sleeper.fire(through: t0 + Controller.debounce)
        await assertEventually { controller.lastWriteFailure != nil && self.writes.count == before + 1 }

        for retry in 1 ... Controller.automaticRetryLimit {
            await assertEventually("retry \(retry) is scheduled") {
                await self.sleeper.pendingDeadlines.contains(t0 + Controller.maximumDelay)
            }
            await sleeper.fire(through: t0 + Controller.maximumDelay)
            await assertEventually("retry \(retry) writes") { self.writes.count == before + 1 + retry }
        }
        // Joins the last automatic retry, then writes once on demand; nothing more is scheduled.
        let drained = await controller.drain()
        guard case .failed = drained else { return XCTFail("the unsaved snapshot is still owed: \(drained)") }
        XCTAssertEqual(writes.count, before + 1 + Controller.automaticRetryLimit + 1)
        await assertEventually("no automatic retry beyond the bound") { await self.sleeper.pendingDeadlines.isEmpty }
        XCTAssertTrue(controller.hasUnsavedSnapshot(id))

        failures.shouldFailWrites = false
        let t1 = clock.now
        controller.draftDidChange(Self.snapshot(id, answer: "saved later"))
        await assertEventually { await self.sleeper.pendingDeadlines.contains(t1 + Controller.debounce) }
        await sleeper.fire(through: t1 + Controller.debounce)
        await assertEventually { await self.stored().first?.items.first?.answer == "saved later" }
        await assertEventually { controller.lastWriteFailure == nil }
        XCTAssertFalse(controller.hasPendingWork)
    }

    /// Review B F9 (controller boundary): a same-owner, same-binding successor adopts exactly the
    /// predecessor's still-live interactions; they stay live, their drafts keep persisting, and
    /// answering removes exactly them. An interaction ended before the hand-over is not handed over.
    func testSuccessorAdoptsOnlyStillLiveInteractionsAndKeepsPersistingThem() async {
        let predecessor = makeController()
        let live = UUID()
        let preserved = UUID()
        _ = await predecessor.commitCreation(Self.snapshot(live, answer: "draft"))
        _ = await predecessor.commitCreation(Self.snapshot(preserved))
        predecessor.end([preserved], preserving: true)
        let handedOver = predecessor.liveSnapshots
        XCTAssertEqual(handedOver.map(\.interactionID), [live], "Only still-live interactions are handed over")
        _ = await predecessor.retire(flushingPending: true)
        XCTAssertTrue(predecessor.liveInteractionIDs.isEmpty)

        let successor = makeController()
        successor.adoptLiveInteractions(handedOver, after: nil)
        XCTAssertEqual(successor.liveInteractionIDs, [live], "The live question stays live, never historical")
        // Review R1: nothing handed over is assumed durable; the successor writes it itself.
        XCTAssertTrue(successor.needsPreservation(live), "An adopted snapshot is pending until this controller writes it")
        await assertEventually { !successor.hasPendingWork && !successor.needsPreservation(live) }
        let rewritten = await stored().first { $0.interactionID == live }?.items.first?.answer
        XCTAssertEqual(rewritten, "draft")

        let t0 = clock.now
        successor.draftDidChange(Self.snapshot(live, answer: "after hand-over"))
        XCTAssertTrue(successor.hasUnsavedSnapshot(live), "Drafts of an adopted question are persisted")
        await assertEventually { await self.sleeper.pendingDeadlines.contains(t0 + Controller.debounce) }
        await sleeper.fire(through: t0 + Controller.debounce)
        await assertEventually {
            await self.stored().first { $0.interactionID == live }?.items.first?.answer == "after hand-over"
        }

        successor.end([live], preserving: false)
        await assertEventually { await self.stored().map(\.interactionID) == [preserved] }
        XCTAssertTrue(successor.liveInteractionIDs.isEmpty)
    }

    /// Review R1 (A F01-R1 / B R1-F3): an answer still unsaved when its lane is handed over is not
    /// treated as durable. Resubmitting the same answer is refused while the predecessor retires,
    /// the successor writes nothing before that retirement ends, a failed retirement and failing
    /// writes keep refusing the reply, and the reply is allowed only once the successor's own write
    /// commits the answer.
    func testHandedOverUnsavedAnswerIsNotRepliedUntilTheSuccessorPreservesItAfterRetirement() async throws {
        let predecessor = makeController()
        let live = UUID()
        _ = await predecessor.commitCreation(Self.snapshot(live))
        failures.shouldFailWrites = true
        predecessor.draftDidChange(Self.snapshot(live, answer: "unsaved answer"))
        let handedOver = predecessor.liveSnapshots
        XCTAssertEqual(handedOver.map { $0.items.first?.answer }, ["unsaved answer"])

        let retirementGate = RecoveryGateLatch()
        let retirementFinished = HandOverFlag()
        let retirement = Task { @MainActor () -> AgentRecoveryQuestionFlushOutcome? in
            await retirementGate.pause()
            let outcome = await predecessor.retire(flushingPending: true)
            retirementFinished.value = true
            return outcome
        }
        let wroteBeforeRetirement = HandOverFlag()
        let sleeper = try XCTUnwrap(sleeper)
        let clock = try XCTUnwrap(clock)
        let successor = Controller(
            write: { [weak self] update in
                if !retirementFinished.value { wroteBeforeRetirement.value = true }
                guard let self else { return .failure(.retired) }
                return await write(update)
            },
            sleep: { try await sleeper.sleep(until: $0) },
            clockNow: { clock.now }
        )
        successor.adoptLiveInteractions(handedOver, after: { _ = await retirement.value })
        // The same answer is resubmitted: no draft change, and still not known durable.
        successor.draftDidChange(Self.snapshot(live, answer: "unsaved answer"))
        XCTAssertTrue(successor.needsPreservation(live))

        let t0 = clock.now
        let early = Task { @MainActor in await successor.preserveBeforeReply(live, within: .seconds(5)) }
        await assertEventually { await sleeper.pendingDeadlines.contains(t0 + .seconds(5)) }
        await sleeper.fire(through: t0 + .seconds(5))
        let earlyResult = await early.value
        XCTAssertEqual(earlyResult, .timedOut, "No reply while the predecessor is still retiring")
        XCTAssertTrue(successor.unsentAnswerIDs.contains(live))

        await retirementGate.open()
        let retired = await retirement.value
        guard case .failed? = retired else { return XCTFail("the predecessor's retirement flush failed: \(String(describing: retired))") }
        XCTAssertFalse(wroteBeforeRetirement.value, "The successor wrote nothing before the predecessor retired")

        let failing = await successor.preserveBeforeReply(live, within: .seconds(5))
        guard case .failed = failing else { return XCTFail("no reply while the answer cannot be saved: \(failing)") }
        XCTAssertTrue(successor.unsentAnswerIDs.contains(live))
        var storedAnswer = await stored().first?.items.first?.answer
        XCTAssertNil(storedAnswer, "The answer is not durable yet")

        failures.shouldFailWrites = false
        let preserved = await successor.preserveBeforeReply(live, within: .seconds(5))
        XCTAssertEqual(preserved, .preserved)
        XCTAssertFalse(successor.unsentAnswerIDs.contains(live))
        storedAnswer = await stored().first?.items.first?.answer
        XCTAssertEqual(storedAnswer, "unsaved answer", "The reply is allowed only after the answer is stored")
    }

    // MARK: - Bounded flush

    func testBoundedFlushReturnsWhenStorageDoesNotAnswerAndTheWriteStillLands() async {
        let controller = makeController()
        let id = UUID()
        _ = await controller.commitCreation(Self.snapshot(id))
        controller.draftDidChange(Self.snapshot(id, answer: "slow"))
        let latch = RecoveryGateLatch()
        writeLatch = latch
        let t0 = clock.now

        let bounded = Task { @MainActor in await controller.flush(within: .seconds(2)) }
        await latch.waitUntilPaused()
        await sleeper.fire(through: t0 + .seconds(2))
        let outcome = await bounded.value
        XCTAssertNil(outcome, "the caller is released at the bound")

        await latch.open()
        await assertEventually { await self.stored().first?.items.first?.answer == "slow" }
    }

    // MARK: - Store and builder

    func testInPlaceUpsertKeepsTheFirstAskTimeAndUnknownFields() async throws {
        let id = UUID()
        let first = Self.snapshot(id, askedAt: 1000, extras: ["future": .string("kept")])
        _ = try await store.updateQuestionSnapshots(binding: binding, expectedRevision: nil, update: .init(upserting: [first]))
        let recapture = Self.snapshot(id, answer: "newer", askedAt: 9000)
        _ = try await store.updateQuestionSnapshots(
            binding: binding,
            expectedRevision: store.currentRevision(sessionID: binding.sessionID),
            update: .init(upserting: [recapture])
        )
        let all = await stored()
        let written = try XCTUnwrap(all.first)
        XCTAssertEqual(written.askedAt, AgentRecoveryTimestamp(millisecondsSince1970: 1000), "a recapture never manufactures freshness")
        XCTAssertEqual(written.extras["future"], .string("kept"))
        XCTAssertEqual(written.items.first?.answer, "newer")
    }

    func testElicitationSnapshotUsesTheRequestsOwnAskTime() {
        let askedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = AgentMCPElicitationRequest(
            requestID: .string("elicitation"),
            method: "mcpServer/elicitation/request",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            prompt: "Provide a value",
            rawParamsJSON: "{}",
            askedAt: askedAt
        )
        let context = AgentRecoveryQuestionSnapshotBuilder.Context(runAttemptID: nil, transcriptResetGeneration: 0, appInstanceID: UUID())
        let first = AgentRecoveryQuestionSnapshotBuilder.snapshot(elicitation: request, context: context)
        let second = AgentRecoveryQuestionSnapshotBuilder.snapshot(elicitation: request, context: context)
        XCTAssertEqual(first.askedAt, AgentRecoveryTimestamp(askedAt))
        XCTAssertEqual(first, second, "captures are stable")
        XCTAssertEqual(first.message, "Provide a value")
        XCTAssertTrue(first.items.isEmpty)
    }

    func testSecretAnswersNeverReachTheStoredBytes() async throws {
        let request = AgentRequestUserInputRequest(
            requestID: .string("secret-request"),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            questions: [
                AgentRequestUserInputQuestion(id: "target", header: "Target", question: "Which environment?", isOther: false, isSecret: false, options: []),
                AgentRequestUserInputQuestion(id: "token", header: "Token", question: "Paste the deploy token", isOther: false, isSecret: true, options: [])
            ]
        )
        let context = AgentRecoveryQuestionSnapshotBuilder.Context(runAttemptID: nil, transcriptResetGeneration: 0, appInstanceID: UUID())
        let controller = makeController()
        _ = await controller.commitCreation(AgentRecoveryQuestionSnapshotBuilder.snapshot(userInput: request, drafts: [:], context: context))
        let drafts = [
            "target": AgentRequestUserInputQuestionDraft(note: "staging"),
            "token": AgentRequestUserInputQuestionDraft(note: "hunter2")
        ]
        controller.draftDidChange(AgentRecoveryQuestionSnapshotBuilder.snapshot(userInput: request, drafts: drafts, context: context))
        let flushed = await controller.flush()
        XCTAssertEqual(flushed, .committed)
        let all = await stored()
        let written = try XCTUnwrap(all.first)
        XCTAssertEqual(written.items.map(\.answer), ["staging", nil])
        let bytes = try Data(contentsOf: store.recordFileURL(sessionID: binding.sessionID))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("hunter2"))
    }
}
