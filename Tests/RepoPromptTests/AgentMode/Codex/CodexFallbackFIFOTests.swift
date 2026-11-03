import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexFallbackFIFOTests: XCTestCase {
    /// Real recovery lane (temporary store) behind every Codex send in this suite: each send is a
    /// `queued` intent admitted through it, so every queue acknowledgement is a store-issued receipt.
    private var laneFixture: RecoveryLaneFixture!

    override func setUp() async throws {
        try await super.setUp()
        laneFixture = try await RecoveryLaneFixture.make("codex-fallback-fifo")
    }

    override func tearDown() async throws {
        laneFixture?.tearDown()
        laneFixture = nil
        try await super.tearDown()
    }

    func testMismatchRetriesOnceWithActualIDThenQueuesExactlyOnce() async throws {
        let firstFailure = requestFailure(
            message: "expected turn mismatch",
            data: .object(["actualTurnId": .string("actual-turn")])
        )
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.expectedTurnMismatch(
                    expectedTurnID: "turn",
                    actualTurnID: "actual-turn",
                    failure: firstFailure
                )),
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = try await send(viewModel, session, text: "retry me")

        guard case let .queuedFallback(receipt, reason) = outcome else {
            return XCTFail("Expected durable fallback queue insertion, got \(outcome)")
        }
        let queueID = receipt.intent.intentID
        XCTAssertEqual(controller.steerTurnIDs, ["turn", "actual-turn"])
        XCTAssertEqual(session.codexFallbackQueue.map(\.id), [queueID])
        XCTAssertEqual(session.codexFallbackQueue.first?.fallbackReason, reason)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
    }

    func testSteerAcceptedIntoDifferentTurnReconcilesWithoutResend() async throws {
        let controller = FallbackFIFOController(
            steerResults: [.success(.init(acceptedTurnID: "actual-turn"))]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = try await send(viewModel, session, text: "steer me")

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertEqual(session.codexPendingSteerLifecycleReconciliation?.priorIdentity.turnID, "turn")
        XCTAssertEqual(
            session.codexPendingSteerLifecycleReconciliation?.acceptedDispatchTurnID,
            "actual-turn"
        )
    }

    func testMismatchRetrySuccessReconcilesOnlyWhenActualLifecycleCompletes() async throws {
        let mismatch = requestFailure(message: "expected turn mismatch")
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.expectedTurnMismatch(
                    expectedTurnID: "turn",
                    actualTurnID: "actual-turn",
                    failure: mismatch
                )),
                .success(CodexTurnSteerReceipt(acceptedTurnID: "actual-turn"))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = try await send(viewModel, session, text: "retry succeeds")

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.steerTurnIDs, ["turn", "actual-turn"])
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(
            session.codexPendingSteerLifecycleReconciliation?.acceptedDispatchTurnID,
            "actual-turn"
        )
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "actual-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexPendingSteerLifecycleReconciliation)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testMismatchRetryAcceptedThenActualStartReconcilesRealControllerForExactCancellation() async throws {
        let recorder = MismatchRetryNativeControllerRecorder()
        let controller = makeNativeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread",
            authoritativeTurnID: "turn",
            routingTurnID: "turn"
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = try await send(viewModel, session, text: "retry against actual")

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn")
        await controller.test_handleNotification(
            method: "turn/started",
            params: lifecycleParams(turnID: "actual-turn")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "actual-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "actual-turn")
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "actual-turn")

        await viewModel.test_codexCoordinator.cancelCodexRun(session)

        XCTAssertEqual(recorder.interruptedTurnIDs, ["actual-turn"])
    }

    func testMismatchRetryAcceptedThenActualCompletionClearsRealControllerForReuse() async throws {
        let recorder = MismatchRetryNativeControllerRecorder()
        let controller = makeNativeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread",
            authoritativeTurnID: "turn",
            routingTurnID: "turn"
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = try await send(viewModel, session, text: "complete actual")
        XCTAssertEqual(outcome, .sent)

        await controller.test_handleNotification(
            method: "turn/completed",
            params: lifecycleParams(turnID: "actual-turn", status: "completed")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "actual-turn", status: .completed),
            session: session
        )

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)

        let nextRunID = UUID()
        session.runID = nextRunID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback.reuse")
        session.codexPendingTurnKind = .user
        await controller.test_handleNotification(
            method: "turn/started",
            params: lifecycleParams(turnID: "next-turn")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "next-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "next-turn")
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "next-turn")
        let receipt = try await controller.interruptUserTurn(expectedTurnID: "next-turn")
        XCTAssertEqual(receipt.interruptedTurnID, "next-turn")
        XCTAssertEqual(recorder.interruptedTurnIDs, ["next-turn"])
    }

    func testNoActiveFallbackAcknowledgesQueueThenIdlePumpStartsHead() async throws {
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "start after idle"
        )
        let queueID = context.queueID

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )

        let ackState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(ackState.queueID, queueID)
        guard case let .queuedFallback(receipt: receipt, reason: .noActiveTurn) = outcome,
              receipt.intent.intentID == queueID
        else {
            return XCTFail("Expected typed no-active queue outcome, got \(outcome)")
        }
        try await waitUntil {
            controller.startCount == 1
                && session.codexFallbackQueue.isEmpty
                && session.codexFallbackDispatchInFlight?.id == queueID
        }
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
    }

    func testDurablyQueuedMCPFallbackInterruptsWaiterOnlyAfterQueueAck() async throws {
        let steerGate = FallbackStartGate()
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ],
            steerGate: steerGate
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        let context = try XCTUnwrap(session.mcpControlContext)
        defer {
            Task {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
        }
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: context.currentEpoch
        )
        let wait = Task.detached {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 5)
        }

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "start after idle",
                allowStartingRun: false
            )
        }
        guard await steerGate.waitUntilWaiting() else {
            dispatch.cancel()
            return XCTFail("Codex steer did not reach the gated provider path")
        }
        let prematureDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0.05
        )
        assertDidNotReleaseAsSteering(prematureDisposition, sessionID: sessionID)
        XCTAssertTrue(
            session.codexFallbackQueue.isEmpty,
            "The fallback should not be visible before the provider failure is converted into a durable queue entry."
        )

        await steerGate.release()
        // Fail with the dispatch's own error: an error propagated through `Task.value` is reported by
        // XCTest as whatever error was last thrown (even swallowed) on the thread, which disguised
        // the ack-deadline `MCPError` as the fake's swallowed `noActiveTurn`.
        let delivery: AgentModeViewModel.MCPInstructionDispatch
        do {
            delivery = try await dispatch.value
        } catch {
            return XCTFail("MCP dispatch failed instead of acknowledging the durable queue: \(error)")
        }
        XCTAssertEqual(delivery, .queuedFollowUp)
        let attemptID = try XCTUnwrap(session.codexSteerAckTracker.test_latestAttemptID)
        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID)
        guard case .durablyQueued = terminalState else {
            return XCTFail("Expected durable queue acknowledgement for MCP fallback, got \(terminalState)")
        }
        let disposition = await wait.value
        assertAcceptedDispatchReleasedWaiter(disposition, sessionID: sessionID)
    }

    func testMCPAckDeadlineDuringGatedDurableEnqueueIsUncertainThenQueuesOnceByReceipt() async throws {
        let disk = try await CodexDiskSeamRecoveryLane.make("codex-mcp-ack-deadline-enqueue")
        defer {
            disk.writes.releaseHeldWrite()
            disk.tearDown()
        }
        let steerGate = FallbackStartGate()
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ],
            steerGate: steerGate
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller, lane: disk.lane)
        session.recoveryAdmissionMode = .mandatory
        defer {
            Task {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
        }
        let tracker = session.codexSteerAckTracker

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "queue after the deadline",
                allowStartingRun: false
            )
        }
        guard await steerGate.waitUntilWaiting() else {
            dispatch.cancel()
            return XCTFail("Codex steer did not reach the gated provider path")
        }
        let attemptID = try XCTUnwrap(tracker.test_latestAttemptID)
        // The provider rejects; its settle-to-queue commit is held inside the store write.
        disk.writes.holdNextWrite()
        await steerGate.release()
        let suspended = await RecoveryTestSupport.eventually { disk.writes.hasArrivedAtHeldWrite }
        XCTAssertTrue(suspended, "The durable enqueue is suspended inside its store write")

        tracker.test_fireDeadline(attemptID: attemptID)
        do {
            let delivery = try await dispatch.value
            return XCTFail("The deadline must not acknowledge an unconfirmed enqueue, got \(delivery)")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(CodexSteerAckTracker.unconfirmedOutcomeMessage),
                "Expected non-retryable uncertainty, got \(error)"
            )
        }
        let expired = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(expired, .deliveryUnknown(message: CodexSteerAckTracker.unconfirmedOutcomeMessage))
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "Nothing is queued before the receipt exists")

        // The operation was not withdrawn: the commit completes and the store issues the receipt.
        disk.writes.releaseHeldWrite()
        try await waitUntil { session.codexFallbackQueue.count == 1 }
        let entry = try XCTUnwrap(session.codexFallbackQueue.first)
        let receipt = try XCTUnwrap(entry.identity.queueReceipt, "The late queue entry is receipt-backed")
        XCTAssertEqual(receipt.intent.intentID, entry.identity.intentID)
        let afterReceipt = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(
            afterReceipt,
            .deliveryUnknown(message: CodexSteerAckTracker.unconfirmedOutcomeMessage),
            "A late receipt never rewrites the returned acknowledgement"
        )
        XCTAssertEqual(controller.steerTurnIDs, ["turn"], "Exactly one steer handoff")
        XCTAssertEqual(controller.startCount, 0)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 && session.codexFallbackQueue.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.startCount, 1, "The queued input is sent at most once")
    }

    func testMCPAckDeadlineReleasesWaiterWithoutJoiningHungAdmission() async throws {
        let disk = try await CodexDiskSeamRecoveryLane.make("codex-mcp-ack-hung-admission")
        defer {
            disk.writes.releaseHeldWrite()
            disk.tearDown()
        }
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller, lane: disk.lane)
        session.recoveryAdmissionMode = .mandatory
        defer {
            Task {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
        }
        let tracker = session.codexSteerAckTracker

        // The MCP input's durable admission commit hangs inside its store write.
        disk.writes.holdNextWrite()
        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "admitted while the caller stopped waiting",
                allowStartingRun: false
            )
        }
        let suspended = await RecoveryTestSupport.eventually { disk.writes.hasArrivedAtHeldWrite }
        XCTAssertTrue(suspended, "The submission driver is inside the admission write")
        XCTAssertEqual(viewModel.test_openCodexMCPSubmissionDriverCount, 1)
        XCTAssertTrue(session.isMCPInstructionDispatchInProgress, "The flag spans the driver's operation")
        let attemptID = try XCTUnwrap(tracker.test_latestAttemptID)

        tracker.test_fireDeadline(attemptID: attemptID)
        do {
            let delivery = try await dispatch.value
            return XCTFail("A hung admission must not be acknowledged, got \(delivery)")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(CodexSteerAckTracker.unconfirmedOutcomeMessage),
                "Expected non-retryable uncertainty, got \(error)"
            )
        }
        XCTAssertEqual(viewModel.test_openCodexMCPSubmissionDriverCount, 1, "The waiter returned without joining the driver")
        XCTAssertTrue(controller.steerTurnIDs.isEmpty, "Nothing reached Codex yet")

        disk.writes.releaseHeldWrite()
        try await waitUntil { viewModel.test_openCodexMCPSubmissionDriverCount == 0 }
        XCTAssertFalse(session.isMCPInstructionDispatchInProgress)
        // The started operation kept its dispatch authorization and delivered exactly once.
        try await waitUntil { controller.steerTurnIDs == ["turn"] }
        let settled = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(settled, .deliveryUnknown(message: CodexSteerAckTracker.unconfirmedOutcomeMessage))
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testMCPCancellationBeforeDriverStartsSubmitsNothing() async throws {
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        defer {
            Task {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
        }
        let userItemsBefore = session.items.count(where: { $0.kind == .user })

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "cancelled before start",
                allowStartingRun: false
            )
        }
        dispatch.cancel()
        do {
            let delivery = try await dispatch.value
            return XCTFail("A dispatch cancelled before its driver started must not deliver, got \(delivery)")
        } catch is CancellationError {
            // Expected: the operation was prevented from starting.
        } catch {
            return XCTFail("Expected CancellationError, got \(error)")
        }
        let attemptID = try XCTUnwrap(session.codexSteerAckTracker.test_latestAttemptID)
        let state = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(state, .cancelled)
        try await waitUntil { viewModel.test_openCodexMCPSubmissionDriverCount == 0 }
        XCTAssertTrue(controller.steerTurnIDs.isEmpty)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(session.items.count(where: { $0.kind == .user }), userItemsBefore, "No bubble was submitted")
        XCTAssertFalse(session.isMCPInstructionDispatchInProgress)
        let record = await laneFixture.store.read(sessionID: laneFixture.sessionID).record
        XCTAssertFalse(
            record?.intents.contains { $0.payload.text == "cancelled before start" } ?? false,
            "No durable intent was admitted"
        )
    }

    func testNoActiveFallbackRetriesTransientSnapshotFailure() async throws {
        let idleSnapshot = CodexNativeSessionController.ThreadSnapshot(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
        let controller = FallbackFIFOController(
            snapshotResults: [
                .failure(FallbackFIFOTestError.transientSnapshotFailure),
                .success(idleSnapshot)
            ],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        _ = try await send(viewModel, session, text: "retry snapshot")

        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testMatchingCompletionAndPublicationDrainExactlyOneThenTailWaitsForSuccessor() async throws {
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable), .failure(nonSteerable)]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        _ = try await send(viewModel, session, text: "first")
        _ = try await send(viewModel, session, text: "second")
        XCTAssertEqual(session.codexFallbackQueue.count, 2)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertNotNil(session.codexFallbackDispatchInFlight)
        // `startCount` proves only that turn/start was entered. Publish the successor once the start
        // has returned (`awaitingLifecycleStart`), which is the ordering this test asserts; the
        // start-still-in-flight ordering (`lifecycleStarted`) is covered by
        // `testManualFallbackQueuedDuringDispatchingRebindsToObservedSuccessor`.
        try await waitUntil {
            session.codexFallbackDispatchInFlight?.state == .awaitingLifecycleStart
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        XCTAssertEqual(controller.startCount, 1)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-1"),
            session: session
        )
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-1")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-1", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testPublishedSuccessorClaimsHeadBeforeProviderStartReturns() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable), .failure(nonSteerable)],
            startGate: startGate
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        _ = try await send(viewModel, session, text: "claim before await")
        _ = try await send(viewModel, session, text: "tail")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertEqual(session.codexFallbackDispatchInFlight?.state, .dispatching)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-before-receipt"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-before-receipt")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-before-receipt", status: .completed),
            session: session
        )
        XCTAssertEqual(controller.startCount, 1)

        await startGate.release()
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testManualFallbackQueuedDuringDispatchingRebindsToObservedSuccessor() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)],
            startGate: startGate
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        _ = try await send(viewModel, session, text: "first")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            session.codexFallbackDispatchInFlight?.state == .dispatching
        }

        _ = try await send(viewModel, session, text: "manual during dispatch")
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "turn")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-dispatching"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-dispatching")
        XCTAssertEqual(session.codexFallbackDispatchInFlight?.state, .lifecycleStarted)

        await startGate.release()
        // The lifecycle start arrived first; the start's return then releases the in-flight claim.
        try await waitUntil { session.codexFallbackDispatchInFlight == nil }
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-dispatching")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-dispatching", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
    }

    func testMCPFallbackQueuedWhileAwaitingLifecycleStartRebindsAndDrains() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)],
            startGate: startGate
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        _ = try await send(viewModel, session, text: "first")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        await startGate.release()
        try await waitUntil {
            session.codexFallbackDispatchInFlight?.state == .awaitingLifecycleStart
        }

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "mcp while awaiting lifecycle"
        )
        let queueID = context.queueID
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(terminalState.queueID, queueID)
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "turn")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-awaiting"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-awaiting")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-awaiting", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
    }

    func testRejectedTerminalPublicationRetriesAndThenStartsEligibleSuccessor() async throws {
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return publicationAttempts == 1
                ? .rejected(reason: "transient")
                : .accepted(successorEpoch: nil)
        }

        _ = try await send(viewModel, session, text: "publish then retry")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        try await waitUntil {
            publicationAttempts == 2 && controller.startCount == 1
        }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testTransientPublicationRetryStopsAndAbandonsQueueWhenMCPControlDeactivates() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return .rejected(reason: "transient")
        }

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "deactivate while retrying"
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            publicationAttempts >= 2 && session.codexFallbackSuccessorRetryTask != nil
        }

        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
        let attemptsAfterDeactivation = publicationAttempts
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(publicationAttempts, attemptsAfterDeactivation)
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertEqual(controller.startCount, 0)
    }

    func testTransientPublicationRetryStopsAndAbandonsQueueWhenMCPControlIsReplaced() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        let originalActivationID = try XCTUnwrap(session.mcpControlContext?.activationID)
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return .rejected(reason: "transient")
        }

        _ = try await send(viewModel, session, text: "replace while retrying")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            publicationAttempts >= 2 && session.codexFallbackSuccessorRetryTask != nil
        }

        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        let attemptsAfterReplacement = publicationAttempts
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(session.mcpControlContext?.activationID, originalActivationID)
        XCTAssertEqual(publicationAttempts, attemptsAfterReplacement)
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 0)
        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testMissingTerminalPublicationEnvelopePermanentlyAbandonsEligibleQueue() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(
            controller: controller,
            prepareEpoch: false
        )

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "missing envelope"
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(
            session.lastTerminalPublicationResult,
            .rejected(reason: "missing_terminal_publication_envelope")
        )
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 0)
        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testNilCompletionDoesNotDrainAndFailedCompletionAbandonsBlockedHead() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        guard let (nilViewModel, nilSession) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        _ = try await send(nilViewModel, nilSession, text: "nil completion")

        await nilViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: nilSession
        )
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(nilSession.codexFallbackQueue.count, 1)
        XCTAssertEqual(nilSession.runState, .running)
        XCTAssertEqual(nilSession.codexAuthoritativeActiveTurn?.turnID, "turn")

        await nilViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: nilSession
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(nilSession.codexFallbackQueue.isEmpty)

        let failedController = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                )),
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        guard let (failedViewModel, failedSession) = makeRunningSession(controller: failedController) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        _ = try await send(failedViewModel, failedSession, text: "failed completion")
        _ = try await send(failedViewModel, failedSession, text: "failed completion tail")
        XCTAssertEqual(failedSession.codexFallbackQueue.count, 2)

        await failedViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .failed),
            session: failedSession
        )
        XCTAssertEqual(failedController.startCount, 0)
        XCTAssertTrue(failedSession.codexFallbackQueue.isEmpty)
    }

    func testLateAcceptedMCPStartRemovesQueuedFallbackBeforeReplay() async throws {
        let startGate = FallbackStartGate()
        let controller = FallbackFIFOController(
            steerResults: [],
            startGate: startGate
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "slow start"
        )

        let sendTask = Task { @MainActor in
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "slow start",
                attachments: [],
                fallbackContext: context
            )
        }
        let didStart = await startGate.waitUntilWaiting()
        XCTAssertTrue(didStart, "Expected turn/start to be in flight")

        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(terminalState, .timedOut)

        let fallbackOutcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "slow start",
            attachments: [],
            fallbackContext: context
        )
        // Receipt contract: the same durable intent is already `dispatching` through the in-flight
        // start, so the store issues no queue receipt; the retry is uncertain, never queued again.
        guard case .deliveryUnknown = fallbackOutcome else {
            return XCTFail("Expected the in-flight intent's retry to stay uncertain, got \(fallbackOutcome)")
        }
        XCTAssertNil(fallbackOutcome.durableQueueReceipt)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "No second projection of an in-flight intent")

        await startGate.release()
        let sendOutcome = await sendTask.value
        XCTAssertEqual(sendOutcome, .sent)
        try await waitUntil { session.codexFallbackQueue.isEmpty }
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 1)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.startCount, 1, "Removed fallback must not replay after the late provider success")
    }

    func testLateAcceptedMCPAttemptDropsAlreadyClaimedFallbackBeforeProviderReplay() async throws {
        let controller = FallbackFIFOController(steerResults: [])
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let claimed = try await laneFixture.queuedIdentity("claimed fallback")
        let queueID = try XCTUnwrap(claimed.intentID)
        _ = try await controller.startUserTurn(
            text: "original delivery",
            images: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
        XCTAssertEqual(controller.startCount, 1)
        session.codexFallbackQueue = [
            fallbackQueueEntry(
                identity: claimed,
                origin: .mcp(attemptID: attemptID),
                text: "claimed fallback",
                session: session,
                controller: controller
            )
        ]

        XCTAssertTrue(viewModel.test_codexCoordinator.test_claimCodexFallbackHead(
            session: session,
            expectedQueueID: queueID,
            beginsSuccessorAttempt: false
        ))
        XCTAssertEqual(session.codexFallbackDispatchInFlight?.id, queueID)

        viewModel.test_codexCoordinator.test_recordDeliveredCodexFallbackAttempt(attemptID, session: session)
        await viewModel.test_codexCoordinator.test_dispatchClaimedCodexFallback(session: session)

        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertEqual(controller.startCount, 1, "Claimed fallback must not re-dispatch after the original attempt is delivered")
    }

    func testRemovingQueuedDeliveredSiblingDoesNotCancelInFlightFallbackOrPendingMask() async throws {
        let controller = FallbackFIFOController(steerResults: [])
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let claimedAttemptID = session.codexSteerAckTracker.beginAttempt()
        let queuedAttemptID = session.codexSteerAckTracker.beginAttempt()
        let claimed = try await laneFixture.queuedIdentity("claimed")
        let queued = try await laneFixture.queuedIdentity("queued sibling")
        let claimedQueueID = try XCTUnwrap(claimed.intentID)
        session.codexFallbackQueue = [
            fallbackQueueEntry(
                identity: claimed,
                origin: .mcp(attemptID: claimedAttemptID),
                text: "claimed",
                session: session,
                controller: controller
            ),
            fallbackQueueEntry(
                identity: queued,
                origin: .mcp(attemptID: queuedAttemptID),
                text: "queued sibling",
                session: session,
                controller: controller
            )
        ]

        XCTAssertTrue(viewModel.test_codexCoordinator.test_claimCodexFallbackHead(
            session: session,
            expectedQueueID: claimedQueueID,
            beginsSuccessorAttempt: false
        ))
        session.mcpFollowUpRunPending = true

        viewModel.test_codexCoordinator.test_recordDeliveredCodexFallbackAttempt(queuedAttemptID, session: session)

        XCTAssertEqual(session.codexFallbackDispatchInFlight?.id, claimedQueueID)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertTrue(session.mcpFollowUpRunPending)

        await viewModel.test_codexCoordinator.test_dispatchClaimedCodexFallback(session: session)
        XCTAssertEqual(controller.startCount, 1)
    }

    func testDefinitiveMCPProviderFailureKeepsFallbackReplayExactlyOnce() async throws {
        let failure = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "review",
            failure: requestFailure(message: "cannot steer a review turn")
        )
        let controller = FallbackFIFOController(steerResults: [.failure(failure)])
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "replay after failure"
        )
        let queueID = context.queueID

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "replay after failure",
            attachments: [],
            fallbackContext: context
        )
        guard case let .queuedFallback(queuedReceipt, .activeTurnNotSteerable) = outcome else {
            return XCTFail("Expected durable fallback after provider rejection, got \(outcome)")
        }
        XCTAssertEqual(queuedReceipt.intent.intentID, queueID)
        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(terminalState.queueID, queueID)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.startCount, 1, "Definitive provider failure should replay exactly once")
    }

    func testManualFallbackKeepsSingleOptimisticBubbleAndDoesNotRestoreDraft() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        viewModel.storeDraftText(for: session.tabID, "queued manual")
        let userItem = AgentChatItem.user(
            "queued manual",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(userItem)
        let context = try await admittedContext(
            origin: .manual,
            text: "queued manual",
            userItemID: userItem.id
        )

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "queued manual",
            attachments: [],
            fallbackContext: context
        )

        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["queued manual"])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "queued manual")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["queued manual"])
    }

    func testClearChatDiscardsFallbackInputWithoutReversingDeliveryAcknowledgement() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        guard let (viewModel, session) = makeRunningSession(controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = try await admittedContext(
            origin: .mcp(attemptID: attemptID),
            text: "discarded queued input"
        )
        let queueID = context.queueID

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "discarded queued input",
            attachments: [],
            fallbackContext: context
        )
        XCTAssertEqual(session.codexFallbackQueue.count, 1)

        viewModel.clearChat(tabID: session.tabID)

        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(terminalState.queueID, queueID)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(viewModel.draftRestorationEvent)
    }

    // MARK: - Durable recovery admission (Phase 1b Codex adapters)

    func testDurableSteerRejectionQueuesSameIntentWithStoreIssuedReceipt() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-rejection")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [
            .failure(CodexTurnSteerError.activeTurnNotSteerable(
                turnKind: "review",
                failure: requestFailure(message: "cannot steer a review turn")
            ))
        ])
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        let identity = try await fixture.queuedIdentity("durable steer")
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "durable steer")

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "durable steer",
            attachments: [],
            fallbackContext: context
        )

        guard case let .queuedFallback(receipt, .activeTurnNotSteerable) = outcome else {
            return XCTFail("Expected a durable fallback after verified rejection, got \(outcome)")
        }
        let storeReceipt = try XCTUnwrap(outcome.durableQueueReceipt, "A durable queue ack carries the store receipt")
        XCTAssertEqual(storeReceipt, receipt, "The ack is the store receipt itself")
        XCTAssertEqual(outcome.fallbackQueueID, identity.intentID)
        XCTAssertEqual(storeReceipt.intent.intentID, identity.intentID, "The same intent is queued again")
        XCTAssertEqual(storeReceipt.intent.userItemID, identity.userItemID)
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        try XCTAssertEqual(session.codexFallbackQueue.map(\.id), [XCTUnwrap(identity.intentID)])
        XCTAssertEqual(session.codexFallbackQueue.first?.identity.queueReceipt, storeReceipt)
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        guard case let .durablyQueued(ackReceipt) = ack else {
            return XCTFail("Expected durable queue ack, got \(ack)")
        }
        XCTAssertEqual(ackReceipt, storeReceipt)

        let storedIntent = await fixture.intent(identity)
        let intent = try XCTUnwrap(storedIntent)
        XCTAssertEqual(intent.deliveryState, .queued)
        let attempts = await recordedAttempts(fixture, identity)
        XCTAssertEqual(attempts.count, 1)
        guard case .failed(.verifiedRejection, _)? = attempts.first?.outcome?.outcome else {
            return XCTFail("Expected the handoff attempt closed as a verified rejection, got \(String(describing: attempts.first?.outcome))")
        }
    }

    func testDurableCommitFailureMakesNoHandoffAndNoQueueAck() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-commit-failure")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        // A withdrawn intent cannot begin a dispatch or be reissued a queue receipt.
        let steered = try await fixture.queuedIdentity("withdrawn steer")
        _ = try await fixture.lane.withdraw(intentID: XCTUnwrap(steered.intentID)).get()
        let steerAttemptID = session.codexSteerAckTracker.beginAttempt()

        let steerOutcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "withdrawn steer",
            attachments: [],
            fallbackContext: durableContext(identity: steered, origin: .mcp(attemptID: steerAttemptID), text: "withdrawn steer")
        )

        // Receipt contract: a refused dispatch commit is never a retryable `.failed` (the durable
        // intent is the only copy); it ends before handoff as `.stale`.
        guard case .stale = steerOutcome else {
            return XCTFail("A failed dispatch commit must end before handoff without a retryable failure, got \(steerOutcome)")
        }
        XCTAssertNil(steerOutcome.durableQueueReceipt)
        XCTAssertEqual(controller.steerTurnIDs, [], "No provider handoff after a failed commit")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        let steerAck = await session.codexSteerAckTracker.awaitTerminalState(attemptID: steerAttemptID, timeoutSeconds: 0.1)
        XCTAssertFalse(steerAck.confirmsInstructionDeliveryOrDurableQueue, "No successful acknowledgement: \(steerAck)")

        // Pre-handoff fallback plan: the queue receipt cannot be reissued, so nothing is projected.
        let (fallbackViewModel, fallbackSession) = try makeDurableRunningSession(
            controller: controller,
            fixture: fixture
        )
        fallbackSession.codexAuthoritativeActiveTurn = nil
        let queued = try await fixture.queuedIdentity("withdrawn queue")
        _ = try await fixture.lane.withdraw(intentID: XCTUnwrap(queued.intentID)).get()
        let queueAttemptID = fallbackSession.codexSteerAckTracker.beginAttempt()

        let queueOutcome = await fallbackViewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: fallbackSession,
            text: "withdrawn queue",
            attachments: [],
            fallbackContext: durableContext(identity: queued, origin: .mcp(attemptID: queueAttemptID), text: "withdrawn queue")
        )

        guard case .stale = queueOutcome else {
            return XCTFail("Expected no queue projection without a receipt, got \(queueOutcome)")
        }
        XCTAssertTrue(fallbackSession.codexFallbackQueue.isEmpty)
        XCTAssertEqual(controller.steerTurnIDs, [])
        let queueAck = await fallbackSession.codexSteerAckTracker.awaitTerminalState(attemptID: queueAttemptID, timeoutSeconds: 0.1)
        XCTAssertFalse(queueAck.confirmsInstructionDeliveryOrDurableQueue, "No successful acknowledgement: \(queueAck)")
    }

    func testConcurrentSameIntentFallbacksJoinOneReservedEnqueue() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-join")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        session.codexAuthoritativeActiveTurn = nil
        let identity = try await fixture.queuedIdentity("joined")
        let context = durableContext(identity: identity, origin: .manual, text: "joined")
        let coordinator = viewModel.test_codexCoordinator

        let first = Task { @MainActor in
            await coordinator.sendCodexNativeMessage(session: session, text: "joined", attachments: [], fallbackContext: context)
        }
        let second = Task { @MainActor in
            await coordinator.sendCodexNativeMessage(session: session, text: "joined", attachments: [], fallbackContext: context)
        }
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        XCTAssertEqual(firstOutcome, secondOutcome, "Same-ID requests share one acknowledgement")
        XCTAssertEqual(firstOutcome.durableQueueReceipt?.intent.intentID, identity.intentID)
        try XCTAssertEqual(session.codexFallbackQueue.map(\.id), [XCTUnwrap(identity.intentID)], "Exactly one projection")
        XCTAssertEqual(controller.steerTurnIDs, [])
        XCTAssertEqual(controller.startCount, 0)
    }

    func testDurableFallbackTargetLostAroundReceiptPersistsStaleHoldWithoutProjection() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-stale")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        session.codexAuthoritativeActiveTurn = nil
        let identity = try await fixture.queuedIdentity("held")
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        // The lane retires: its receipt read still succeeds, but the target is no longer current.
        await fixture.coordinator.releaseLane(fixture.lane).value

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "held",
            attachments: [],
            fallbackContext: durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "held")
        )

        guard case .stale = outcome else {
            return XCTFail("A lost target must not be acknowledged as queued, got \(outcome)")
        }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "No queue projection after target loss")
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        XCTAssertFalse(ack.confirmsInstructionDeliveryOrDurableQueue)
        let storedIntent = await fixture.intent(identity)
        let intent = try XCTUnwrap(storedIntent)
        XCTAssertEqual(intent.deliveryState, .queued, "The intent is preserved, never withdrawn")
        XCTAssertNotNil(intent.staleTargetMarkedAt, "The stale-target hold is persisted")
    }

    func testAcceptedRetryThenReconciliationFailureNeverQueuesFallback() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-accepted-retry")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [
            .failure(CodexTurnSteerError.expectedTurnMismatch(
                expectedTurnID: "turn",
                actualTurnID: "actual-turn",
                failure: requestFailure(message: "expected turn mismatch")
            )),
            .success(CodexTurnSteerReceipt(acceptedTurnID: "actual-turn"))
        ])
        controller.prepareLifecycleResult = false
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        let identity = try await fixture.queuedIdentity("accepted retry")

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "accepted retry",
            attachments: [],
            fallbackContext: durableContext(identity: identity, origin: .manual, text: "accepted retry")
        )

        XCTAssertEqual(outcome, .sent, "Accepted input is never turned into a fallback")
        XCTAssertEqual(controller.steerTurnIDs, ["turn", "actual-turn"])
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        let intent = try await waitForIntent(fixture, identity) { $0.deliveryState == .providerAccepted }
        XCTAssertEqual(intent.deliveryState, .providerAccepted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.startCount, 0, "No replay of accepted input")
    }

    func testUncertainDurableStartRecordsDeliveryUnknownWithoutRetryOrDraft() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-uncertain")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        controller.startErrors = [
            CodexAppServerClient.ClientError.requestFailed(
                .init(method: "turn/start", code: -32000, message: "request timed out", data: nil)
            )
        ]
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        let identity = try await fixture.queuedIdentity("uncertain")
        let attemptID = session.codexSteerAckTracker.beginAttempt()

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "uncertain",
            attachments: [],
            fallbackContext: durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "uncertain")
        )

        guard case .deliveryUnknown = outcome else {
            return XCTFail("An unproven handoff must surface uncertainty, got \(outcome)")
        }
        XCTAssertFalse(outcome.didSend)
        XCTAssertEqual(controller.startCount, 1, "Exactly one handoff; no automatic retry or auth replay")
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "Uncertain input never becomes a fallback")
        XCTAssertNil(viewModel.draftRestorationEvent, "Uncertain input is never restored as a retryable draft")
        XCTAssertTrue(session.pendingImageAttachments.isEmpty)
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        guard case .deliveryUnknown = ack else {
            return XCTFail("Expected an uncertain MCP acknowledgement, got \(ack)")
        }
        let intent = try await waitForIntent(fixture, identity) { $0.deliveryState == .deliveryUnknown }
        XCTAssertEqual(intent.deliveryState, .deliveryUnknown)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.startCount, 1)
    }

    func testPreflightDurableStartFailureSettlesSameIntentAndHoldsIt() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-preflight")
        defer { fixture.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        controller.startErrors = [CodexTurnStartPreflightError.noActiveThread]
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        let identity = try await fixture.queuedIdentity("preflight")

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "preflight",
            attachments: [],
            fallbackContext: durableContext(identity: identity, origin: .manual, text: "preflight")
        )

        guard case .failed = outcome else {
            return XCTFail("A proven pre-handoff failure is a plain failure, got \(outcome)")
        }
        XCTAssertNil(viewModel.draftRestorationEvent)
        let intent = try await waitForIntent(fixture, identity) { $0.staleTargetMarkedAt != nil }
        XCTAssertEqual(intent.deliveryState, .queued, "Proven no-handoff returns the same intent to queued")
        let attempts = await recordedAttempts(fixture, identity)
        guard case .failed(.preHandoff, _)? = attempts.last?.outcome?.outcome else {
            return XCTFail("Expected a pre-handoff attempt outcome, got \(String(describing: attempts.last?.outcome))")
        }
    }

    func testDurableFIFODrainKeepsIdentityAndTeardownPreservesQueuedInput() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-fifo")
        defer { fixture.tearDown() }
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "review",
            failure: requestFailure(message: "cannot steer a review turn")
        )
        let controller = FallbackFIFOController(steerResults: [.failure(nonSteerable), .failure(nonSteerable)])
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        let firstItem = AgentChatItem.user("first", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(firstItem)
        let first = try await fixture.queuedIdentity("first", userItemID: firstItem.id)
        let secondItem = AgentChatItem.user("second", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(secondItem)
        let second = try await fixture.queuedIdentity("second", userItemID: secondItem.id)
        viewModel.storeDraftText(for: session.tabID, "")

        for (identity, text) in [(first, "first"), (second, "second")] {
            let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: text,
                attachments: [],
                fallbackContext: durableContext(identity: identity, origin: .manual, text: text)
            )
            XCTAssertEqual(outcome.durableQueueReceipt?.intent.intentID, identity.intentID)
        }
        XCTAssertEqual(session.codexFallbackQueue.map(\.id), [first.intentID, second.intentID].compactMap(\.self))
        XCTAssertEqual(session.codexFallbackQueue.map(\.identity.userItemID), [firstItem.id, secondItem.id])
        XCTAssertTrue(session.codexFallbackQueue.allSatisfy(\.identity.isDurable))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        let drained = try await waitForIntent(fixture, first) { $0.deliveryState == .providerAccepted }
        XCTAssertEqual(drained.userItemID, firstItem.id, "The drained head keeps its deterministic item ID")
        XCTAssertEqual(session.codexFallbackQueue.map(\.id), [second.intentID].compactMap(\.self))

        viewModel.test_codexCoordinator.handleMCPControlReset(for: session, reason: "test teardown")

        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertTrue(
            session.items.contains(where: { $0.id == secondItem.id }),
            "Teardown keeps the durable input's bubble"
        )
        XCTAssertNil(viewModel.draftRestorationEvent, "Durable input is never restored as a draft on teardown")
        let held = try await waitForIntent(fixture, second) { $0.staleTargetMarkedAt != nil }
        XCTAssertEqual(held.deliveryState, .queued, "Teardown preserves, never withdraws")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.startCount, 1)
    }

    func testDurableDispatchCommitDiskWriteFailureMakesNoHandoffAndNoQueueAck() async throws {
        let disk = try await CodexDiskSeamRecoveryLane.make("codex-disk-begin-failure")
        defer { disk.tearDown() }
        let controller = FallbackFIFOController(steerResults: [])
        let (viewModel, session) = try makeDiskSeamRunningSession(controller: controller, disk: disk)
        let identity = try await disk.queuedIdentity("unsaved dispatch")
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        // The store's real file-write seam fails the `dispatching` commit itself.
        disk.writes.shouldFailWrites = true

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "unsaved dispatch",
            attachments: [],
            fallbackContext: durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "unsaved dispatch")
        )
        disk.writes.shouldFailWrites = false

        guard case .stale = outcome else {
            return XCTFail("A dispatch record that cannot be written ends before handoff, got \(outcome)")
        }
        XCTAssertNil(outcome.durableQueueReceipt)
        XCTAssertEqual(controller.steerTurnIDs, [], "Zero provider handoffs")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "Zero queue projections")
        XCTAssertNil(viewModel.draftRestorationEvent)
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        XCTAssertFalse(ack.confirmsInstructionDeliveryOrDurableQueue, "No queue or delivery acknowledgement: \(ack)")
        let stored = await disk.intent(identity)
        XCTAssertEqual(stored?.deliveryState, .queued, "The saved intent is unchanged on disk")
        let attempts = await disk.attempts(identity)
        XCTAssertTrue(attempts.isEmpty, "No delivery attempt was persisted")
    }

    func testRejectionEvidenceDiskWriteFailureLeavesIntentUncertainWithoutQueueAck() async throws {
        let disk = try await CodexDiskSeamRecoveryLane.make("codex-disk-settle-failure")
        defer { disk.tearDown() }
        let steerGate = FallbackStartGate()
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ],
            steerGate: steerGate
        )
        let (viewModel, session) = try makeDiskSeamRunningSession(controller: controller, disk: disk)
        let identity = try await disk.queuedIdentity("unsaved rejection")
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "unsaved rejection")
        let coordinator = viewModel.test_codexCoordinator

        let send = Task { @MainActor in
            await coordinator.sendCodexNativeMessage(
                session: session,
                text: "unsaved rejection",
                attachments: [],
                fallbackContext: context
            )
        }
        let steering = await steerGate.waitUntilWaiting()
        XCTAssertTrue(steering, "The dispatch record committed and the steer reached the provider")
        // The provider's rejection cannot be recorded: its settle-to-queue write fails on disk.
        disk.writes.shouldFailWrites = true
        await steerGate.release()
        let outcome = await send.value
        disk.writes.shouldFailWrites = false

        guard case .deliveryUnknown = outcome else {
            return XCTFail("An unrecorded rejection stays uncertain, got \(outcome)")
        }
        XCTAssertFalse(outcome.didSend)
        XCTAssertNil(outcome.durableQueueReceipt, "No queue acknowledgement without a recorded settlement")
        XCTAssertEqual(controller.steerTurnIDs, ["turn"], "Exactly one handoff")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "Never projected")
        XCTAssertNil(viewModel.draftRestorationEvent)
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        guard case .deliveryUnknown = ack else {
            return XCTFail("Expected an uncertain MCP acknowledgement, got \(ack)")
        }
        let stored = await disk.intent(identity)
        XCTAssertEqual(stored?.deliveryState, .dispatching, "The unsettled attempt stays uncertain on disk")
    }

    func testLaneRetiresWhileRejectionCommitIsSuspendedPersistsStaleHoldWithoutProjection() async throws {
        let disk = try await CodexDiskSeamRecoveryLane.make("codex-disk-stale-after-commit")
        defer {
            disk.writes.releaseHeldWrite()
            disk.tearDown()
        }
        let steerGate = FallbackStartGate()
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ],
            steerGate: steerGate
        )
        let (viewModel, session) = try makeDiskSeamRunningSession(controller: controller, disk: disk)
        let identity = try await disk.queuedIdentity("suspended settle")
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = durableContext(identity: identity, origin: .mcp(attemptID: attemptID), text: "suspended settle")
        let coordinator = viewModel.test_codexCoordinator

        let send = Task { @MainActor in
            await coordinator.sendCodexNativeMessage(
                session: session,
                text: "suspended settle",
                attachments: [],
                fallbackContext: context
            )
        }
        let steering = await steerGate.waitUntilWaiting()
        XCTAssertTrue(steering, "The dispatch record committed and the steer reached the provider")
        disk.writes.holdNextWrite()
        await steerGate.release()
        let suspended = await RecoveryTestSupport.eventually { disk.writes.hasArrivedAtHeldWrite }
        XCTAssertTrue(suspended, "The rejection's settle-to-queue commit is suspended inside the store write")
        // The recovery lane retires while that commit is in flight; the commit then completes.
        disk.coordinator.releaseLane(disk.lane)
        XCTAssertTrue(disk.lane.isRetired)
        disk.writes.releaseHeldWrite()
        let outcome = await send.value

        guard case .stale = outcome else {
            return XCTFail("A target lost after the commit must not be acknowledged as queued, got \(outcome)")
        }
        XCTAssertNil(outcome.durableQueueReceipt)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "No queue projection after the target was lost")
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        XCTAssertEqual(controller.startCount, 0)
        let ack = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID, timeoutSeconds: 0.1)
        XCTAssertFalse(ack.confirmsInstructionDeliveryOrDurableQueue, "No queue acknowledgement: \(ack)")
        let storedIntent = await disk.intent(identity)
        let intent = try XCTUnwrap(storedIntent)
        XCTAssertEqual(intent.deliveryState, .queued, "The committed settlement returned the same intent to queued")
        XCTAssertNotNil(intent.staleTargetMarkedAt, "The stale-target hold is persisted after the commit")
        let attempts = await disk.attempts(identity)
        guard case .failed(.verifiedRejection, _)? = attempts.last?.outcome?.outcome else {
            return XCTFail("Expected the attempt closed as a verified rejection, got \(String(describing: attempts.last?.outcome))")
        }
    }

    func testConcurrentDirectSameIntentWhileInFlightIsUncertainNeverRetryableOrQueued() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-durable-direct-in-flight")
        defer { fixture.tearDown() }
        let startGate = FallbackStartGate()
        let controller = FallbackFIFOController(steerResults: [], startGate: startGate)
        let (viewModel, session) = try makeDurableRunningSession(controller: controller, fixture: fixture)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        let identity = try await fixture.queuedIdentity("in flight")
        let context = durableContext(identity: identity, origin: .manual, text: "in flight")
        let coordinator = viewModel.test_codexCoordinator

        let first = Task { @MainActor in
            await coordinator.sendCodexNativeMessage(
                session: session,
                text: "in flight",
                attachments: [],
                fallbackContext: context
            )
        }
        let started = await startGate.waitUntilWaiting()
        XCTAssertTrue(started, "The first delivery committed `dispatching` and reached turn/start")
        // A steerable turn is current now, so the duplicate plans a direct steer of the same intent.
        let runID = try XCTUnwrap(session.runID)
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        let duplicate = await coordinator.sendCodexNativeMessage(
            session: session,
            text: "in flight",
            attachments: [],
            fallbackContext: context,
            terminalizeRejectedSend: false
        )

        guard case .deliveryUnknown = duplicate else {
            return XCTFail("A same-intent send already in flight is never a retryable failure, got \(duplicate)")
        }
        XCTAssertFalse(duplicate.didSend)
        XCTAssertNil(duplicate.durableQueueReceipt)
        XCTAssertEqual(controller.steerTurnIDs, [], "The duplicate never hands off")
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, "The duplicate is never queued")
        XCTAssertNil(viewModel.draftRestorationEvent, "Nothing is restored as a retryable draft")
        XCTAssertTrue(session.runState.isActive, "The in-flight delivery's run is untouched")

        session.codexAuthoritativeActiveTurn = nil
        await startGate.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .sent)
        XCTAssertEqual(controller.startCount, 1, "Exactly one handoff of the intent")
        let intent = try await waitForIntent(fixture, identity) { $0.deliveryState == .providerAccepted }
        XCTAssertEqual(intent.deliveryState, .providerAccepted)
    }

    private func makeDiskSeamRunningSession(
        controller: any CodexSessionControlling,
        disk: CodexDiskSeamRecoveryLane
    ) throws -> (AgentModeViewModel, AgentTabSession) {
        let made = try XCTUnwrap(makeRunningSession(controller: controller, lane: disk.lane))
        made.1.recoveryAdmissionMode = .mandatory
        return made
    }

    private func makeDurableRunningSession(
        controller: any CodexSessionControlling,
        fixture: RecoveryLaneFixture
    ) throws -> (AgentModeViewModel, AgentTabSession) {
        let made = try XCTUnwrap(makeRunningSession(controller: controller, lane: fixture.lane))
        made.1.recoveryAdmissionMode = .mandatory
        return made
    }

    private func durableContext(
        identity: AgentQueuedInputIdentity,
        origin: AgentTabSession.CodexFallbackOrigin,
        text: String
    ) -> AgentTabSession.CodexFallbackSubmissionContext {
        .init(
            queueID: identity.intentID ?? UUID(),
            providerText: text,
            images: [],
            taggedFileAttachments: [],
            draftText: text,
            identity: identity,
            origin: origin,
            dispatchTicket: nil
        )
    }

    private func recordedAttempts(
        _ fixture: RecoveryLaneFixture,
        _ identity: AgentQueuedInputIdentity
    ) async -> [AgentRecoveryAttempt] {
        guard let intentID = identity.intentID else { return [] }
        return await fixture.store.read(sessionID: fixture.sessionID).record?.attempts(forIntent: intentID) ?? []
    }

    private func waitForIntent(
        _ fixture: RecoveryLaneFixture,
        _ identity: AgentQueuedInputIdentity,
        timeout: TimeInterval = 2,
        _ predicate: (AgentRecoveryIntent) -> Bool
    ) async throws -> AgentRecoveryIntent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let intent = await fixture.intent(identity), predicate(intent) {
                return intent
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let latest = await fixture.intent(identity)
        return try XCTUnwrap(latest, "Timed out waiting for the durable intent state")
    }

    /// A running Codex turn whose run attempt began under the persistent binding of `lane`'s
    /// session (as production binds before any run starts), so its ownership is that lane's run
    /// evidence (R07).
    private func makeRunningSession(
        controller: any CodexSessionControlling,
        lane: AgentRecoverySessionLane? = nil
    ) -> (AgentModeViewModel, AgentTabSession)? {
        let lane = lane ?? laneFixture.lane
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        guard let session = viewModel.session(for: UUID(), createIfNeeded: true) else {
            XCTFail("Expected the Codex test session to materialize")
            return nil
        }
        let runID = UUID()
        // Durable identities from the suite lane; admission stays `.inactive` here, while
        // `makeDurableRunningSession` covers mandatory admission explicitly.
        _ = viewModel.test_installPersistentSessionBinding(sessionID: lane.sessionID, on: session)
        session.recoveryLane = lane
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback")
        session.codexController = controller
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        return (viewModel, session)
    }

    /// MCP-controlled running Codex session. Acknowledgement deadlines are manual (never fired unless
    /// a test calls `test_fireDeadline`), so FIFO ordering assertions cannot race host load; the
    /// production 2.5 s deadline is covered by the tracker suite.
    private func makeMCPRunningSession(
        controller: any CodexSessionControlling,
        prepareEpoch: Bool = true,
        lane: AgentRecoverySessionLane? = nil
    ) async throws -> (AgentModeViewModel, AgentTabSession, UUID) {
        let lane = lane ?? laneFixture.lane
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        // Bound to the lane's session before the run attempt begins (R07 ownership).
        let sessionID = lane.sessionID
        let session = try! await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        if prepareEpoch {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        let runID = UUID()
        session.recoveryLane = lane
        session.codexSteerAckTracker.test_useManualDeadlines()
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback.mcp")
        session.codexController = controller
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        return (viewModel, session, sessionID)
    }

    private func makeNativeController(
        recorder: MismatchRetryNativeControllerRecorder
    ) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(mcpHost: ServerNetworkManager.shared),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            options: .agentModeDefault(forceExperimentalSteering: false, goalSupportEnabledProvider: { CodexGoalSupport.isEnabled }),
            requestExecutor: { method, params, timeout in
                try recorder.handle(method: method, params: params, timeout: timeout)
            }
        )
    }

    private func lifecycleParams(
        turnID: String,
        status: String? = nil
    ) -> [String: CodexJSONValue] {
        var turn: [String: CodexJSONValue] = ["id": .string(turnID)]
        if let status {
            turn["status"] = .string(status)
        }
        return [
            "threadId": .string("thread"),
            "turn": .object(turn)
        ]
    }

    /// A submission context for a real `queued` intent admitted through the suite's lane; the
    /// queue ID is the intent ID.
    private func admittedContext(
        origin: AgentTabSession.CodexFallbackOrigin,
        text: String,
        userItemID: UUID = UUID()
    ) async throws -> AgentTabSession.CodexFallbackSubmissionContext {
        let identity = try await laneFixture.queuedIdentity(text, userItemID: userItemID)
        return durableContext(identity: identity, origin: origin, text: text)
    }

    /// Sends `text` as real durable input (see `admittedContext`).
    private func send(
        _ viewModel: AgentModeViewModel,
        _ session: AgentTabSession,
        text: String,
        origin: AgentTabSession.CodexFallbackOrigin = .manual
    ) async throws -> CodexAgentModeCoordinator.NativeSendOutcome {
        let context = try await admittedContext(origin: origin, text: text)
        return await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: text,
            attachments: [],
            fallbackContext: context
        )
    }

    private func fallbackQueueEntry(
        identity: AgentQueuedInputIdentity,
        origin: AgentTabSession.CodexFallbackOrigin,
        text: String,
        session: AgentTabSession,
        controller: any CodexSessionControlling
    ) -> AgentTabSession.CodexFallbackQueueEntry {
        .init(
            id: identity.intentID ?? UUID(),
            providerText: text,
            images: [],
            taggedFileAttachments: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            attachmentReservationID: nil,
            identity: identity,
            draftText: text,
            origin: origin,
            fallbackReason: .activeWithoutAuthoritativeIdentity,
            originThreadID: session.codexConversationID ?? "thread",
            originControllerInstanceID: ObjectIdentifier(controller),
            originControllerGeneration: session.codexControllerGeneration,
            originRunID: session.runID!,
            originRunAttemptID: session.activeRunAttemptID!,
            blockingTurn: nil,
            state: .queued
        )
    }

    private func requestFailure(
        message: String,
        data: CodexJSONValue? = nil
    ) -> CodexAppServerClient.RequestFailure {
        .init(method: "turn/steer", code: -32602, message: message, data: data)
    }

    private func assertAcceptedDispatchReleasedWaiter(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch disposition {
        case let .noteworthySnapshot(snapshot, .steeringRequested),
             let .snapshotReady(snapshot):
            XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
        default:
            XCTFail("Expected accepted dispatch to release waiter, got \(disposition)", file: file, line: line)
        }
    }

    private func assertDidNotReleaseAsSteering(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .noteworthySnapshot(snapshot, reason) = disposition,
           reason == .steeringRequested
        {
            XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
            XCTFail("Codex fallback must not release waiters as steeringRequested before durable queue ack", file: file, line: line)
        }
    }

    private func assertSteeringRequested(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .noteworthySnapshot(snapshot, reason) = disposition else {
            return XCTFail("Expected steering wake, got \(disposition)", file: file, line: line)
        }
        XCTAssertEqual(reason, .steeringRequested, file: file, line: line)
        XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Codex fallback FIFO state")
    }
}

