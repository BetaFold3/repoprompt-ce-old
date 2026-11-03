@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// D7: a background session's `.liveMutation` refresh waits a fixed window from its first pending
/// event; freshness barriers flush only work that window deferred. Every sleep here is
/// test-controlled (released explicitly), so no test waits on wall-clock time.
@MainActor
final class AgentTranscriptBackgroundRefreshDeferralTests: XCTestCase {
    private typealias Session = AgentTabSession

    // MARK: - Delay window

    func testBackgroundFirstEventWindowMergesLaterEventsWithoutMovingDeadline() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        let buildsBefore = Self.builds(session)
        let attemptsBefore = session.transcriptPerformanceSnapshot.incrementalImportAttemptCount

        session.appendItem(.assistant("first"))
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        let generation = session.derivedTranscriptRefreshGeneration
        let task = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        XCTAssertEqual(harness.gate.requestedDelays, [.milliseconds(1500)])
        XCTAssertEqual(AgentModeViewModel.backgroundDerivedTranscriptRefreshDelay, .milliseconds(1500))

        session.appendItem(.assistant("second"))
        session.appendItem(.assistant("third"))
        await Self.yield()
        XCTAssertEqual(harness.gate.requestedDelays.count, 1, "later events do not move the deadline")
        XCTAssertEqual(session.derivedTranscriptRefreshGeneration, generation)
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertNotNil(session.pendingSourceItemsMutationSummary)
        XCTAssertEqual(Self.builds(session), buildsBefore)
        XCTAssertFalse(Self.isSynchronized(session))

