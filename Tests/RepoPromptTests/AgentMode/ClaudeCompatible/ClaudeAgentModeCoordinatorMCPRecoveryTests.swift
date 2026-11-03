import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// WS2: a Claude launch whose RepoPrompt MCP connection was lost is restarted at the next turn
/// boundary, resuming the same conversation with the same launch configuration, and a turn is
/// submitted only after fresh RepoPrompt MCP connected evidence.
@MainActor
extension AgentModeRunServiceLifecycleTests {
    func testUnhealthyRepoPromptMCPLaunchRestartsWithResumeAndProbesBeforeSend() async {
        await assertUnhealthyLaunchRestartsWithResumeAndProbesBeforeSend(reason: .toolExecutionWatchdog)
    }

    /// WS5: an idle launch marked unhealthy by a helper exit or an unrestored route recovers at
    /// the next turn exactly like the watchdog case: the coordinator never looks at the reason.
    func testHelperExitUnhealthyLaunchRestartsExactlyLikeTheWatchdogCase() async {
        await assertUnhealthyLaunchRestartsWithResumeAndProbesBeforeSend(reason: .helperExited)
        await assertUnhealthyLaunchRestartsWithResumeAndProbesBeforeSend(reason: .routeNotRestored)
    }

    private func assertUnhealthyLaunchRestartsWithResumeAndProbesBeforeSend(
        reason: AgentMCPRunConnectionLoss.Reason
    ) async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: reason.rawValue))
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "recovered",
            sessionID: "mcp-recovery-conversation"
        )
        var factorySettings: [ClaudeAgentModeCoordinator.ControllerLaunchSettings] = []
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, settings in
                recorder.record("factory:recovery")
                factorySettings.append(settings)
                return recoveredController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)
        let launchSettingsBeforeRecovery = harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session)

        let didSend = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "next turn after watchdog",
            attachments: []
        )

        XCTAssertTrue(didSend)
        assertOrderedEvents([
            "unhealthy:shutdown",
            "factory:recovery",
            "recovered:start",
            "recovered:mcp-probe",
            "recovered:send"
        ], in: recorder)
        XCTAssertFalse(recorder.contains("unhealthy:send"))
        XCTAssertEqual(factorySettings.count, 1)
        XCTAssertEqual(factorySettings.first, launchSettingsBeforeRecovery)
        let resumedSessionIDs = await recoveredController.recordedStartExistingSessionIDs()
        XCTAssertEqual(resumedSessionIDs, ["mcp-recovery-conversation"])
        let probeCount = await recoveredController.recordedRepoPromptMCPProbeCount()
        XCTAssertEqual(probeCount, 1)
        let sentMessages = await recoveredController.recordedSentMessages()
        XCTAssertEqual(sentMessages, ["next turn after watchdog"])
        XCTAssertEqual(session.providerSessionID, "mcp-recovery-conversation")
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
        XCTAssertNil(session.recoveryResumeFallbackSuppressedConversationID)
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        // An idle launch is restarted between turns: no running turn was stopped.
        XCTAssertFalse(session.items.contains {
            $0.text == ClaudeAgentModeCoordinator.repoPromptMCPStoppedRunningTurnNotice
        })
    }

    func testRepoPromptMCPRecoveryWithoutConnectedEvidenceDoesNotSubmit() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "not-reconnected",
            sessionID: "mcp-recovery-conversation"
        )
        await recoveredController.setRepoPromptMCPProbe(outcome: .notConnected("timed out"))
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return recoveredController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let didSend = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "must not be written",
            attachments: []
        )

        XCTAssertFalse(didSend)
        XCTAssertEqual(factoryInvocationCount, 1)
        let probeCount = await recoveredController.recordedRepoPromptMCPProbeCount()
        XCTAssertEqual(probeCount, 1)
        XCTAssertFalse(recorder.contains("unhealthy:send"))
        XCTAssertFalse(recorder.contains("not-reconnected:send"))
        let sentMessages = await recoveredController.recordedSentMessages()
        XCTAssertTrue(sentMessages.isEmpty)
        assertOrderedEvents([
            "unhealthy:shutdown",
            "not-reconnected:start",
            "not-reconnected:mcp-probe",
            "not-reconnected:shutdown"
        ], in: recorder)
        XCTAssertNil(session.claudeController)
        XCTAssertEqual(session.runState, .failed)
        let errors = session.items.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.text.contains("did not reconnect") == true)
        XCTAssertTrue(errors.first?.text.contains("Nothing was sent") == true)
        // The conversation is kept for the next attempt; nothing fresh replaced it.
        XCTAssertEqual(session.providerSessionID, "mcp-recovery-conversation")
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session),
            "mcp-recovery-conversation"
        )
        XCTAssertNil(session.pendingHandoff.payload)
    }

    func testRepoPromptMCPRecoveryNeverFallsBackToFreshConversation() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let resumeFailingController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "resume-unavailable",
            // A launch whose resume failed has no session (as the real controller reports).
            hasActiveSession: false,
            failResumeStart: true,
            sessionID: "mcp-recovery-conversation"
        )
        let freshController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fresh-unexpected",
            sessionID: "fresh-conversation"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? resumeFailingController : freshController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        session.appendItem(.user("prior request", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(.assistant("prior answer", sequenceIndex: session.nextSequenceIndex))
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let didSend = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "must not reach a fresh conversation",
            attachments: []
        )

        XCTAssertFalse(didSend)
        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertFalse(recorder.contains("fresh-unexpected:start"))
        XCTAssertFalse(recorder.contains(prefix: "resume-unavailable:send"))
        let resumeAttempts = await resumeFailingController.recordedStartExistingSessionIDs()
        XCTAssertEqual(resumeAttempts, ["mcp-recovery-conversation"])
        XCTAssertEqual(session.recoveryResumeUnavailableConversationID, "mcp-recovery-conversation")
        XCTAssertNil(session.pendingHandoff.payload)
    }

    func testConcurrentRepoPromptMCPRecoveryPreparationsCoalesce() async {
        let recorder = LifecycleRecorder()
        let startGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "recovered",
            startGate: startGate,
            sessionID: "mcp-recovery-conversation"
        )
        let unexpectedController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unexpected"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? recoveredController : unexpectedController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let firstEnsure = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await startGate.waitUntilArrived()
        let joiningEnsure = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await Task.yield()
        await startGate.release()
        await firstEnsure.value
        await joiningEnsure.value

        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertEqual(recorder.events.count { $0 == "unhealthy:shutdown" }, 1)
        XCTAssertFalse(recorder.contains("unexpected:start"))
        let maximumConcurrentStarts = await recoveredController.maximumConcurrentStartInvocationCount()
        XCTAssertEqual(maximumConcurrentStarts, 1)
        let probeCount = await recoveredController.recordedRepoPromptMCPProbeCount()
        XCTAssertEqual(probeCount, 1)
        guard let installedController = session.claudeController else {
            return XCTFail("Expected the recovered controller to be installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(recoveredController as AnyObject)
        )
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
        XCTAssertEqual(session.runState, .running)
    }

    func testSupersededRecoveryEvidenceCannotFailNewerLaunch() async {
        let recorder = LifecycleRecorder()
        let probeGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let recoveringController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "superseded-recovery",
            sessionID: "mcp-recovery-conversation"
        )
        await recoveringController.setRepoPromptMCPProbe(outcome: .notConnected("timed out"), gate: probeGate)
        let newerController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "newer",
            sessionID: "mcp-recovery-conversation"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in recoveringController }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await probeGate.waitUntilArrived()
        session.claudeController = newerController
        await probeGate.release()
        await ensureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the newer controller to remain installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(newerController as AnyObject)
        )
        XCTAssertFalse(recorder.contains("newer:shutdown"))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testQueuedSteeringRecoversUnhealthyLaunchWithTurnInFlightOnce() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy-in-flight",
            hasTurnInFlight: true,
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "recovered",
            sessionID: "mcp-recovery-conversation"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return recoveredController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)
        session.pendingClaudeSteeringInstructions = [
            makeClaudeSteeringInstruction(session: session, text: "steer after watchdog")
        ]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await session.claudeSteeringFlushTask?.value

        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertFalse(recorder.contains("unhealthy-in-flight:send"))
        assertOrderedEvents([
            "unhealthy-in-flight:interrupt:interrupt",
            "unhealthy-in-flight:shutdown",
            "recovered:start",
            "recovered:mcp-probe",
            "recovered:send"
        ], in: recorder)
        let resumedSessionIDs = await recoveredController.recordedStartExistingSessionIDs()
        XCTAssertEqual(resumedSessionIDs, ["mcp-recovery-conversation"])
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        // The user is told the running turn was stopped to reconnect RepoPrompt tools.
        let notices = session.items.filter {
            $0.kind == .system && $0.text == ClaudeAgentModeCoordinator.repoPromptMCPStoppedRunningTurnNotice
        }
        XCTAssertEqual(notices.count, 1)
    }

    func testHealthyRepoPromptMCPLaunchIsReusedWithoutRestartOrProbe() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "healthy",
            sessionID: "healthy-conversation"
        )
        await controller.setRepoPromptMCPHealth(.connected)
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return controller
            }
        )
        let session = makeRunningClaudeSession(controller: controller)
        session.providerSessionID = "healthy-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let didSend = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "healthy turn",
            attachments: []
        )

        XCTAssertTrue(didSend)
        XCTAssertEqual(factoryInvocationCount, 0)
        XCTAssertFalse(recorder.contains("healthy:shutdown"))
        XCTAssertFalse(recorder.contains("healthy:mcp-probe"))
        XCTAssertTrue(recorder.contains("healthy:send"))
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
    }

    // MARK: - Loss during a running turn (end to end)

    /// A loss lands mid-turn: the events a real controller emits for it (delivered through its
    /// production loss handler and forwarded verbatim into the running turn) are non-terminal —
    /// the run keeps running and keeps processing stream events until its turn completes — and the
    /// next send restarts Claude resuming the conversation, proving RepoPrompt MCP before writing.
    func testRepoPromptMCPLossDuringRunningTurnIsNonTerminalAndNextSendRecovers() async throws {
        try await assertLossDuringRunningTurnIsNonTerminalAndNextSendRecovers(reason: .toolExecutionWatchdog)
    }

    /// WS5: the helper-exit loss of a real controller, landing mid-turn, is handled exactly like
    /// the watchdog loss: non-terminal for the running turn, recovered at the next send.
    func testHelperExitLossDuringRunningTurnRecoversExactlyLikeTheWatchdog() async throws {
        try await assertLossDuringRunningTurnIsNonTerminalAndNextSendRecovers(reason: .helperExited)
    }

    private func assertLossDuringRunningTurnIsNonTerminalAndNextSendRecovers(
        reason: AgentMCPRunConnectionLoss.Reason
    ) async throws {
        let lossEvents = try await realControllerRepoPromptMCPLossEvents(reason: reason)
        XCTAssertTrue(lossEvents.contains { event in
            if case .error = event { return true }
            return false
        })
        XCTAssertTrue(lossEvents.contains { event in
            if case let .runtimeInit(status) = event { return status.repoPromptMCPHealth.isUnhealthy }
            return false
        })

        let recorder = LifecycleRecorder()
        let firstSendGate = LifecycleAsyncGate()
        let lostController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "lost",
            sendUserMessageGate: firstSendGate,
            emittedAssistantTextOnSend: "answer before the loss"
        )
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "recovered",
            emittedAssistantTextOnSend: "answer after recovery"
        )
        var factoryInvocationCount = 0
        var transcriptSession: AgentTabSession?
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? lostController : recoveredController
            },
            handleHeadlessStreamResult: { result in
                if let transcriptSession, let text = result.text {
                    transcriptSession.appendItem(.assistant(text, sequenceIndex: transcriptSession.nextSequenceIndex))
                }
            },
            autoSignalACPRouting: true
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        transcriptSession = session

        let firstOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "first turn",
            initialMessageForRun: "first turn",
            attachments: []
        )
        XCTAssertNil(firstOutcome)
        try await waitUntil("first turn written", recorder) { recorder.contains("lost:send") }
        await firstSendGate.release()
        let firstTurnID = try await pendingTurnID(of: lostController, recorder)
        try await waitUntil("first turn expected", recorder) { session.claudeExpectedTurnIDs.contains(firstTurnID) }

        // The loss lands while the turn is running; Claude keeps streaming afterwards.
        await lostController.setRepoPromptMCPHealth(.unhealthy(reason: reason.rawValue))
        for event in lossEvents {
            await lostController.emitRuntimeEvent(event)
        }
        await lostController.emitAssistantText("answer after the loss")
        try await waitUntil("stream event after the loss processed", recorder) {
            session.items.contains { $0.kind == .assistant && $0.text == "answer after the loss" }
        }
        XCTAssertEqual(session.runState, .running, "the loss is not terminal for the running turn")
        let lossErrors = session.items.filter { $0.kind == .error }
        XCTAssertEqual(lossErrors.count, 1)
        XCTAssertTrue(lossErrors.first?.text.contains("RepoPrompt MCP disconnected") == true)

        await lostController.emitPendingTurnCompletion()
        try await waitUntil("first run completed", recorder) { session.runState == .completed }
        XCTAssertFalse(recorder.contains("lost:shutdown"), "nothing restarts mid-turn")

        let secondOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "second turn",
            initialMessageForRun: "second turn",
            attachments: []
        )
        XCTAssertNil(secondOutcome)
        try await waitUntil("second turn written after recovery", recorder) { recorder.contains("recovered:send") }
        let secondTurnID = try await pendingTurnID(of: recoveredController, recorder)
        try await waitUntil("second turn expected", recorder) { session.claudeExpectedTurnIDs.contains(secondTurnID) }
        await recoveredController.emitPendingTurnCompletion()
        try await waitUntil("second run completed", recorder) { session.runState == .completed }

        assertOrderedEvents([
            "lost:send",
            "lost:shutdown",
            "recovered:start",
            "recovered:mcp-probe",
            "recovered:send"
        ], in: recorder)
        XCTAssertEqual(factoryInvocationCount, 2)
        let lostSends = await lostController.recordedSentMessages()
        XCTAssertEqual(lostSends.count, 1, "the second turn never reaches the unhealthy launch")
        let recoveredSends = await recoveredController.recordedSentMessages()
        XCTAssertEqual(recoveredSends.count, 1, "no replay: only the new turn is written")
        XCTAssertTrue(recoveredSends.first?.contains("second turn") == true)
        XCTAssertFalse(recoveredSends.first?.contains("first turn") == true)
        let resumedSessionIDs = await recoveredController.recordedStartExistingSessionIDs()
        XCTAssertEqual(resumedSessionIDs, ["lifecycle-claude-session"])
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["answer before the loss", "answer after the loss", "answer after recovery"]
        )
    }

    // MARK: - Supersession and inactive failure

    /// The recovered launch fails its evidence and is retired; while that retirement is in
    /// flight a newer attempt takes the tab. The stale confirmation must not fail it.
    func testRecoveryFailureSupersededDuringRetirementChangesNothing() async {
        let recorder = LifecycleRecorder()
        let retirementGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let notReconnected = LifecycleFakeNativeController(
            recorder: recorder,
            label: "not-reconnected",
            shutdownGate: retirementGate,
            sessionID: "mcp-recovery-conversation"
        )
        await notReconnected.setRepoPromptMCPProbe(outcome: .notConnected("timed out"))
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in notReconnected }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await retirementGate.waitUntilArrived()
        session.beginRunAttempt(source: "superseding-attempt")
        let supersedingAttemptID = session.activeRunAttemptID
        await retirementGate.release()
        await ensureTask.value

        XCTAssertTrue(recorder.contains("not-reconnected:mcp-probe"))
        XCTAssertEqual(session.activeRunAttemptID, supersedingAttemptID)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session),
            "mcp-recovery-conversation",
            "the recovery stays pending for the superseding attempt"
        )
    }

    /// The run ends while the failed launch is being retired: no dispatch is active any more, so
    /// nothing is failed or appended, and the recovery stays pending for the next dispatch.
    func testRecoveryFailureAfterRunEndedDuringRetirementDoesNotFinalize() async {
        let recorder = LifecycleRecorder()
        let retirementGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let notReconnected = LifecycleFakeNativeController(
            recorder: recorder,
            label: "not-reconnected",
            shutdownGate: retirementGate,
            sessionID: "mcp-recovery-conversation"
        )
        await notReconnected.setRepoPromptMCPProbe(outcome: .notConnected("timed out"))
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in notReconnected }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await retirementGate.waitUntilArrived()
        session.runState = .idle
        await retirementGate.release()
        await ensureTask.value

        XCTAssertEqual(session.runState, .idle)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session),
            "mcp-recovery-conversation"
        )
        assertNoRecoveryStatus(on: session)
    }

    /// Preparation outside a dispatch restarts an unhealthy launch with a conversation: recovery
    /// is armed for the next dispatch, but the idle tab never shows a recovery status.
    func testRecoveryArmedOutsideDispatchLeavesNoStatusOnTheIdleTab() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        let successor = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor",
            sessionID: "mcp-recovery-conversation"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in successor }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        session.runState = .idle
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        XCTAssertTrue(recorder.contains("unhealthy:shutdown"))
        XCTAssertFalse(recorder.contains("successor:send"))
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session),
            "mcp-recovery-conversation",
            "the next dispatch still proves RepoPrompt MCP before writing"
        )
        XCTAssertEqual(session.runState, .idle)
        assertNoRecoveryStatus(on: session)
    }

    private func assertNoRecoveryStatus(
        on session: AgentTabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let recoveryStatuses = [
            ClaudeAgentModeCoordinator.repoPromptMCPRestartingStatus,
            ClaudeAgentModeCoordinator.repoPromptMCPStoppedTurnStatus,
            ClaudeAgentModeCoordinator.repoPromptMCPWaitingStatus
        ]
        XCTAssertFalse(
            session.runningStatusText.map(recoveryStatuses.contains) ?? false,
            "stale recovery status on an idle tab: \(session.runningStatusText ?? "nil")",
            file: file,
            line: line
        )
    }

    /// Preparation outside a user dispatch finds an unhealthy launch with no conversation to
    /// resume: it neither finalizes the idle session as failed nor appends an error, and leaves the
    /// launch for the next dispatch to fail visibly.
    func testRecoveryWithoutConversationOutsideDispatchDoesNotFinalize() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy-no-conversation",
            sessionID: ""
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return oldController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.runState = .idle
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        XCTAssertEqual(session.runState, .idle)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertEqual(factoryInvocationCount, 0)
        XCTAssertFalse(recorder.contains("unhealthy-no-conversation:shutdown"))
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
    }

    /// A second preparation that arrives while the first is suspended in the unhealthy launch's
    /// health read joins that in-flight preparation (single flight) instead of reading health and
    /// recycling on its own: health is read once, the launch is retired once, and exactly one
    /// successor is created and proven.
    func testSecondPreparationJoinsTheInFlightHealthCheckAndRecyclesOnce() async throws {
        let recorder = LifecycleRecorder()
        let healthGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unhealthy",
            sessionID: "mcp-recovery-conversation"
        )
        await oldController.setRepoPromptMCPHealth(.unhealthy(reason: "tool_execution_watchdog"))
        await oldController.setRepoPromptMCPHealthGate(healthGate)
        let recoveredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "recovered",
            sessionID: "mcp-recovery-conversation"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return recoveredController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.providerSessionID = "mcp-recovery-conversation"
        installMatchingMCPRecoveryLaunchSettings(for: session, harness: harness)

        let firstEnsure = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await healthGate.waitUntilArrived()
        let joinsBefore = harness.host.claudeCoordinator.testPreparationJoinCount
        let secondEnsure = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        // Barrier: the second preparation has joined the first while the first is still held.
        try await waitUntil("second preparation joined", recorder) {
            harness.host.claudeCoordinator.testPreparationJoinCount == joinsBefore + 1
        }
        let readsWhileHeld = await oldController.recordedRepoPromptMCPHealthReadCount()
        XCTAssertEqual(readsWhileHeld, 1, "the joined preparation does not read health itself")
        await healthGate.release()
        await firstEnsure.value
        await secondEnsure.value

        let totalReads = await oldController.recordedRepoPromptMCPHealthReadCount()
        XCTAssertEqual(totalReads, 1)
        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertEqual(recorder.events.count { $0 == "unhealthy:shutdown" }, 1)
        let probeCount = await recoveredController.recordedRepoPromptMCPProbeCount()
        XCTAssertEqual(probeCount, 1)
        let starts = await recoveredController.recordedStartExistingSessionIDs()
        XCTAssertEqual(starts, ["mcp-recovery-conversation"])
        guard let installedController = session.claudeController else {
            return XCTFail("Expected the recovered controller to be installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(recoveredController as AnyObject)
        )
        XCTAssertNil(harness.host.claudeCoordinator.test_pendingRepoPromptMCPRecoveryConversationID(for: session))
        XCTAssertEqual(session.runState, .running)
    }

    // MARK: - Helpers

    private struct BoundedWaitTimeout: Error {}

    /// Bounded (5 s): fails with the recorded lifecycle events instead of hanging.
    private func waitUntil(
        _ what: String,
        _ recorder: LifecycleRecorder,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0 ..< 1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(what); events: \(recorder.events)", file: file, line: line)
        throw BoundedWaitTimeout()
    }

    private func pendingTurnID(
        of controller: LifecycleFakeNativeController,
        _ recorder: LifecycleRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> UUID {
        for _ in 0 ..< 1000 {
            if let turnID = await controller.currentPendingTurnCompletionID() {
                return turnID
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("No pending turn; events: \(recorder.events)", file: file, line: line)
        throw BoundedWaitTimeout()
    }

    /// The events a real Claude native controller emits when a loss of its current launch is
    /// delivered to its production loss handler (fixture pipes, no child process).
    private func realControllerRepoPromptMCPLossEvents(
        reason: AgentMCPRunConnectionLoss.Reason
    ) async throws -> [NativeAgentRuntimeEvent] {
        let pipes = [Pipe(), Pipe(), Pipe()]
        let process = SpawnedProcess(
            pid: pid_t.max,
            processGroupID: nil,
            stdin: pipes[0].fileHandleForWriting,
            stdinDescriptor: pipes[0].fileHandleForWriting.fileDescriptor,
            stdout: pipes[1].fileHandleForReading,
            stderr: pipes[2].fileHandleForReading
        )
        let runID = UUID()
        let controller = try ClaudeNativeProcessSessionController(
            runID: runID,
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: .standard, permissionMode: nil),
            mcpHost: ServerNetworkManager()
        )
        await controller.test_attachSpawnedProcess(process)
        await controller.test_registerExpectedAgentPID(process.pid)
        await controller.ensureEventsStreamReady()
        let registeredLaunch = await controller.test_currentRunConnectionLossObserverLaunch()
        let launch = try XCTUnwrap(registeredLaunch)
        await controller.noteRepoPromptMCPConnectionLost(AgentMCPRunConnectionLoss(
            runID: runID,
            connectionID: UUID(),
            clientName: "claude-code",
            launchToken: launch.token,
            agentProcessID: launch.agentProcessID,
            connectionPredatesLaunch: false,
            toolName: reason == .toolExecutionWatchdog ? "slow_tool" : nil,
            reason: reason,
            closeReason: reason == .toolExecutionWatchdog ? "tool_execution_watchdog" : "peer_eof"
        ))
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unhealthy(reason: reason.rawValue))

        // Through the protocol witness (as Agent Mode calls it).
        let runtime: any NativeAgentRuntimeControlling = controller
        let stream = await runtime.events
        let marker = UUID()
        let generation = await runtime.emitEventMarker(marker)
        guard generation != nil else {
            XCTFail("the events stream must be ready")
            return []
        }
        let collector = Task {
            var events: [NativeAgentRuntimeEvent] = []
            for await event in stream {
                if case let .marker(id) = event, id == marker { return (events, true) }
                events.append(event)
            }
            return (events, false)
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            collector.cancel()
        }
        let (events, reachedMarker) = await collector.value
        timeout.cancel()
        XCTAssertTrue(reachedMarker, "events before the marker: \(events)")
        await controller.test_detachFixtureTransport()
        _ = pipes
        return events
    }

    private func installMatchingMCPRecoveryLaunchSettings(
        for session: AgentTabSession,
        harness: LifecycleHarness
    ) {
        let providerBindingService = harness.host.providerBindingService
        let permissionMode = providerBindingService.runtimePermission(
            for: .claudeCode,
            profile: session.permissionProfile
        ).claudePermissionMode
        let preferences = providerBindingService.preferences
        let runtime = ClaudeControllerLaunchPolicy.resolve(
            permissionMode: permissionMode,
            profile: session.permissionProfile,
            defaults: preferences.defaults,
            securePermissions: preferences.securePermissions
        )
        harness.host.claudeCoordinator.test_setControllerLaunchSettings(
            .init(
                runtimeVariant: .standard,
                workspacePath: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath
                ).standardizedFileURL.path,
                permissionMode: runtime.permissionMode,
                allowNativeBashTool: runtime.allowNativeBashTool,
                mcpStrictMode: runtime.mcpStrictMode,
                sessionProfile: .standard,
                toolSearchEnabled: nil
            ),
            for: session
        )
    }
}
