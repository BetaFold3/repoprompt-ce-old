import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    /// `workspace_steer request_grant`, Step 4 (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
    ///
    /// Each call goes through a registered window's production tool catalog and request-metadata
    /// override into the real service, a real `WorkspaceApprovalManager` (isolated settings storage,
    /// no app or window activation) and a real grant store on a temporary settings file. The test
    /// plays the owner by resolving the pending request as the overlay's buttons do. Nothing touches
    /// real settings, launches an app, or shows a window.
    @MainActor
    final class WorkspaceSteeringGrantRequestTests: XCTestCase {
        private typealias Service = WorkspaceSteeringMCPToolService
        private typealias Reply = WorkspaceSteeringMCPToolService.GrantRequestReply

        private struct LiveSession {
            let tabID: UUID
            let sessionID: UUID
            let session: AgentTabSession
        }

        private static let clientName = "workspace-steering-grant-request-tests"
        /// `WorkspaceApprovalManager`'s settings key.
        private static let approvalSettingsKey = "workspace.approvalSettings"

        private var grantStore: WorkspaceSteeringGrantStore!
        private var approvalDefaults: UserDefaults!

        override func setUp() async throws {
            try await super.setUp()
            grantStore = try makeGrantStore()
            let suiteName = "WorkspaceSteeringGrantRequestTests.approval.\(UUID().uuidString)"
            approvalDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            }
        }

        override func tearDown() async throws {
            grantStore = nil
            approvalDefaults = nil
            try await super.tearDown()
        }

        // MARK: - Allow

        /// Allow writes exactly one grant for the caller's workspace pair. The prompt is queued on the
        /// caller's window with app-authored names, IDs and wording only; Always Allow is ignored (no
        /// client policy). A second request then returns `already_granted` without a prompt.
        func testAllowWritesExactlyOneGrantAndAnExistingGrantReturnsAlreadyGrantedWithoutAPrompt() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = addWorkspace(to: source, name: "Target")
            _ = try routeSource(source)

            let call = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingRequest != nil }
            let request = try XCTUnwrap(manager.pendingRequest)
            XCTAssertTrue(manager.isApprovalOverlayVisible)
            XCTAssertEqual(request.operation, .workspaceSteeringGrant)
            XCTAssertFalse(request.operation.allowsAutoApproval)
            XCTAssertEqual(request.windowID, source.windowID)
            XCTAssertEqual(request.steeringGrant, WorkspaceSteeringGrantApprovalDetails(
                sourceWorkspaceID: sourceWorkspace.id,
                sourceWorkspaceName: sourceWorkspace.name,
                targetWorkspaceID: target.id,
                targetWorkspaceName: target.name
            ))
            XCTAssertEqual(
                request.detailedDescription,
                "Allow every session in '\(sourceWorkspace.name)' to list and steer top-level sessions in '\(target.name)' until you revoke it?"
            )
            XCTAssertNil(request.workspaceName)
            XCTAssertNil(request.folderPath)
            XCTAssertTrue(grantStore.grants.isEmpty, "Nothing is written before the owner answers")

            // An answer without the displayed request's ID, or for another request, is ignored.
            manager.resolveApproval(allow: true)
            manager.resolveApproval(allow: true, expectedRequestID: UUID())
            XCTAssertEqual(manager.pendingRequest?.id, request.id, "Unbound or stale answers leave the prompt pending")
            XCTAssertTrue(manager.isApprovalOverlayVisible)
            XCTAssertTrue(grantStore.grants.isEmpty)

            manager.resolveApproval(allow: true, alwaysAllow: true, expectedRequestID: request.id)
            let reply = try await call.value
            XCTAssertEqual(reply.status, .granted)
            XCTAssertEqual(grantStore.grants.map(\.sourceWorkspaceID), [sourceWorkspace.id])
            XCTAssertEqual(grantStore.grants.map(\.targetWorkspaceID), [target.id])
            XCTAssertTrue(grantStore.isGranted(source: sourceWorkspace.id, target: target.id))
            XCTAssertFalse(grantStore.isGranted(source: target.id, target: sourceWorkspace.id), "Grants are one-way")
            XCTAssertTrue(manager.settings.clientPolicies.isEmpty, "Always Allow creates no client policy")
            XCTAssertNil(manager.pendingRequest)

            let again = try await requestGrant(source, target: target.id).value
            XCTAssertEqual(again.status, .alreadyGranted)
            XCTAssertNil(manager.pendingRequest, "An existing grant never prompts")
            XCTAssertEqual(manager.pendingQueueCountForTesting, 0)
            XCTAssertEqual(grantStore.grants.count, 1)
        }

        /// A grant created in Settings returns `already_granted` without a prompt, even when the
        /// calling tab holds no live run (nothing would be written).
        func testSettingsGrantReturnsAlreadyGrantedWithoutAPrompt() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = addWorkspace(to: source, name: "Target")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: target.id), .added)
            try routeWithoutLiveSession(source)

            let reply = try await requestGrant(source, target: target.id).value
            XCTAssertEqual(reply.status, .alreadyGranted)
            XCTAssertNil(manager.pendingRequest)
            XCTAssertEqual(grantStore.grants.count, 1)
        }

        // MARK: - Deny and cancellation

        /// Deny, cancelling the call while its prompt is shown or still queued behind another
        /// request, and closing the caller's window all report `denied` and write nothing; a
        /// cancelled queued request leaves the active request in place.
        func testDenyAndCancellationOfActiveOrQueuedRequestsWriteNothing() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let target = addWorkspace(to: source, name: "Target")
            _ = try routeSource(source)

            // Deny.
            let denied = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingRequest?.operation == .workspaceSteeringGrant }
            try answer(manager, allow: false)
            let deniedReply = try await denied.value
            XCTAssertEqual(deniedReply.status, .denied)
            XCTAssertTrue(grantStore.grants.isEmpty)

            // Cancelling the call (as the tool watchdog does) while its prompt is shown.
            let cancelledActive = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingRequest?.operation == .workspaceSteeringGrant }
            cancelledActive.cancel()
            let cancelledActiveReply = try await cancelledActive.value
            XCTAssertEqual(cancelledActiveReply.status, .denied)
            XCTAssertNil(manager.pendingRequest)
            XCTAssertFalse(manager.isApprovalOverlayVisible)

            // Cancelling the call while its prompt is queued behind another request.
            let other = WorkspaceApprovalRequest(
                clientID: "other-client",
                operation: .createWorkspace,
                workspaceName: "Other",
                windowID: source.windowID
            )
            let otherApproval = Task { @MainActor in await manager.requestApproval(for: other) }
            try await waitUntil { manager.pendingRequest?.id == other.id }
            let cancelledQueued = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingQueueCountForTesting == 1 }
            cancelledQueued.cancel()
            let cancelledQueuedReply = try await cancelledQueued.value
            XCTAssertEqual(cancelledQueuedReply.status, .denied)
            XCTAssertEqual(manager.pendingRequest?.id, other.id, "The active request stays")
            XCTAssertEqual(manager.pendingQueueCountForTesting, 0)

            // Closing the caller's window denies its queued grant request.
            let closedQueued = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingQueueCountForTesting == 1 }
            manager.cancelPending(forWindowID: source.windowID)
            let closedQueuedReply = try await closedQueued.value
            XCTAssertEqual(closedQueuedReply.status, .denied)
            guard case .denied = await otherApproval.value else {
                return XCTFail("Closing the window denies its other request too")
            }
            XCTAssertNil(manager.pendingRequest)
            XCTAssertTrue(grantStore.grants.isEmpty, "Deny and cancellation write nothing")
        }

        /// An answer bound to a prompt that was cancelled, after a queued grant request was promoted
        /// in its place, is ignored (as the overlay's delayed Allow/Deny pass the displayed request's
        /// ID); the promoted request is approved only by an answer bound to it.
        func testStaleAnswerForACancelledPromptCannotResolveThePromotedGrantRequest() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let first = addWorkspace(to: source, name: "First target")
            let second = addWorkspace(to: source, name: "Second target")
            _ = try routeSource(source)

            let firstCall = requestGrant(source, target: first.id)
            try await waitUntil { manager.pendingRequest?.steeringGrant?.targetWorkspaceID == first.id }
            let displayedID = try XCTUnwrap(manager.pendingRequest?.id)
            let secondCall = requestGrant(source, target: second.id)
            try await waitUntil { manager.pendingQueueCountForTesting == 1 }

            // The displayed prompt times out (watchdog cancellation); the queued request is promoted.
            firstCall.cancel()
            let firstReply = try await firstCall.value
            XCTAssertEqual(firstReply.status, .denied)
            try await waitUntil { manager.pendingRequest?.steeringGrant?.targetWorkspaceID == second.id }
            let promotedID = try XCTUnwrap(manager.pendingRequest?.id)
            XCTAssertNotEqual(promotedID, displayedID)

            // The owner's click on the old prompt lands after the promotion: Allow, then Deny.
            manager.resolveApproval(allow: true, expectedRequestID: displayedID)
            manager.resolveApproval(allow: false, expectedRequestID: displayedID)
            XCTAssertEqual(manager.pendingRequest?.id, promotedID, "A stale answer leaves the promoted request pending")
            XCTAssertTrue(manager.isApprovalOverlayVisible)
            XCTAssertTrue(grantStore.grants.isEmpty)

            manager.resolveApproval(allow: true, expectedRequestID: promotedID)
            let secondReply = try await secondCall.value
            XCTAssertEqual(secondReply.status, .granted)
            XCTAssertEqual(grantStore.grants.map(\.targetWorkspaceID), [second.id])
            XCTAssertEqual(grantStore.grants.map(\.sourceWorkspaceID), [sourceWorkspace.id])
        }

        // MARK: - Auto-approval never grants

        /// Stored global, per-operation and per-client auto-approval (including entries naming this
        /// operation, as a hand-edited or stale setting would) never skip the prompt, at admission or
        /// when a queued request is promoted. Always Allow on Allow adds no policy, and the setters
        /// refuse to store auto-approval for this operation.
        func testAutoApprovalSettingsAndClientPoliciesNeverSkipThePromptAtAdmissionOrPromotion() async throws {
            var policy = WorkspaceApprovalClientPolicy(clientID: Self.clientName)
            policy.allowedOperations = Set(WorkspaceApprovalOperation.allCases)
            let seeded = WorkspaceApprovalSettings(
                autoApproveAll: true,
                autoApproveOperations: Set(WorkspaceApprovalOperation.allCases),
                clientPolicies: [Self.clientName: policy]
            )
            try approvalDefaults.set(JSONEncoder().encode(seeded), forKey: Self.approvalSettingsKey)
            let manager = makeManager()
            XCTAssertTrue(manager.settings.autoApproveAll, "The seeded settings are in effect")
            XCTAssertTrue(manager.settings.shouldAutoApprove(operation: .createWorkspace, clientID: Self.clientName))
            XCTAssertFalse(manager.settings.shouldAutoApprove(operation: .workspaceSteeringGrant, clientID: Self.clientName))

            let source = try await makeWindow(name: "Assistant", manager: manager)
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let first = addWorkspace(to: source, name: "First target")
            let second = addWorkspace(to: source, name: "Second target")
            _ = try routeSource(source)

            // Initial admission prompts despite every auto-approval setting.
            let firstCall = requestGrant(source, target: first.id)
            try await waitUntil { manager.pendingRequest?.steeringGrant?.targetWorkspaceID == first.id }
            // A second request queues; promotion after the first is answered prompts again.
            let secondCall = requestGrant(source, target: second.id)
            try await waitUntil { manager.pendingQueueCountForTesting == 1 }
            try answer(manager, allow: false)
            let firstReply = try await firstCall.value
            XCTAssertEqual(firstReply.status, .denied)
            try await waitUntil { manager.pendingRequest?.steeringGrant?.targetWorkspaceID == second.id }
            XCTAssertTrue(manager.isApprovalOverlayVisible, "A promoted request is shown, not auto-approved")
            XCTAssertTrue(grantStore.grants.isEmpty)

            try answer(manager, allow: true, alwaysAllow: true)
            let secondReply = try await secondCall.value
            XCTAssertEqual(secondReply.status, .granted)
            XCTAssertEqual(grantStore.grants.map(\.targetWorkspaceID), [second.id])
            XCTAssertEqual(grantStore.grants.map(\.sourceWorkspaceID), [sourceWorkspace.id])
            XCTAssertEqual(manager.settings.clientPolicies.count, 1)
            XCTAssertEqual(manager.settings.clientPolicies[Self.clientName]?.allowedOperations, policy.allowedOperations)

            // Owner-facing setters never store auto-approval for this operation.
            let freshSuite = "WorkspaceSteeringGrantRequestTests.fresh.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults(suiteName: freshSuite)?.removePersistentDomain(forName: freshSuite) }
            let fresh = try makeManager(defaults: XCTUnwrap(UserDefaults(suiteName: freshSuite)))
            fresh.setAutoApproveOperation(.workspaceSteeringGrant, enabled: true)
            fresh.addAutoApproval(clientID: Self.clientName, operation: .workspaceSteeringGrant)
            XCTAssertFalse(fresh.settings.autoApproveOperations.contains(.workspaceSteeringGrant))
            XCTAssertTrue(fresh.settings.clientPolicies.isEmpty)
            XCTAssertFalse(WorkspaceApprovalOperation.autoApprovableCases.contains(.workspaceSteeringGrant))
            XCTAssertEqual(
                Set(WorkspaceApprovalOperation.autoApprovableCases),
                [.createWorkspace, .deleteWorkspace, .addFolder, .removeFolder],
                "Existing operations stay offered for auto-approval"
            )
        }

        // MARK: - Revalidation and refusals

        /// After Allow, the caller is revalidated from the same captured route and the target from
        /// the workspace list: a different run in the caller's tab, or a target removed while the
        /// prompt was open, writes nothing.
        func testAllowAfterTheCallerRunOrTargetChangedWritesNothing() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let target = addWorkspace(to: source, name: "Target")
            let caller = try routeSource(source)

            let replacedRun = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingRequest != nil }
            let originalRunID = caller.session.runID
            caller.session.runID = UUID()
            try answer(manager, allow: true)
            await assertRefusal(replacedRun, Service.callerChangedDuringRequestMessage)
            XCTAssertTrue(grantStore.grants.isEmpty)
            caller.session.runID = originalRunID

            let removedTarget = requestGrant(source, target: target.id)
            try await waitUntil { manager.pendingRequest != nil }
            source.workspaceManager.workspaces.removeAll { $0.id == target.id }
            try answer(manager, allow: true)
            await assertRefusal(removedTarget, Service.targetGoneDuringRequestMessage)
            XCTAssertTrue(grantStore.grants.isEmpty)
        }

        /// A cancellation (as the tool watchdog delivers) that arrives after Allow, while the caller
        /// revalidation is suspended in its gateway check, writes nothing and reports `denied`. The
        /// production service is built directly so its injected gateway check can be held.
        func testCancellationDuringRevalidationAfterAllowWritesNothing() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let target = addWorkspace(to: source, name: "Target")
            _ = try routeSource(source)
            let gate = GatewayCheckGate(holdOnCall: 2)
            let service = Service(
                captureRequestMetadata: { await source.mcpServer.captureRequestMetadata() },
                isGatewayPrincipalConnection: { _ in await gate.check() },
                windows: { WindowStatesManager.shared.allWindows },
                grantStore: { [grantStore] in grantStore! },
                approvalManager: { manager }
            )

            let call = Task { @MainActor in
                try await service.execute(args: [
                    "op": .string("request_grant"),
                    "target_workspace_id": .string(target.id.uuidString)
                ])
            }
            try await waitUntil { manager.pendingRequest != nil }
            XCTAssertEqual(gate.calls, 1, "Entry ran the gateway check once")
            try answer(manager, allow: true)
            try await waitUntil { gate.isHolding }
            call.cancel()
            gate.release()

            let value = try await call.value
            let reply = try JSONDecoder().decode(Reply.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(reply.status, .denied)
            XCTAssertEqual(gate.calls, 2)
            XCTAssertTrue(grantStore.grants.isEmpty, "A cancellation during revalidation writes nothing")
        }

        /// A malformed, self or unknown target, and a caller tab with no live run, are refused before
        /// any prompt.
        func testInvalidTargetsAndACallerWithoutALiveRunAreRefusedWithoutAPrompt() async throws {
            let manager = makeManager()
            let source = try await makeWindow(name: "Assistant", manager: manager)
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = addWorkspace(to: source, name: "Target")
            _ = try routeSource(source)

            await assertRefusal(
                requestGrant(source, args: ["op": .string("request_grant"), "target_workspace_id": .string("nope")]),
                "must be a workspace UUID. No grant was requested."
            )
            await assertRefusal(requestGrant(source, target: sourceWorkspace.id), Service.selfGrantMessage)
            let unknown = UUID()
            await assertRefusal(
                requestGrant(source, target: unknown),
                Service.unknownTargetMessage(workspaceID: unknown.uuidString)
            )

            try routeWithoutLiveSession(source)
            await assertRefusal(requestGrant(source, target: target.id), Service.sourceSessionUnavailableForGrantMessage)
            XCTAssertNil(manager.pendingRequest)
            XCTAssertTrue(grantStore.grants.isEmpty)
        }

        // MARK: - Fixtures

        /// Injected gateway check that suspends on its `holdOnCall`-th call until released, without
        /// observing cancellation (as an in-flight actor hop would not).
        @MainActor
        private final class GatewayCheckGate {
            private let holdOnCall: Int
            private var continuation: CheckedContinuation<Void, Never>?
            private(set) var calls = 0
            private(set) var isHolding = false

            init(holdOnCall: Int) {
                self.holdOnCall = holdOnCall
            }

            func check() async -> Bool {
                calls += 1
                if calls == holdOnCall {
                    isHolding = true
                    await withCheckedContinuation { continuation = $0 }
                }
                return false
            }

            func release() {
                isHolding = false
                continuation?.resume()
                continuation = nil
            }
        }

        /// The owner answering the shown prompt, bound to its request ID as the overlay does.
        private func answer(_ manager: WorkspaceApprovalManager, allow: Bool, alwaysAllow: Bool = false) throws {
            let requestID = try XCTUnwrap(manager.pendingRequest?.id, "No prompt is shown")
            manager.resolveApproval(allow: allow, alwaysAllow: alwaysAllow, expectedRequestID: requestID)
        }

        private func makeManager(defaults: UserDefaults? = nil) -> WorkspaceApprovalManager {
            let manager = WorkspaceApprovalManager.makeForTesting(defaults: defaults ?? approvalDefaults)
            addTeardownBlock { @MainActor in manager.cancelAllPending() }
            return manager
        }

        private func makeGrantStore() throws -> WorkspaceSteeringGrantStore {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringGrantRequestTests-\(UUID().uuidString)", isDirectory: true)
            let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let suiteName = "WorkspaceSteeringGrantRequestTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: root)
            }
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            return WorkspaceSteeringGrantStore(settings: settings)
        }

        /// A registered window whose active workspace is new, using this test's grant store and
        /// approval manager. Unregistered at teardown.
        private func makeWindow(name: String, manager: WorkspaceApprovalManager) async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = nil
                window.mcpServer.workspaceApprovalManagerOverrideForTesting = nil
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            let workspace = addWorkspace(to: window, name: name)
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "workspaceSteeringGrantRequestTests"
            )
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, workspace.id, "switch: \(result)")
            window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = grantStore
            window.mcpServer.workspaceApprovalManagerOverrideForTesting = manager
            return window
        }

        /// Appends an ephemeral workspace (saved under a temporary folder) without switching to it.
        private func addWorkspace(to window: WindowState, name: String) -> WorkspaceModel {
            let storage = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringGrantRequestTests-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
            let workspace = WorkspaceModel(
                name: "\(name) \(UUID().uuidString.prefix(6))",
                repoPaths: [],
                customStoragePath: storage,
                ephemeralFlag: true
            )
            window.workspaceManager.workspaces.append(workspace)
            return workspace
        }

        private func addTab(to window: WindowState, name: String) throws -> UUID {
            let manager = window.workspaceManager
            let workspaceID = try XCTUnwrap(manager.activeWorkspace?.id)
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            let tabID = UUID()
            manager.workspaces[index].composeTabs.append(ComposeTabState(id: tabID, name: name))
            window.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index], syncPromptText: false)
            return tabID
        }

        /// A running source session in a new tab of `source`, and its tool calls routed as that
        /// session's Agent Mode run (the route's run ID is the session's process run ID).
        private func routeSource(_ source: WindowState) throws -> LiveSession {
            let workspaceID = try XCTUnwrap(source.workspaceManager.activeWorkspace?.id)
            let tabID = try addTab(to: source, name: "Assistant run")
            let sessionID = UUID()
            let session = try XCTUnwrap(source.agentModeViewModel.session(for: tabID, createIfNeeded: true))
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            session.hasLoadedPersistedState = true
            let runID = UUID()
            session.runID = runID
            session.runState = .running
            session.beginRunAttempt(source: "test.workspaceSteeringGrantRequest")
            session.appendItem(.user("first", sequenceIndex: session.nextSequenceIndex))
            source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: UUID(),
                clientName: Self.clientName,
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: runID, windowID: source.windowID, workspaceID: workspaceID, tabID: tabID)
            ))
            return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
        }

        /// Routes `source`'s calls as an Agent Mode run in a new tab that holds no live session.
        private func routeWithoutLiveSession(_ source: WindowState) throws {
            let workspaceID = try XCTUnwrap(source.workspaceManager.activeWorkspace?.id)
            let tabID = try addTab(to: source, name: "Assistant run")
            source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: UUID(),
                clientName: Self.clientName,
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: UUID(), windowID: source.windowID, workspaceID: workspaceID, tabID: tabID)
            ))
        }

        private func requestGrant(_ window: WindowState, target: UUID) -> Task<Reply, Error> {
            requestGrant(window, args: [
                "op": .string("request_grant"),
                "target_workspace_id": .string(target.uuidString)
            ])
        }

        /// Calls `workspace_steer` through the window's production tool catalog.
        private func requestGrant(_ window: WindowState, args: [String: Value]) -> Task<Reply, Error> {
            Task { @MainActor in
                let tools = await window.mcpServer.windowMCPTools
                let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.workspaceSteer })
                let value = try await tool(args)
                return try JSONDecoder().decode(Reply.self, from: JSONEncoder().encode(value))
            }
        }

        private func assertRefusal(
            _ call: Task<Reply, Error>,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                let reply = try await call.value
                XCTFail("Expected refusal containing \(message); got \(reply)", file: file, line: line)
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(message),
                    "Expected \(message); got \(error)",
                    file: file,
                    line: line
                )
            }
        }

        private func waitUntil(
            timeout: TimeInterval = 5,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ condition: @escaping @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for condition", file: file, line: line)
        }
    }
#endif