        await harness.gate.release([task])
        XCTAssertEqual(Self.builds(session), buildsBefore + 1, "one refresh per window")
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertNil(session.derivedTranscriptRefreshTask)
        XCTAssertNil(session.pendingSourceItemsMutationSummary)
        XCTAssertEqual(
            session.transcriptPerformanceSnapshot.incrementalImportAttemptCount,
            attemptsBefore + 1,
            "the merged summary reaches the incremental importer"
        )
        XCTAssertTrue(Self.history(session).contains("third"))
    }

    func testContinuousBackgroundStreamRefreshesOncePerWindow() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        let buildsBefore = Self.builds(session)

        for window in 0 ..< 3 {
            session.appendItem(.assistant("window \(window) event 0"))
            let task = session.derivedTranscriptRefreshTask
            for event in 1 ..< 5 {
                session.appendItem(.assistant("window \(window) event \(event)"))
            }
            await harness.gate.waitForParked(1)
            XCTAssertEqual(harness.gate.requestedDelays.count, window + 1)
            XCTAssertEqual(Self.builds(session), buildsBefore + window)
            await harness.gate.release([task])
            XCTAssertEqual(Self.builds(session), buildsBefore + window + 1)
            XCTAssertTrue(Self.isSynchronized(session))
            XCTAssertTrue(Self.history(session).contains("window \(window) event 4"))
        }
    }

    func testActiveSessionKeepsNextTurnCoalescingWithoutDelay() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let active = harness.active
        let buildsBefore = Self.builds(active)

        active.appendItem(.assistant("active one"))
        active.appendItem(.assistant("active two"))
        XCTAssertNotNil(active.derivedTranscriptRefreshTask)
        XCTAssertFalse(active.hasDeferredDerivedTranscriptRefresh)
        await active.derivedTranscriptRefreshTask?.value

        XCTAssertEqual(Self.builds(active), buildsBefore + 1)
        XCTAssertTrue(Self.isSynchronized(active))
        XCTAssertTrue(harness.gate.requestedDelays.isEmpty, "active sessions never sleep")
    }

    func testDeferredTaskYieldsToNextTurnRefreshOnceSessionCanPublish() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        session.appendItem(.assistant("while hidden"))
        let deferredTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)

        harness.viewModel.test_setCurrentTabIDOverride(session.tabID)
        session.appendItem(.assistant("now visible"))
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        let nextTurnTask = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        await nextTurnTask.value
        let buildsAfterRefresh = Self.builds(session)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertTrue(Self.history(session).contains("while hidden"), "merged summary kept")
        XCTAssertTrue(Self.history(session).contains("now visible"))

        await harness.gate.release([deferredTask])
        XCTAssertEqual(Self.builds(session), buildsAfterRefresh, "superseded delayed task is a no-op")
    }

    // MARK: - Barriers

    func testActivationRefreshesSynchronouslyAndReleasedDeferredTaskIsNoOp() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        session.appendItem(.assistant("while hidden"))
        let deferredTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)

        harness.viewModel.test_setCurrentTabIDOverride(session.tabID)
        harness.viewModel.applySessionToBindings(session)
        let buildsAfterActivation = Self.builds(session)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertNil(session.derivedTranscriptRefreshTask)
        XCTAssertEqual(harness.viewModel.activeTranscriptPresentation.tabID, session.tabID)
        XCTAssertEqual(harness.viewModel.activeTranscriptPresentation.visibleRows.last?.text, "while hidden")

        await harness.gate.release([deferredTask])
        XCTAssertEqual(Self.builds(session), buildsAfterActivation, "released old task is a no-op")
    }

    func testTerminalTransitionFlushesDeferredWorkAfterFooter() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        session.runState = .running
        let user = AgentChatItem.user("Do the task")
        session.appendItem(user)
        let userItem = try XCTUnwrap(session.items.last)
        session.pendingTurnRuntimeAnchors.append(.init(
            userItemID: userItem.id,
            userSequenceIndex: userItem.sequenceIndex,
            startedAt: Date().addingTimeInterval(-5)
        ))
        let reply = AgentChatItem.assistant("Task finished.")
        session.appendItem(reply)
        let deferredTask = session.derivedTranscriptRefreshTask
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertFalse(Self.history(session).contains("Task finished."))

        session.runState = .completed
        let buildsAfterTerminal = Self.builds(session)
        XCTAssertNotNil(session.agentMessageRuntimeFootersByItemID[reply.id], "footer completed")
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertEqual(session.derivedTranscriptSyncState?.runState, .completed)
        XCTAssertTrue(Self.history(session).contains("Task finished."))

        await harness.gate.release([deferredTask])
        XCTAssertEqual(Self.builds(session), buildsAfterTerminal)
    }

    func testQuestionAggregateChangeCatchesUpBackgroundSessionWithoutPendingTask() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background
        let buildsBefore = Self.builds(session)

        session.pendingAskUser = try Self.pendingAskUser()
        XCTAssertEqual(Self.builds(session), buildsBefore + 1, "aggregate false -> true")
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertEqual(session.derivedTranscriptSyncState?.hidePendingQuestionToolCall, true)
        XCTAssertNil(session.derivedTranscriptRefreshTask)

        session.pendingAskUser?.draftsByQuestionID["continue"] = AgentAskUserDraft(customResponse: "draft")
        session.pendingAskUser = try Self.pendingAskUser()
        session.pendingUserInputRequest = Self.pendingUserInputRequest()
        session.pendingAskUser = nil
        XCTAssertEqual(Self.builds(session), buildsBefore + 1, "drafts, replacement, and unchanged aggregate stay silent")

        session.pendingUserInputRequest = nil
        XCTAssertEqual(Self.builds(session), buildsBefore + 2, "aggregate true -> false")
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertEqual(session.derivedTranscriptSyncState?.hidePendingQuestionToolCall, false)

        let activeBuilds = Self.builds(harness.active)
        harness.active.pendingAskUser = try Self.pendingAskUser()
        XCTAssertEqual(Self.builds(harness.active), activeBuilds, "active sessions keep their binding path")
        harness.active.pendingAskUser = nil
    }

    func testQuestionAggregateChangeFlushesPendingDeferredWork() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let session = harness.background

        session.appendItem(.assistant("before question"))
        let firstTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        session.pendingAskUser = try Self.pendingAskUser()
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertNil(session.pendingSourceItemsMutationSummary)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertTrue(Self.history(session).contains("before question"))

        session.appendItem(.assistant("while asking"))
        let secondTask = session.derivedTranscriptRefreshTask
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        session.pendingAskUser = nil
        let buildsAfterQuestions = Self.builds(session)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertTrue(Self.history(session).contains("while asking"))

        await harness.gate.release([firstTask, secondTask])
        XCTAssertEqual(Self.builds(session), buildsAfterQuestions)
    }

    func testLocalHandoffHeadlessReplayAndRevealFlushDeferredWork() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let viewModel = harness.viewModel
        let session = harness.background

        session.appendItem(.assistant("handoff text"))
        XCTAssertFalse(Self.history(session).contains("handoff text"))
        let handoffTranscript = try XCTUnwrap(viewModel.resolvedHandoffSourceTranscript(for: session, upToItemID: nil))
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(AgentTranscriptIO.buildConversationHistory(from: handoffTranscript).contains("handoff text"))

        session.appendItem(.assistant("replayed text"))
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        let message = viewModel.test_buildHeadlessAgentMessage(session: session, initialMessage: "Next step")
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(message.userMessage.contains("<previous_conversation>"))
        XCTAssertTrue(message.userMessage.contains("replayed text"))

        session.appendItem(.assistant("expanded text"))
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        viewModel.setTranscriptWindowExpanded(tabID: session.tabID, isExpanded: !session.isTranscriptWindowExpanded)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(Self.isSynchronized(session))

        session.appendItem(.assistant("revealed text"))
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        viewModel.setCompressedHistoryVisibility(tabID: session.tabID, isRevealed: !session.isCompressedHistoryRevealed)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertTrue(Self.history(session).contains("revealed text"))
    }

    func testSaveAndLiveMCPReadersFlushDeferredBackgroundWork() async throws {
        let window = try await Self.makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let gate = DerivedTranscriptDeferralSleepGate()
        defer { gate.open() }
        viewModel.test_setDerivedTranscriptDeferralSleep(gate.makeSleep())
        viewModel.test_setBackgroundDerivedTranscriptDeferralEnabledOverride(true)

        let session = try await Self.makeRegisteredSession(in: window)
        let sessionID = UUID()
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        // Delete only the session this test persists. The ephemeral workspace follows the
        // existing window-backed MCP test pattern (no workspace cleanup).
        addTeardownBlock { @MainActor in
            session.saveDebounceTask?.cancel()
            try? await AgentSessionDataService.shared.deleteAgentSession(id: sessionID, for: workspace)
        }
        _ = try await Self.makeRegisteredSession(in: window)
        XCTAssertNotEqual(viewModel.currentTabID, session.tabID)
        XCTAssertFalse(viewModel.canBuildOrPublishActiveTranscriptBindings(for: session))
        session.runState = .running
        session.appendItem(.user("Start"))
        XCTAssertTrue(viewModel.flushDeferredDerivedTranscriptRefresh(tabID: session.tabID))
        let service = Self.makeService(window: window)

        session.appendItem(.assistant("get_log text"))
        session.saveDebounceTask?.cancel()
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        let logResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh, "active get_log flushed")
        XCTAssertTrue(try XCTUnwrap(logResult.objectValue?["transcript_xml"]?.stringValue).contains("get_log text"))

        session.appendItem(.assistant("handoff text"))
        session.saveDebounceTask?.cancel()
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        let handoffResult = try await service.execute(args: [
            "op": .string("extract_handoff"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh, "live handoff flushed")
        XCTAssertTrue(try XCTUnwrap(handoffResult.objectValue?["handoff_xml"]?.stringValue).contains("handoff text"))

        session.appendItem(.assistant("saved text"))
        session.saveDebounceTask?.cancel()
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        let saved = await viewModel.saveSession(for: session.tabID)
        XCTAssertTrue(saved)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh, "save flushed")
        XCTAssertTrue(Self.isSynchronized(session))
        let loaded = try await AgentSessionDataService.shared.loadAgentSession(
            reference: sessionID.uuidString,
            for: workspace
        )
        let persistedTranscript = try XCTUnwrap(XCTUnwrap(loaded).transcript)
        XCTAssertTrue(AgentTranscriptIO.buildConversationHistory(from: persistedTranscript).contains("saved text"))
    }

    // MARK: - Ownership and generations

    func testRemovedCancelledSilentOrSupersededDeferredTasksAreNoOps() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        let viewModel = harness.viewModel
        let session = harness.background

        // Each delayed task is parked in its wait before the competing event, so the release
        // exercises the post-wait cancellation/ownership/generation guards.
        session.appendItem(.assistant("superseded"))
        let supersededTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        let buildsAfterNewerGeneration = Self.builds(session)
        await harness.gate.release([supersededTask])
        XCTAssertEqual(Self.builds(session), buildsAfterNewerGeneration, "newer generation wins")

        session.appendItem(.assistant("torn down"))
        let tornDownTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        session.cancelEphemeralRuntimeState()
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertFalse(viewModel.flushDeferredDerivedTranscriptRefresh(for: session))
        await harness.gate.release([tornDownTask])
        XCTAssertEqual(Self.builds(session), buildsAfterNewerGeneration)
        XCTAssertFalse(Self.isSynchronized(session), "teardown is not resurrected")

        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
        session.appendItem(.assistant("silently replaced"))
        let silentTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        session.setItemsSilently(session.items, reason: .testOverride)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        let buildsAfterSilent = Self.builds(session)
        await harness.gate.release([silentTask])
        XCTAssertEqual(Self.builds(session), buildsAfterSilent)

        session.pendingAskUser = try Self.pendingAskUser()
        let buildsBeforeRemoval = Self.builds(session)
        session.appendItem(.assistant("removed"))
        let removedTask = session.derivedTranscriptRefreshTask
        await harness.gate.waitForParked(1)
        viewModel.test_removeLiveSession(tabID: session.tabID)
        XCTAssertFalse(viewModel.flushDeferredDerivedTranscriptRefresh(tabID: session.tabID))
        XCTAssertFalse(viewModel.flushDeferredDerivedTranscriptRefresh(for: session))
        session.pendingAskUser = nil
        XCTAssertEqual(Self.builds(session), buildsBeforeRemoval, "question clear on a removed session does not refresh")
        await harness.gate.release([removedTask])
        XCTAssertEqual(Self.builds(session), buildsBeforeRemoval, "removed session is not refreshed")
    }

    /// Pre-start cancellation only: the default-sleep task is cancelled before it ever runs, so
    /// this proves the cancelled-before-execution path is a no-op. It does not qualify an
    /// in-flight real sleep; post-wait cancellation and generation guards are covered by the
    /// controlled-gate tests above.
    func testDefaultSleepTaskCancelledBeforeExecutionIsNoOp() async throws {
        let harness = try await Harness.make()
        defer { harness.gate.open() }
        harness.viewModel.test_setDerivedTranscriptDeferralSleep(nil)
        let session = harness.background

        session.appendItem(.assistant("cancelled before start"))
        let task = try XCTUnwrap(session.derivedTranscriptRefreshTask)
        XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh)
        harness.viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
        let buildsAfterRefresh = Self.builds(session)
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        await task.value
        XCTAssertEqual(Self.builds(session), buildsAfterRefresh)
        XCTAssertTrue(Self.isSynchronized(session))
    }

    // MARK: - Kill switch

    func testKillSwitchRestoresUndelayedSchedulingAndQuestionPolicy() async throws {
        XCTAssertEqual(
            AgentModeViewModel.backgroundDerivedTranscriptDeferralDisabledDefaultsKey,
            "AgentModeDisableBackgroundTranscriptRefreshDeferral"
        )
        let harness = try await Harness.make(deferralEnabled: false)
        defer { harness.gate.open() }
        let session = harness.background

        session.appendItem(.assistant("undelayed"))
        XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh)
        XCTAssertFalse(harness.viewModel.flushDeferredDerivedTranscriptRefresh(for: session))
        await session.derivedTranscriptRefreshTask?.value
        XCTAssertTrue(Self.isSynchronized(session))
        XCTAssertTrue(harness.gate.requestedDelays.isEmpty)

        let buildsBefore = Self.builds(session)
        session.pendingAskUser = try Self.pendingAskUser()
        XCTAssertEqual(Self.builds(session), buildsBefore, "question catch-up is part of D7")
        XCTAssertFalse(Self.isSynchronized(session))
    }

    // MARK: - Fixtures

    @MainActor
    private struct Harness {
        let viewModel: AgentModeViewModel
        let gate: DerivedTranscriptDeferralSleepGate
        let active: Session
        let background: Session

        /// `active` is the current tab; `background` cannot publish. Both start synchronized.
        static func make(deferralEnabled: Bool = true) async throws -> Harness {
            let viewModel = AgentModeViewModel(
                codexControllerFactory: { _, _, _, _, _, _ in
                    LifecycleNoopCodexController(recorder: LifecycleRecorder())
                }
            )
            viewModel.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
            let gate = DerivedTranscriptDeferralSleepGate()
            viewModel.test_setDerivedTranscriptDeferralSleep(gate.makeSleep())
            viewModel.test_setBackgroundDerivedTranscriptDeferralEnabledOverride(deferralEnabled)
            let activeTabID = UUID()
            viewModel.test_setCurrentTabIDOverride(activeTabID)
            let active = try await viewModel.ensureSessionReady(tabID: activeTabID)
            let background = try await viewModel.ensureSessionReady(tabID: UUID())
            for (session, prefix) in [(active, "active"), (background, "background")] {
                session.setItemsSilently(
                    [.user("\(prefix) request", sequenceIndex: 0), .assistant("\(prefix) reply", sequenceIndex: 1)],
                    reason: .testOverride
                )
                session.nextSequenceIndex = 2
                viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh)
            }
            viewModel.applySessionToBindings(active)
            XCTAssertTrue(viewModel.canBuildOrPublishActiveTranscriptBindings(for: active))
            XCTAssertFalse(viewModel.canBuildOrPublishActiveTranscriptBindings(for: background))
            XCTAssertTrue(AgentTranscriptBackgroundRefreshDeferralTests.isSynchronized(background))
            return Harness(viewModel: viewModel, gate: gate, active: active, background: background)
        }
    }

    private static func builds(_ session: Session) -> Int {
        session.transcriptPerformanceSnapshot.projectionBuildCount
    }

    private static func isSynchronized(_ session: Session) -> Bool {
        guard let state = session.derivedTranscriptSyncState else { return false }
        return state.sourceItemsRevision == session.sourceItemsRevision
            && state.nextSequenceIndex == session.nextSequenceIndex
            && state.runState == session.runState
            && state.hidePendingQuestionToolCall == session.hasPendingQuestionUI
    }

    private static func history(_ session: Session) -> String {
        AgentTranscriptIO.buildConversationHistory(from: session.transcript)
    }

    private static func yield(_ count: Int = 5) async {
        for _ in 0 ..< count {
            await Task.yield()
        }
    }

    private static func pendingAskUser() throws -> AgentAskUserPendingState {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            title: "Continue",
            context: "D7",
            timeoutSeconds: 30,
            questions: [AgentAskUserQuestion(id: "continue", question: "Continue?", allowsCustom: true)]
        )
        try interaction.validate()
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: interaction.emptyDrafts(),
            currentQuestionIndex: 0
        )
    }

    private static func pendingUserInputRequest() -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string("d7-request"),
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
    }

    private static func makeRegisteredSession(in window: WindowState) async throws -> Session {
        await window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
    }

    private static func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let workspace = window.workspaceManager.createWorkspace(
            name: "D7 Deferral \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "d7DeferralTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private static func makeService(window: WindowState) -> AgentManageMCPToolService {
        let connectionID = UUID()
        return AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "d7-deferral",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }
}

/// Test-controlled replacement for the D7 deferral sleep. Parked sleeps resume only on
/// `release` / `open`, so tests decide exactly when the delayed window ends.
@MainActor
final class DerivedTranscriptDeferralSleepGate {
    private(set) var requestedDelays: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    nonisolated func makeSleep() -> @Sendable (Duration) async -> Void {
        { [self] delay in await suspend(delay) }
    }

    /// Yields until `count` scheduled tasks reached their wait.
    func waitForParked(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 200 where waiters.count < count {
            await Task.yield()
        }
        XCTAssertEqual(waiters.count, count, "parked deferral sleeps", file: file, line: line)
    }

    /// Ends every current and pending wait, then awaits `tasks`; later sleeps park again.
    func release(_ tasks: [Task<Void, Never>?]) async {
        isOpen = true
        resumeAll()
        for task in tasks {
            await task?.value
        }
        isOpen = false
    }

    /// Permanently ends every wait (test teardown).
    func open() {
        isOpen = true
        resumeAll()
    }

    private func suspend(_ delay: Duration) async {
        requestedDelays.append(delay)
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeAll() {
        let released = waiters
        waiters.removeAll()
        for waiter in released {
            waiter.resume()
        }
    }
}
