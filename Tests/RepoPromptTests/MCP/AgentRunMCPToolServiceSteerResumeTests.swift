import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testSteerCompletedUserOwnedSessionWithoutControlContextReactivatesAndStartsFollowUp() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var observedText: String?
        var observedEpoch: AgentRunTurnEpoch?
        service.testDispatchSteerInstruction = { dispatchedSessionID, text, _, agentModeVM in
            observedText = text
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertFalse(controlledSession.isMCPOriginated)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            let context = try XCTUnwrap(controlledSession.mcpControlContext)
            observedEpoch = try XCTUnwrap(context.currentEpoch)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("continue this user-owned session")
        ])

        XCTAssertEqual(observedText, "continue this user-owned session")
        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertFalse(session.isMCPOriginated)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertEqual(epoch, observedEpoch)
        XCTAssertEqual(epoch.transitionKind, .steering)
        XCTAssertEqual(epoch.ordinal, 1)
        XCTAssertNil(context.pendingEpochTransition)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, context.registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            throw MCPError.internalError("synthetic steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("synthetic steer dispatch failure"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var replacementActivationID: UUID?
        var replacementRegistration: AgentRunSessionStore.Registration?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            let originalContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)

            try await agentModeVM.mcpActivateControlContext(
                forTabID: controlledSession.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true
            )
            let replacementContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertNotEqual(replacementContext.activationID, originalContext.activationID)
            replacementActivationID = replacementContext.activationID
            replacementRegistration = replacementContext.registration
            throw MCPError.internalError("synthetic steer dispatch failure after replacement")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails after replacement")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic steer dispatch failure after replacement"),
                String(describing: error)
            )
        }

        let activationID = try XCTUnwrap(replacementActivationID)
        let registration = try XCTUnwrap(replacementRegistration)
        let context = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(context.activationID, activationID)
        XCTAssertEqual(context.registration, registration)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let unknownSessionID = UUID()
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Unknown sessions must not reach dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("unknown session")
            ])
            XCTFail("Expected unknown session failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("was not found"), String(describing: error))
        }

        XCTAssertNil(viewModel.mcpControlledSession(sessionID: unknownSessionID))
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: unknownSessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerActiveUncontrolledSessionIsRejected() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .running

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Active uncontrolled sessions must be rejected before dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("active uncontrolled session")
            ])
            XCTFail("Expected active uncontrolled session rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("active but is not controlled"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    // MARK: - Plan §6.4 steer wait selection ordering

    func testSteerRejectsExplicitTimeoutAboveMaximumBeforeAnyMutationOrReactivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("An invalid explicit timeout must fail before the steering mutation")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("never dispatched"),
                "timeout_seconds": .int(14401)
            ])
            XCTFail("Expected timeout validation failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("14400"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext, "Validation must run before control-context reactivation")
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerWithWaitFalseIgnoresSuppliedTimeoutWithoutParsingAndReportsNoPolicy() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var resolutionCount = 0
        service.resolveWaitPolicyContext = { metadata in
            resolutionCount += 1
            return AgentMCPWaitPolicy.RequestContext(
                metadata: metadata,
                parentFamily: .codex,
                parentPromptCacheRetention: .standard
            )
        }
        var dispatchCount = 0
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            dispatchCount += 1
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        // 99,999 would fail validation if parsed; wait=false must keep ignoring it with the warning.
        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("fire and forget"),
            "wait": .bool(false),
            "timeout_seconds": .int(99999)
        ])

        XCTAssertEqual(dispatchCount, 1)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertTrue(
            object["warning"]?.stringValue?.contains("Ignoring timeout_seconds because wait=false") == true,
            "warning: \(String(describing: object["warning"]))"
        )
        XCTAssertNil(object["wait_policy"], "A deliberately non-waiting steer has no wait policy to report")
        XCTAssertEqual(resolutionCount, 0, "No wait selection means no parent-family resolution")

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerWithExplicitZeroFreezesFamilyBeforeDispatchAndReportsPollPolicy() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var resolvedBeforeDispatch = false
        var resolutionCount = 0
        service.resolveWaitPolicyContext = { metadata in
            resolutionCount += 1
            resolvedBeforeDispatch = true
            return AgentMCPWaitPolicy.RequestContext(
                metadata: metadata,
                parentFamily: .codex,
                parentPromptCacheRetention: .standard
            )
        }
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            XCTAssertTrue(resolvedBeforeDispatch, "The parent family must be frozen before the steering mutation")
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("steer then poll"),
            "wait": .bool(true),
            "timeout_seconds": .int(0)
        ])

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertNil(object["warning"])
        XCTAssertEqual(object["wait_policy"], .object(["mode": .string("poll"), "timeout_seconds": .int(0)]))
        XCTAssertEqual(resolutionCount, 1)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    // MARK: - Plan 2026-10-30 Step 1: paired-device control of desktop roots

    private static let remoteDeviceID = "remote:1a2b3c4d"

    /// A user-driven desktop root bound to a durable session ID, with no MCP control.
    private func makeRemoteRoot(
        in window: WindowState,
        runState: AgentSessionRunState
    ) async throws -> (session: AgentTabSession, sessionID: UUID) {
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = runState
        if runState.isActive {
            session.runID = UUID()
            session.beginRunAttempt(source: "test.remote-root")
        }
        XCTAssertTrue(viewModel.isAttentionNotificationRoot(session))
        XCTAssertIdentical(viewModel.remoteAttentionRootSession(sessionID: sessionID), session)
        return (session, sessionID)
    }

    private func assertNoMCPControl(
        _ session: AgentTabSession,
        sessionID: UUID,
        viewModel: AgentModeViewModel,
        controlledTabsBefore: Set<UUID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertNil(session.mcpControlContext, file: file, line: line)
        XCTAssertFalse(session.isMCPOriginated, file: file, line: line)
        XCTAssertFalse(session.mcpFollowUpRunPending, file: file, line: line)
        XCTAssertNil(viewModel.mcpControlledSession(sessionID: sessionID), file: file, line: line)
        XCTAssertEqual(viewModel.mcpControlledTabIDs, controlledTabsBefore, file: file, line: line)
        XCTAssertTrue(viewModel.isAttentionNotificationRoot(session), file: file, line: line)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration, file: file, line: line)
    }

    private func makeQuestionForm() -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            timeoutSeconds: 300,
            questions: [
                AgentAskUserQuestion(
                    id: "target",
                    question: "Which environment?",
                    options: [AgentAskUserOption(label: "staging"), AgentAskUserOption(label: "production")],
                    allowsCustom: false
                ),
                AgentAskUserQuestion(
                    id: "notes",
                    question: "Anything else?",
                    allowsCustom: true
                )
            ]
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if Task.isCancelled || clock.now >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testGatewayDeviceSteersRunningRootThroughRemoteSendWithoutInstallingControl() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs

        var service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("A paired device must not use the MCP control steer path")
            return .startedRun
        }
        var dispatched: [String] = []
        service.testDispatchRemoteRootInstruction = { dispatchedSessionID, text, _, agentModeVM in
            XCTAssertEqual(dispatchedSessionID, sessionID)
            XCTAssertIdentical(agentModeVM.remoteAttentionRootSession(sessionID: dispatchedSessionID), session)
            XCTAssertNil(session.mcpControlContext)
            dispatched.append(text)
            return .queuedFollowUp
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("also cover the edge case"),
            "wait": .bool(true)
        ])

        XCTAssertEqual(dispatched, ["also cover the edge case"])
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertTrue(
            String(describing: value).contains("Waiting is not available for remote control"),
            "A requested wait is reported, not silently dropped: \(value)"
        )
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    func testGatewayDeviceFollowsUpIdleRootThroughRemoteSendWithoutReactivatingControl() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .completed)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs

        var service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("A paired device must not reactivate MCP control for an idle root")
            return .startedRun
        }
        service.testDispatchRemoteRootInstruction = { _, text, _, _ in
            XCTAssertEqual(text, "next, write the tests")
            XCTAssertNil(session.mcpControlContext)
            session.runID = UUID()
            session.runState = .running
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("next, write the tests")
        ])

        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertFalse(String(describing: value).contains("Waiting is not available"))
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    /// Review A R1 (round 2 narrow cut): an indexed but unhydrated root keeps its remote identity,
    /// so a verified device's steer or follow-up takes the remote branch and fails there with a clear
    /// reason; it never falls through to ordinary MCP idle reactivation or active-session control.
    func testGatewayDeviceSendToUnhydratedRootFailsClearlyWithoutMCPFallThrough() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .completed)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            [sessionID: rootIndexEntry(sessionID, tabID: session.tabID)],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        session.hasLoadedPersistedState = false
        XCTAssertIdentical(viewModel.remoteAttentionRootSession(sessionID: sessionID), session)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let itemsBefore = session.items.map(\.id)

        var service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("A paired device must not reach the MCP control steer path")
            return .startedRun
        }

        for running in [false, true] {
            if running {
                session.runID = UUID()
                session.runState = .running
                session.beginRunAttempt(source: "test.remote-root.unhydrated")
            }
            do {
                _ = try await service.execute(args: [
                    "op": .string("steer"),
                    "session_id": .string(sessionID.uuidString),
                    "message": .string("from the phone")
                ])
                XCTFail("An unhydrated root must refuse a remote send (running: \(running))")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(AgentModeViewModel.remoteRootNotLoadedMessage),
                    "running: \(running): \(error)"
                )
            }
            XCTAssertEqual(session.items.map(\.id), itemsBefore, "running: \(running)")
            XCTAssertTrue(session.pendingInstructions.isEmpty, "running: \(running)")
            await assertNoMCPControl(
                session,
                sessionID: sessionID,
                viewModel: viewModel,
                controlledTabsBefore: controlledTabsBefore
            )
        }
    }

    private func rootIndexEntry(_ sessionID: UUID, tabID: UUID) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Root",
            lastUserMessageAt: Date(timeIntervalSince1970: 100),
            savedAt: Date(timeIntervalSince1970: 100),
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: nil,
            remoteHostName: nil,
            isMCPOriginated: false,
            origin: nil,
            profile: .standard,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    /// A client that only names itself like a device app link (no verified gateway device identity)
    /// keeps the ordinary MCP rules: an active uncontrolled root is refused.
    func testRemoteLookingClientNameWithoutVerifiedDeviceIsStillRefusedForActiveRoot() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs

        var service = makeService(window: window, clientName: Self.remoteDeviceID, gatewayRemoteDeviceID: nil)
        service.testDispatchRemoteRootInstruction = { _, _, _, _ in
            XCTFail("clientName alone must never reach the remote root path")
            return .startedRun
        }
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Active uncontrolled sessions must be rejected before dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("pretend to be a phone")
            ])
            XCTFail("Expected active uncontrolled session rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("active but is not controlled"), String(describing: error))
        }
        let currentRunID = try XCTUnwrap(session.runID)
        for runID in [nil, currentRunID] {
            var args: [String: Value] = [
                "op": .string("cancel"),
                "session_id": .string(sessionID.uuidString)
            ]
            if let runID {
                args["run_id"] = .string(runID.uuidString)
            }
            do {
                _ = try await service.execute(args: args)
                XCTFail("Expected a plain MCP cancel of an uncontrolled root to be refused")
            } catch {
                // Review B P3-4: the refusal names the missing control instead of contradicting the
                // `running` status that poll reports, also when the reported `run_id` is passed.
                XCTAssertTrue(
                    String(describing: error).contains("not under agent_run control"),
                    "run_id: \(String(describing: runID)): \(error)"
                )
            }
        }
        XCTAssertEqual(session.runState, .running)
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    func testGatewayDeviceAnswersExactMultiQuestionFormWithDeviceAttribution() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let interaction = makeQuestionForm()
        let asked = Task { try await viewModel.askUser(tabID: session.tabID, interaction: interaction) }
        try await waitUntil("the question to be pending") { session.pendingAskUser?.interaction.id == interaction.id }

        // Polling a live waiting root reports the true status and the structured question.
        let service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)
        let polled = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        let polledObject = try XCTUnwrap(polled.objectValue)
        XCTAssertEqual(polledObject["status"]?.stringValue, AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
        // Review B R1-P2-2: the live projection reports the current run so a device can guard Stop.
        XCTAssertEqual(polledObject["run_id"]?.stringValue, try XCTUnwrap(session.runID).uuidString)
        let polledInteraction = try XCTUnwrap(polledObject["interaction"]?.objectValue, "\(polled)")
        XCTAssertEqual(polledInteraction["id"]?.stringValue, interaction.id.uuidString)
        XCTAssertEqual(polledInteraction["kind"]?.stringValue, AgentRunMCPSnapshot.Interaction.Kind.question.rawValue)
        XCTAssertTrue(String(describing: polled).contains("Which environment?"), "\(polled)")
        XCTAssertTrue(String(describing: polled).contains("Anything else?"), "\(polled)")

        // A stale question ID is refused and leaves nothing behind.
        do {
            _ = try await service.execute(args: [
                "op": .string("respond"),
                "session_id": .string(sessionID.uuidString),
                "interaction_id": .string(UUID().uuidString),
                "answers": .object(["target": .string("staging"), "notes": .string("none")])
            ])
            XCTFail("A stale interaction_id must be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interaction_id"), String(describing: error))
        }
        XCTAssertEqual(session.pendingAskUser?.interaction.id, interaction.id)
        XCTAssertNil(session.pendingInteractionResolutionAttribution)

        let value = try await service.execute(args: [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(interaction.id.uuidString),
            "answers": .object([
                "target": .array([.string("production")]),
                "notes": .string("ship after lunch")
            ])
        ])

        let response = try await asked.value
        XCTAssertFalse(response.timedOut)
        XCTAssertFalse(response.skipped)
        XCTAssertEqual(response.answersByQuestionID["target"]?.answers, ["production"])
        XCTAssertEqual(response.answersByQuestionID["notes"]?.answers, ["ship after lunch"])
        XCTAssertNil(session.pendingAskUser)
        XCTAssertEqual(session.lastInteractionResolution?.interactionID, interaction.id)
        XCTAssertEqual(session.lastInteractionResolution?.resolvedBy, Self.remoteDeviceID)
        XCTAssertNil(session.pendingInteractionResolutionAttribution)
        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertNil(value.objectValue?["interaction"]?.objectValue)
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    /// Review B P2-4c: a plain MCP client (no verified device) cannot answer a desktop root's
    /// question; nothing is resolved or attributed and no control is installed.
    func testPlainMCPRespondToUncontrolledRootQuestionIsRefused() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let interaction = makeQuestionForm()
        let asked = Task { try await viewModel.askUser(tabID: session.tabID, interaction: interaction) }
        defer { asked.cancel() }
        try await waitUntil("the question to be pending") { session.pendingAskUser?.interaction.id == interaction.id }

        for clientName in ["agent-run-steer-resume-tests", Self.remoteDeviceID] {
            let service = makeService(window: window, clientName: clientName, gatewayRemoteDeviceID: nil)
            do {
                _ = try await service.execute(args: [
                    "op": .string("respond"),
                    "session_id": .string(sessionID.uuidString),
                    "interaction_id": .string(interaction.id.uuidString),
                    "answers": .object(["target": .string("staging"), "notes": .string("none")])
                ])
                XCTFail("A plain MCP client must not answer an uncontrolled root's question (\(clientName))")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
            XCTAssertEqual(session.pendingAskUser?.interaction.id, interaction.id, clientName)
            XCTAssertNil(session.pendingInteractionResolutionAttribution, clientName)
            XCTAssertNil(session.lastInteractionResolution, clientName)
        }
        viewModel.skipAskUser(tabID: session.tabID, interactionID: interaction.id)
        _ = try? await asked.value
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    func testGatewayDeviceCannotResolveMCPElicitationOnRoot() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let elicitation = AgentMCPElicitationRequest(
            requestID: .string("remote-root-elicitation"),
            method: "mcpServer/elicitation/request",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            prompt: "Provide a value",
            rawParamsJSON: "{}"
        )
        session.pendingMCPElicitationRequest = elicitation
        defer { session.pendingMCPElicitationRequest = nil }

        let service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)
        do {
            _ = try await service.execute(args: [
                "op": .string("respond"),
                "session_id": .string(sessionID.uuidString),
                "interaction_id": .string(elicitation.id.uuidString),
                "response": .string("accept")
            ])
            XCTFail("A paired device must not resolve MCP elicitations")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Resolve it on the Mac"), String(describing: error))
        }
        XCTAssertEqual(session.pendingMCPElicitationRequest?.id, elicitation.id)
        XCTAssertNil(session.pendingInteractionResolutionAttribution)
        XCTAssertNil(session.lastInteractionResolution)
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    func testGatewayDeviceStopsRunningRootThroughDesktopStop() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let runID = try XCTUnwrap(session.runID)
        let service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)

        do {
            _ = try await service.execute(args: [
                "op": .string("cancel"),
                "session_id": .string(sessionID.uuidString),
                "run_id": .string(UUID().uuidString)
            ])
            XCTFail("A different run_id must be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("run_id"), String(describing: error))
        }
        XCTAssertEqual(session.runState, .running)

        let value = try await service.execute(args: [
            "op": .string("cancel"),
            "session_id": .string(sessionID.uuidString),
            "run_id": .string(runID.uuidString)
        ])

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.cancelled.rawValue)
        await assertNoMCPControl(
            session,
            sessionID: sessionID,
            viewModel: viewModel,
            controlledTabsBefore: controlledTabsBefore
        )
    }

    /// Waiting on a live root without an MCP registration samples the truthful live snapshot: it
    /// neither reports an expired handle nor collapses a running root to completed.
    func testWaitOnLiveUnregisteredRootSamplesUntilSettledOrTimeout() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        AgentRunMCPToolService.liveUnregisteredWaitPollSecondsOverride = 0.01
        defer { AgentRunMCPToolService.liveUnregisteredWaitPollSecondsOverride = nil }
        let viewModel = window.agentModeViewModel
        let (session, sessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let (otherSession, otherSessionID) = try await makeRemoteRoot(in: window, runState: .running)
        let controlledTabsBefore = viewModel.mcpControlledTabIDs
        let service = makeService(window: window, gatewayRemoteDeviceID: Self.remoteDeviceID)

        let multi = try await service.execute(args: [
            "op": .string("wait"),
            "session_ids": .array([.string(sessionID.uuidString), .string(otherSessionID.uuidString)]),
            "timeout": .double(0.05)
        ])
        XCTAssertEqual(multi.objectValue?["_meta"]?.objectValue?["wait_result"]?.stringValue, "timed_out", "\(multi)")
        XCTAssertEqual(multi.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)

        let timedOut = try await service.execute(args: [
            "op": .string("wait"),
            "session_id": .string(sessionID.uuidString),
            "timeout": .double(0.05)
        ])
        let timedOutObject = try XCTUnwrap(timedOut.objectValue)
        XCTAssertEqual(timedOutObject["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(timedOutObject["_meta"]?.objectValue?["wait_result"]?.stringValue, "timed_out")

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(sessionID.uuidString),
                "timeout": .double(5)
            ])
        }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        session.runState = .completed
        let settled = try await waitTask.value
        XCTAssertEqual(settled.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)

        // A multi-wait over two live roots, one of which has already settled, returns that root
        // as ready immediately (the sampled multi-wait wake itself is covered by the mixed-wait
        // tests in AgentRunMCPToolServiceWaitTests).
        let multiReady = try await service.execute(args: [
            "op": .string("wait"),
            "session_ids": .array([.string(otherSessionID.uuidString), .string(sessionID.uuidString)]),
            "timeout": .double(5)
        ])
        XCTAssertEqual(multiReady.objectValue?["session_id"]?.stringValue, sessionID.uuidString, "\(multiReady)")
        XCTAssertEqual(otherSession.runState, .running)
        for (root, rootID) in [(session, sessionID), (otherSession, otherSessionID)] {
            await assertNoMCPControl(
                root,
                sessionID: rootID,
                viewModel: viewModel,
                controlledTabsBefore: controlledTabsBefore
            )
        }
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
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        clientName: String = "agent-run-steer-resume-tests",
        gatewayRemoteDeviceID: String? = nil
    ) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: clientName,
                    windowID: window.windowID,
                    actorRoutedRunTab: nil,
                    gatewayRemoteDeviceID: gatewayRemoteDeviceID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}
