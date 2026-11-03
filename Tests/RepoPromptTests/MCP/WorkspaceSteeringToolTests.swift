import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    /// `workspace_steer` Step 2 (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md):
    /// tool advertisement through real Agent Mode lease policies, caller derivation from the actor
    /// run route, and `list` over real registered windows and their Agent Mode view models. Tool
    /// calls go through each window's production tool catalog. Grants use a temporary settings
    /// file; nothing touches real settings, launches an app, or sends anything.
    @MainActor
    final class WorkspaceSteeringToolTests: XCTestCase {
        private typealias Service = WorkspaceSteeringMCPToolService
        private typealias ListReply = WorkspaceSteeringMCPToolService.ListReply

        private struct LiveSession {
            let tabID: UUID
            let sessionID: UUID
            let session: AgentTabSession
        }

        private struct RoutedRun {
            let runID: UUID
            let connectionID: UUID
            let clientName: String
        }

        private struct RoutingServiceUnavailable: Error {}

        private var grantStore: WorkspaceSteeringGrantStore!
        private var grantFileURL: URL!

        override func setUp() async throws {
            try await super.setUp()
            grantStore = try makeGrantStore()
        }

        override func tearDown() async throws {
            grantStore = nil
            grantFileURL = nil
            try await super.tearDown()
        }

        // MARK: - Advertisement

        /// Every Agent Mode provider and profile grants the tool; it is policy-gated, so a
        /// connection without an Agent Mode run policy (an external client) never sees it, and it is
        /// not a delegation tool, so delegation leaves keep it.
        func testEveryAgentModeProviderAndProfileGrantsWorkspaceSteerAndItStaysPolicyGated() {
            XCTAssertTrue(MCPPolicyGatedTools.names.contains(MCPWindowToolName.workspaceSteer))
            XCTAssertFalse(AgentDelegationPolicy.delegationToolNames.contains(MCPWindowToolName.workspaceSteer))
            XCTAssertTrue(AgentModeMCPToolPolicy.knowledgeAllowedTools.contains(MCPWindowToolName.workspaceSteer))
            XCTAssertFalse(AgentModeMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.workspaceSteer))
            for agent in AgentProviderKind.allCases {
                for profile in [AgentSessionProfile.standard, .knowledge] {
                    XCTAssertTrue(
                        AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile)
                            .contains(MCPWindowToolName.workspaceSteer),
                        "\(agent) \(profile) must grant workspace_steer"
                    )
                }
            }
        }

        /// The production lease → connection policy path advertises the tool to a depth-2
        /// sub-worker, an explore session and a Knowledge research worker, all delegation leaves (no
        /// `agent_run`), as well as to a root (which also sees `agent_run`). Each lease has the tool in
        /// its configured connection policy state and lists the granted target through the
        /// production catalog under its own
        /// connection.
        func testDepthTwoExploreAndKnowledgeWorkerLeasesAdvertiseAndCallWorkspaceSteerList() async throws {
            let window = try await makeWindow(name: "Lease Source")
            let sourceWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            try await registerCatalog(for: window)
            let target = try await makeWindow(name: "Lease Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let targetRoot = try makeSession(in: target, name: "Target root")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            struct LeaseCase {
                let label: String
                let decision: AgentDelegationPolicy.Decision
                let role: AgentModelCatalog.TaskLabelKind
                let profile: AgentSessionProfile
                let expectsAgentRun: Bool
            }
            let rootDecision = AgentDelegationPolicy.decision(taskLabelKind: .pair, lineage: .resolved(depth: 0))
            let depthTwoDecision = AgentDelegationPolicy.decision(taskLabelKind: .pair, lineage: .resolved(depth: 2))
            let exploreDecision = AgentDelegationPolicy.decision(taskLabelKind: .explore, lineage: .resolved(depth: 1))
            let knowledgeWorkerDecision = AgentDelegationPolicy.decision(
                taskLabelKind: .engineer,
                lineage: .resolved(depth: 1),
                sessionProfile: .knowledge
            )
            XCTAssertEqual(rootDecision, .eligible(depth: 0))
            XCTAssertEqual(depthTwoDecision, .depthLimit(depth: 2))
            XCTAssertEqual(exploreDecision, .exploreLeaf)
            XCTAssertEqual(knowledgeWorkerDecision, .knowledgeLeaf(depth: 1))

            let cases = [
                LeaseCase(label: "root", decision: rootDecision, role: .pair, profile: .standard, expectsAgentRun: true),
                LeaseCase(label: "depth-2", decision: depthTwoDecision, role: .pair, profile: .standard, expectsAgentRun: false),
                LeaseCase(label: "explore", decision: exploreDecision, role: .explore, profile: .standard, expectsAgentRun: false),
                LeaseCase(label: "knowledge worker", decision: knowledgeWorkerDecision, role: .engineer, profile: .knowledge, expectsAgentRun: false)
            ]
            for leaseCase in cases {
                let policy = AgentDelegationPolicy.runToolPolicy(
                    decision: leaseCase.decision,
                    taskLabelKind: leaseCase.role,
                    sessionProfile: leaseCase.profile
                )
                let tabID = try addTab(to: window, name: "Lease \(leaseCase.label)")
                let run = try await routeRun(
                    window: window,
                    tabID: tabID,
                    role: leaseCase.role,
                    profile: leaseCase.profile,
                    policy: policy
                )
                let tools = try await ServerNetworkManager.shared.debugListToolNames(for: run.connectionID)
                XCTAssertTrue(
                    tools.contains(MCPWindowToolName.workspaceSteer),
                    "\(leaseCase.label) lease must advertise workspace_steer. Tools: \(tools)"
                )
                XCTAssertEqual(
                    tools.contains(MCPWindowToolName.agentRun),
                    leaseCase.expectsAgentRun,
                    "\(leaseCase.label) lease agent_run advertisement. Tools: \(tools)"
                )
                let policyState = await ServerNetworkManager.shared.debugConnectionPolicyState(for: run.connectionID)
                XCTAssertTrue(
                    policyState.additionalTools.contains(MCPWindowToolName.workspaceSteer),
                    "\(leaseCase.label) lease policy state must grant workspace steering"
                )
                let reply = try await ServerNetworkManager.withConnectionID(run.connectionID) {
                    try await self.listReply(window, ["op": .string("list")])
                }
                XCTAssertEqual(reply.workspaces.map(\.workspaceID), [targetWorkspace.id.uuidString], leaseCase.label)
                XCTAssertEqual(
                    reply.workspaces.first?.sessions.map(\.sessionID),
                    [targetRoot.sessionID.uuidString],
                    leaseCase.label
                )
            }
        }

        /// An explore leaf steers through its production route: the lease's run ID is the session's
        /// process run ID (as `makeLease(runID)` builds it from `AgentModeProcessRunIdentity`), the
        /// installed policy grants `workspace_steer`, and a send under that connection's real request
        /// context is attributed to the explore session. Once the session's process run is replaced,
        /// the old connection's route no longer matches and is refused without sending.
        func testExploreLeafSourceSendsThroughItsProductionRouteAndAReplacedRunIsRefused() async throws {
            let window = try await makeWindow(name: "Explore Source")
            let sourceWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            try await registerCatalog(for: window)
            let target = try await makeWindow(name: "Explore Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let targetVM = target.agentModeViewModel
            let targetSettings = target.apiSettingsViewModel
            let previousOpenCode = targetSettings.isOpenCodeConnected
            addTeardownBlock { @MainActor in
                targetSettings.isOpenCodeConnected = previousOpenCode
                targetVM.test_workspaceSteeringGrantStoreOverride = nil
            }
            targetVM.test_workspaceSteeringGrantStoreOverride = grantStore
            targetSettings.isOpenCodeConnected = true
            let targetRoot = try makeSession(in: target, name: "Target root")
            targetRoot.session.selectedAgent = .openCode
            targetRoot.session.runID = UUID()
            targetRoot.session.runState = .running
            targetRoot.session.beginRunAttempt(source: "test.workspaceSteering.exploreTarget")
            targetRoot.session.appendItem(.user("first", sequenceIndex: targetRoot.session.nextSequenceIndex))
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            let parent = try makeSession(in: window, name: "Explore parent")
            let explore = try makeSession(in: window, name: "Explore child", parent: parent.sessionID)
            let processRunID = AgentModeProcessRunIdentity.startFreshProcessRun(for: explore.session)
            explore.session.runState = .running
            explore.session.beginRunAttempt(source: "test.workspaceSteering.explore")
            let decision = AgentDelegationPolicy.decision(taskLabelKind: .explore, lineage: .resolved(depth: 1))
            XCTAssertEqual(decision, .exploreLeaf)
            let run = try await routeRun(
                window: window,
                tabID: explore.tabID,
                role: .explore,
                profile: .standard,
                policy: AgentDelegationPolicy.runToolPolicy(decision: decision, taskLabelKind: .explore, sessionProfile: .standard),
                runID: processRunID
            )
            let tools = try await ServerNetworkManager.shared.debugListToolNames(for: run.connectionID)
            XCTAssertTrue(tools.contains(MCPWindowToolName.workspaceSteer), "Tools: \(tools)")
            let args: [String: Value] = [
                "op": .string("send"),
                "target_workspace_id": .string(targetWorkspace.id.uuidString),
                "session_id": .string(targetRoot.sessionID.uuidString),
                "message": .string("From the explore leaf")
            ]

            let value = try await ServerNetworkManager.withConnectionID(run.connectionID) {
                try await self.callSteer(window, args)
            }
            let reply = try JSONDecoder().decode(Service.SendReply.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(reply.delivery, "queued_follow_up")
            let expected = "[Steer from workspace \"\(sourceWorkspace.name)\" (\(sourceWorkspace.id.uuidString)), "
                + "session \(explore.sessionID.uuidString)]\n\nFrom the explore leaf"
            XCTAssertEqual(targetRoot.session.pendingInstructions.map(\.text), [expected])

            // A new process run for the explore session: the old connection's route names the
            // previous run and is never credited to the new one.
            _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: explore.session)
            do {
                let refused = try await ServerNetworkManager.withConnectionID(run.connectionID) {
                    try await self.callSteer(window, args)
                }
                XCTFail("A replaced run must be refused; got \(refused)")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(Service.sourceSessionUnavailableMessage),
                    "\(error)"
                )
            }
            XCTAssertEqual(targetRoot.session.pendingInstructions.map(\.text), [expected], "Nothing more was sent")
            XCTAssertNil(targetRoot.session.mcpControlContext)
            XCTAssertTrue(targetVM.isAttentionNotificationRoot(targetRoot.session))
        }

        /// A connection with no Agent Mode lease (an external client) and a gateway-principal
        /// connection neither see the tool in `tools/list` nor have an additional-tool grant in
        /// their configured policy state. A call that reaches the tool under either connection's real
        /// request context is refused without listing anything.
        func testExternalAndGatewayConnectionsNeitherSeeNorCallWorkspaceSteer() async throws {
            let window = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            try await registerCatalog(for: window)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            _ = try makeSession(in: target, name: "Target root")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            let manager = ServerNetworkManager.shared
            let external = UUID()
            let gateway = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: gateway,
                clientName: "repoprompt-gateway",
                principal: .gateway
            )
            let isGateway = await manager.isGatewayPrincipalConnection(gateway)
            XCTAssertTrue(isGateway)

            let cases = [
                (label: "external", connectionID: external, message: Service.noRunRouteMessage),
                (label: "gateway", connectionID: gateway, message: Service.gatewayRefusalMessage)
            ]
            for connection in cases {
                let tools = try await manager.debugListToolNames(for: connection.connectionID)
                XCTAssertTrue(
                    tools.contains(MCPWindowToolName.readFile),
                    "Control: \(connection.label) still lists ungated tools. Tools: \(tools)"
                )
                XCTAssertFalse(tools.contains(MCPWindowToolName.workspaceSteer), "\(connection.label) tools: \(tools)")
                let policyState = await manager.debugConnectionPolicyState(for: connection.connectionID)
                XCTAssertFalse(
                    policyState.additionalTools.contains(MCPWindowToolName.workspaceSteer),
                    "\(connection.label) policy state must not grant workspace steering"
                )
                do {
                    let value = try await ServerNetworkManager.withConnectionID(connection.connectionID) {
                        try await self.callSteer(window, ["op": .string("list")])
                    }
                    XCTFail("\(connection.label) call must be refused; got \(value)")
                } catch {
                    XCTAssertTrue(
                        String(describing: error).contains(connection.message),
                        "\(connection.label): expected \(connection.message); got \(error)"
                    )
                }
            }
        }

        // MARK: - Caller derivation

        /// A connection routed by a real lease policy resolves the source from its run route: the
        /// route records the run tab's workspace, and `_windowID`, `context_id` and the window whose
        /// catalog handles the call do not change it. The source session is the one bound in the
        /// route-owned run tab.
        func testRoutedConnectionTakesSourceFromRunRouteNotArgumentsOrCallingWindow() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let runTab = try addTab(to: source, name: "Assistant run")
            let runSession = try makeSession(in: source, tabID: runTab)

            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let targetRoot = try makeSession(in: target, name: "Target root")

            let other = try await makeWindow(name: "Other")
            let otherWorkspace = try XCTUnwrap(other.workspaceManager.activeWorkspace)
            let otherTab = try addTab(to: other, name: "Other tab")
            let otherTarget = try await makeWindow(name: "Other Target")
            let otherTargetWorkspace = try XCTUnwrap(otherTarget.workspaceManager.activeWorkspace)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            XCTAssertEqual(grantStore.add(source: otherWorkspace.id, target: otherTargetWorkspace.id), .added)

            let run = try await routeRun(
                window: source,
                tabID: runTab,
                role: .pair,
                profile: .standard,
                policy: AgentDelegationPolicy.runToolPolicy(decision: .eligible(depth: 0), taskLabelKind: .pair)
            )
            let route = await ServerNetworkManager.shared.actorRoutedRunPolicyTab(for: run.connectionID)
            XCTAssertEqual(
                route,
                ServerNetworkManager.RunPolicyTab(
                    runID: run.runID,
                    windowID: source.windowID,
                    workspaceID: sourceWorkspace.id,
                    tabID: runTab
                ),
                "Applying the run policy records the run tab's workspace on the actor route"
            )

            let hostileArgs: [String: Value] = [
                "op": .string("list"),
                "_windowID": .int(other.windowID),
                "context_id": .string(otherTab.uuidString),
                "source_workspace_id": .string(otherWorkspace.id.uuidString)
            ]
            for calling in [source, other] {
                let reply = try await ServerNetworkManager.withConnectionID(run.connectionID) {
                    try await self.listReply(calling, hostileArgs)
                }
                XCTAssertEqual(reply.workspaces.map(\.workspaceID), [targetWorkspace.id.uuidString], "via window \(calling.windowID)")
                XCTAssertEqual(reply.workspaces.first?.sessions.map(\.sessionID), [targetRoot.sessionID.uuidString])
            }

            let service = productionService(for: other)
            let caller = try await ServerNetworkManager.withConnectionID(run.connectionID) {
                try await service.resolveCaller(metadata: other.mcpServer.captureRequestMetadata())
            }
            XCTAssertEqual(caller.runID, run.runID)
            XCTAssertEqual(caller.windowID, source.windowID)
            XCTAssertEqual(caller.tabID, runTab)
            XCTAssertEqual(caller.sourceWorkspaceID, sourceWorkspace.id)
            XCTAssertEqual(caller.sourceWorkspaceName, sourceWorkspace.name)
            XCTAssertEqual(caller.sourceSessionID, runSession.sessionID)
        }

        /// Request-level hints that point at another window, tab or workspace (`context_id`'s tab
        /// hint, a validated hidden `_windowID`, the request window) never move the source; only the
        /// route does.
        func testContextAndWindowHintsDoNotChangeTheSource() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let runTab = try addTab(to: source, name: "Assistant run")
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let other = try await makeWindow(name: "Other")
            let otherWorkspace = try XCTUnwrap(other.workspaceManager.activeWorkspace)
            let otherTab = try addTab(to: other, name: "Other tab")
            let otherTarget = try await makeWindow(name: "Other Target")
            let otherTargetWorkspace = try XCTUnwrap(otherTarget.workspaceManager.activeWorkspace)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            XCTAssertEqual(grantStore.add(source: otherWorkspace.id, target: otherTargetWorkspace.id), .added)

            let connectionID = UUID()
            let sourceRoute = ServerNetworkManager.RunPolicyTab(
                runID: UUID(),
                windowID: source.windowID,
                workspaceID: sourceWorkspace.id,
                tabID: runTab
            )
            other.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: connectionID,
                clientName: "workspace-steering-tests",
                windowID: other.windowID,
                runPurpose: .agentModeRun,
                tabContextHint: .init(tabID: otherTab, workspaceID: otherWorkspace.id, windowID: other.windowID),
                explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                    connectionID: connectionID,
                    toolName: MCPWindowToolName.workspaceSteer,
                    windowID: other.windowID,
                    windowStateIdentity: ObjectIdentifier(other),
                    serverViewModelIdentity: ObjectIdentifier(other.mcpServer),
                    provenance: .hiddenWindowArgument
                ),
                actorRoutedRunTab: sourceRoute
            ))
            let hinted = try await listReply(other, [
                "op": .string("list"),
                "_windowID": .int(other.windowID),
                "context_id": .string(otherTab.uuidString)
            ])
            XCTAssertEqual(hinted.workspaces.map(\.workspaceID), [targetWorkspace.id.uuidString])

            // Control: the route, and only the route, moves the source.
            other.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: connectionID,
                clientName: "workspace-steering-tests",
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: UUID(), windowID: other.windowID, workspaceID: otherWorkspace.id, tabID: otherTab)
            ))
            let rerouted = try await listReply(other, ["op": .string("list")])
            XCTAssertEqual(rerouted.workspaces.map(\.workspaceID), [otherTargetWorkspace.id.uuidString])
        }

        func testRefusesCallsWithoutAnAgentModeRunRoute() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let runTab = try addTab(to: source, name: "Assistant run")
            let route = ServerNetworkManager.RunPolicyTab(
                runID: UUID(),
                windowID: source.windowID,
                workspaceID: sourceWorkspace.id,
                tabID: runTab
            )

            // No request context at all: the production metadata capture has no connection.
            await assertRefused(source, ["op": .string("list")], message: Service.noRunRouteMessage)

            let refusedMetadata: [MCPServerViewModel.RequestMetadata] = [
                .init(connectionID: UUID(), clientName: "external-client", windowID: source.windowID, actorRoutedRunTab: nil),
                .init(connectionID: UUID(), clientName: "agent", windowID: source.windowID, runPurpose: .agentModeRun, actorRoutedRunTab: nil),
                .init(connectionID: UUID(), clientName: "unknown-purpose", windowID: source.windowID, runPurpose: .unknown, actorRoutedRunTab: route)
            ]
            for metadata in refusedMetadata {
                source.mcpServer.setRequestMetadataOverrideForTesting(metadata)
                await assertRefused(source, ["op": .string("list")], message: Service.noRunRouteMessage)
            }
        }

        /// A paired device is refused before anything else, even with a run route, whether the
        /// gateway is identified by the device ID in metadata or by the connection's principal.
        func testRefusesGatewayCallers() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let runTab = try addTab(to: source, name: "Assistant run")
            let route = ServerNetworkManager.RunPolicyTab(
                runID: UUID(),
                windowID: source.windowID,
                workspaceID: sourceWorkspace.id,
                tabID: runTab
            )
            source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: UUID(),
                clientName: "repoprompt-gateway",
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: route,
                gatewayRemoteDeviceID: "remote:abcd1234"
            ))
            await assertRefused(source, ["op": .string("list")], message: Service.gatewayRefusalMessage)

            let connectionID = UUID()
            let gatewayPrincipal = Service(
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: connectionID,
                        clientName: "agent",
                        windowID: source.windowID,
                        runPurpose: .agentModeRun,
                        actorRoutedRunTab: route
                    )
                },
                isGatewayPrincipalConnection: { $0 == connectionID },
                windows: { WindowStatesManager.shared.allWindows },
                grantStore: { [grantStore] in grantStore! }
            )
            do {
                _ = try await gatewayPrincipal.execute(args: ["op": .string("list")])
                XCTFail("A gateway-principal connection must be refused")
            } catch {
                XCTAssertTrue(String(describing: error).contains(Service.gatewayRefusalMessage), "\(error)")
            }
        }

        /// Missing route workspace, a window that no longer shows the route's workspace, and a
        /// route window that no longer exists all refuse; nothing falls back to the request window.
        func testRefusesWhenTheRouteWorkspaceIsMissingOrNoLongerShown() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let runTab = try addTab(to: source, name: "Assistant run")
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            let background = addWorkspace(to: source, name: "Background")

            let cases: [(ServerNetworkManager.RunPolicyTab, String)] = [
                (.init(runID: UUID(), windowID: source.windowID, workspaceID: nil, tabID: runTab), Service.missingSourceWorkspaceMessage),
                (.init(runID: UUID(), windowID: source.windowID, workspaceID: background.id, tabID: runTab), Service.sourceWindowChangedMessage),
                (.init(runID: UUID(), windowID: Int(Int32.max), workspaceID: sourceWorkspace.id, tabID: runTab), Service.sourceWindowChangedMessage)
            ]
            for (route, message) in cases {
                source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                    connectionID: UUID(),
                    clientName: "agent",
                    windowID: source.windowID,
                    runPurpose: .agentModeRun,
                    actorRoutedRunTab: route
                ))
                await assertRefused(source, ["op": .string("list")], message: message)
            }
        }

        // MARK: - list

        /// Grants are one-way: a grant from the target to the source does not let the source list
        /// the target, and an explicit ungranted target is an error.
        func testUngrantedTargetIsRefusedAndListsNothing() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = try await makeWindow(name: "Ungranted Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            _ = try makeSession(in: target, name: "Target root")
            XCTAssertEqual(grantStore.add(source: targetWorkspace.id, target: sourceWorkspace.id), .added)
            try routeOverride(source)

            await assertRefused(
                source,
                ["op": .string("list"), "target_workspace_id": .string(targetWorkspace.id.uuidString)],
                message: "is not granted to '\(sourceWorkspace.name)'"
            )
            for malformed in ["not-a-uuid", "", "   "] {
                await assertRefused(
                    source,
                    ["op": .string("list"), "target_workspace_id": .string(malformed)],
                    message: "target_workspace_id must be a workspace UUID"
                )
            }
            await assertRefused(
                source,
                ["op": .string("list"), "target_workspace_id": .int(1)],
                message: "target_workspace_id must be a workspace UUID"
            )
            let all = try await listReply(source, ["op": .string("list")])
            XCTAssertEqual(all.workspaces, [])
        }

        /// Explicit and implicit listing read the grants file the same way and fail closed when it
        /// is unreadable, even for a target granted before the file broke.
        func testUnreadableGrantsRefuseExplicitAndImplicitListing() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            _ = try makeSession(in: target, name: "Target root")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)
            let explicit: [String: Value] = [
                "op": .string("list"),
                "target_workspace_id": .string(targetWorkspace.id.uuidString)
            ]
            let granted = try await listReply(source, explicit)
            XCTAssertEqual(granted.workspaces.map(\.workspaceID), [targetWorkspace.id.uuidString])

            try Data("not json".utf8).write(to: grantFileURL)
            await assertRefused(source, explicit, message: Service.grantsUnreadableMessage)
            await assertRefused(source, ["op": .string("list")], message: Service.grantsUnreadableMessage)
        }

        /// A granted target that exists but no window shows is reported as not open; a granted
        /// target that no window's workspace list knows (a deleted workspace) asks for the grant to be
        /// removed instead of opened.
        func testClosedGrantedTargetReportsNotOpenAndDeletedTargetReportsRemoval() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let closed = addWorkspace(to: source, name: "Closed Target")
            let closedName = closed.name
            let deletedID = UUID()
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: closed.id), .added)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: deletedID), .added)
            try routeOverride(source)

            let expected = ListReply.Workspace(
                workspaceID: closed.id.uuidString,
                name: closedName,
                isOpen: false,
                sessions: [],
                warnings: ["Workspace '\(closedName)' is not open on this Mac. Open it, then retry."]
            )
            let deleted = ListReply.Workspace(
                workspaceID: deletedID.uuidString,
                name: Service.unknownWorkspaceName,
                isOpen: false,
                sessions: [],
                warnings: [
                    "Workspace \(deletedID.uuidString) no longer exists on this Mac. The owner can remove this grant in Settings → Manage Workspaces → Workspace Steering."
                ]
            )
            let all = try await listReply(source, ["op": .string("list")])
            XCTAssertEqual(Set(all.workspaces.map(\.workspaceID)), [closed.id.uuidString, deletedID.uuidString])
            XCTAssertEqual(all.workspaces.first { $0.workspaceID == closed.id.uuidString }, expected)
            XCTAssertEqual(all.workspaces.first { $0.workspaceID == deletedID.uuidString }, deleted)
            let explicit = try await listReply(source, [
                "op": .string("list"),
                "target_workspace_id": .string(closed.id.uuidString)
            ])
            XCTAssertEqual(explicit.workspaces, [expected])
            let explicitDeleted = try await listReply(source, [
                "op": .string("list"),
                "target_workspace_id": .string(deletedID.uuidString)
            ])
            XCTAssertEqual(explicitDeleted.workspaces, [deleted])
        }

        /// A session created through the production new-session path
        /// (`createAndActivateSessionTab` → `PromptViewModel.createComposeTab`, no fixture tab
        /// edits) is in the stored workspace model, which is the membership authority, as soon as
        /// the call returns, and is listed.
        func testSessionCreatedThroughTheNewSessionPathIsListed() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)
            let viewModel = target.agentModeViewModel
            let priorTabID = viewModel.currentTabID

            let created = await viewModel.createAndActivateSessionTab()
            let tabID = try XCTUnwrap(created, "The new-session path must create a tab")
            XCTAssertNotEqual(tabID, priorTabID, "A new tab, not a reused placeholder")
            let sessionID = try XCTUnwrap(viewModel.sessions[tabID]?.activeAgentSessionID)
            let storedTab = target.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == tabID }
            XCTAssertNotNil(storedTab, "Stored membership does not lag the new tab")
            XCTAssertEqual(storedTab?.activeAgentSessionID, sessionID, "The stored claim is written on creation")
            XCTAssertTrue(target.promptManager.currentComposeTabs.contains { $0.id == tabID })

            let reply = try await listReply(source, ["op": .string("list")])
            let workspace = try XCTUnwrap(reply.workspaces.first)
            XCTAssertEqual(workspace.sessions.map(\.sessionID), [sessionID.uuidString])
            XCTAssertEqual(workspace.warnings, [])
        }

        /// One target workspace open in two windows: each window's root is listed once with its
        /// tab name and run state.
        func testListsDistinctSessionsFromTwoWindowsOfTheTargetWorkspace() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let first = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(first.workspaceManager.activeWorkspace)
            let second = try await makeWindow(name: "Target", sharing: targetWorkspace)
            XCTAssertEqual(second.workspaceManager.activeWorkspace?.id, targetWorkspace.id)
            let alpha = try makeSession(in: first, name: "Alpha root")
            let beta = try makeSession(in: second, name: "Beta root")
            beta.session.runState = .running
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)

            let reply = try await listReply(source, ["op": .string("list")])
            let workspace = try XCTUnwrap(reply.workspaces.first)
            XCTAssertEqual(reply.workspaces.count, 1)
            XCTAssertEqual(workspace.workspaceID, targetWorkspace.id.uuidString)
            XCTAssertEqual(workspace.name, targetWorkspace.name)
            XCTAssertTrue(workspace.isOpen)
            XCTAssertEqual(workspace.warnings, [])
            XCTAssertEqual(workspace.sessions, [
                ListReply.Session(sessionID: alpha.sessionID.uuidString, name: "Alpha root", runState: "idle"),
                ListReply.Session(sessionID: beta.sessionID.uuidString, name: "Beta root", runState: "running")
            ])
        }

        /// A session bound in two windows, or to two tabs of one window, is omitted with a warning;
        /// other roots are still listed.
        func testDuplicateBindingsAreOmittedWithAWarning() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let first = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(first.workspaceManager.activeWorkspace)
            let second = try await makeWindow(name: "Target", sharing: targetWorkspace)
            let unique = try makeSession(in: first, name: "Unique root")
            let crossWindowID = UUID()
            _ = try makeSession(in: first, name: "Cross A", sessionID: crossWindowID)
            _ = try makeSession(in: second, name: "Cross B", sessionID: crossWindowID)
            let sameWindowID = UUID()
            _ = try makeSession(in: second, name: "Same A", sessionID: sameWindowID)
            _ = try makeSession(in: second, name: "Same B", sessionID: sameWindowID)
            XCTAssertThrowsError(try second.agentModeViewModel.authoritativeLiveSession(for: sameWindowID))
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)

            let reply = try await listReply(source, ["op": .string("list")])
            let workspace = try XCTUnwrap(reply.workspaces.first)
            XCTAssertEqual(workspace.sessions.map(\.sessionID), [unique.sessionID.uuidString])
            XCTAssertEqual(
                Set(workspace.warnings),
                Set([crossWindowID, sameWindowID].map { Service.ambiguousSessionMessage(sessionID: $0.uuidString) })
            )
            XCTAssertEqual(workspace.warnings.count, 2)
        }

        /// A live root in one window whose ID another window of the same target
        /// workspace claims, persisted only, on a different tab is omitted with a warning, even though
        /// that second window alone resolves no live binding for it. A claim mirrored for the same
        /// tab in the second window counts once, so that root stays listed.
        func testPersistedClaimOnAnotherTabInAnotherWindowIsAmbiguousButAMirroredClaimIsNot() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let first = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(first.workspaceManager.activeWorkspace)
            let second = try await makeWindow(name: "Target", sharing: targetWorkspace)
            let conflicted = try makeSession(in: first, name: "Conflicted root")
            let mirrored = try makeSession(in: first, name: "Mirrored root")

            let otherTab = try addTab(to: second, name: "Persisted claim")
            try claim(conflicted.sessionID, tabID: otherTab, in: second)
            _ = try addTab(to: second, name: "Mirrored root", id: mirrored.tabID)
            try claim(mirrored.sessionID, tabID: mirrored.tabID, in: second)
            for sessionID in [conflicted.sessionID, mirrored.sessionID] {
                guard case .unbound = second.agentModeViewModel.workspaceSteeringTargetResolution(
                    sessionID: sessionID,
                    workspaceID: targetWorkspace.id
                ) else {
                    return XCTFail("The second window alone holds only a persisted claim for \(sessionID)")
                }
            }
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)

            let reply = try await listReply(source, ["op": .string("list")])
            let workspace = try XCTUnwrap(reply.workspaces.first)
            XCTAssertEqual(workspace.sessions.map(\.sessionID), [mirrored.sessionID.uuidString])
            XCTAssertEqual(workspace.warnings, [Service.ambiguousSessionMessage(sessionID: conflicted.sessionID.uuidString)])
        }

        /// Only top-level sessions the owner started on this Mac are targets: MCP-controlled roots,
        /// child sessions, remote-host projections, Knowledge sessions and live sessions of another
        /// workspace in the same window are omitted. A Knowledge root remains a paired-phone root;
        /// the steering exclusion does not change phone eligibility.
        func testMCPControlledRemoteHostKnowledgeChildAndOtherWorkspaceTargetsAreOmitted() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let window = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let viewModel = window.agentModeViewModel

            let root = try makeSession(in: window, name: "Owner root")
            let controlled = try makeSession(in: window, name: "Controlled", controlled: true)
            let child = try makeSession(in: window, name: "Child", parent: root.sessionID)
            let remote = try makeSession(in: window, name: "Remote")
            remote.session.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "host-1",
                hostDisplayName: "Studio Mac",
                remoteSessionID: remote.sessionID.uuidString
            )
            let knowledge = try makeSession(in: window, name: "Knowledge", profile: .knowledge)
            let moved = try makeSession(in: window, name: "Background")
            let backgroundWorkspace = addWorkspace(to: window, name: "Background")
            try moveTab(moved.tabID, in: window, from: targetWorkspace.id, to: backgroundWorkspace.id)

            XCTAssertNotNil(viewModel.remoteAttentionRootSession(sessionID: knowledge.sessionID), "Phone eligibility unchanged")
            XCTAssertNotNil(viewModel.remoteAttentionRootSession(sessionID: moved.sessionID))
            for omitted in [controlled, child, remote] {
                XCTAssertNil(viewModel.remoteAttentionRootSession(sessionID: omitted.sessionID))
            }
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)

            let reply = try await listReply(source, ["op": .string("list")])
            let workspace = try XCTUnwrap(reply.workspaces.first)
            XCTAssertEqual(workspace.sessions.map(\.sessionID), [root.sessionID.uuidString])
            XCTAssertEqual(workspace.warnings, [])
        }

        /// An unknown op is refused. `send` (Step 3, `WorkspaceSteeringSendTests`) refuses here too:
        /// this route's tab holds no live session to attribute the message to. `request_grant` is
        /// covered by `WorkspaceSteeringGrantRequestTests`.
        func testUnknownOpAndSendWithoutALiveSourceSessionRefuse() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let root = try makeSession(in: target, name: "Target root")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)
            try routeOverride(source)
            let itemsBefore = root.session.items.count

            await assertRefused(source, [
                "op": .string("send"),
                "target_workspace_id": .string(targetWorkspace.id.uuidString),
                "session_id": .string(root.sessionID.uuidString),
                "message": .string("hello")
            ], message: Service.sourceSessionUnavailableMessage)
            await assertRefused(source, ["op": .string("steer")], message: "workspace_steer requires op")
            XCTAssertEqual(root.session.items.count, itemsBefore)
            XCTAssertFalse(root.session.runState.isActive)
        }

        // MARK: - Fixtures

        private func makeGrantStore() throws -> WorkspaceSteeringGrantStore {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringToolTests-\(UUID().uuidString)", isDirectory: true)
            let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
            grantFileURL = fileURL
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let suiteName = "WorkspaceSteeringToolTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: root)
            }
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            return WorkspaceSteeringGrantStore(settings: settings)
        }

        /// A registered window whose active workspace is new (or `sharing`, appended to its list),
        /// using this test's grant store. Unregistered at teardown.
        private func makeWindow(name: String, sharing: WorkspaceModel? = nil) async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = nil
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            let workspace = sharing ?? addWorkspace(to: window, name: name)
            if sharing != nil {
                window.workspaceManager.workspaces.append(workspace)
            }
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "workspaceSteeringToolTests"
            )
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, workspace.id, "switch: \(result)")
            window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = grantStore
            return window
        }

        /// Appends an ephemeral workspace without switching to it. Built directly rather than with
        /// `createWorkspace`, whose list-change notification makes every other window reload its
        /// list from disk and drop the other test windows' ephemeral workspaces.
        private func addWorkspace(to window: WindowState, name: String) -> WorkspaceModel {
            let workspace = WorkspaceModel(
                name: "\(name) \(UUID().uuidString.prefix(6))",
                repoPaths: [],
                ephemeralFlag: true
            )
            window.workspaceManager.workspaces.append(workspace)
            return workspace
        }

        /// Adds a compose tab to the window's active workspace and loads it into the prompt manager.
        @discardableResult
        private func addTab(to window: WindowState, name: String, id tabID: UUID = UUID()) throws -> UUID {
            let manager = window.workspaceManager
            let workspaceID = try XCTUnwrap(manager.activeWorkspace?.id)
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            manager.workspaces[index].composeTabs.append(ComposeTabState(id: tabID, name: name))
            window.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index], syncPromptText: false)
            return tabID
        }

        /// Writes a persisted session claim on an unclaimed tab of the window's active workspace
        /// through the production claim writer, with no live record.
        private func claim(_ sessionID: UUID, tabID: UUID, in window: WindowState) throws {
            let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
            XCTAssertTrue(window.workspaceManager.compareAndSetActiveAgentSessionID(
                expected: nil,
                replacement: sessionID,
                forTabID: tabID,
                inWorkspaceID: workspaceID
            ))
            XCTAssertNil(window.agentModeViewModel.sessions[tabID], "A persisted-only claim has no live record")
        }

        private func moveTab(_ tabID: UUID, in window: WindowState, from: UUID, to: UUID) throws {
            let manager = window.workspaceManager
            let fromIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == from })
            let toIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == to })
            let tab = try XCTUnwrap(manager.workspaces[fromIndex].composeTabs.first { $0.id == tabID })
            manager.workspaces[fromIndex].composeTabs.removeAll { $0.id == tabID }
            manager.workspaces[toIndex].composeTabs.append(tab)
        }

        /// A live, hydrated Agent Mode record bound to `sessionID` in a new (or given) compose tab of
        /// the window's active workspace.
        private func makeSession(
            in window: WindowState,
            name: String = "Session",
            tabID existingTabID: UUID? = nil,
            sessionID: UUID = UUID(),
            parent: UUID? = nil,
            controlled: Bool = false,
            profile: AgentSessionProfile = .standard
        ) throws -> LiveSession {
            let tabID = try existingTabID ?? addTab(to: window, name: name)
            let session = try XCTUnwrap(window.agentModeViewModel.session(for: tabID, createIfNeeded: true))
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            session.parentSessionID = parent
            session.hasLoadedPersistedState = true
            if profile != .standard {
                XCTAssertTrue(session.adoptSessionProfile(profile))
            }
            if controlled {
                session.mcpControlContext = AgentMCPControlContext(
                    sessionID: sessionID,
                    activationID: UUID(),
                    registration: .init(sessionID: sessionID, generation: 0),
                    currentEpoch: nil,
                    preparedEpoch: nil,
                    pendingEpochTransition: nil,
                    originatingConnectionID: nil,
                    interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
                    suppressUserNotifications: true,
                    forceAutoEditEnabled: false,
                    autoEditEnabledBeforeOverride: false,
                    taskLabelKind: .engineer
                )
            }
            return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
        }

        /// Routes `source`'s tool calls as an Agent Mode run in a new tab of its active workspace.
        private func routeOverride(_ source: WindowState) throws {
            let workspaceID = try XCTUnwrap(source.workspaceManager.activeWorkspace?.id)
            let tabID = try addTab(to: source, name: "Assistant run")
            source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: UUID(),
                clientName: "workspace-steering-tests",
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: UUID(), windowID: source.windowID, workspaceID: workspaceID, tabID: tabID)
            ))
        }

        private func registerCatalog(for window: WindowState) async throws {
            let catalogService = window.mcpServer.windowMCPToolCatalogService
            ServiceRegistry.register(catalogService)
            let routing = try await Self.ensureRoutingService()
            addTeardownBlock { @MainActor in
                ServiceRegistry.unregister(catalogService)
                if routing.owned {
                    ServiceRegistry.unregister(routing.service)
                }
            }
        }

        /// Installs the production Agent Mode lease policy for `tabID` and admits a connection under
        /// it, as a provider process connecting for that run would. Cleaned up at teardown.
        private func routeRun(
            window: WindowState,
            tabID: UUID,
            role: AgentModelCatalog.TaskLabelKind,
            profile: AgentSessionProfile,
            policy: AgentDelegationPolicy.RunToolPolicy,
            runID: UUID = UUID()
        ) async throws -> RoutedRun {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            let spec = MCPBootstrapLeaseSpec.agentMode(
                tabID: tabID,
                runID: runID,
                gateID: UUID(),
                windowID: window.windowID,
                agent: .cursor,
                sessionProfile: profile,
                taskLabelKind: role,
                allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools,
                additionalRestrictedTools: policy.additionalRestrictedTools
            )
            let clientName = try XCTUnwrap(spec.clientName)
            let windowID = window.windowID
            addTeardownBlock {
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                await manager.removeConnection(connectionID)
                await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                await MCPRoutingWaiter.cleanup(runID: runID)
                await HeadlessAgentConnectionGate.cancelAll()
            }
            await MCPBootstrapLease.agentModePolicyInstaller(Self.productionPolicyInstaller)(spec)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: clientName,
                sessionKey: "workspace-steering-\(runID.uuidString)",
                pidGateTimeout: 0.25
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.runID, runID)
            XCTAssertEqual(applied.purpose, .agentModeRun)
            return RoutedRun(runID: runID, connectionID: connectionID, clientName: clientName)
        }

        /// The connection-policy installer Agent Mode uses in production.
        private static let productionPolicyInstaller: AgentConnectionPolicyInstaller = installProductionPolicy

        // swiftlint:disable:next function_parameter_count
        private static func installProductionPolicy(
            clientName: String,
            windowID: Int,
            restrictedTools: Set<String>,
            oneShot: Bool,
            reason: String?,
            ttl: TimeInterval,
            tabID: UUID?,
            runID: UUID?,
            additionalTools: Set<String>?,
            allowedToolsOverride: Set<String>?,
            sessionProfile: AgentSessionProfile,
            purpose: MCPRunPurpose,
            taskLabelKind: AgentModelCatalog.TaskLabelKind?,
            allowsAgentExternalControlTools: Bool,
            requiresExpectedAgentPID: Bool,
            codeModeEligibility: MCPCodeModeEligibility
        ) async {
            await ServerNetworkManager.shared.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: restrictedTools,
                oneShot: oneShot,
                reason: reason,
                ttl: ttl,
                tabID: tabID,
                runID: runID,
                additionalTools: additionalTools,
                allowedToolsOverride: allowedToolsOverride,
                sessionProfile: sessionProfile,
                purpose: purpose,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: requiresExpectedAgentPID,
                codeModeEligibility: codeModeEligibility
            )
        }

        private static func ensureRoutingService() async throws -> (service: WindowRoutingService, owned: Bool) {
            if let existing = ServiceRegistry.services.first(where: { $0 is WindowRoutingService }) as? WindowRoutingService {
                return (existing, false)
            }
            let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
            for _ in 0 ..< 100 {
                let registered = ServiceRegistry.services.contains { $0 as AnyObject === service as AnyObject }
                let names = await service.tools.map(\.name)
                if registered, names.contains("bind_context") {
                    return (service, true)
                }
                await Task.yield()
            }
            ServiceRegistry.unregister(service)
            XCTFail("WindowRoutingService did not register bind_context; the routed-connection tests cannot run")
            throw RoutingServiceUnavailable()
        }

        /// The window's production service wiring, minus the tool-catalog wrapper.
        private func productionService(for window: WindowState) -> Service {
            Service(
                captureRequestMetadata: { await window.mcpServer.captureRequestMetadata() },
                isGatewayPrincipalConnection: { await ServerNetworkManager.shared.isGatewayPrincipalConnection($0) },
                windows: { WindowStatesManager.shared.allWindows },
                grantStore: { [grantStore] in grantStore! }
            )
        }

        private func callSteer(_ window: WindowState, _ args: [String: Value]) async throws -> Value {
            let tools = await window.mcpServer.windowMCPTools
            let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.workspaceSteer })
            return try await tool(args)
        }

        private func listReply(_ window: WindowState, _ args: [String: Value]) async throws -> ListReply {
            let value = try await callSteer(window, args)
            return try JSONDecoder().decode(ListReply.self, from: JSONEncoder().encode(value))
        }

        private func assertRefused(
            _ window: WindowState,
            _ args: [String: Value],
            message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                let value = try await callSteer(window, args)
                XCTFail("Expected refusal containing \(message); got \(value)", file: file, line: line)
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(message),
                    "Expected \(message); got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
#endif
