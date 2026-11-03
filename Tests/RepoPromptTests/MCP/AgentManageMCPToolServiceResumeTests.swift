import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

@MainActor
final class AgentManageMCPToolServiceResumeTests: XCTestCase {
    #if DEBUG
        override func setUp() async throws {
            try await super.setUp()
            await OMPQualificationSharedGateTestIsolation.shared.acquire()
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        }

        override func tearDown() async throws {
            AgentRunSessionStore.waiterTimeoutSleepOverride = nil
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            await OMPQualificationSharedGateTestIsolation.shared.release()
            try await super.tearDown()
        }
    #endif

    func testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let initialConnectionID = UUID()
        let resumedConnectionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: initialConnectionID,
            taskLabelKind: .pair,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.resume.initial")
        session.runState = .running
        viewModel.publishMCPStateChange(for: session)

        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        let initialCursor = AgentRunSessionStore.WaitCursor(
            registration: initialContext.registration,
            epoch: initialEpoch
        )
        let originalWaitTimeoutGate = AgentRunSessionStoreTimeoutGate()
        AgentRunSessionStore.waiterTimeoutSleepOverride = { nanoseconds in
            await originalWaitTimeoutGate.sleep(nanoseconds: nanoseconds)
        }
        let originalWait = Task {
            await AgentRunSessionStore.waitUntilInteresting(
                cursor: initialCursor,
                timeoutSeconds: 1
            )
        }
        defer {
            AgentRunSessionStore.waiterTimeoutSleepOverride = nil
            originalWaitTimeoutGate.release()
            originalWait.cancel()
        }

        do {
            try await waitForAgentRunSessionStoreWaiter(registration: initialContext.registration)
            let requestedTimeoutNanoseconds = try await originalWaitTimeoutGate.waitForRequestedTimeout()
            XCTAssertEqual(requestedTimeoutNanoseconds, 1_000_000_000)
            AgentRunSessionStore.waiterTimeoutSleepOverride = nil

            let service = makeService(window: window, connectionID: resumedConnectionID)
            _ = try await service.execute(args: [
                "op": .string("resume_session"),
                "session_id": .string(sessionID.uuidString)
            ])

            let resumedContext = try XCTUnwrap(session.mcpControlContext)
            XCTAssertEqual(resumedContext.activationID, initialContext.activationID)
            XCTAssertEqual(resumedContext.registration, initialContext.registration)
            XCTAssertEqual(resumedContext.taskLabelKind, .pair)
            let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
            XCTAssertEqual(currentRegistration, initialContext.registration)

            session.runState = .cancelled
            try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
                await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            }
            let steeredContext = try XCTUnwrap(session.mcpControlContext)
            let steeredEpoch = try XCTUnwrap(steeredContext.currentEpoch)
            XCTAssertEqual(steeredContext.registration, initialContext.registration)
            XCTAssertEqual(steeredEpoch.transitionKind, .steering)

            let firstDisposition = try await waitForBoundedFixtureTaskValue(
                originalWait,
                description: "pre-resume waiter steering wake",
                cleanupBeforeCancellation: {
                    originalWaitTimeoutGate.release()
                }
            )
            originalWaitTimeoutGate.release()
            XCTAssertEqual(firstDisposition, .epochAdvanced(steeredEpoch, .steering))

            let steeredCursor = AgentRunSessionStore.WaitCursor(
                registration: initialContext.registration,
                epoch: steeredEpoch
            )
            let steeredWait = Task {
                await AgentRunSessionStore.waitUntilInteresting(
                    cursor: steeredCursor,
                    timeoutSeconds: 1
                )
            }
            try await waitForAgentRunSessionStoreWaiter(registration: initialContext.registration)
            let cancelled = makeSnapshot(sessionID: sessionID, status: .cancelled)
            await AgentRunSessionStore.signalSnapshot(cancelled, cursor: steeredCursor)
            let terminalDisposition = await steeredWait.value
            XCTAssertEqual(terminalDisposition, .snapshotReady(cancelled))

