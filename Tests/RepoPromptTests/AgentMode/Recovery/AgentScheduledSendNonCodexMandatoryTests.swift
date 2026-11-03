import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Mandatory lossless-restart scheduled dispatch on non-Codex providers (R2/R9). The injected starter
/// reproduces the run service's non-Codex evidence contract against the linked intent: `dispatching`
/// is committed before the provider, the start returns before acceptance (Claude/ACP accept on the
/// provider's response), and acceptance or a proven non-handoff is written afterwards.
@MainActor
final class AgentScheduledSendNonCodexMandatoryTests: XCTestCase {
    func testClaudeScheduledSendCommitsIntentFirstAndTransfersOnlyAfterAffirmativeAcceptance() async throws {
        let harness = try await makeHarness(windowID: 4801, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            await probe.observeHandoff(harness)
            guard let evidence = await probe.beginEvidence(harness) else { return .failed(message: "no evidence") }
            probe.evidence = evidence
            // The run starts; acceptance arrives later with the provider's response.
            harness.session.runID = UUID()
            harness.session.runState = .running
            return nil
        }

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Run the Claude tests", probe: probe)

        XCTAssertEqual(probe.intentsAtHandoff.count, 1, "The scheduled intent is committed before the provider start")
        XCTAssertEqual(probe.intentsAtHandoff.first?.origin, .scheduled)
        XCTAssertEqual(probe.intentsAtHandoff.first?.deliveryState, .queued)
        XCTAssertEqual(probe.intentsAtHandoff.first?.userItemID, attempt.itemID, "The intent owns the bubble's item")
        XCTAssertEqual(probe.userItemIDsAtHandoff, [attempt.itemID], "The bubble is appended before the provider start")

        // Dispatch returned while the intent is still `dispatching`: held, never confirmed or transferred.
        try await harness.waitUntil("hold awaits provider evidence") {
            harness.coordinator.transferHold(scheduleID: scheduleID)?.reason == .awaitingProviderEvidence
                && !harness.session.isScheduledDispatchInFlight
        }
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertNil(harness.session.lastScheduledDispatch)
        XCTAssertNil(harness.coordinator.recoveryStatus(sessionID: harness.sessionID))
        let dispatchingIntent = try await harness.singleIntent()
        XCTAssertEqual(dispatchingIntent.deliveryState, .dispatching)

        // Run ends before the late evidence write lands: the hold keeps waiting.
        harness.session.runState = .completed
        let evidence = try XCTUnwrap(probe.evidence)
        evidence.noteAccepted()
        let failures = await evidence.settled()
        XCTAssertTrue(failures.isEmpty)
        let acceptedIntent = try await harness.singleIntent()
        XCTAssertEqual(acceptedIntent.deliveryState, .providerAccepted)

        try await harness.waitUntil("transfer completes as provider acceptance") {
            harness.session.lastScheduledDispatch != nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertEqual(receipt.kind, .providerAccepted)
        XCTAssertEqual(receipt.scheduleID, scheduleID)
        XCTAssertEqual(receipt.attemptID, attempt.attemptID)
        XCTAssertNil(harness.session.scheduledSend, "The pending schedule is cleared by the transfer")
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1, "The bubble is kept")
        XCTAssertEqual(probe.startCount, 1, "Never re-driven")
    }

