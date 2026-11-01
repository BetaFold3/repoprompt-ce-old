import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    /// `workspace_steer send`, Step 3 (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
    ///
    /// Two levels, both through production code:
    /// - Tool level: registered windows, each window's production tool catalog and request metadata
    ///   override, the real cross-window scan and pinning, and the real send into a running target
    ///   whose provider has no steering route (the shared pending-instruction queue, no provider).
    /// - Pinned view-model level: `workspaceSteeringDispatchInstruction` (what the tool calls on the
    ///   pinned view model) on a view model with a real workspace manager and stub Codex controller,
    ///   for the idle new turn, refusals, real recovery-admission suspension through the recovery
    ///   store's `FileOperations.writeAtomically` seam, and a real save/reload.
    ///
    /// Grants use a temporary settings file. No provider process is launched and no app is opened.
    @MainActor
    final class WorkspaceSteeringSendTests: XCTestCase {
        private typealias Service = WorkspaceSteeringMCPToolService
        private typealias SendReply = WorkspaceSteeringMCPToolService.SendReply

        private struct LiveSession {
            let tabID: UUID
            let sessionID: UUID
            let session: AgentTabSession
        }

        private var grantStore: WorkspaceSteeringGrantStore!

        override func setUp() async throws {
            try await super.setUp()
            grantStore = try makeGrantStore()
        }

        override func tearDown() async throws {
            grantStore = nil
            try await super.tearDown()
        }

        // MARK: - Tool level

        /// A running target is steered through the tool: one attributed instruction is queued and
        /// shown, the reply carries the `MCPInstructionDispatch` encoding, and the target keeps no
        /// MCP control and stays an attention root (so its alerts and approvals stay with the owner).
        func testRunningTargetIsSteeredThroughTheToolWithTheAttributedMessage() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let caller = try routeSource(source)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let root = try makeSession(in: target, name: "Target root")
            root.session.selectedAgent = .openCode
            beginTurn(root.session)
            let targetVM = target.agentModeViewModel
            XCTAssertFalse(targetVM.requiresDurableRecoveryAdmission(for: root.session))
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            let reply = try await sendReply(source, [
                "op": .string("send"),
                "target_workspace_id": .string(targetWorkspace.id.uuidString),
                "session_id": .string(root.sessionID.uuidString),
                "message": .string("  Also cover the edge case\n")
            ])

            XCTAssertEqual(reply, SendReply(
                workspaceID: targetWorkspace.id.uuidString,
                sessionID: root.sessionID.uuidString,
                delivery: "queued_follow_up"
            ))
            let expected = "[Steer from workspace \"\(sourceWorkspace.name)\" (\(sourceWorkspace.id.uuidString)), "
                + "session \(caller.sessionID.uuidString)]\n\nAlso cover the edge case"
            XCTAssertEqual(root.session.pendingInstructions.map(\.text), [expected])
            XCTAssertEqual(root.session.items.last { $0.kind == .user }?.text, expected)
            XCTAssertTrue(root.session.runState.isActive)
            assertUncontrolledAttentionRoot(targetVM, root)
            XCTAssertFalse(caller.session.items.contains { $0.text.contains("Also cover") })
        }

        /// Every entry refusal happens before admission and sends nothing: an ungranted target, a
        /// missing or blank message, malformed or unknown session IDs, ineligible targets (an
        /// MCP-controlled root, a child, a Knowledge root), a closed workspace (exact wording), and a
        /// caller whose run is no longer its tab's current run (attribution refused).
        func testEntryRefusalsSendNothing() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let caller = try routeSource(source)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let root = try makeSession(in: target, name: "Target root")
            let controlled = try makeSession(in: target, name: "Controlled", controlled: true)
            let child = try makeSession(in: target, name: "Child", parent: root.sessionID)
            let knowledge = try makeSession(in: target, name: "Knowledge", profile: .knowledge)
            let all = [root, controlled, child, knowledge]
            for live in all {
                live.session.selectedAgent = .openCode
                beginTurn(live.session)
            }
            let itemsBefore = all.map { $0.session.items.map(\.id) }
            func send(_ sessionID: UUID, _ message: Value? = .string("hello"), target workspaceID: UUID? = nil) -> [String: Value] {
                var args: [String: Value] = [
                    "op": .string("send"),
                    "target_workspace_id": .string((workspaceID ?? targetWorkspace.id).uuidString),
                    "session_id": .string(sessionID.uuidString)
                ]
                args["message"] = message
                return args
            }

            // Named from the caller window's workspace list, else by ID (as `list` does).
            let targetName = WorkspaceSteeringGrantStore.displayNames(for: source.workspaceManager.workspaces)[targetWorkspace.id]
                ?? targetWorkspace.id.uuidString
            await assertRefused(source, send(root.sessionID), message: Service.notGrantedMessage(
                target: targetName,
                source: sourceWorkspace.name
            ) + " Nothing was sent.")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            let empty = AgentModeViewModel.workspaceSteeringEmptyMessageMessage
            await assertRefused(source, send(root.sessionID, nil), message: empty)
            await assertRefused(source, send(root.sessionID, .string(" \n\t ")), message: empty)
            await assertRefused(source, send(root.sessionID, .int(1)), message: empty)
            var malformed = send(root.sessionID)
            malformed["session_id"] = .string("not-a-uuid")
            await assertRefused(source, malformed, message: "session_id must be a session UUID. Nothing was sent.")
            for ineligible in [UUID(), controlled.sessionID, child.sessionID, knowledge.sessionID] {
                await assertRefused(
                    source,
                    send(ineligible),
                    message: Service.targetUnavailableMessage(sessionID: ineligible.uuidString)
                )
            }

            // Known to the source window, granted, but not the active workspace of any window.
            let closedWorkspace = addWorkspace(to: source, name: "Closed")
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: closedWorkspace.id), .added)
            await assertRefused(
                source,
                send(root.sessionID, target: closedWorkspace.id),
                message: "Workspace '\(closedWorkspace.name)' is not open on this Mac. Open it, then retry. Nothing was sent."
            )

            // The routed run is no longer the tab's current run: never credited to the new run.
            caller.session.runID = UUID()
            await assertRefused(source, send(root.sessionID), message: Service.sourceSessionUnavailableMessage)

            for (live, before) in zip(all, itemsBefore) {
                XCTAssertEqual(live.session.items.map(\.id), before)
                XCTAssertTrue(live.session.pendingInstructions.isEmpty)
            }
        }

        /// Every local session of the source workspace may steer, not only roots: a delegated child
        /// and a Knowledge session each send, attributed to their own durable session ID.
        func testChildAndKnowledgeSourceSessionsSendWithTheirOwnAttribution() async throws {
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let root = try makeSession(in: target, name: "Target root")
            root.session.selectedAgent = .openCode
            beginTurn(root.session)
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            let parent = try makeSession(in: source, name: "Assistant root")
            let child = try routeSource(source, parent: parent.sessionID)
            XCTAssertFalse(source.agentModeViewModel.isAttentionNotificationRoot(child.session))
            _ = try await sendReply(source, sendArgs(targetWorkspace.id, root.sessionID, "from the child"))
            let knowledge = try routeSource(source, profile: .knowledge)
            _ = try await sendReply(source, sendArgs(targetWorkspace.id, root.sessionID, "from Knowledge"))

            let prefix = "[Steer from workspace \"\(sourceWorkspace.name)\" (\(sourceWorkspace.id.uuidString)), session "
            XCTAssertEqual(root.session.pendingInstructions.map(\.text), [
                prefix + "\(child.sessionID.uuidString)]\n\nfrom the child",
                prefix + "\(knowledge.sessionID.uuidString)]\n\nfrom Knowledge"
            ])
            assertUncontrolledAttentionRoot(target.agentModeViewModel, root)
        }

        /// Admitted delivery does not depend on the source staying current: the source run stops
        /// (cancelled, its process run ID cleared, its route gone) while the target's durable
        /// admission is suspended, and the attributed message is still delivered exactly once, kept
        /// in recovery, to a target that keeps no MCP control and stays an attention root.
        func testSourceStoppingAfterEntryStillDeliversTheAdmittedSteerOnce() async throws {
            let writes = HeldRecoveryWrite()
            let lane = try await RecoveryLaneFixture.make("workspace-steering-source-stop", fileOperations: writes.fileOperations())
            defer {
                writes.release()
                lane.tearDown()
            }
            let source = try await makeWindow(name: "Assistant")
            let sourceWorkspace = try XCTUnwrap(source.workspaceManager.activeWorkspace)
            let caller = try routeSource(source)
            let target = try await makeWindow(name: "Target")
            let targetWorkspace = try XCTUnwrap(target.workspaceManager.activeWorkspace)
            let root = try makeSession(in: target, name: "Target root", sessionID: lane.sessionID)
            root.session.selectedAgent = .openCode
            beginTurn(root.session)
            root.session.recoveryLane = lane.lane
            root.session.recoveryAdmissionMode = .mandatory
            XCTAssertTrue(target.agentModeViewModel.requiresDurableRecoveryAdmission(for: root.session))
            XCTAssertEqual(grantStore.add(source: sourceWorkspace.id, target: targetWorkspace.id), .added)

            writes.holdNext()
            let send = Task { @MainActor in
                try await self.sendReply(source, self.sendArgs(targetWorkspace.id, root.sessionID, "Keep going"))
            }
            let suspended = await RecoveryTestSupport.eventually { writes.hasArrived }
            XCTAssertTrue(suspended, "The send is suspended inside the target's admission write")

            caller.session.runState = .cancelled
            AgentModeProcessRunIdentity.clearProcessRunID(for: caller.session)
            source.mcpServer.setRequestMetadataOverrideForTesting(nil)
            target.apiSettingsViewModel.isOpenCodeConnected = true
            writes.release()

            let reply = try await send.value
            XCTAssertEqual(reply, SendReply(
                workspaceID: targetWorkspace.id.uuidString,
                sessionID: root.sessionID.uuidString,
                delivery: "queued_follow_up"
            ))
            let expected = "[Steer from workspace \"\(sourceWorkspace.name)\" (\(sourceWorkspace.id.uuidString)), "
                + "session \(caller.sessionID.uuidString)]\n\nKeep going"
            XCTAssertEqual(root.session.pendingInstructions.map(\.text), [expected])
            XCTAssertEqual(root.session.items.count { $0.kind == .user && $0.text == expected }, 1)
            let record = await lane.store.read(sessionID: lane.sessionID).record
            XCTAssertEqual(record?.intents.count, 1)
            XCTAssertNotEqual(record?.intents.first?.deliveryState, .withdrawn, "The admitted input is kept")
            assertUncontrolledAttentionRoot(target.agentModeViewModel, root)
        }

        // MARK: - Pinned view-model level

        /// The final-fence authority is the steering resolution, not the bare attention-root check:
        /// it needs the grant for the view model's current workspace, keeps the Knowledge exclusion,
        /// and drops the target when the window shows another workspace.
        func testGrantedTargetAuthorityRequiresTheGrantTheCurrentWorkspaceAndASteerableRoot() throws {
            let host = try makeHost(windowID: 49101, tabCount: 2)
            let sourceID = UUID()
            let root = try makeRoot(host, tab: 0)
            let knowledge = try makeRoot(host, tab: 1, profile: .knowledge)
            let vm = host.viewModel
            XCTAssertNil(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: sourceID))

            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added)
            XCTAssertIdentical(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: sourceID), root.session)
            XCTAssertIdentical(
                vm.instructionTargetSession(sessionID: root.sessionID, target: .workspaceGrant(sourceWorkspaceID: sourceID)),
                root.session
            )
            XCTAssertIdentical(vm.remoteAttentionRootSession(sessionID: knowledge.sessionID), knowledge.session)
            XCTAssertNil(vm.workspaceSteeringGrantedTarget(sessionID: knowledge.sessionID, sourceWorkspaceID: sourceID))
            XCTAssertNil(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: UUID()))

            let other = WorkspaceModel(name: "Other", repoPaths: [], ephemeralFlag: true)
            host.workspaceManager.workspaces.append(other)
            host.workspaceManager.activeWorkspace = other
            XCTAssertNil(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: sourceID))
            host.workspaceManager.activeWorkspace = host.workspace
            XCTAssertIdentical(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: sourceID), root.session)

            XCTAssertEqual(grantStore.remove(source: sourceID, target: host.workspace.id), .removed)
            XCTAssertNil(vm.workspaceSteeringGrantedTarget(sessionID: root.sessionID, sourceWorkspaceID: sourceID))
        }

        /// An idle target gets a follow-up that starts a new turn through the normal send path (here
        /// reaching the stub Codex controller), with the attributed text, and keeps no MCP control.
        func testIdleTargetGetsANewTurnWithTheAttributedMessage() async throws {
            let host = try makeHost(windowID: 49102)
            let sourceID = UUID()
            let root = try makeRoot(host, tab: 0)
            root.session.selectedAgent = .codexExec
            XCTAssertFalse(root.session.runState.isActive)
            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added)
            let attribution = Self.attribution(sourceID)

            let delivery = try await host.viewModel.workspaceSteeringDispatchInstruction(
                session: root.session,
                sessionID: root.sessionID,
                sourceWorkspaceID: sourceID,
                message: "Please pick the plan back up",
                attribution: attribution
            )

            XCTAssertEqual(delivery, .startedRun)
            let reached = await RecoveryTestSupport.eventually { host.recorder.contains("codex:send") }
            XCTAssertTrue(reached, "The follow-up reaches the stub Codex controller")
            let expected = "\(attribution)\n\nPlease pick the plan back up"
            XCTAssertEqual(root.session.items.last { $0.kind == .user }?.text, expected)
            XCTAssertTrue(host.controller.sentTexts.contains { $0.contains(expected) }, "\(host.controller.sentTexts)")
            XCTAssertTrue(root.session.runState.isActive)
            assertUncontrolledAttentionRoot(host.viewModel, root)
        }

        /// Readiness refusals are judged on the original message and send nothing: `/compact` and
        /// `/goal` (the prefix would hide them from the submit path), a pending question, a pending
        /// approval, and an unverified (unloaded) record.
        func testReadinessRefusalsOnTheOriginalMessageSendNothing() async throws {
            let host = try makeHost(windowID: 49103)
            let sourceID = UUID()
            let root = try makeRoot(host, tab: 0)
            root.session.selectedAgent = .codexExec
            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added)
            let vm = host.viewModel
            let attribution = Self.attribution(sourceID)
            XCTAssertEqual(vm.resolvedNativeSlashCommand(in: "/compact", session: root.session)?.command.behavior, .controlPlane)
            XCTAssertNil(
                vm.resolvedNativeSlashCommand(in: "\(attribution)\n\n/compact", session: root.session),
                "Behind the prefix the submit path would not see the command, so the original is checked"
            )
            let itemsBefore = root.session.items.map(\.id)

            func assertRefusal(_ message: String, _ expected: String, line: UInt = #line) async {
                do {
                    let delivery = try await vm.workspaceSteeringDispatchInstruction(
                        session: root.session,
                        sessionID: root.sessionID,
                        sourceWorkspaceID: sourceID,
                        message: message,
                        attribution: attribution
                    )
                    XCTFail("Expected refusal \(expected); got \(delivery)", line: line)
                } catch {
                    XCTAssertTrue(String(describing: error).contains(expected), "Expected \(expected); got \(error)", line: line)
                }
                XCTAssertEqual(root.session.items.map(\.id), itemsBefore, line: line)
                XCTAssertTrue(host.controller.sentTexts.isEmpty, line: line)
                XCTAssertFalse(root.session.runState.isActive, line: line)
            }

            let control = AgentModeViewModel.workspaceSteeringControlCommandMessage
            await assertRefusal("/compact", control)
            await assertRefusal("  \n/compact now", control)
            await assertRefusal("/goal ship it", control)
            await assertRefusal("   ", AgentModeViewModel.workspaceSteeringEmptyMessageMessage)

            root.session.pendingAskUser = Self.pendingQuestion()
            await assertRefusal("hello", AgentModeViewModel.workspaceSteeringPendingInteractionMessage(kind: "question"))
            root.session.pendingAskUser = nil

            root.session.pendingApproval = Self.pendingApproval()
            await assertRefusal("hello", AgentModeViewModel.workspaceSteeringPendingInteractionMessage(kind: "approval"))
            root.session.pendingApproval = nil

            root.session.hasLoadedPersistedState = false
            await assertRefusal("hello", AgentModeViewModel.workspaceSteeringTargetChangedMessage)
            root.session.hasLoadedPersistedState = true
            XCTAssertFalse(host.recorder.contains("codex:send"))
        }

        /// A record that is not loaded yet but whose standard profile is verified (from its saved
        /// index entry) is refused for its loaded state; after a real save, the attributed message
        /// of an accepted steer is what reloads from disk.
        func testAttributedMessagePersistsThroughSaveAndReloadAndAnUnloadedRecordIsRefused() async throws {
            let host = try makeHost(windowID: 49104, persistent: true)
            let vm = host.viewModel
            let sourceID = UUID()
            let tabID = host.tabIDs[0]
            let session = try await vm.ensureSessionReady(tabID: tabID)
            session.appendItem(.user("Earlier turn"))
            let firstSave = await vm.flushSave(for: tabID)
            XCTAssertTrue(firstSave)
            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added)
            let attribution = Self.attribution(sourceID)

            // The saved index entry verifies the standard profile, so the target still resolves and
            // the loaded-state readiness rule is what refuses.
            session.hasLoadedPersistedState = false
            XCTAssertEqual(vm.mcpDelegationCallerProfile(for: session), .standard)
            XCTAssertIdentical(vm.workspaceSteeringGrantedTarget(sessionID: sessionID, sourceWorkspaceID: sourceID), session)
            do {
                let delivery = try await vm.workspaceSteeringDispatchInstruction(
                    session: session,
                    sessionID: sessionID,
                    sourceWorkspaceID: sourceID,
                    message: "too early",
                    attribution: attribution
                )
                XCTFail("An unloaded record must be refused, got \(delivery)")
            } catch {
                XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.remoteRootNotLoadedMessage), "\(error)")
            }
            XCTAssertFalse(session.items.contains { $0.text.contains("too early") })
            XCTAssertFalse(host.recorder.contains("codex:send"))
            session.hasLoadedPersistedState = true

            session.selectedAgent = .codexExec
            let delivery = try await vm.workspaceSteeringDispatchInstruction(
                session: session,
                sessionID: sessionID,
                sourceWorkspaceID: sourceID,
                message: "Saved steer",
                attribution: attribution
            )
            XCTAssertEqual(delivery, .startedRun)
            let reached = await RecoveryTestSupport.eventually { host.recorder.contains("codex:send") }
            XCTAssertTrue(reached)
            let secondSave = await vm.flushSave(for: tabID)
            XCTAssertTrue(secondSave)

            let reloaded = try await vm.test_dataService.loadAgentSession(id: sessionID, for: host.workspace)
            let userTexts = try XCTUnwrap(reloaded).toLiveItems().filter { $0.kind == .user }.map(\.text)
            XCTAssertEqual(userTexts.last, "\(attribution)\n\nSaved steer")
            XCTAssertFalse(userTexts.contains("Saved steer"), "Only the attributed form is saved")
            XCTAssertNil(session.mcpControlContext)
        }

        /// Revocation, the window showing another workspace, replacement of the pinned session, or a
        /// question or approval for the owner arriving while the input's durable admission is
        /// suspended in the store write: the final predicate refuses, nothing is queued, shown or
        /// handed to Codex, and the admitted intent is withdrawn, on both the ordinary path and the
        /// Codex bounded-acknowledgement path. On the ordinary path the final readiness check also
        /// runs on the original message (`/compact` becoming a native command meanwhile is refused).
        func testRevocationWorkspaceSwitchReplacementOrOwnerInteractionDuringAdmissionSendsNothing() async throws {
            var windowID = 49110
            for path in [DispatchPath.ordinary, .codexBoundedAck] {
                for mutation in [
                    FenceMutation.revokeGrant,
                    .switchWorkspace,
                    .replaceSession,
                    .pendingQuestion,
                    .pendingApproval
                ] {
                    windowID += 1
                    try await assertFenceRefusal(path: path, mutation: mutation, windowID: windowID)
                }
            }
            windowID += 1
            try await assertFenceRefusal(path: .ordinary, mutation: .becomesControlCommand, windowID: windowID)
        }

        private enum DispatchPath: String {
            case ordinary
            case codexBoundedAck
        }

        private enum FenceMutation: String {
            case revokeGrant
            case switchWorkspace
            case replaceSession
            /// An ask-user question for the owner arrives.
            case pendingQuestion
            /// An approval request for the owner arrives.
            case pendingApproval
            /// The target's provider changes so the original message parses as `/compact`.
            case becomesControlCommand
        }

        private func assertFenceRefusal(path: DispatchPath, mutation: FenceMutation, windowID: Int) async throws {
            let label = "\(path.rawValue)/\(mutation.rawValue)"
            let writes = HeldRecoveryWrite()
            let lane = try await RecoveryLaneFixture.make("workspace-steering-\(label)", fileOperations: writes.fileOperations())
            defer {
                writes.release()
                lane.tearDown()
            }
            let host = try makeHost(windowID: windowID)
            let vm = host.viewModel
            let sourceID = UUID()
            let root = try makeRoot(host, tab: 0, sessionID: lane.sessionID)
            let session = root.session
            session.recoveryLane = lane.lane
            session.recoveryAdmissionMode = .mandatory
            switch path {
            case .ordinary:
                session.selectedAgent = .openCode
                beginTurn(session)
            case .codexBoundedAck:
                prepareActiveCodexTurn(session, controller: host.controller)
            }
            XCTAssertTrue(vm.requiresDurableRecoveryAdmission(for: session), label)
            XCTAssertTrue(
                AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: vm.agentAvailabilityContext),
                "\(label): the provider is available, so only the fence can refuse"
            )
            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added, label)
            let message = mutation == .becomesControlCommand ? "/compact" : "steer \(label)"
            let itemsBefore = session.items.map(\.id)

            writes.holdNext()
            let dispatch = Task { @MainActor in
                try await vm.workspaceSteeringDispatchInstruction(
                    session: session,
                    sessionID: root.sessionID,
                    sourceWorkspaceID: sourceID,
                    message: message,
                    attribution: Self.attribution(sourceID)
                )
            }
            let suspended = await RecoveryTestSupport.eventually { writes.hasArrived }
            XCTAssertTrue(suspended, "\(label): the send is suspended inside its admission write")

            let replacement = AgentTabSession(tabID: root.tabID)
            switch mutation {
            case .revokeGrant:
                XCTAssertEqual(grantStore.remove(source: sourceID, target: host.workspace.id), .removed, label)
            case .switchWorkspace:
                let other = WorkspaceModel(name: "Other", repoPaths: [], ephemeralFlag: true)
                host.workspaceManager.workspaces.append(other)
                host.workspaceManager.activeWorkspace = other
            case .replaceSession:
                replacement.testInstallPersistentSessionBinding(sessionID: root.sessionID)
                replacement.hasLoadedPersistedState = true
                vm.test_installLiveSession(replacement)
            case .pendingQuestion:
                session.pendingAskUser = Self.pendingQuestion()
            case .pendingApproval:
                session.pendingApproval = Self.pendingApproval()
            case .becomesControlCommand:
                session.selectedAgent = .codexExec
            }
            // Settings models reload their CLI flags from defaults on any connection notification;
            // keep this host's in-memory flags so the provider stays deliverable past the fence.
            host.apiSettings.isOpenCodeConnected = true
            host.apiSettings.isCodexConnected = true
            writes.release()

            let expected = switch mutation {
            case .becomesControlCommand:
                AgentModeViewModel.workspaceSteeringControlCommandMessage
            case .pendingQuestion:
                AgentModeViewModel.workspaceSteeringPendingInteractionMessage(kind: "question")
            case .pendingApproval:
                AgentModeViewModel.workspaceSteeringPendingInteractionMessage(kind: "approval")
            case .revokeGrant, .switchWorkspace, .replaceSession:
                AgentModeViewModel.workspaceSteeringTargetChangedMessage
            }
            do {
                let delivery = try await dispatch.value
                XCTFail("\(label): expected refusal, got \(delivery)")
            } catch {
                XCTAssertTrue(String(describing: error).contains(expected), "\(label): \(error)")
            }
            XCTAssertTrue(
                AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: vm.agentAvailabilityContext),
                "\(label): the provider stayed available, so the refusal came from the fence"
            )
            if path == .codexBoundedAck {
                let drained = await RecoveryTestSupport.eventually { vm.test_openCodexMCPSubmissionDriverCount == 0 }
                XCTAssertTrue(drained, label)
            }
            XCTAssertEqual(session.items.map(\.id), itemsBefore, "\(label): no bubble")
            XCTAssertTrue(session.pendingInstructions.isEmpty, label)
            XCTAssertTrue(session.codexFallbackQueue.isEmpty, label)
            XCTAssertTrue(host.controller.sentTexts.isEmpty, "\(label): nothing reached Codex")
            XCTAssertFalse(host.recorder.contains("codex:send"), label)
            XCTAssertTrue(replacement.items.isEmpty && replacement.pendingInstructions.isEmpty, "\(label): replacement untouched")
            XCTAssertNil(session.mcpControlContext, label)
            // The admission was written, then released: nothing persists as an undelivered input
            // and no dispatch was begun.
            let record = await lane.store.read(sessionID: lane.sessionID).record
            XCTAssertEqual(record?.intents.map(\.deliveryState), [.withdrawn], "\(label): the admitted intent is withdrawn")
            XCTAssertEqual(record?.attempts.isEmpty, true, "\(label): no dispatch was begun")
            if mutation == .replaceSession {
                vm.test_installLiveSession(session)
            }
        }

        /// An active Codex turn acknowledges the steer: the reply is `dispatched_codex_turn`, the
        /// attributed text reaches the provider exactly once and is shown once, and the target keeps
        /// no MCP control and stays an attention root.
        func testActiveCodexTargetAcknowledgesTheAttributedSteerOnce() async throws {
            let host = try makeHost(windowID: 49130)
            let sourceID = UUID()
            let root = try makeRoot(host, tab: 0)
            host.viewModel.test_initializeRunService()
            prepareActiveCodexTurn(root.session, controller: host.controller)
            // The live controller was started for this view model's workspace (else the send
            // reconnects it and the turn is no longer steerable).
            root.session.codexControllerWorkspacePath = try XCTUnwrap(host.workspace.repoPaths.first)
            XCTAssertFalse(host.viewModel.requiresDurableRecoveryAdmission(for: root.session))
            XCTAssertEqual(grantStore.add(source: sourceID, target: host.workspace.id), .added)
            let attribution = Self.attribution(sourceID)
            let expected = "\(attribution)\n\nAlso check the migration"

            let delivery: AgentModeViewModel.MCPInstructionDispatch
            do {
                delivery = try await host.viewModel.workspaceSteeringDispatchInstruction(
                    session: root.session,
                    sessionID: root.sessionID,
                    sourceWorkspaceID: sourceID,
                    message: "Also check the migration",
                    attribution: attribution
                )
            } catch {
                return XCTFail("\(error); sent: \(host.controller.sentTexts); recorded: \(host.recorder.contains("codex:send"))")
            }

            XCTAssertEqual(delivery, .dispatchedCodexTurn)
            let drained = await RecoveryTestSupport.eventually { host.viewModel.test_openCodexMCPSubmissionDriverCount == 0 }
            XCTAssertTrue(drained)
            XCTAssertEqual(host.controller.sentTexts.count { $0.contains(expected) }, 1, "\(host.controller.sentTexts)")
            XCTAssertEqual(root.session.items.count { $0.kind == .user && $0.text == expected }, 1)
            XCTAssertTrue(root.session.codexFallbackQueue.isEmpty)
            XCTAssertTrue(root.session.runState.isActive)
            assertUncontrolledAttentionRoot(host.viewModel, root)
        }

        // MARK: - Assertions

        private func assertUncontrolledAttentionRoot(
            _ vm: AgentModeViewModel,
            _ root: LiveSession,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertNil(root.session.mcpControlContext, file: file, line: line)
            XCTAssertFalse(root.session.isMCPOriginated, file: file, line: line)
            XCTAssertFalse(vm.isMCPControlled(tabID: root.tabID), file: file, line: line)
            XCTAssertTrue(vm.isAttentionNotificationRoot(root.session), file: file, line: line)
            XCTAssertIdentical(vm.remoteAttentionRootSession(sessionID: root.sessionID), root.session, file: file, line: line)
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

        // MARK: - Tool-level fixtures

        private func makeGrantStore() throws -> WorkspaceSteeringGrantStore {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringSendTests-\(UUID().uuidString)", isDirectory: true)
            let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let suiteName = "WorkspaceSteeringSendTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: root)
            }
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            return WorkspaceSteeringGrantStore(settings: settings)
        }

        /// A registered window whose active workspace is new (saved under a temporary folder), with
        /// this test's grant store for both the tool and the view model's final fence.
        private func makeWindow(name: String) async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            let apiSettings = window.apiSettingsViewModel
            let previousOpenCode = apiSettings.isOpenCodeConnected
            addTeardownBlock { @MainActor in
                apiSettings.isOpenCodeConnected = previousOpenCode
                window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = nil
                window.agentModeViewModel.test_workspaceSteeringGrantStoreOverride = nil
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            let workspace = addWorkspace(to: window, name: name)
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "workspaceSteeringSendTests"
            )
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, workspace.id, "switch: \(result)")
            window.mcpServer.workspaceSteeringGrantStoreOverrideForTesting = grantStore
            window.agentModeViewModel.test_workspaceSteeringGrantStoreOverride = grantStore
            // In memory only (connecting writes the defaults; assigning the flag does not), after the
            // window's initial loads, so the OpenCode no-controller route is available regardless of
            // this Mac's provider setup.
            apiSettings.isOpenCodeConnected = true
            XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.openCode, availability: window.agentModeViewModel.agentAvailabilityContext))
            return window
        }

        /// Appends an ephemeral workspace (saved under a temporary folder) without switching to it.
        private func addWorkspace(to window: WindowState, name: String) -> WorkspaceModel {
            let storage = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringSendTests-\(UUID().uuidString)", isDirectory: true)
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

        /// A live, hydrated record bound to a new durable session in a new compose tab of the
        /// window's active workspace.
        private func makeSession(
            in window: WindowState,
            name: String = "Session",
            sessionID: UUID = UUID(),
            parent: UUID? = nil,
            controlled: Bool = false,
            profile: AgentSessionProfile = .standard
        ) throws -> LiveSession {
            let tabID = try addTab(to: window, name: name)
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

        /// A running source session in a new tab of `source`, and its tool calls routed as that
        /// session's Agent Mode run (the route's run ID is the session's process run ID).
        private func routeSource(
            _ source: WindowState,
            parent: UUID? = nil,
            profile: AgentSessionProfile = .standard
        ) throws -> LiveSession {
            let workspaceID = try XCTUnwrap(source.workspaceManager.activeWorkspace?.id)
            let live = try makeSession(in: source, name: "Assistant run", parent: parent, profile: profile)
            beginTurn(live.session)
            let runID = try XCTUnwrap(live.session.runID)
            source.mcpServer.setRequestMetadataOverrideForTesting(.init(
                connectionID: UUID(),
                clientName: "workspace-steering-send-tests",
                windowID: source.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: runID, windowID: source.windowID, workspaceID: workspaceID, tabID: live.tabID)
            ))
            return live
        }

        private func sendArgs(_ workspaceID: UUID, _ sessionID: UUID, _ message: String) -> [String: Value] {
            [
                "op": .string("send"),
                "target_workspace_id": .string(workspaceID.uuidString),
                "session_id": .string(sessionID.uuidString),
                "message": .string(message)
            ]
        }

        private func callSteer(_ window: WindowState, _ args: [String: Value]) async throws -> Value {
            let tools = await window.mcpServer.windowMCPTools
            let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.workspaceSteer })
            return try await tool(args)
        }

        private func sendReply(_ window: WindowState, _ args: [String: Value]) async throws -> SendReply {
            let value = try await callSteer(window, args)
            return try JSONDecoder().decode(SendReply.self, from: JSONEncoder().encode(value))
        }

        // MARK: - Pinned view-model fixtures

        private struct Host {
            let viewModel: AgentModeViewModel
            let workspaceManager: WorkspaceManagerViewModel
            let promptManager: PromptViewModel
            let apiSettings: APISettingsViewModel
            let workspace: WorkspaceModel
            let tabIDs: [UUID]
            let recorder: LifecycleRecorder
            let controller: LifecycleNoopCodexController
        }

        /// A view model with a real (standalone) workspace manager whose active workspace holds
        /// `tabCount` compose tabs, this test's grant store, and a stub Codex controller (no
        /// provider process). `persistent` saves sessions under the workspace's temporary folder.
        private func makeHost(windowID: Int, tabCount: Int = 1, persistent: Bool = false) throws -> Host {
            let storageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSteeringSendTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: storageURL) }
            let tabIDs = (0 ..< tabCount).map { _ in UUID() }
            let workspace = WorkspaceModel(
                name: "Steering Target",
                repoPaths: [storageURL.path],
                customStoragePath: storageURL,
                ephemeralFlag: true,
                composeTabs: tabIDs.enumerated().map { ComposeTabState(id: $1, name: "Tab \($0)") },
                activeComposeTabID: tabIDs.first
            )
            let fileManager = WorkspaceFilesViewModel()
            let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(
                    keyManager: keyManager,
                    mcpHost: ServerNetworkManager.shared,
                    routingWaiter: .shared,
                    codexAuthRecovery: CodexManagedAuthRecoveryService.shared,
                    modelOverrides: AppModelOverrideReader(),
                    ohMyPiConnectionState: { OhMyPiConnectionAvailability.isEffectivelyConnected() }
                ),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let promptManager = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: windowID,
                settingsManager: WindowSettingsManager(windowID: windowID)
            )
            let workspaceManager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: promptManager,
                performInitialWorkspaceActivation: false
            )
            promptManager.attachWorkspaceManager(workspaceManager)
            workspaceManager.workspaces = [workspace]
            workspaceManager.activeWorkspace = workspace
            promptManager.loadComposeTabsFromWorkspace(workspace)

            let recorder = LifecycleRecorder()
            let controller = LifecycleNoopCodexController(recorder: recorder)
            let viewModel = AgentModeViewModel(
                testWindowID: windowID,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                codexControllerFactory: { _, _, _, _, _, _ in controller }
            )
            if persistent {
                viewModel.test_establishPersistenceWorkspace(workspace)
                viewModel.test_setCurrentTabIDOverride(tabIDs.first)
            }
            viewModel.test_setSidebarAutoArchiveDependencies(promptManager: promptManager, workspaceManager: workspaceManager)
            viewModel.test_workspaceSteeringGrantStoreOverride = grantStore
            // This host's own settings model, in memory only, set after the wiring above.
            apiSettings.isOpenCodeConnected = true
            apiSettings.isCodexConnected = true
            XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.openCode, availability: viewModel.agentAvailabilityContext))
            XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.codexExec, availability: viewModel.agentAvailabilityContext))
            return Host(
                viewModel: viewModel,
                workspaceManager: workspaceManager,
                promptManager: promptManager,
                apiSettings: apiSettings,
                workspace: workspace,
                tabIDs: tabIDs,
                recorder: recorder,
                controller: controller
            )
        }

        private func makeRoot(
            _ host: Host,
            tab index: Int,
            sessionID: UUID = UUID(),
            profile: AgentSessionProfile = .standard
        ) throws -> LiveSession {
            let tabID = host.tabIDs[index]
            let session = try XCTUnwrap(host.viewModel.session(for: tabID, createIfNeeded: true))
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            session.hasLoadedPersistedState = true
            if profile != .standard {
                XCTAssertTrue(session.adoptSessionProfile(profile))
            }
            return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
        }

        /// Starts one run attempt with its first user message.
        private func beginTurn(_ session: AgentTabSession) {
            if session.runID == nil {
                session.runID = UUID()
            }
            session.runState = .running
            session.beginRunAttempt(source: "test.workspaceSteering")
            session.appendItem(.user("first", sequenceIndex: session.nextSequenceIndex))
        }

        /// A live Codex user turn on `controller`, as a real controller start leaves it, with manual
        /// acknowledgement deadlines so the bounded wait cannot race host load.
        private func prepareActiveCodexTurn(_ session: AgentTabSession, controller: LifecycleNoopCodexController) {
            let runID = UUID()
            session.codexSteerAckTracker.test_useManualDeadlines()
            session.selectedAgent = .codexExec
            session.runID = runID
            session.runState = .running
            session.beginRunAttempt(source: "test.workspaceSteering.codex")
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
        }

        private static func attribution(_ sourceWorkspaceID: UUID) -> String {
            Service.attribution(sourceWorkspaceName: "Assistant", sourceWorkspaceID: sourceWorkspaceID, sourceSessionID: UUID())
        }

        private static func pendingQuestion() -> AgentAskUserPendingState {
            let interaction = AgentAskUserInteraction(
                id: UUID(),
                questions: [AgentAskUserQuestion(id: "q", question: "Which plan?", allowsCustom: true)]
            )
            return AgentAskUserPendingState(
                interaction: interaction,
                draftsByQuestionID: interaction.emptyDrafts(),
                currentQuestionIndex: 0
            )
        }

        private static func pendingApproval() -> AgentApprovalRequest {
            AgentApprovalRequest(
                requestID: .remoteGateway(interactionID: "approval"),
                method: "test.approval",
                kind: .commandExecution,
                threadID: "thread",
                turnID: "turn",
                itemID: "item",
                reason: "Run command?",
                command: "echo ok"
            )
        }
    }

    /// The recovery store's real file-write seam (`AgentRecoveryStore.FileOperations`) with one held
    /// write: `holdNext()` suspends exactly the next store write until `release()`.
    private final class HeldRecoveryWrite: @unchecked Sendable {
        private let lock = NSLock()
        private var holdsNext = false
        private var arrived = false
        private let gate = DispatchSemaphore(value: 0)

        var hasArrived: Bool {
            lock.withLock { arrived }
        }

        func holdNext() {
            lock.withLock {
                holdsNext = true
                arrived = false
            }
        }

        /// Resumes a held write (harmless when none is held).
        func release() {
            gate.signal()
        }

        func fileOperations() -> AgentRecoveryStore.FileOperations {
            AgentRecoveryStore.FileOperations(
                writeAtomically: { [self] data, url in
                    let holds: Bool = lock.withLock {
                        guard holdsNext else { return false }
                        holdsNext = false
                        arrived = true
                        return true
                    }
                    if holds {
                        // Bounded so a failing test never wedges the store.
                        _ = gate.wait(timeout: .now() + 10)
                    }
                    try data.write(to: url, options: .atomic)
                },
                removeItem: { url in try FileManager.default.removeItem(at: url) }
            )
        }
    }
#endif