            await viewModel.mcpDeactivateControlContext(
                sessionID: sessionID,
                cleanupSessionStore: true
            )
        } catch {
            originalWaitTimeoutGate.release()
            originalWait.cancel()
            _ = await originalWait.result
            throw error
        }
    }

    func testBoundedWaitObservationFailsAndDrainsWhenSteeringWakeIsMissing() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID(),
            taskLabelKind: .pair,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.resume.missing-steering-wake")
        session.runState = .running
        viewModel.publishMCPStateChange(for: session)

        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: epoch
        )
        let timeoutGate = AgentRunSessionStoreTimeoutGate()
        AgentRunSessionStore.waiterTimeoutSleepOverride = { nanoseconds in
            await timeoutGate.sleep(nanoseconds: nanoseconds)
        }
        let waitTask = Task {
            await AgentRunSessionStore.waitUntilInteresting(
                cursor: cursor,
                timeoutSeconds: 1
            )
        }
        defer {
            AgentRunSessionStore.waiterTimeoutSleepOverride = nil
            timeoutGate.release()
            waitTask.cancel()
        }

        do {
            try await waitForAgentRunSessionStoreWaiter(registration: context.registration)
            let requestedTimeoutNanoseconds = try await timeoutGate.waitForRequestedTimeout()
            XCTAssertEqual(requestedTimeoutNanoseconds, 1_000_000_000)

            do {
                _ = try await waitForBoundedFixtureTaskValue(
                    waitTask,
                    description: "missing steering wake",
                    timeout: 0.05,
                    cleanupBeforeCancellation: {
                        timeoutGate.release()
                    }
                )
                XCTFail("Expected bounded observation to time out without a steering wake")
            } catch let error as AsyncTestConditionTimeout {
                XCTAssertEqual(error.description, "missing steering wake")
                XCTAssertEqual(error.timeout, 0.05)
            }

            _ = await waitTask.result
            try await waitForAgentRunSessionStoreWaiter(
                registration: context.registration,
                expectedCount: 0
            )
            XCTAssertEqual(timeoutGate.parkedSleepCount, 0)

            AgentRunSessionStore.waiterTimeoutSleepOverride = nil
            await AgentRunSessionStore.cleanup(registration: context.registration)
        } catch {
            timeoutGate.release()
            waitTask.cancel()
            _ = await waitTask.result
            AgentRunSessionStore.waiterTimeoutSleepOverride = nil
            await AgentRunSessionStore.cleanup(registration: context.registration)
            throw error
        }
    }

    func testResumeAcceptsConnectedOhMyPiWithoutQualificationLease() async throws {
        defer {
            AgentACPModelRegistry.shared.reset(providerID: .ohMyPi)
        }

        let modelRaw = "smoke-provider/exact-model"
        let discovered = ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: modelRaw,
                    displayName: "Exact Smoke Model",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: modelRaw
        )
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .ohMyPi))

        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.apiSettingsViewModel.isOhMyPiConnected = true

        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        let tabID = session.tabID
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let modelID = AgentModelSelectionID(
            agentRaw: AgentProviderKind.ohMyPi.rawValue,
            modelRaw: modelRaw
        ).rawValue

        session.selectedAgent = .ohMyPi
        session.selectedModelRaw = modelRaw
        let service = makeService(window: window, connectionID: UUID())
        let resumeArguments: [[String: Value]] = [
            [
                "op": .string("resume_session"),
                "session_id": .string(sessionID.uuidString),
                "model_id": .string(modelID)
            ],
            [
                "op": .string("resume_session"),
                "session_id": .string(sessionID.uuidString)
            ]
        ]
        for arguments in resumeArguments {
            let result = try await service.execute(args: arguments)
            XCTAssertEqual(result.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
            XCTAssertEqual(
                result.objectValue?["agent"]?.objectValue?["id"]?.stringValue,
                AgentProviderKind.ohMyPi.rawValue
            )
            XCTAssertTrue(window.agentModeViewModel.session(for: tabID, createIfNeeded: false) === session)
            XCTAssertEqual(window.agentModeViewModel.test_bindingResolution(sessionID: sessionID), .unique(tabID: tabID))
            XCTAssertEqual(session.selectedAgent, .ohMyPi)
            XCTAssertEqual(session.selectedModelRaw, modelRaw)
        }

        await window.agentModeViewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testGetLogHostRowIDAttributesAreFeatureGatedAndLegacyOutputIsByteIdentical() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let userRowID = UUID()
        let assistantRowID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .completed
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                AgentChatItem(id: userRowID, kind: .user, text: "Prompt", sequenceIndex: 0),
                AgentChatItem(id: assistantRowID, kind: .assistant, text: "Reply", sequenceIndex: 1)
            ],
            terminalState: .completed,
            compact: false
        )
        let service = makeService(window: window, connectionID: UUID())
        let baseArgs: [String: Value] = [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ]

        let legacyResult = try await service.execute(args: baseArgs)
        let explicitFalseResult = try await service.execute(args: baseArgs.merging([
            "include_host_row_ids": .bool(false)
        ]) { _, incoming in incoming })
        let optedInResult = try await service.execute(args: baseArgs.merging([
            "include_host_row_ids": .bool(true)
        ]) { _, incoming in incoming })
        let legacyXML = try XCTUnwrap(legacyResult.objectValue?["transcript_xml"]?.stringValue)
        let explicitFalseXML = try XCTUnwrap(explicitFalseResult.objectValue?["transcript_xml"]?.stringValue)
        let optedInXML = try XCTUnwrap(optedInResult.objectValue?["transcript_xml"]?.stringValue)

        XCTAssertEqual(legacyXML, "<transcript>\n<user>Prompt</user>\n<assistant>Reply</assistant>\n</transcript>")
        XCTAssertEqual(explicitFalseXML, legacyXML)
        XCTAssertEqual(
            optedInXML,
            "<transcript>\n<user id=\"\(userRowID.uuidString)\">Prompt</user>\n<assistant id=\"\(assistantRowID.uuidString)\">Reply</assistant>\n</transcript>"
        )
    }

    func testGetLogReportsOnlyLeadingCompletedTurns() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let service = makeService(window: window, connectionID: UUID())

        session.runState = .running
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [.user("Prompt", sequenceIndex: 0)],
            terminalState: .running,
            compact: false
        )
        let runningResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(runningResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(runningResult.objectValue?["returned_turn_count"]?.intValue, 1)

        session.runState = .completed
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Reply", sequenceIndex: 1)
            ],
            terminalState: .completed,
            compact: false
        )
        let completedResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(completedResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(completedResult.objectValue?["returned_turn_count"]?.intValue, 1)

        session.runState = .running
        var staleMiddleTranscript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Reply", sequenceIndex: 1),
                .user("Follow-up", sequenceIndex: 2)
            ],
            terminalState: .running,
            compact: false
        )
        staleMiddleTranscript.turns[0].terminalState = .running
        session.transcript = staleMiddleTranscript
        let staleMiddleResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(staleMiddleResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(staleMiddleResult.objectValue?["returned_turn_count"]?.intValue, 2)

        session.runState = .running
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [.user("Queued prompt", sequenceIndex: 0)],
            terminalState: .idle,
            compact: false
        )
        let activeSingleStaleCompleteResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(activeSingleStaleCompleteResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(activeSingleStaleCompleteResult.objectValue?["returned_turn_count"]?.intValue, 1)

        session.runState = .running
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Reply", sequenceIndex: 1),
                .user("Queued follow-up", sequenceIndex: 2)
            ],
            terminalState: .idle,
            compact: false
        )
        let activeStaleCompleteResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(activeStaleCompleteResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(activeStaleCompleteResult.objectValue?["returned_turn_count"]?.intValue, 2)

        session.runState = .waitingForUser
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Need input", sequenceIndex: 1)
            ],
            terminalState: .waitingForUser,
            compact: false
        )
        let waitingResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(waitingResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(waitingResult.objectValue?["returned_turn_count"]?.intValue, 1)

        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let persistedActiveSessionID = UUID()
        let persistedActiveTranscript = AgentTranscriptIO.buildTranscript(
            from: [.user("Persisted queued prompt", sequenceIndex: 0)],
            terminalState: .idle,
            compact: false
        )
        let persistedActiveSession = AgentSession(
            id: persistedActiveSessionID,
            workspaceID: workspace.id,
            name: "Persisted Active",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            transcript: persistedActiveTranscript,
            itemCount: 1,
            lastRunState: AgentSessionRunState.running.rawValue,
            autoEditEnabled: true
        )
        _ = try await AgentSessionDataService.shared.saveAgentSession(
            persistedActiveSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let persistedActiveResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(persistedActiveSessionID.uuidString)
        ])
        XCTAssertEqual(persistedActiveResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(persistedActiveResult.objectValue?["returned_turn_count"]?.intValue, 1)

        let persistedCompletedSessionID = UUID()
        let persistedCompletedTranscript = AgentTranscriptIO.buildTranscript(
            from: [.user("Persisted prompt", sequenceIndex: 0), .assistant("Persisted reply", sequenceIndex: 1)],
            terminalState: .completed,
            compact: false
        )
        let persistedCompletedSession = AgentSession(
            id: persistedCompletedSessionID,
            workspaceID: workspace.id,
            name: "Persisted Completed",
            savedAt: Date(timeIntervalSinceReferenceDate: 11),
            transcript: persistedCompletedTranscript,
            itemCount: 2,
            lastRunState: AgentSessionRunState.completed.rawValue,
            autoEditEnabled: true
        )
        _ = try await AgentSessionDataService.shared.saveAgentSession(
            persistedCompletedSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 2
        )
        let persistedCompletedResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(persistedCompletedSessionID.uuidString)
        ])
        XCTAssertEqual(persistedCompletedResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(persistedCompletedResult.objectValue?["returned_turn_count"]?.intValue, 1)
    }

    private func makeRegisteredSession(
        in window: WindowState
    ) async throws -> AgentTabSession {
        await window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Resume Ownership \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageResumeOwnershipTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        connectionID: UUID
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "resume-ownership-regression",
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

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Pair Session",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: "buffered assistant text",
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: status == .cancelled ? .cancelled : nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}