    func testOpenCodeProvenNoHandoffTransfersAsSavedInQueueNeverAcceptance() async throws {
        let harness = try await makeHarness(windowID: 4802, agent: .openCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            await probe.observeHandoff(harness)
            guard let evidence = await probe.beginEvidence(harness) else { return .failed(message: "no evidence") }
            // The post-commit freshness check failed before the provider boundary: settle back to queue.
            evidence.noteNoHandoff(message: "target changed")
            _ = await evidence.settled()
            return .stale(reason: "target changed")
        }

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Summarize the ACP log", probe: probe)

        XCTAssertEqual(probe.intentsAtHandoff.map(\.deliveryState), [.queued], "Committed before the provider start")
        try await harness.waitUntil("transfer completes as saved input") {
            harness.session.lastScheduledDispatch != nil
        }
        let intent = try await harness.singleIntent()
        XCTAssertEqual(intent.deliveryState, .queued)
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertFalse(receipt.isProviderAccepted, "A queued intent is saved input, never delivery evidence")
        XCTAssertEqual(receipt.queueLink, AgentScheduledSendQueueLink(intentID: intent.intentID, userItemID: attempt.itemID))
        XCTAssertEqual(receipt.scheduleID, scheduleID)
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1, "The queued intent's bubble is kept")
        XCTAssertEqual(probe.startCount, 1)
    }

    // MARK: - F1: deferred run-start handoff

    /// F1: `nil` from a non-Codex start means its runner owns the input, and the runner commits the
    /// dispatch later (adopted plan §5), so the intent is still `queued` when the start returns. The
    /// schedule is held with its payload, intent, and bubble: never failed, withdrawn, or transferred
    /// as saved input while the runner owes its settlement. The dispatch commit is not acceptance;
    /// only the provider's acceptance transfers. The earlier turn is never touched.
    func testClaudeDeferredRunStartHoldsUntilItsRunnerCommitsAndTheProviderAccepts() async throws {
        let harness = try await makeHarness(windowID: 4803, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = probe.deferredRunStarter(harness)

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Run the deferred tests", probe: probe)
        let handoff = try XCTUnwrap(probe.handoff)
        let intentID = try XCTUnwrap(probe.intentsAtHandoff.first?.intentID)
        try await harness.waitForHold(scheduleID: scheduleID)
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .queued)
        XCTAssertEqual(harness.lane.deferredRunStartHandoffState(intentID: intentID), .pending)

        // The run goes inactive while the runner still owes its settlement (the F1 race): a `queued`
        // intent is not saved-queue evidence here, so the re-check decides nothing.
        harness.session.runState = .completed
        harness.viewModel.recheckScheduledSendTransferAwaitingEvidence(for: harness.session)
        try await harness.letRechecksRun()
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .queued)
        harness.session.runState = .running

        // The runner's delayed preparation finishes: attach the run attempt, commit, hand off.
        XCTAssertEqual(handoff.attributedUserItemID, attempt.itemID, "The attempt's own input, never the earlier turn")
        let ownership = harness.session.beginRunAttempt(source: "claudeNative", inputUserItemID: handoff.attributedUserItemID)
        guard case .success = await handoff.attachRunAttempt(ownership: ownership, processRunID: nil, session: harness.session) else {
            return XCTFail("attach failed")
        }
        guard case .success = await handoff.commitDispatch(session: harness.session) else { return XCTFail("commit failed") }
        XCTAssertNil(harness.lane.deferredRunStartHandoffState(intentID: intentID), "Committed evidence speaks from here")
        XCTAssertTrue(handoff.enterProviderBoundary(in: harness.session))

        // A dispatch commit is not acceptance: the run ends with the intent still `dispatching`.
        harness.session.runState = .completed
        harness.viewModel.recheckScheduledSendTransferAwaitingEvidence(for: harness.session)
        try await harness.letRechecksRun()
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .dispatching)

        handoff.noteAccepted()
        let failures = await handoff.evidence.settled()
        XCTAssertTrue(failures.isEmpty)
        try await harness.waitUntil("transfer completes as provider acceptance") {
            harness.session.lastScheduledDispatch != nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertEqual(receipt.kind, .providerAccepted)
        XCTAssertEqual(receipt.attemptID, attempt.attemptID)
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1, "The bubble is kept")
        let scheduledText = try XCTUnwrap(probe.scheduledItemText)
        XCTAssertEqual(harness.userItemTexts(), ["Earlier turn", scheduledText], "The earlier turn is unchanged")
        XCTAssertEqual(probe.startCount, 1, "Never re-driven")
    }

    /// F1: the runner's own proven no-handoff (here a failed lease acquisition before its dispatch
    /// commit) is the only settlement that withdraws the still-`queued` intent, removes only the
    /// scheduled bubble, and fails the schedule with the scheduled explanation (the handoff's own
    /// message is logged, never shown).
    func testClaudeDeferredRunStartNoHandoffFailsTheScheduleAndRemovesOnlyItsBubble() async throws {
        let harness = try await makeHarness(windowID: 4804, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = probe.deferredRunStarter(harness)

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Start then fail", probe: probe)
        let handoff = try XCTUnwrap(probe.handoff)
        let intentID = try XCTUnwrap(probe.intentsAtHandoff.first?.intentID)
        try await harness.waitForHold(scheduleID: scheduleID)
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .queued)

        let message = "Claude Code could not start its tool connection."
        handoff.noteNoHandoff(message: message)
        handoff.settleRunInputScope()
        harness.session.runState = .failed

        try await harness.waitUntil("schedule failed before handoff") {
            harness.session.pendingScheduledSendRecord?.state == .failed
        }
        // Releasing the hold after the failure commit never turns the attempt into an unowned
        // `.dispatching` record (no delivery-unknown confirmation is raised over the failure).
        try await harness.letRechecksRun()
        let failed = try XCTUnwrap(harness.session.pendingScheduledSendRecord)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.confirmationReason)
        XCTAssertEqual(
            failed.lastFailureMessage,
            AgentModeViewModel.scheduledNotHandedOffMessage,
            "The scheduled explanation, never the handoff's internal text (logged instead)"
        )
        XCTAssertEqual(failed.attempt?.attemptID, attempt.attemptID)
        let intent = try await harness.singleIntent()
        XCTAssertEqual(intent.deliveryState, .withdrawn)
        XCTAssertFalse(harness.session.items.contains { $0.id == attempt.itemID }, "The scheduled bubble is removed")
        XCTAssertEqual(harness.userItemTexts(), ["Earlier turn"], "Only the scheduled bubble is removed")
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertNil(harness.session.lastScheduledDispatch, "Never Sent")
        XCTAssertNil(harness.lane.deferredRunStartHandoffState(intentID: intentID))
        XCTAssertEqual(probe.startCount, 1)
    }

    /// F1 (ACP route): a run cancelled during preparation settles its uncommitted handoff at the end
    /// of the runner's scope with no message; the schedule fails with the generic explanation.
    func testOpenCodeDeferredRunStartCancelledDuringPreparationFailsTheSchedule() async throws {
        let harness = try await makeHarness(windowID: 4805, agent: .openCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = probe.deferredRunStarter(harness)

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Cancel me early", probe: probe)
        let handoff = try XCTUnwrap(probe.handoff)
        try await harness.waitForHold(scheduleID: scheduleID)
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .queued)

        // The run is cancelled; the runner's task ends without a commit (its deferred scope settle).
        harness.session.runState = .cancelled
        try await harness.letRechecksRun()
        try await harness.assertHeldUnsent(attempt: attempt, intentState: .queued)
        handoff.settleRunInputScope()

        try await harness.waitUntil("schedule failed before handoff") {
            harness.session.pendingScheduledSendRecord?.state == .failed
        }
        try await harness.letRechecksRun()
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .failed)
        XCTAssertNil(harness.session.pendingScheduledSendRecord?.confirmationReason)
        XCTAssertEqual(
            harness.session.pendingScheduledSendRecord?.lastFailureMessage,
            AgentModeViewModel.scheduledNotHandedOffMessage
        )
        let intent = try await harness.singleIntent()
        XCTAssertEqual(intent.deliveryState, .withdrawn)
        XCTAssertEqual(harness.userItemTexts(), ["Earlier turn"])
        XCTAssertNil(harness.session.lastScheduledDispatch)
    }

    /// F1: when the tab is replaced while the runner is still preparing, the old owner never decides:
    /// the runner's later no-handoff does not withdraw the intent from a session that no longer owns
    /// the schedule. The intent stays `queued` and the settlement stays recorded; a successor owner
    /// that hydrates later consumes it and fails the schedule (see
    /// `testSuccessorHydratedWhileTheHandoffIsPendingWaitsForItsSettlement`).
    func testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput() async throws {
        let harness = try await makeHarness(windowID: 4806, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = probe.deferredRunStarter(harness)

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Replaced mid-preparation", probe: probe)
        let handoff = try XCTUnwrap(probe.handoff)
        let intentID = try XCTUnwrap(probe.intentsAtHandoff.first?.intentID)
        try await harness.waitForHold(scheduleID: scheduleID)

        harness.viewModel.test_removeLiveSession(tabID: harness.session.tabID)
        handoff.noteNoHandoff(message: "late")
        handoff.settleRunInputScope()
        harness.session.runState = .failed
        harness.viewModel.recheckScheduledSendTransferAwaitingEvidence(for: harness.session)
        try await harness.letRechecksRun()

        let intent = try await harness.singleIntent()
        XCTAssertEqual(intent.deliveryState, .queued, "Never withdrawn by a replaced owner")
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1)
        XCTAssertNil(harness.session.lastScheduledDispatch)
        XCTAssertEqual(harness.lane.deferredRunStartHandoffState(intentID: intentID), .notHandedOff(message: "late"))
    }

    /// F1 (R2): a successor owner hydrated while its predecessor's run-start handoff is still pending
    /// never reads the `queued` intent as saved input: no `savedInQueue` transfer and no second
    /// delivery while pending. The predecessor's lane is retired by the successor's claim, so the
    /// old runner's late commit is refused; its no-handoff settlement then fails the schedule
    /// through the successor.
    func testSuccessorHydratedWhileTheHandoffIsPendingWaitsForItsSettlement() async throws {
        let harness = try await makeHarness(windowID: 4807, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = probe.deferredRunStarter(harness)

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Reopened mid-preparation", probe: probe)
        let handoff = try XCTUnwrap(probe.handoff)
        let intentID = try XCTUnwrap(probe.intentsAtHandoff.first?.intentID)
        try await harness.waitForHold(scheduleID: scheduleID)

        // The tab is replaced/reopened: a successor owner hydrates the same durable session.
        harness.viewModel.test_removeLiveSession(tabID: harness.session.tabID)
        let successorTabID = UUID()
        harness.viewModel.test_setCurrentTabIDOverride(successorTabID)
        let successor = try await harness.viewModel.ensureSessionReady(tabID: successorTabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: harness.sessionID, on: successor))
        _ = await harness.viewModel.test_hydrateBoundSession(tabID: successorTabID)
        let successorLane = try XCTUnwrap(successor.recoveryLane)
        XCTAssertFalse(successorLane === harness.lane)
        XCTAssertTrue(harness.lane.isRetired, "The successor's claim retires the predecessor lane")
        XCTAssertEqual(successorLane.deferredRunStartHandoffState(intentID: intentID), .pending, "Visible to the successor")

        try await harness.letRechecksRun()
        XCTAssertEqual(harness.coordinator.transferHold(scheduleID: scheduleID)?.reason, .awaitingProviderEvidence)
        XCTAssertEqual(successor.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertNil(successor.lastScheduledDispatch, "Never transferred as saved input while pending")
        let pendingIntent = try await harness.singleIntent()
        XCTAssertEqual(pendingIntent.deliveryState, .queued)

        // The old runner's late commit goes through its retired lane and is refused.
        let ownership = harness.session.beginRunAttempt(source: "claudeNative", inputUserItemID: handoff.attributedUserItemID)
        _ = await handoff.attachRunAttempt(ownership: ownership, processRunID: nil, session: harness.session)
        guard case .failure(.dispatch(.refused(.laneRetired))) = await handoff.commitDispatch(session: harness.session) else {
            return XCTFail("A late commit through the retired lane must be refused")
        }
        let refusedIntent = try await harness.singleIntent()
        XCTAssertEqual(refusedIntent.deliveryState, .queued, "Nothing was handed off")

        // Its no-handoff settlement wakes the successor, which fails the schedule (never Sent).
        handoff.noteNoHandoff(message: "The session changed before the message was handed off.")
        handoff.settleRunInputScope()
        harness.session.runState = .failed
        try await harness.waitUntil("successor fails the schedule") {
            successor.pendingScheduledSendRecord?.state == .failed
        }
        try await harness.letRechecksRun()
        XCTAssertEqual(successor.pendingScheduledSendRecord?.state, .failed)
        XCTAssertEqual(successor.pendingScheduledSendRecord?.lastFailureMessage, AgentModeViewModel.scheduledNotHandedOffMessage)
        XCTAssertEqual(successor.pendingScheduledSendRecord?.attempt?.attemptID, attempt.attemptID)
        XCTAssertNil(successor.lastScheduledDispatch, "Never Sent")
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        let withdrawnIntent = try await harness.singleIntent()
        XCTAssertEqual(withdrawnIntent.deliveryState, .withdrawn)
        XCTAssertNil(successorLane.deferredRunStartHandoffState(intentID: intentID), "Consumed by its owner")
        XCTAssertEqual(probe.startCount, 1, "Never re-driven")
    }

    // MARK: - Harness

    @MainActor
    private final class StarterProbe {
        var startCount = 0
        var intentsAtHandoff: [AgentRecoveryIntent] = []
        var userItemIDsAtHandoff: [UUID] = []
        var attemptAtHandoff: AgentScheduledSendPersist.Attempt?
        var evidence: AgentRecoveryDispatchEvidence?
        var handoff: AgentProviderHandoff?
        var scheduledItemText: String?

        /// The run service's non-Codex start as shipped: the handoff is prepared (nothing written), the
        /// runner is admitted (`running`), and `startRun` returns `nil` before the runner's deferred
        /// preparation commits the dispatch. The test plays the runner's later steps.
        func deferredRunStarter(_ harness: Harness) -> ScheduledDispatchRunStarter {
            { [harness, self] _, _, _, _ in
                await observeHandoff(harness)
                scheduledItemText = harness.session.items.last { $0.kind == .user }?.text
                guard let lane = harness.session.recoveryLane,
                      let intentID = intentsAtHandoff.first?.intentID,
                      case let .success(receipt) = await lane.issueQueueReceipt(intentID: intentID),
                      case let .success(prepared) = AgentProviderHandoff.prepareRunStart(
                          session: harness.session,
                          constituents: [AgentQueuedInputIdentity(receipt: receipt)]
                      )
                else { return .failed(message: "no handoff") }
                handoff = prepared
                harness.session.runID = UUID()
                harness.session.runState = .running
                return nil
            }
        }

        func observeHandoff(_ harness: Harness) async {
            startCount += 1
            attemptAtHandoff = harness.session.pendingScheduledSendRecord?.attempt
            intentsAtHandoff = await harness.intents()
            userItemIDsAtHandoff = harness.session.items.filter { $0.kind == .user && $0.text != "Earlier turn" }.map(\.id)
        }

        /// The run service's before-handoff step for the linked intent (`dispatching` committed).
        func beginEvidence(_ harness: Harness) async -> AgentRecoveryDispatchEvidence? {
            guard let lane = harness.session.recoveryLane,
                  let intentID = intentsAtHandoff.first?.intentID,
                  case let .success(receipt) = await lane.issueQueueReceipt(intentID: intentID),
                  case let .success(evidence) = await AgentRecoveryDispatchEvidence.begin(
                      session: harness.session,
                      constituents: [AgentQueuedInputIdentity(receipt: receipt)],
                      runAttemptID: nil
                  )
            else { return nil }
            return evidence
        }
    }

    private struct Timeout: Error {}

    @MainActor
    private struct Harness {
        let viewModel: AgentModeViewModel
        let coordinator: AgentScheduledSendCoordinator
        let clock: FakeSchedulerClock
        let session: AgentTabSession
        let lane: AgentRecoverySessionLane

        var sessionID: UUID {
            lane.sessionID
        }

        func intents() async -> [AgentRecoveryIntent] {
            await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        }

        func singleIntent() async throws -> AgentRecoveryIntent {
            let intents = await intents()
            XCTAssertEqual(intents.count, 1)
            return try XCTUnwrap(intents.first)
        }

        func userItemTexts() -> [String] {
            session.items.filter { $0.kind == .user }.map(\.text)
        }

        func waitForHold(scheduleID: UUID) async throws {
            try await waitUntil("hold awaits the runner's settlement") {
                coordinator.transferHold(scheduleID: scheduleID)?.reason == .awaitingProviderEvidence
                    && !session.isScheduledDispatchInFlight
            }
        }

        /// Lets any triggered evidence re-check (bounded 40 × 50 ms loop) reach its decision.
        func letRechecksRun() async throws {
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        /// Held with schedule, payload, intent, and bubble; never Sent, failed, or transferred.
        func assertHeldUnsent(
            attempt: AgentScheduledSendPersist.Attempt,
            intentState: AgentRecoveryDeliveryState,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let record = try XCTUnwrap(session.pendingScheduledSendRecord, file: file, line: line)
            XCTAssertEqual(coordinator.transferHold(scheduleID: record.id)?.reason, .awaitingProviderEvidence, file: file, line: line)
            XCTAssertEqual(record.state, .dispatching, file: file, line: line)
            XCTAssertEqual(record.attempt?.attemptID, attempt.attemptID, file: file, line: line)
            XCTAssertNil(session.lastScheduledDispatch, file: file, line: line)
            XCTAssertEqual(session.items.count { $0.id == attempt.itemID }, 1, "The bubble is kept", file: file, line: line)
            XCTAssertEqual(userItemTexts().first, "Earlier turn", file: file, line: line)
            let intent = try await singleIntent()
            XCTAssertEqual(intent.deliveryState, intentState, file: file, line: line)
        }

        func waitUntil(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
            for _ in 0 ..< 400 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for \(label); \(stateSummary())")
            throw Timeout()
        }

        /// Scheduler-side state for a timeout message.
        func stateSummary() -> String {
            let record = session.pendingScheduledSendRecord
            let hold = record.flatMap { coordinator.transferHold(scheduleID: $0.id) }
            return "record=\(String(describing: record?.state)) failure=\(String(describing: record?.lastFailureMessage)) reason=\(String(describing: record?.confirmationReason)) "
                + "hold=\(String(describing: hold?.reason)) run=\(session.runState) "
                + "inFlight=\(session.isScheduledDispatchInFlight) ownsLive=\(session.ownsLiveScheduledAttempt) "
                + "admission=\(coordinator.activeAdmission(sessionID: sessionID) != nil)"
        }

        /// Installs a schedule, fires it, and returns once its single dispatch finished.
        func fireSchedule(text: String, probe: StarterProbe) async throws -> (UUID, AgentScheduledSendPersist.Attempt) {
            let notBefore = clock.now.addingTimeInterval(60)
            let scheduleID = try await viewModel.installScheduledSend(
                text: text,
                on: session,
                notBefore: notBefore,
                runAlongsideOtherSessions: false,
                isNewSessionStart: false
            ).get()
            clock.advance(to: notBefore.addingTimeInterval(1))
            try await waitUntil("scheduled attempt dispatched") {
                probe.startCount == 1 && !session.isScheduledDispatchInFlight
            }
            return try (scheduleID, XCTUnwrap(probe.attemptAtHandoff))
        }
    }

    private func makeHarness(windowID: Int, agent: AgentProviderKind) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentScheduledSendNonCodexWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentScheduledSendNonCodexStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = AgentRecoveryStore(rootURL: recoveryRoot)
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let recoveryCoordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        recoveryCoordinator.startIfNeeded()
        guard await recoveryCoordinator.awaitStartup() == .ready else { throw RecoveryLaneFixtureError.startupNotReady }

        let workspace = WorkspaceModel(
            name: "Scheduled Non-Codex Recovery",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(recoveryCoordinator, admissionMode: .mandatory)
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
        session.selectedAgent = agent

        // The first save claims the session's lane.
        session.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(session.recoveryLane, "The first save claims the session's lane")

        let clock = FakeSchedulerClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        viewModel.attachScheduledSendCoordinator(coordinator)
        return Harness(viewModel: viewModel, coordinator: coordinator, clock: clock, session: session, lane: lane)
    }
}

/// Deterministic scheduler clock: sleepers resume only when the test advances time.
@MainActor
private final class FakeSchedulerClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []

    init(now: Date) {
        self.now = now
    }

    var clock: SchedulerClock {
        SchedulerClock(
            now: { [weak self] in
                self?.now ?? .distantPast
            },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await sleep(until: deadline)
            },
            probe: { .none }
        )
    }

    func advance(to date: Date) {
        now = max(now, date)
        let ready = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    private func sleep(until deadline: Date) async throws {
        if deadline <= now { return }
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }
}
