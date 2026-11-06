import Foundation
@testable import RepoPromptAgentCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Reliability plan item 1: the 300-second idle release of delegated (MCP-originated) Claude
/// runtimes. Time is injected (`IdleReleaseManualClock`); no test sleeps for real intervals.
@MainActor
extension AgentModeRunServiceLifecycleTests {
    private static let idleFullInterval = ClaudeAgentModeCoordinator.delegatedIdleRuntimeReleaseDelayNanos
    private static let idleProbeInterval = ClaudeAgentModeCoordinator.delegatedIdleRuntimeReleaseProbeNanos
    private static let idleHandoffWording = "runtime was released to free resources"
    private static let genuineResumeFailureWording = "after a native resume failed"

    // MARK: - Release

    func testClaudeDelegatedIdleReleaseShutsDownOnceAtFullIntervalAndPreservesHistory() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "idle-a", sessionID: "idle-a-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session
        let coordinator = fixture.coordinator

        try await runIdleReleaseTurn(fixture, controller: controller, text: "delegated task")

        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(session.providerSessionID, "idle-a-session")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        XCTAssertTrue(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(fixture.clock.requestedIntervals, [Self.idleFullInterval])
        XCTAssertEqual(Self.idleFullInterval, 300_000_000_000)
        XCTAssertFalse(recorder.contains("idle-a:shutdown"), "nothing is released before the full interval")
        XCTAssertNotNil(session.claudeController)

        let itemsBefore = session.items.map(\.id)
        let bindingsBefore = session.worktreeBindings
        let timer = try XCTUnwrap(coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value

        XCTAssertEqual(recorder.events.count(where: { $0 == "idle-a:shutdown" }), 1)
        XCTAssertNil(session.claudeController)
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseRetiring(for: session))
        XCTAssertEqual(session.runState, .completed, "a released runtime never turns the answer into a failure")
        XCTAssertEqual(session.items.map(\.id), itemsBefore)
        XCTAssertEqual(session.worktreeBindings, bindingsBefore)
        XCTAssertEqual(session.providerSessionID, "idle-a-session", "the prior identity is kept")
        XCTAssertEqual(session.claudeIdleReleasedConversationID, "idle-a-session")
        XCTAssertFalse(session.pendingHandoff.hasPayload)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertEqual(coordinator.test_idleRuntimeReleaseEvents.filter { $0.hasPrefix("released:") }, ["released:idle-interval"])
        XCTAssertEqual(fixture.clock.pendingCount, 0, "a released runtime arms nothing further")
    }

    func testClaudeDelegatedIdleReleaseNeverArmsForUserOwnedTab() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "user-owned", sessionID: "user-owned-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller], origin: .user)
        XCTAssertFalse(fixture.session.isMCPOriginated)