private final class FallbackFIFOController: CodexSessionControlling {
    private let snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let activeTurnIDs: [String]
    private var snapshotResults: [Result<CodexNativeSessionController.ThreadSnapshot, Error>]
    private var steerResults: [Result<CodexTurnSteerReceipt, Error>]
    private let startGate: FallbackStartGate?
    private let steerGate: FallbackStartGate?

    private(set) var steerTurnIDs: [String] = []
    private(set) var startCount = 0
    private(set) var hasActiveThread = true
    /// Result of the accepted-mismatch lifecycle reconciliation (protocol default is `true`).
    var prepareLifecycleResult = true
    /// Errors thrown by successive `turn/start` calls after they are counted.
    var startErrors: [Error] = []

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .active(activeFlags: []),
        activeTurnIDs: [String] = ["turn"],
        snapshotResults: [Result<CodexNativeSessionController.ThreadSnapshot, Error>] = [],
        steerResults: [Result<CodexTurnSteerReceipt, Error>],
        startGate: FallbackStartGate? = nil,
        steerGate: FallbackStartGate? = nil
    ) {
        self.snapshot = snapshot
        self.activeTurnIDs = activeTurnIDs
        self.snapshotResults = snapshotResults
        self.steerResults = steerResults
        self.startGate = startGate
        self.steerGate = steerGate
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        if !snapshotResults.isEmpty {
            return try snapshotResults.removeFirst().get()
        }
        return .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshot,
            currentTurnID: activeTurnIDs.first,
            activeTurnIDs: activeTurnIDs,
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startCount += 1
        await startGate?.wait()
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        return .init(provisionalSubmissionID: "submission-\(startCount)")
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        prepareLifecycleResult
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        steerTurnIDs.append(expectedTurnID)
        await steerGate?.wait()
        guard !steerResults.isEmpty else {
            return .init(acceptedTurnID: expectedTurnID)
        }
        return try steerResults.removeFirst().get()
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private enum FallbackFIFOTestError: Error {
    case transientSnapshotFailure
}

/// Controls the recovery store's real file-write seam (`AgentRecoveryStore.FileOperations`): fail
/// every write, or suspend exactly the next write inside the store until released.
private final class CodexRecoveryWriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private var failWrites = false
    private var holdNext = false
    private var arrivedAtHeldWrite = false
    private let heldWriteRelease = DispatchSemaphore(value: 0)

    var shouldFailWrites: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    var hasArrivedAtHeldWrite: Bool {
        lock.withLock { arrivedAtHeldWrite }
    }

    func holdNextWrite() {
        lock.withLock {
            holdNext = true
            arrivedAtHeldWrite = false
        }
    }

    /// Resumes a suspended write (harmless when none is suspended).
    func releaseHeldWrite() {
        heldWriteRelease.signal()
    }

    func fileOperations() -> AgentRecoveryStore.FileOperations {
        AgentRecoveryStore.FileOperations(
            writeAtomically: { [self] data, url in
                let holds: Bool = lock.withLock {
                    guard holdNext else { return false }
                    holdNext = false
                    arrivedAtHeldWrite = true
                    return true
                }
                if holds {
                    // Bounded so a failing test can never wedge the store forever.
                    _ = heldWriteRelease.wait(timeout: .now() + 10)
                }
                if shouldFailWrites {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
    }
}

/// `RecoveryLaneFixture` with the store's file-write seam under test control: a temporary store
/// and tombstone root behind the real `AgentSessionDataService` gate, a started coordinator, and
/// one durable session lane. Identities come only from receipts the store issues.
@MainActor
private final class CodexDiskSeamRecoveryLane {
    private struct Workspace: AgentWorkspaceStorageReference {
        let id = UUID()
        let name = "Codex Disk Seam Recovery Lane"
        let customStoragePath: URL?
    }

    private final class Owner {}

    let root: URL
    let writes: CodexRecoveryWriteControl
    let store: AgentRecoveryStore
    let coordinator: AgentRecoveryCoordinator
    let lane: AgentRecoverySessionLane
    private let service: AgentSessionDataService
    private let owner: Owner

    private init(
        root: URL,
        writes: CodexRecoveryWriteControl,
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        coordinator: AgentRecoveryCoordinator,
        lane: AgentRecoverySessionLane,
        owner: Owner
    ) {
        self.root = root
        self.writes = writes
        self.store = store
        self.service = service
        self.coordinator = coordinator
        self.lane = lane
        self.owner = owner
    }

    static func make(_ name: String) async throws -> CodexDiskSeamRecoveryLane {
        let writes = CodexRecoveryWriteControl()
        let root = try RecoveryTestSupport.makeTemporaryRoot(name)
        let recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        let workspace = Workspace(customStoragePath: root.appendingPathComponent("workspace", isDirectory: true))
        let store = AgentRecoveryStore(rootURL: recoveryRoot, fileOperations: writes.fileOperations())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
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
        coordinator.startIfNeeded()
        guard await coordinator.awaitStartup() == .ready else {
            throw RecoveryLaneFixtureError.startupNotReady
        }
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Codex Disk Seam"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let owner = Owner()
        let lane = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        return CodexDiskSeamRecoveryLane(
            root: root,
            writes: writes,
            store: store,
            service: service,
            coordinator: coordinator,
            lane: lane,
            owner: owner
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Commits a real `queued` intent through the lane and returns its durable identity.
    func queuedIdentity(_ text: String, userItemID: UUID = UUID()) async throws -> AgentQueuedInputIdentity {
        let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: userItemID,
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content(text)
        )).get()
        return AgentQueuedInputIdentity(receipt: admitted.receipt)
    }

    func intent(_ identity: AgentQueuedInputIdentity) async -> AgentRecoveryIntent? {
        guard let intentID = identity.intentID else { return nil }
        return await store.read(sessionID: lane.sessionID).record?.intent(id: intentID)
    }

    func attempts(_ identity: AgentQueuedInputIdentity) async -> [AgentRecoveryAttempt] {
        guard let intentID = identity.intentID else { return [] }
        return await store.read(sessionID: lane.sessionID).record?.attempts(forIntent: intentID) ?? []
    }
}

private final class MismatchRetryNativeControllerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steerAttemptCount = 0
    private var recordedInterruptedTurnIDs: [String] = []

    var interruptedTurnIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInterruptedTurnIDs
    }

    func handle(
        method: String,
        params: [String: Any]?,
        timeout _: TimeInterval?
    ) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "turn/steer":
            steerAttemptCount += 1
            if steerAttemptCount == 1 {
                let failure = CodexAppServerClient.RequestFailure(
                    method: method,
                    code: -32602,
                    message: "expected active turn id `turn` but found `actual-turn`",
                    data: .object(["actualTurnId": .string("actual-turn")])
                )
                throw CodexAppServerClient.ClientError.requestFailed(failure)
            }
            return ["turnId": params?["expectedTurnId"] as? String ?? ""]
        case "turn/interrupt":
            if let turnID = params?["turnId"] as? String {
                recordedInterruptedTurnIDs.append(turnID)
            }
            return [:]
        default:
            return [:]
        }
    }
}

private actor FallbackStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var waiting = false

    func wait() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waiting { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return waiting
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