        try await runIdleReleaseTurn(fixture, controller: controller, text: "user task")
        // Between-run output on a user-owned tab never arms either.
        await controller.emitAssistantText("user background output")
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        XCTAssertFalse(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: fixture.session))
        XCTAssertEqual(fixture.clock.requestedIntervals, [])
        XCTAssertNotNil(fixture.session.claudeController)
        XCTAssertFalse(recorder.contains("user-owned:shutdown"))
        XCTAssertEqual(fixture.coordinator.test_idleRuntimeReleaseEvents, [])
    }

    // MARK: - Terminal evidence and persistence

    func testClaudeDelegatedIdleArmsOnlyFromAcceptedTerminalPublicationOfCurrentState() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "rejected", sessionID: "rejected-session")
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            publishTerminalCommitResult: { _, _, _ in .rejected(reason: "test-rejected") }
        )
        let session = fixture.session
        let coordinator = fixture.coordinator

        // The run task returns normally, but its terminal publication was rejected: no arm.
        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(session.lastTerminalPublicationResult, .rejected(reason: "test-rejected"))
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(fixture.clock.requestedIntervals, [])
        XCTAssertEqual(coordinator.test_idleRuntimeReleaseEvents, ["not-armed:terminal-not-accepted"])

        // Accepted publication, but the session shows a state the commit never published: neither
        // the acceptance observer nor an explicit request arms.
        session.runState = .idle
        session.lastTerminalPublicationResult = .accepted(successorEpoch: nil)
        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test")
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))

        // A stale publication (superseded) does not arm either.
        session.runState = .completed
        session.lastTerminalPublicationResult = .stale
        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test")
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))

        // The run-end arm names its own attempt: another attempt's commit is not its evidence.
        // (The acceptance observer is detached here so only the explicit request is evaluated.)
        session.onClaudeTerminalPublicationAccepted = nil
        session.lastTerminalPublicationResult = .accepted(successorEpoch: nil)
        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test", committedAttemptID: UUID())
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))

        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test")
        XCTAssertTrue(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(coordinator.test_idleRuntimeReleaseEvents.count(where: { $0 == "not-armed:terminal-not-accepted" }), 5)
        XCTAssertFalse(recorder.contains("rejected:shutdown"))
    }

    /// Oracle A5: a rejected first publication that a later barrier retry turns into an accepted one
    /// arms the release, with no further run or provider output.
    func testClaudeDelegatedIdleRetriedPublicationAcceptanceArmsRelease() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "retried", sessionID: "retried-session")
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            publishTerminalCommitResult: { _, _, _ in .rejected(reason: "test-rejected") }
        )
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        XCTAssertFalse(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(fixture.clock.requestedIntervals, [])

        // The barrier's duplicate-commit retry records the accepted result for the still-current
        // commit (`AgentRunTerminalCommitBarrier.commit`, retry branch).
        session.lastTerminalPublicationResult = .accepted(successorEpoch: nil)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:publication-accepted"))
        try await idleWaitUntil("armed by the accepted retry") { fixture.clock.pendingCount == 1 }
        XCTAssertEqual(fixture.clock.requestedIntervals, [Self.idleFullInterval])

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "retried:shutdown" }), 1)
    }

    /// Oracle A5 (round 1): attempt A stays suspended in its real terminal publication (its run
    /// task alive) while attempt B runs, completes with a rejected publication, and the barrier's
    /// real duplicate-commit retry accepts B. A's live runner must not suppress B's arm; the
    /// expiry-time runner fence keeps the runtime until A returns, then B releases exactly once.
    func testClaudeDelegatedIdleAcceptedRetryArmsWhileSupersededRunnerStillPublishes() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "overlap", sessionID: "overlap-session")
        let publicationGate = LifecycleAsyncGate()
        var publications = 0
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            publishTerminalCommitResult: { _, _, _ in
                publications += 1
                switch publications {
                case 1:
                    // Attempt A: held inside its terminal publication.
                    await publicationGate.arriveAndWait()
                    return .accepted(successorEpoch: nil)
                case 2:
                    // Attempt B's first publication.
                    return .rejected(reason: "test-rejected")
                default:
                    // The barrier's retry of B.
                    return .accepted(successorEpoch: nil)
                }
            }
        )
        let session = fixture.session
        let coordinator = fixture.coordinator

        session.appendItem(.user("first task", sequenceIndex: session.nextSequenceIndex))
        let outcomeA = await fixture.harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "first task",
            initialMessageForRun: "first task",
            attachments: [],
            inputConstituents: [AgentQueuedInputIdentity.inactiveForTesting(in: session)]
        )
        XCTAssertNil(outcomeA)
        let runTaskA = try XCTUnwrap(session.agentTask)
        let turnA = await controller.waitForPendingTurnCompletion()
        try await idleWaitUntil("turn A expected") { session.claudeExpectedTurnIDs.contains(turnA) }
        await controller.emitPendingTurnCompletion()
        await publicationGate.waitUntilArrived()
        let attemptA = try XCTUnwrap(session.lastTerminalCommitRevision?.ownership.attemptID)

        try await runIdleReleaseTurn(fixture, controller: controller, text: "second task")
        let revisionB = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertNotEqual(revisionB.ownership.attemptID, attemptA)
        XCTAssertEqual(session.lastTerminalPublicationResult, .rejected(reason: "test-rejected"))
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))

        let retried = await fixture.harness.service.test_terminalCommitBarrier().commit(
            AgentRunTerminalCommitBarrier.Request(
                session: session,
                ownership: revisionB.ownership,
                expectedRunID: revisionB.expectedRunID,
                terminalState: revisionB.terminalState,
                source: "test.idleOverlapRetry",
                cause: .ordinary,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false
            )
        )
        XCTAssertEqual(retried?.commitID, revisionB.commitID, "a retry, not a new commit")
        XCTAssertEqual(publications, 3)
        XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
        XCTAssertTrue(coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:publication-accepted"))
        try await idleWaitUntil("B armed by its accepted retry") { fixture.clock.pendingCount == 1 }
        XCTAssertEqual(fixture.clock.requestedIntervals, [Self.idleFullInterval])

        // A's runner is still alive: the expiry-time fence defers instead of releasing.
        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("deferred by A's live runner") {
            coordinator.test_idleRuntimeReleaseEvents.contains("deferred:run-task-alive")
                && fixture.clock.pendingCount == 1
        }
        XCTAssertFalse(recorder.contains("overlap:shutdown"))

        // A's publication returns superseded; its run end's request (A's commit is no longer
        // current) leaves B's interval armed.
        await publicationGate.release()
        await runTaskA.value
        session.isDirty = false
        XCTAssertTrue(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(session.lastTerminalCommitRevision?.commitID, revisionB.commitID)

        // Quiescence observed after A returned starts one fresh full interval; only it releases.
        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("fresh full interval after A returned") {
            coordinator.test_idleRuntimeReleaseEvents.contains("rearmed:quiescent") && fixture.clock.pendingCount == 1
        }
        XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleFullInterval)
        XCTAssertFalse(recorder.contains("overlap:shutdown"))
        let timer = try XCTUnwrap(coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "overlap:shutdown" }), 1)
        XCTAssertEqual(coordinator.test_idleRuntimeReleaseEvents.filter { $0.hasPrefix("released:") }, ["released:idle-interval"])
    }

    /// Oracle A2: a superseded attempt's late run-end request (its own commit is no longer current)
    /// neither cancels nor replaces the successor's armed interval.
    func testClaudeDelegatedIdleLateRequestOfSupersededAttemptKeepsSuccessorTimer() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "late", sessionID: "late-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "first task")
        let supersededAttemptID = try XCTUnwrap(session.lastTerminalCommitRevision?.ownership.attemptID)
        try await runIdleReleaseTurn(fixture, controller: controller, text: "second task")
        try await idleWaitUntil("successor armed") { fixture.clock.pendingCount == 1 }
        let successorTimer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        let cancelledBefore = fixture.clock.cancelledCount
        let requestedBefore = fixture.clock.requestedIntervals.count

        // The superseded attempt's runner `defer` runs late.
        fixture.coordinator.scheduleIdleRuntimeReleaseIfEligible(
            for: session,
            reason: "run-ended",
            committedAttemptID: supersededAttemptID
        )

        XCTAssertEqual(fixture.coordinator.test_idleRuntimeReleaseTask(for: session), successorTimer)
        XCTAssertFalse(successorTimer.isCancelled)
        XCTAssertEqual(fixture.clock.cancelledCount, cancelledBefore)
        XCTAssertEqual(fixture.clock.requestedIntervals.count, requestedBefore)
        XCTAssertEqual(fixture.coordinator.test_idleRuntimeReleaseEvents.last, "not-armed:terminal-not-accepted")

        XCTAssertTrue(fixture.clock.fireOldest())
        await successorTimer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "late:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleReleaseWaitsForSaveReceipt() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "unsaved", sessionID: "unsaved-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task", acknowledgeSave: false)
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        session.isDirty = true

        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("persistence probe") { fixture.clock.requestedIntervals.count == 2 }
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("deferred:persistence-pending"))
        XCTAssertFalse(recorder.contains("unsaved:shutdown"))

        // The save receipt (`isDirty = false`) is observed by the next probe; release then still
        // needs a full interval from that observation.
        session.isDirty = false
        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("fresh full interval") { fixture.clock.requestedIntervals.count == 3 }
        XCTAssertEqual(
            fixture.clock.requestedIntervals,
            [Self.idleFullInterval, Self.idleProbeInterval, Self.idleFullInterval]
        )
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("rearmed:quiescent"))
        XCTAssertFalse(recorder.contains("unsaved:shutdown"))

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "unsaved:shutdown" }), 1)
    }

    // MARK: - Activity, cancellation and re-arming

    func testClaudeDelegatedIdleTransientBlockerBeforeOriginalDeadlineRestartsFullIntervalFromItsEnd() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "transient", sessionID: "transient-session")
        // Cancelled sleepers stay pending and can still be fired: a cancelled interval's deadline
        // waking must never release.
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            clockIgnoresCancellation: true
        )
        let session = fixture.session
        let coordinator = fixture.coordinator
        defer { fixture.clock.resumeAllThrowing() }

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        let blockers: [(name: String, apply: () -> Void, clear: () -> Void)] = [
            ("question", { session.waitingPrompt = "question" }, { session.waitingPrompt = nil }),
            ("approval", { session.pendingApproval = self.idleApprovalRequest() }, { session.pendingApproval = nil }),
            ("reservation", { session.recoveryQuestionCreationReservation = UUID() }, { session.recoveryQuestionCreationReservation = nil }),
            ("queued-instruction", { session.mcpFollowUpRunPending = true }, { session.mcpFollowUpRunPending = false }),
            (
                "steer",
                { session.pendingClaudeSteeringInstructions = [self.makeClaudeSteeringInstruction(session: session, text: "steer")] },
                { session.pendingClaudeSteeringInstructions.removeAll() }
            ),
            ("location-transition", { session.isChangingExecutionLocation = true }, { session.isChangingExecutionLocation = false })
        ]
        for blocker in blockers {
            let originalDeadline = try XCTUnwrap(coordinator.test_idleRuntimeReleaseTask(for: session))
            let pendingBefore = fixture.clock.pendingCount
            let requestedBefore = fixture.clock.requestedIntervals.count
            // The blocker appears and settles entirely before the original deadline; each change
            // synchronously restarts the interval.
            blocker.apply()
            blocker.clear()
            XCTAssertTrue(originalDeadline.isCancelled, blocker.name)
            try await idleWaitUntil("restarted twice by \(blocker.name)") {
                fixture.clock.requestedIntervals.count == requestedBefore + 2
                    && fixture.clock.pendingCount == pendingBefore + 2
            }
            XCTAssertEqual(Array(fixture.clock.requestedIntervals.suffix(2)), [Self.idleFullInterval, Self.idleFullInterval], blocker.name)
            // Fire every superseded interval, the original deadline first: none releases. The two
            // restarted tasks register their sleepers concurrently, so select by cancellation,
            // not by registration order.
            XCTAssertEqual(fixture.clock.supersededCount, fixture.clock.pendingCount - 1, blocker.name)
            while fixture.clock.supersededCount > 0 {
                XCTAssertTrue(fixture.clock.fireOldestSuperseded())
            }
            XCTAssertEqual(fixture.clock.pendingCount, 1, blocker.name)
            await originalDeadline.value
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            XCTAssertFalse(recorder.contains("transient:shutdown"), blocker.name)
            XCTAssertTrue(coordinator.test_isIdleRuntimeReleaseArmed(for: session), blocker.name)
        }
        XCTAssertEqual(
            coordinator.test_idleRuntimeReleaseEvents.count(where: { $0 == "scheduled:activity" }),
            blockers.count * 2
        )

        // Only the interval that started when the last blocker settled releases.
        let timer = try XCTUnwrap(coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "transient:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleBlockersAtExpiryDeferAndRestartFullIntervalWhenTheySettle() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "blocked", sessionID: "blocked-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session
        let coordinator = fixture.coordinator

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        let blockers: [(reason: String, apply: () -> Void, clear: () -> Void)] = [
            ("interaction", { session.waitingPrompt = "question" }, { session.waitingPrompt = nil }),
            ("interaction", { session.recoveryQuestionCreationReservation = UUID() }, { session.recoveryQuestionCreationReservation = nil }),
            ("interaction", { session.recoveryQuestionResolutionReservations.insert(UUID()) }, { session.recoveryQuestionResolutionReservations.removeAll() }),
            ("queued-work", { session.mcpFollowUpRunPending = true }, { session.mcpFollowUpRunPending = false }),
            ("queued-work", { session.isMCPInstructionDispatchInProgress = true }, { session.isMCPInstructionDispatchInProgress = false }),
            (
                "queued-work",
                { session.pendingClaudeSteeringInstructions = [self.makeClaudeSteeringInstruction(session: session, text: "steer")] },
                { session.pendingClaudeSteeringInstructions.removeAll() }
            ),
            (
                "pending-handoff",
                { session.pendingHandoff = AgentPendingHandoffState(payload: "pending", payloadID: UUID()) },
                { session.pendingHandoff = AgentPendingHandoffState() }
            ),
            ("superseding-completion", { session.pendingSupersedingTurnCompletions = 1 }, { session.pendingSupersedingTurnCompletions = 0 }),
            ("location-transition", { session.worktreeBindingTransitionInProgress = true }, { session.worktreeBindingTransitionInProgress = false })
        ] + idleInteractionBlockerMatrix(session: session, host: fixture.harness.host)
        for blocker in blockers {
            // The blocker appears (a fresh full interval starts), is still pending at that
            // interval's expiry (deferred, probing), then settles (a fresh full interval from then).
            let requestedBefore = fixture.clock.requestedIntervals.count
            blocker.apply()
            try await idleWaitUntil("restarted by \(blocker.reason)") {
                fixture.clock.requestedIntervals.count == requestedBefore + 1 && fixture.clock.pendingCount == 1
            }
            XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleFullInterval, blocker.reason)
            XCTAssertTrue(fixture.clock.fireOldest())
            try await idleWaitUntil("probe for \(blocker.reason)") {
                fixture.clock.requestedIntervals.count == requestedBefore + 2 && fixture.clock.pendingCount == 1
            }
            XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleProbeInterval, blocker.reason)
            XCTAssertEqual(
                coordinator.test_idleRuntimeReleaseEvents.last(where: { $0.hasPrefix("deferred:") }),
                "deferred:\(blocker.reason)"
            )
            blocker.clear()
            try await idleWaitUntil("restarted after \(blocker.reason)") {
                fixture.clock.requestedIntervals.count == requestedBefore + 3 && fixture.clock.pendingCount == 1
            }
            XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleFullInterval, blocker.reason)
            XCTAssertFalse(recorder.contains("blocked:shutdown"), blocker.reason)
        }

        let timer = try XCTUnwrap(coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "blocked:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleTimerIsCancelledByNewTurnAndRearmsAfterIt() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "rearm", sessionID: "rearm-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "first task")
        try await idleWaitUntil("first idle timer armed") { fixture.clock.pendingCount == 1 }
        let firstCommit = try XCTUnwrap(session.lastTerminalCommitRevision?.commitID)

        try await runIdleReleaseTurn(fixture, controller: controller, text: "second task")

        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("cancelled:new-turn"))
        try await idleWaitUntil("second idle timer armed") { fixture.clock.pendingCount == 1 }
        XCTAssertNotEqual(session.lastTerminalCommitRevision?.commitID, firstCommit)
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:publication-accepted"))
        XCTAssertEqual(fixture.clock.requestedIntervals.count, 2)
        XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleFullInterval)
        XCTAssertFalse(recorder.contains("rearm:shutdown"))

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "rearm:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleCancelledOldTimerCannotRemoveSuccessorTimer() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "stale-timer", sessionID: "stale-timer-session")
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            clockIgnoresCancellation: true
        )
        let session = fixture.session
        defer { fixture.clock.resumeAllThrowing() }

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("first idle timer armed") { fixture.clock.pendingCount == 1 }
        let oldTimer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))

        fixture.coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test-rearm")
        try await idleWaitUntil("successor idle timer armed") { fixture.clock.pendingCount == 2 }
        let successorTimer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))

        // The cancelled timer still wakes (its sleeper ignored cancellation) after the successor
        // was installed: it must neither release nor clear the successor's slot.
        XCTAssertTrue(fixture.clock.fireOldest())
        await oldTimer.value
        XCTAssertTrue(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertFalse(recorder.contains("stale-timer:shutdown"))

        XCTAssertTrue(fixture.clock.fireOldest())
        await successorTimer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "stale-timer:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleBackgroundOutputRestartsFullInterval() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "background", sessionID: "background-session")
        var backgroundTexts: [String] = []
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            handleBackgroundNativeStreamResult: { result, _ in
                backgroundTexts.append(result.text ?? "")
            }
        )
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        await controller.emitAssistantText("autonomous continuation")
        try await idleWaitUntil("background output re-armed the timer") {
            fixture.coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:background-output")
                && fixture.clock.pendingCount == 1
        }
        XCTAssertEqual(backgroundTexts, ["autonomous continuation"])
        // The delivered output restarts the interval once (a fresh full interval). The router
        // reports only held approvals, so ordinary output adds no per-event `activity` restart.
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:activity"))
        XCTAssertEqual(fixture.clock.cancelledCount, 1)
        XCTAssertEqual(fixture.clock.requestedIntervals, Array(repeating: Self.idleFullInterval, count: 2))
        XCTAssertFalse(recorder.contains("background:shutdown"))

        session.isDirty = false
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "background:shutdown" }), 1)
    }

    /// Oracle A3: a provider turn still in flight at expiry keeps probing; the fresh full interval
    /// starts only after a completed observation that no turn is in flight.
    func testClaudeDelegatedIdleProviderTurnInFlightNeedsObservedIdleBeforeFreshInterval() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "busy", sessionID: "busy-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        await controller.setTurnInFlight(true)

        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("first probe") { fixture.clock.requestedIntervals.count == 2 }
        // Several probes while the provider stays busy: none restarts the full interval.
        for probe in 3 ... 5 {
            XCTAssertTrue(fixture.clock.fireOldest())
            try await idleWaitUntil("probe \(probe)") {
                fixture.clock.requestedIntervals.count == probe && fixture.clock.pendingCount == 1
            }
        }
        XCTAssertEqual(
            fixture.clock.requestedIntervals,
            [Self.idleFullInterval] + Array(repeating: Self.idleProbeInterval, count: 4)
        )
        XCTAssertEqual(
            fixture.coordinator.test_idleRuntimeReleaseEvents.count(where: { $0 == "deferred:provider-turn-in-flight" }),
            1
        )
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("rearmed:quiescent"))

        // The provider is observed idle: only now a fresh full interval starts, and only its
        // expiry releases.
        await controller.setTurnInFlight(false)
        XCTAssertTrue(fixture.clock.fireOldest())
        try await idleWaitUntil("fresh full interval") { fixture.clock.requestedIntervals.count == 6 }
        XCTAssertEqual(fixture.clock.requestedIntervals.last, Self.idleFullInterval)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("rearmed:quiescent"))
        XCTAssertFalse(recorder.contains("busy:shutdown"))

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "busy:shutdown" }), 1)
    }

    /// Oracle A4: a between-run approval held by the event router and then cancelled (the router
    /// drops the pair without delivering either) entirely before the original deadline restarts
    /// the interval synchronously; the original deadline never releases.
    func testClaudeDelegatedIdleBetweenRunApprovalHeldAndCancelledBeforeDeadlineRestartsInterval() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "held", sessionID: "held-session")
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [controller],
            clockIgnoresCancellation: true
        )
        let session = fixture.session
        defer { fixture.clock.resumeAllThrowing() }

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        let originalDeadline = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))

        await controller.emitRuntimeEvent(.approvalRequest(idleApprovalRequest()))
        try await idleWaitUntil("held approval restarted the interval") { fixture.clock.requestedIntervals.count == 2 }
        XCTAssertTrue(originalDeadline.isCancelled)
        XCTAssertNil(session.pendingApproval, "a between-run approval is held by the router, not shown")
        await controller.emitRuntimeEvent(.approvalCancelled(requestID: "idle-approval"))
        try await idleWaitUntil("dropped pair restarted the interval") {
            fixture.clock.requestedIntervals.count == 3 && fixture.clock.pendingCount == 3
        }
        XCTAssertEqual(fixture.clock.requestedIntervals, Array(repeating: Self.idleFullInterval, count: 3))

        // Every superseded deadline (the original first) wakes without releasing.
        while fixture.clock.supersededCount > 0 {
            XCTAssertTrue(fixture.clock.fireOldestSuperseded())
        }
        await originalDeadline.value
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertFalse(recorder.contains("held:shutdown"))
        XCTAssertTrue(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: session))

        // Only the interval started when the pair was dropped releases.
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "held:shutdown" }), 1)
    }

    /// B P2-1: a between-run runtime init with a new conversation identity re-arms the interval
    /// for that identity instead of leaving the retained runtime without a timer.
    func testClaudeDelegatedIdleRuntimeInitWithNewConversationRearms() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "reinit", sessionID: "reinit-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        await controller.emitRuntimeEvent(.runtimeInit(NativeAgentRuntimeRuntimeInitStatus(
            sessionID: "reinit-new-session",
            tools: [],
            mcpServerStatuses: [:],
            initializeResponse: nil
        )))
        try await idleWaitUntil("re-armed for the new identity") {
            session.providerSessionID == "reinit-new-session"
                && fixture.coordinator.test_idleRuntimeReleaseEvents.last == "scheduled:runtime-init"
                && fixture.clock.pendingCount == 1
        }
        session.isDirty = false

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "reinit:shutdown" }), 1)
        // The marker names the identity retirement captured from the runtime (this fake reports
        // its fixed launch ID).
        XCTAssertNotNil(session.claudeIdleReleasedConversationID)
        XCTAssertEqual(session.claudeIdleReleasedConversationID, session.providerSessionID)
    }

    /// B P2-2: hiding agent mode (`stop()`) cancels armed intervals while runtimes stay alive;
    /// showing it again re-arms eligible delegated tabs with a fresh full interval.
    func testClaudeDelegatedIdleAgentModeReactivationRearmsAfterStop() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "hidden", sessionID: "hidden-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        fixture.harness.host.setAgentModeActive(false)
        XCTAssertFalse(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("cancelled:coordinator-stop"))
        XCTAssertNotNil(session.claudeController, "hiding the UI keeps the runtime")

        fixture.harness.host.setAgentModeActive(true)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("scheduled:agent-mode-active"))
        try await idleWaitUntil("re-armed") { fixture.clock.pendingCount == 1 }
        session.isDirty = false

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertEqual(recorder.events.count(where: { $0 == "hidden:shutdown" }), 1)
    }

    func testClaudeDelegatedIdleTimerCancelledByWorkspaceDetachCoordinatorStopAndExplicitShutdown() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "teardown", sessionID: "teardown-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session
        let coordinator = fixture.coordinator

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        coordinator.detachAllClaudeToolTrackingHandlersForWorkspaceSwitch()
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        try await idleWaitUntil("detach cancelled the sleeper") { fixture.clock.pendingCount == 0 }

        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test-rearm")
        try await idleWaitUntil("re-armed after detach") { fixture.clock.pendingCount == 1 }
        coordinator.stop()
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        try await idleWaitUntil("stop cancelled the sleeper") { fixture.clock.pendingCount == 0 }

        coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test-rearm")
        try await idleWaitUntil("re-armed after stop") { fixture.clock.pendingCount == 1 }
        await coordinator.shutdownClaudeSession(session)
        XCTAssertFalse(coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(fixture.clock.pendingCount, 0)
        XCTAssertEqual(recorder.events.count(where: { $0 == "teardown:shutdown" }), 1)
        XCTAssertNil(session.claudeIdleReleasedConversationID, "an explicit shutdown is not an idle release")

        let cancellations = coordinator.test_idleRuntimeReleaseEvents.filter { $0.hasPrefix("cancelled:") }
        XCTAssertEqual(cancellations, ["cancelled:workspace-detach", "cancelled:coordinator-stop", "cancelled:explicit-shutdown"])
        XCTAssertFalse(coordinator.test_idleRuntimeReleaseEvents.contains { $0.hasPrefix("released:") })
    }

    // MARK: - Stale owners

    func testClaudeDelegatedIdleExpiryRacingReplacementControllerOrReusedTabIsStale() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "raced", sessionID: "raced-session")
        let replacement = idleController(recorder, label: "raced-replacement", sessionID: "raced-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        // A replacement controller installed before expiry survives.
        session.claudeController = replacement
        var timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:controller-replaced"))
        XCTAssertTrue(session.claudeController === replacement)
        XCTAssertFalse(recorder.contains("raced:shutdown"))
        XCTAssertFalse(recorder.contains("raced-replacement:shutdown"))

        // Tab reuse: another session object now owns the tab ID.
        session.claudeController = controller
        fixture.coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test-rearm")
        try await idleWaitUntil("re-armed") { fixture.clock.pendingCount == 1 }
        let reused = AgentTabSession(tabID: session.tabID)
        fixture.harness.host.test_installLiveSession(reused)
        timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:session-not-live"))
        XCTAssertFalse(recorder.contains("raced:shutdown"))
        fixture.harness.host.test_installLiveSession(session)
    }

    func testClaudeDelegatedIdleSameObjectReboundToAnotherDurableSessionSurvives() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "rebound", sessionID: "rebound-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID()))

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }

        // The same tab object, still live and still holding the same controller, now binds
        // another durable session before expiry.
        let transition = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID()))
        session.finishPersistentBindingTransition(generation: transition)

        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:session-rebound"))
        XCTAssertFalse(recorder.contains("rebound:shutdown"))
        XCTAssertNotNil(session.claudeController)
        XCTAssertNil(session.claudeIdleReleasedConversationID)

        // Activity after the rebinding never re-arms the old owner's interval either.
        fixture.coordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "test-rearm")
        try await idleWaitUntil("armed for the new binding") { fixture.clock.pendingCount == 1 }
        let rearmTransition = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID()))
        session.finishPersistentBindingTransition(generation: rearmTransition)
        session.waitingPrompt = "question"
        XCTAssertFalse(fixture.coordinator.test_isIdleRuntimeReleaseArmed(for: session))
        XCTAssertEqual(fixture.coordinator.test_idleRuntimeReleaseEvents.last, "stale:session-rebound")
        XCTAssertFalse(recorder.contains("rebound:shutdown"))
    }

    func testClaudeDelegatedIdleRebindingDuringRetirementKeepsTheNewOwnersState() async throws {
        let recorder = LifecycleRecorder()
        let shutdownGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retiring",
            shutdownGate: shutdownGate,
            emittedAssistantTextOnSend: "retiring answer",
            sessionID: "retiring-session"
        )
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await shutdownGate.waitUntilArrived()
        XCTAssertTrue(fixture.coordinator.test_isIdleRuntimeReleaseRetiring(for: session))

        // While the old process shuts down, the object is rebound to another durable session.
        let transition = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID()))
        session.finishPersistentBindingTransition(generation: transition)
        let runIDAfterRebind = session.runID

        await shutdownGate.release()
        await timer.value

        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:superseded-during-release"))
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("released:idle-interval"))
        XCTAssertEqual(session.runID, runIDAfterRebind, "the new owner's run identity is untouched")
        XCTAssertNil(session.claudeIdleReleasedConversationID, "the old session's fresh-start intent is dropped")
    }

    /// Oracle A1 / B P1-1: the same tab object is rebound to another durable session (with another
    /// conversation) while retirement awaits the old controller's session reference. The captured
    /// identity is never written into, or saved for, the new owner.
    func testClaudeDelegatedIdleRebindDuringRetirementCaptureNeverOverwritesNewOwner() async throws {
        let recorder = LifecycleRecorder()
        let controller = idleController(recorder, label: "capture", sessionID: "capture-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        XCTAssertEqual(session.providerSessionID, "capture-session")
        let captureGate = LifecycleAsyncGate()
        await controller.setCurrentSessionRefGate(captureGate)
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await captureGate.waitUntilArrived()
        XCTAssertNil(session.claudeController)

        let transition = session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID()))
        session.providerSessionID = "other-owner-conversation"
        session.finishPersistentBindingTransition(generation: transition)
        session.isDirty = false

        await captureGate.release()
        await timer.value

        XCTAssertEqual(session.providerSessionID, "other-owner-conversation", "the old identity is never written")
        XCTAssertFalse(session.isDirty, "no save is scheduled for the captured identity")
        XCTAssertNil(session.claudeIdleReleasedConversationID)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:superseded-during-release"))
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("released:idle-interval"))
        XCTAssertEqual(recorder.events.count(where: { $0 == "capture:shutdown" }), 1, "the detached process still retires")
    }

    /// Oracle A1 / B P1-2: another session object takes the tab while the old process shuts down and
    /// starts tool tracking before any preparation or dispatch. The release stops only its own
    /// detached tracker; the successor's tracker, run identity and tab slots survive.
    func testClaudeDelegatedIdleTabReplacedDuringRetirementKeepsSuccessorTracker() async throws {
        let recorder = LifecycleRecorder()
        let shutdownGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replaced",
            shutdownGate: shutdownGate,
            emittedAssistantTextOnSend: "replaced answer",
            sessionID: "replaced-session"
        )
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [controller])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: controller, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        let oldRunID = session.runID
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await shutdownGate.waitUntilArrived()

        let successor = AgentTabSession(tabID: session.tabID)
        successor.selectedAgent = .claudeCode
        fixture.harness.host.test_installLiveSession(successor)
        defer { fixture.harness.host.test_installLiveSession(session) }
        let successorRunID = UUID()
        await fixture.coordinator.ensureClaudeToolTrackingIfNeeded(for: successor, runID: successorRunID)
        XCTAssertEqual(fixture.coordinator.test_trackedClaudeRunID(for: successor), successorRunID)

        await shutdownGate.release()
        await timer.value

        XCTAssertEqual(fixture.coordinator.test_trackedClaudeRunID(for: successor), successorRunID)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:superseded-during-release"))
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("released:idle-interval"))
        XCTAssertEqual(session.runID, oldRunID, "the replaced object's run state is not cleared either")
        XCTAssertFalse(fixture.coordinator.test_isIdleRuntimeReleaseRetiring(for: successor))
    }

    // MARK: - Follow-up after release

    func testClaudeDelegatedIdleFollowUpSendsExactlyOneTruthfulHandoffToTheProvider() async throws {
        let recorder = LifecycleRecorder()
        let first = idleController(recorder, label: "idle-first", sessionID: "idle-first-session")
        let second = idleController(recorder, label: "idle-second", sessionID: "idle-second-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [first, second])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: first, text: "first task")
        try await releaseIdleRuntime(fixture)

        try await runIdleReleaseTurn(fixture, controller: second, text: "follow-up task")

        let firstStarts = await first.recordedStartExistingSessionIDs()
        let secondStarts = await second.recordedStartExistingSessionIDs()
        XCTAssertEqual(firstStarts, [nil])
        XCTAssertEqual(secondStarts, [nil], "the released conversation is not selected as a resume target")
        XCTAssertEqual(session.providerSessionID, "idle-second-session")
        XCTAssertNil(session.claudeIdleReleasedConversationID)
        let sent = await second.recordedSentMessages()
        assertProviderReceivedIdleHandoff(
            sent,
            followUp: "follow-up task",
            transcriptMarker: "idle-first answer"
        )
        // The host consumes a payload only for a `.sent` outcome whose stage carries the current
        // payload ID, so the write above carried exactly the staged idle handoff.
        XCTAssertFalse(session.pendingHandoff.hasPayload, "the delivered handoff is consumed")
        XCTAssertTrue(recorder.contains("handoff:true"))
        XCTAssertEqual(
            fixture.coordinator.test_idleRuntimeReleaseEvents.filter { $0.hasPrefix("fresh-start:") },
            ["fresh-start:idle-continuation-handoff"]
        )
        XCTAssertEqual(session.runState, .completed)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertFalse(recorder.contains("idle-second:shutdown"))
        // The follow-up's own accepted end arms a fresh interval for its new runtime.
        try await idleWaitUntil("follow-up idle timer armed") { fixture.clock.pendingCount == 1 }
    }

    func testClaudeDelegatedIdleDurableFollowUpSendsExactlyOneTruthfulHandoffToTheProvider() async throws {
        let lane = try await RecoveryLaneFixture.make("idle-release-durable-follow-up")
        defer { lane.tearDown() }
        let recorder = LifecycleRecorder()
        let first = idleController(recorder, label: "durable-first", sessionID: "durable-first-session")
        let second = idleController(recorder, label: "durable-second", sessionID: "durable-second-session")
        let fixture = makeIdleReleaseFixture(
            recorder: recorder,
            controllers: [first, second],
            session: lane.boundTabSession()
        )
        let session = fixture.session
        session.recoveryAdmissionMode = .mandatory

        let firstItem = AgentChatItem.user("first task", sequenceIndex: session.nextSequenceIndex)
        try await runIdleReleaseTurn(
            fixture,
            controller: first,
            text: "first task",
            item: firstItem,
            identity: lane.queuedIdentity("first task", userItemID: firstItem.id)
        )
        try await releaseIdleRuntime(fixture)

        let followUpItem = AgentChatItem.user("follow-up task", sequenceIndex: session.nextSequenceIndex)
        try await runIdleReleaseTurn(
            fixture,
            controller: second,
            text: "follow-up task",
            item: followUpItem,
            identity: lane.queuedIdentity("follow-up task", userItemID: followUpItem.id)
        )

        let secondStarts = await second.recordedStartExistingSessionIDs()
        XCTAssertEqual(secondStarts, [nil])
        let sent = await second.recordedSentMessages()
        assertProviderReceivedIdleHandoff(
            sent,
            followUp: "follow-up task",
            transcriptMarker: "durable-first answer"
        )
        XCTAssertEqual(session.providerSessionID, "durable-second-session")
        XCTAssertFalse(session.pendingHandoff.hasPayload, "the delivered handoff is consumed")
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    func testClaudeDelegatedIdleFollowUpWithExistingPayloadStartsFreshAndDeliversThatPayload() async throws {
        let recorder = LifecycleRecorder()
        let first = idleController(recorder, label: "payload-first", sessionID: "payload-first-session")
        let second = idleController(recorder, label: "payload-second", sessionID: "payload-second-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [first, second])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: first, text: "first task")
        try await releaseIdleRuntime(fixture)
        XCTAssertEqual(session.claudeIdleReleasedConversationID, "payload-first-session")

        let existingPayloadID = UUID()
        session.pendingHandoff = AgentPendingHandoffState(
            payload: "existing payload delivery_id=existing-delivery",
            payloadID: existingPayloadID
        )

        try await runIdleReleaseTurn(fixture, controller: second, text: "follow-up task")

        let secondStarts = await second.recordedStartExistingSessionIDs()
        XCTAssertEqual(secondStarts, [nil], "a pending payload does not turn the fresh start into a resume")
        // The existing payload (not a replacement) was the staged one: the host consumed it only
        // because the provider write's stage carried `existingPayloadID`.
        XCTAssertFalse(session.pendingHandoff.hasPayload, "the existing payload was delivered and consumed")
        XCTAssertNotEqual(session.pendingHandoff.payloadID, existingPayloadID)
        let sent = await second.recordedSentMessages()
        XCTAssertEqual(sent.count, 1)
        let message = try XCTUnwrap(sent.first)
        XCTAssertEqual(message.components(separatedBy: "existing payload").count - 1, 1)
        XCTAssertEqual(message.components(separatedBy: "delivery_id=").count - 1, 1)
        XCTAssertTrue(message.contains("delivery_id=existing-delivery"))
        XCTAssertFalse(message.contains(Self.idleHandoffWording), "the existing payload is never displaced")
        XCTAssertTrue(message.contains("follow-up task"))
        XCTAssertNil(session.claudeIdleReleasedConversationID)
        XCTAssertEqual(session.providerSessionID, "payload-second-session")
    }

    /// B P2-4: after the idle handoff was delivered and consumed by the production host, a second
    /// follow-up on the same fresh runtime carries no handoff again.
    func testClaudeDelegatedIdleSecondFollowUpCarriesNoHandoffAgain() async throws {
        let recorder = LifecycleRecorder()
        let first = idleController(recorder, label: "twice-first", sessionID: "twice-first-session")
        let second = idleController(recorder, label: "twice-second", sessionID: "twice-second-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [first, second])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: first, text: "first task")
        try await releaseIdleRuntime(fixture)
        try await runIdleReleaseTurn(fixture, controller: second, text: "follow-up one")
        XCTAssertFalse(session.pendingHandoff.hasPayload)
        try await runIdleReleaseTurn(fixture, controller: second, text: "follow-up two")

        XCTAssertEqual(fixture.factoryInvocationCount(), 2, "the second follow-up reuses the fresh runtime")
        let sent = await second.recordedSentMessages()
        XCTAssertEqual(sent.count, 2)
        assertProviderReceivedIdleHandoff(
            Array(sent.prefix(1)),
            followUp: "follow-up one",
            transcriptMarker: "twice-first answer"
        )
        let secondMessage = try XCTUnwrap(sent.last)
        XCTAssertFalse(secondMessage.contains(Self.idleHandoffWording))
        XCTAssertFalse(secondMessage.contains("delivery_id="))
        XCTAssertTrue(secondMessage.contains("follow-up two"))
    }

    /// B P2-3: the fresh-start intent belongs to the delegated tab it was recorded for; a tab whose
    /// provenance changed resumes ordinarily with no idle-release wording.
    func testClaudeDelegatedIdleMarkerIsNotConsumedAfterProvenanceChange() async throws {
        let recorder = LifecycleRecorder()
        let first = idleController(recorder, label: "origin-first", sessionID: "origin-first-session")
        let second = idleController(recorder, label: "origin-second", sessionID: "origin-first-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [first, second])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: first, text: "first task")
        try await releaseIdleRuntime(fixture)
        XCTAssertEqual(session.claudeIdleReleasedConversationID, "origin-first-session")

        session.origin = .user
        try await runIdleReleaseTurn(fixture, controller: second, text: "user follow-up")

        let secondStarts = await second.recordedStartExistingSessionIDs()
        XCTAssertEqual(secondStarts, ["origin-first-session"], "ordinary resume")
        XCTAssertNil(session.claudeIdleReleasedConversationID)
        let sent = await second.recordedSentMessages()
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(try XCTUnwrap(sent.first).contains(Self.idleHandoffWording))
        XCTAssertFalse(fixture.coordinator.test_idleRuntimeReleaseEvents.contains { $0.hasPrefix("fresh-start:") })
    }

    func testClaudeDelegatedIdleDelayedShutdownIsJoinedBySuccessorThatStartsFresh() async throws {
        let recorder = LifecycleRecorder()
        let shutdownGate = LifecycleAsyncGate()
        let first = LifecycleFakeNativeController(
            recorder: recorder,
            label: "delayed",
            shutdownGate: shutdownGate,
            emittedAssistantTextOnSend: "delayed answer",
            sessionID: "delayed-session"
        )
        let successor = idleController(recorder, label: "delayed-successor", sessionID: "delayed-successor-session")
        let fixture = makeIdleReleaseFixture(recorder: recorder, controllers: [first, successor])
        let session = fixture.session

        try await runIdleReleaseTurn(fixture, controller: first, text: "task")
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await shutdownGate.waitUntilArrived()
        XCTAssertTrue(fixture.coordinator.test_isIdleRuntimeReleaseRetiring(for: session))
        XCTAssertNil(session.claudeController)

        session.runState = .running
        session.beginRunAttempt(source: "test.idleSuccessor")
        let ensure = Task {
            await fixture.coordinator.ensureClaudeNativeSession(session: session)
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.factoryInvocationCount(), 1, "the successor waits for the retiring runtime")
        // Cancellation of armed timers never interrupts a release already retiring.
        fixture.coordinator.cancelArmedIdleRuntimeRelease(for: session.tabID, reason: "test-cancel")
        XCTAssertTrue(fixture.coordinator.test_isIdleRuntimeReleaseRetiring(for: session))

        await shutdownGate.release()
        await timer.value
        await ensure.value

        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("stale:superseded-during-release"))
        XCTAssertEqual(recorder.events.count(where: { $0 == "delayed:shutdown" }), 1)
        let shutdownIndex = try XCTUnwrap(recorder.events.firstIndex(of: "delayed:shutdown"))
        let successorStartIndex = try XCTUnwrap(recorder.events.firstIndex(of: "delayed-successor:start"))
        XCTAssertLessThan(shutdownIndex, successorStartIndex)
        XCTAssertTrue(session.claudeController === successor)
        XCTAssertNotNil(session.runID, "the successor's run identity is untouched by the stale release")
        let successorStarts = await successor.recordedStartExistingSessionIDs()
        XCTAssertEqual(successorStarts, [nil])
        XCTAssertEqual(session.providerSessionID, "delayed-successor-session")
        XCTAssertTrue(session.pendingHandoff.payload?.contains(Self.idleHandoffWording) == true)
        XCTAssertFalse(recorder.contains("delayed-successor:shutdown"))
    }

    // MARK: - Fixture

    private struct IdleReleaseFixture {
        let harness: LifecycleHarness
        let session: AgentTabSession
        let clock: IdleReleaseManualClock
        let factoryInvocationCount: () -> Int

        @MainActor var coordinator: ClaudeAgentModeCoordinator {
            harness.host.claudeCoordinator
        }
    }

    private func idleController(
        _ recorder: LifecycleRecorder,
        label: String,
        sessionID: String
    ) -> LifecycleFakeNativeController {
        LifecycleFakeNativeController(
            recorder: recorder,
            label: label,
            emittedAssistantTextOnSend: "\(label) answer",
            sessionID: sessionID
        )
    }

    private func idleApprovalRequest() -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .claudeControl("idle-approval"),
            method: "can_use_tool",
            kind: .commandExecution,
            threadID: "thread",
            turnID: "idle-approval",
            itemID: "idle-approval"
        )
    }

    /// B P1-3: every interaction/work field whose change notifies the idle interval, applied and
    /// cleared through its real session field, so the expiry predicate (`hasBindingBlockingInteraction`
    /// and the coordinator fences) is exercised for each one, not only the notifier.
    private func idleInteractionBlockerMatrix(
        session: AgentTabSession,
        host: AgentModeViewModel
    ) -> [(reason: String, apply: () -> Void, clear: () -> Void)] {
        let userInput = AgentRequestUserInputRequest(
            requestID: .string("idle-user-input"),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            questions: [
                AgentRequestUserInputQuestion(
                    id: "q1",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: []
                )
            ]
        )
        let elicitation = AgentMCPElicitationRequest(
            remoteInteractionID: "idle-elicitation",
            requestID: .string("idle-elicitation"),
            method: "mcp_elicitation",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            title: "MCP Elicitation",
            prompt: "Provide value",
            rawParamsJSON: "{}"
        )
        let permissions = AgentPermissionsRequest(
            requestID: .string("idle-permissions"),
            method: "permissions",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            cwd: "/tmp",
            permissionsJSON: "{}"
        )
        let review = PendingApplyEditsReview(
            scope: host.applyEditsScope(for: session.tabID),
            path: "idle.swift",
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
        )
        return [
            ("interaction", { session.pendingApproval = self.idleApprovalRequest() }, { session.pendingApproval = nil }),
            ("interaction", { session.pendingPermissionsRequest = permissions }, { session.pendingPermissionsRequest = nil }),
            ("interaction", { session.pendingUserInputRequest = userInput }, { session.pendingUserInputRequest = nil }),
            ("interaction", { session.pendingMCPElicitationRequest = elicitation }, { session.pendingMCPElicitationRequest = nil }),
            ("interaction", { session.pendingApplyEditsReview = review }, { session.pendingApplyEditsReview = nil }),
            ("interaction", { session.queuedUserInputRequests = [userInput] }, { session.queuedUserInputRequests = [] }),
            ("interaction", { session.queuedMCPElicitationRequests = [elicitation] }, { session.queuedMCPElicitationRequests = [] }),
            (
                "interaction",
                {
                    Task { @MainActor in
                        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UserInstructionResponse, Error>) in
                            session.instructionContinuation = continuation
                        }
                    }
                },
                {
                    session.instructionContinuation?.resume(throwing: CancellationError())
                    session.instructionContinuation = nil
                }
            ),
            ("interaction", { session.resolvingWorktreeMergeReviewOperationIDs = ["idle-merge"] }, { session.resolvingWorktreeMergeReviewOperationIDs = [] }),
            (
                "queued-work",
                { session.pendingInstructions = [AgentPendingInstruction(text: "queued", identity: .inactiveForTesting(in: session))] },
                { session.pendingInstructions = [] }
            ),
            ("superseding-completion", { session.claudeExpectedTurnIDs = [UUID()] }, { session.claudeExpectedTurnIDs = [] }),
            ("run-active", { session.terminalCommitInProgress = true }, { session.terminalCommitInProgress = false }),
            ("location-transition", { session.isPreparingInitialWorktree = true }, { session.isPreparingInitialWorktree = false }),
            ("location-transition", { session.isChangingExecutionLocation = true }, { session.isChangingExecutionLocation = false })
        ]
    }

    private func makeIdleReleaseFixture(
        recorder: LifecycleRecorder,
        controllers: [LifecycleFakeNativeController],
        origin: AgentSessionOrigin = .mcp(clientID: "idle-release-test"),
        session providedSession: AgentTabSession? = nil,
        clockIgnoresCancellation: Bool = false,
        publishTerminalCommitResult: ((
            AgentTabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult)? = nil,
        handleBackgroundNativeStreamResult: ((AIStreamResult, UUID) async -> Void)? = nil
    ) -> IdleReleaseFixture {
        var factoryInvocations = 0
        let session = providedSession ?? AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.origin = origin
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                let controller = controllers[min(factoryInvocations, controllers.count - 1)]
                factoryInvocations += 1
                return controller
            },
            publishTerminalCommitResult: publishTerminalCommitResult,
            handleHeadlessStreamResult: { [weak session] result in
                guard let session, result.type == "assistant", let text = result.text else { return }
                session.appendItem(.assistant(text, sequenceIndex: session.nextSequenceIndex))
            },
            handleBackgroundNativeStreamResult: handleBackgroundNativeStreamResult,
            autoSignalACPRouting: true,
            // The production host settles (consumes on `.sent`) the exact staged handoff.
            recordsPendingHandoffSendOutcomeThroughHost: true
        )
        harness.host.test_installLiveSession(session)
        let clock = IdleReleaseManualClock(ignoresCancellation: clockIgnoresCancellation)
        harness.host.claudeCoordinator.test_setIdleRuntimeReleaseClock { nanoseconds in
            try await clock.sleep(nanoseconds)
        }
        return IdleReleaseFixture(
            harness: harness,
            session: session,
            clock: clock,
            factoryInvocationCount: { factoryInvocations }
        )
    }

    /// One complete delegated turn. `acknowledgeSave` stands in for the host's clean save receipt
    /// (`isDirty = false`), which the release waits for.
    private func runIdleReleaseTurn(
        _ fixture: IdleReleaseFixture,
        controller: LifecycleFakeNativeController,
        text: String,
        item: AgentChatItem? = nil,
        identity: AgentQueuedInputIdentity? = nil,
        acknowledgeSave: Bool = true
    ) async throws {
        let session = fixture.session
        session.appendItem(item ?? .user(text, sequenceIndex: session.nextSequenceIndex))
        let outcome = await fixture.harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: text,
            initialMessageForRun: text,
            attachments: [],
            inputConstituents: [identity ?? AgentQueuedInputIdentity.inactiveForTesting(in: session)]
        )
        XCTAssertNil(outcome)
        let agentTask = try XCTUnwrap(session.agentTask)
        let turnID = await controller.waitForPendingTurnCompletion()
        try await idleWaitUntil("turn \(text) expected") { session.claudeExpectedTurnIDs.contains(turnID) }
        await controller.emitPendingTurnCompletion()
        await agentTask.value
        if acknowledgeSave {
            session.isDirty = false
        }
    }

    /// Elapses the armed full interval and waits for the release to finish.
    private func releaseIdleRuntime(_ fixture: IdleReleaseFixture) async throws {
        try await idleWaitUntil("idle timer armed") { fixture.clock.pendingCount == 1 }
        let timer = try XCTUnwrap(fixture.coordinator.test_idleRuntimeReleaseTask(for: fixture.session))
        XCTAssertTrue(fixture.clock.fireOldest())
        await timer.value
        XCTAssertNil(fixture.session.claudeController)
        XCTAssertTrue(fixture.coordinator.test_idleRuntimeReleaseEvents.contains("released:idle-interval"))
    }

    /// The provider's recorded write carries exactly one idle-continuation handoff (truthful
    /// wording, one delivery ID, the prior transcript once) followed by the follow-up text.
    private func assertProviderReceivedIdleHandoff(
        _ sent: [String],
        followUp: String,
        transcriptMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sent.count, 1, "one provider write", file: file, line: line)
        guard let message = sent.first else { return }
        func occurrences(_ needle: String) -> Int {
            message.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(occurrences(Self.idleHandoffWording), 1, file: file, line: line)
        XCTAssertEqual(occurrences("Nothing failed."), 1, file: file, line: line)
        XCTAssertEqual(occurrences("delivery_id="), 1, file: file, line: line)
        XCTAssertEqual(occurrences(transcriptMarker), 1, "the prior transcript is carried once", file: file, line: line)
        XCTAssertEqual(occurrences(Self.genuineResumeFailureWording), 0, file: file, line: line)
        XCTAssertTrue(message.hasSuffix(followUp) || message.contains(followUp), file: file, line: line)
        if let handoffRange = message.range(of: Self.idleHandoffWording),
           let followUpRange = message.range(of: followUp, options: .backwards)
        {
            XCTAssertLessThan(handoffRange.lowerBound, followUpRange.lowerBound, "handoff precedes the follow-up", file: file, line: line)
        }
    }

    private func idleWaitUntil(
        _ message: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 2000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(message)")
        throw CancellationError()
    }
}

/// Injected idle-release clock: records each requested interval and suspends until the test fires
/// it. Cancellation throws synchronously (lock-protected), unless the clock ignores cancellation to
/// model a timer that wakes after it was superseded.
final class IdleReleaseManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        /// The sleeping task was cancelled (its interval was superseded). Only tracked by clocks
        /// that ignore cancellation, whose cancelled sleepers stay pending.
        var superseded: Bool
    }

    private let lock = NSLock()
    private let ignoresCancellation: Bool
    private var sleepers: [Sleeper] = []
    private var requested: [UInt64] = []
    private var cancelled = 0

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    var pendingCount: Int {
        lock.withLock { sleepers.count }
    }

    var requestedIntervals: [UInt64] {
        lock.withLock { requested }
    }

    var cancelledCount: Int {
        lock.withLock { cancelled }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                requested.append(nanoseconds)
                if Task.isCancelled, !ignoresCancellation {
                    cancelled += 1
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, continuation: continuation, superseded: Task.isCancelled))
                lock.unlock()
            }
        } onCancel: {
            guard !ignoresCancellation else {
                // A sleeper not yet registered sees `Task.isCancelled` when it registers.
                lock.withLock {
                    if let index = sleepers.firstIndex(where: { $0.id == id }) {
                        sleepers[index].superseded = true
                    }
                }
                return
            }
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                cancelled += 1
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Elapses the oldest pending interval. Returns false when none is pending.
    @discardableResult
    func fireOldest() -> Bool {
        let sleeper: Sleeper? = lock.withLock {
            sleepers.isEmpty ? nil : sleepers.removeFirst()
        }
        guard let sleeper else { return false }
        sleeper.continuation.resume()
        return true
    }

    /// Pending sleepers whose task was cancelled (clocks that ignore cancellation only).
    var supersededCount: Int {
        lock.withLock { sleepers.count(where: \.superseded) }
    }

    /// Elapses the oldest pending superseded interval, independent of the order in which
    /// concurrently started timer tasks registered. Returns false when none is pending.
    @discardableResult
    func fireOldestSuperseded() -> Bool {
        let sleeper: Sleeper? = lock.withLock {
            guard let index = sleepers.firstIndex(where: \.superseded) else { return nil }
            return sleepers.remove(at: index)
        }
        guard let sleeper else { return false }
        sleeper.continuation.resume()
        return true
    }

    /// Cleanup for clocks that ignore cancellation: ends every pending sleeper.
    func resumeAllThrowing() {
        let pending: [Sleeper] = lock.withLock {
            let pending = sleepers
            sleepers.removeAll()
            return pending
        }
        for sleeper in pending {
            sleeper.continuation.resume(throwing: CancellationError())
        }
    }
}
