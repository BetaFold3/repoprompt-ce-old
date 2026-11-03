import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

/// Service-level bounded-delegation boundaries: routed callers are re-admitted at commit/dispatch,
/// routed creates never orphan, adoption never invalidates a delegated subtree, and delegated
/// workers cannot control or read sessions that are not deeper than themselves.
@MainActor
final class AgentDelegationServiceBoundaryTests: XCTestCase {
    func testWorkerControlOperationsCannotAddressItselfOrShallowerSessions() async throws {
        try await withFixture { fixture in
            let run = makeRunService(fixture, sourceTabID: fixture.worker.tabID)
            for op in ["cancel", "respond"] {
                await assertInvalidParams(contains: "may only target sessions deeper", label: "\(op) main") {
                    _ = try await run.execute(args: controlArgs(op, fixture.main.sessionID))
                }
                await assertInvalidParams(contains: "may only target sessions deeper", label: "\(op) sibling") {
                    _ = try await run.execute(args: controlArgs(op, fixture.sibling.sessionID))
                }
                await assertInvalidParams(contains: "cannot target the calling agent session itself", label: "\(op) self") {
                    _ = try await run.execute(args: controlArgs(op, fixture.worker.sessionID))
                }
            }
            // The worker's own sub-worker passes the delegation gate (and fails later for having no run).
            do {
                _ = try await run.execute(args: controlArgs("cancel", fixture.subWorker.sessionID))
            } catch {
                XCTAssertFalse(String(describing: error).contains("deeper in the delegation tree"), String(describing: error))
                XCTAssertFalse(String(describing: error).contains("calling agent session itself"), String(describing: error))
            }

            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: { fixture.worker.sessionID })
            for op in ["stop_session", "get_log"] {
                await assertInvalidParams(contains: "may only target sessions deeper", label: op) {
                    _ = try await manage.execute(args: [
                        "op": .string(op),
                        "session_id": .string(fixture.main.sessionID.uuidString)
                    ])
                }
            }
            let cleanup = try await manage.execute(args: [
                "op": .string("cleanup_sessions"),
                "session_ids": .array([
                    .string(fixture.main.sessionID.uuidString),
                    .string(fixture.subWorker.sessionID.uuidString)
                ])
            ])
            let skipped = try XCTUnwrap(cleanup.objectValue?["skipped_sessions"]?.arrayValue)
            let reasons = Dictionary(uniqueKeysWithValues: skipped.compactMap(\.objectValue).compactMap { entry -> (String, String)? in
                guard let id = entry["session_id"]?.stringValue, let reason = entry["reason"]?.stringValue else { return nil }
                return (id, reason)
            })
            XCTAssertEqual(reasons[fixture.main.sessionID.uuidString], "outside_delegation_scope")
            XCTAssertNotEqual(reasons[fixture.subWorker.sessionID.uuidString], "outside_delegation_scope")
            XCTAssertNotNil(fixture.viewModel.sessions[fixture.main.tabID], "Cleanup must not delete an ancestor")

            // Main (depth 0) keeps its existing session-addressed control.
            let mainManage = makeManageService(fixture, sourceTabID: fixture.main.tabID, parentSessionID: { fixture.main.sessionID })
            let stopped = try await mainManage.execute(args: [
                "op": .string("stop_session"),
                "session_id": .string(fixture.worker.sessionID.uuidString)
            ])
            XCTAssertEqual(stopped.objectValue?["session_id"]?.stringValue, fixture.worker.sessionID.uuidString)
        }
    }

    func testCreateSessionRefusesRoutedCallerWithoutResolvedParent() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: { nil })
            await assertInvalidParams(contains: "Refusing to create an unparented session", label: "create_session") {
                _ = try await manage.execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
        }
    }

    func testCreateSessionRevalidatesCallerLineageAtCommitAndRollsBackCreatedTab() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            // The caller's lineage changes while parent resolution is suspended: the worker's root
            // is placed under another session, so the admitted depth-1 worker is now depth 2.
            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: {
                fixture.main.session.parentSessionID = fixture.otherRoot.sessionID
                return fixture.worker.sessionID
            })
            await assertInvalidParams(contains: "delegation depth 2", label: "create_session") {
                _ = try await manage.execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "The created tab is discarded")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
            XCTAssertEqual(
                fixture.viewModel.sessions.values.count(where: { $0.parentSessionID == fixture.worker.sessionID }),
                1,
                "Only the pre-existing sub-worker is parented to the worker"
            )
        }
    }

    func testResumeRejectsAdoptingRootWithDelegatedChildren() async throws {
        try await withFixture { fixture in
            let manage = makeManageService(fixture, sourceTabID: fixture.main.tabID, parentSessionID: { fixture.main.sessionID })
            await assertInvalidParams(contains: "already has delegated child sessions", label: "resume_session") {
                _ = try await manage.execute(args: [
                    "op": .string("resume_session"),
                    "session_id": .string(fixture.otherRoot.sessionID.uuidString)
                ])
            }
            XCTAssertNil(fixture.otherRoot.session.parentSessionID)
            XCTAssertEqual(
                fixture.viewModel.mcpDelegationLineage(for: fixture.otherRootChild.session),
                .resolved(depth: 1)
            )
        }
    }

    func testSteerRevalidatesCallerBeforeDispatch() async throws {
        try await withFixture { fixture in
            var run = makeRunService(fixture, sourceTabID: fixture.worker.tabID)
            var dispatched = false
            run.resolveWaitPolicyContext = { metadata in
                // Lineage changes after admission, while the steer request is suspended.
                fixture.main.session.parentSessionID = fixture.otherRoot.sessionID
                return AgentMCPWaitPolicy.RequestContext.unresolved(metadata: metadata)
            }
            run.testDispatchSteerInstruction = { _, _, _, _ in
                dispatched = true
                throw MCPError.internalError("dispatch must not run")
            }
            await assertInvalidParams(contains: "delegation depth 2", label: "steer") {
                _ = try await run.execute(args: [
                    "op": .string("steer"),
                    "session_id": .string(fixture.subWorker.sessionID.uuidString),
                    "message": .string("continue"),
                    "wait": .bool(true)
                ])
            }
            XCTAssertFalse(dispatched)
        }
    }

    func testCreateAndResumeRejectReplacementCallerBoundDuringParentResolution() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            /// The admitted worker's tab is rebound to a different, still-eligible identity while the
            /// parent is resolved; the resolver then reports that replacement identity.
            @MainActor func rebindingService() -> AgentManageMCPToolService {
                makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: {
                    let replacementID = UUID()
                    fixture.worker.session.testInstallPersistentSessionBinding(sessionID: replacementID)
                    return replacementID
                })
            }
            await assertInvalidParams(contains: "changed while its parent was being resolved", label: "create_session") {
                _ = try await rebindingService().execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)

            fixture.worker.session.testInstallPersistentSessionBinding(sessionID: fixture.worker.sessionID)
            await assertInvalidParams(contains: "changed while its parent was being resolved", label: "resume_session") {
                _ = try await rebindingService().execute(args: [
                    "op": .string("resume_session"),
                    "session_id": .string(fixture.subWorker.sessionID.uuidString)
                ])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
        }
    }

    func testCancelRevalidatesCallerScopeAtMutationBoundaryAfterAllowedAdoption() async throws {
        try await withFixture { fixture in
            let target = fixture.otherRoot
            target.session.mcpControlContext = controlContext(sessionID: target.sessionID, role: nil)
            target.session.runState = .running
            defer { target.session.runState = .idle }
            let adoption = AdoptionProbe()
            // A childless depth-0 caller passes cancel admission for another root, then is adopted
            // under main (allowed: it has no children) while cancellation is suspended.
            var run = makeRunService(fixture, sourceTabID: fixture.loneRoot.tabID, beforeHeartbeatOperation: {
                fixture.viewModel.applySpawnParentSessionID(fixture.main.sessionID, to: fixture.loneRoot.session)
                adoption.didAdopt = true
            })
            run.currentSnapshotProvider = { sessionID, _ in
                Self.runningSnapshot(sessionID: sessionID)
            }
            await assertInvalidParams(contains: "may only target sessions deeper", label: "cancel") {
                _ = try await run.execute(args: controlArgs("cancel", target.sessionID))
            }
            XCTAssertTrue(adoption.didAdopt, "The denial comes from the mutation-boundary recheck, after admission")
            XCTAssertEqual(fixture.loneRoot.session.parentSessionID, fixture.main.sessionID)
            XCTAssertEqual(target.session.runState, .running, "The root's run is not cancelled")
        }
    }

    func testExplicitTabParentMustMatchReconciledParentWhileRestorationSucceeds() async throws {
        try await withFixture { fixture in
            // The sibling's own live record lost its parent, but another live record bound to the
            // same identity still claims main, and the sibling has a delegated child.
            let sibling = fixture.sibling
            sibling.session.parentSessionID = nil
            let duplicate = try await makeExtraSession(fixture)
            duplicate.testInstallPersistentSessionBinding(sessionID: sibling.sessionID)
            duplicate.parentSessionID = fixture.main.sessionID
            duplicate.hasLoadedPersistedState = true
            let siblingChild = try await makeExtraSession(fixture)
            siblingChild.testInstallPersistentSessionBinding(sessionID: UUID())
            siblingChild.parentSessionID = sibling.sessionID
            siblingChild.hasLoadedPersistedState = true
            XCTAssertEqual(fixture.viewModel.mcpDelegationParentLookup(sessionID: sibling.sessionID), .parent(fixture.main.sessionID))

            await assertInvalidParams(contains: "different or conflicting parent", label: "conflicting parent") {
                _ = try await fixture.viewModel.mcpResolveOrCreateSessionTarget(
                    tabID: sibling.tabID,
                    sessionID: nil,
                    createIfNeeded: false,
                    sessionName: nil,
                    parentSessionID: fixture.otherRoot.sessionID
                )
            }
            XCTAssertNil(sibling.session.parentSessionID)

            // Restoring the reconciled parent changes no depth, so it is not subtree adoption.
            _ = try await fixture.viewModel.mcpResolveOrCreateSessionTarget(
                tabID: sibling.tabID,
                sessionID: nil,
                createIfNeeded: false,
                sessionName: nil,
                parentSessionID: fixture.main.sessionID
            )
            XCTAssertEqual(sibling.session.parentSessionID, fixture.main.sessionID)
            XCTAssertEqual(fixture.viewModel.mcpDelegationLineage(for: siblingChild), .resolved(depth: 2))
        }
    }

    // MARK: - Delegated child links (lossless-restart Step 5b)

    /// A recovery-tracked parent must link its child by the call's dispatcher invocation UUID under
    /// its current run attempt; without either, start fails closed before any target or dispatch.
    func testRecoveryTrackedParentStartFailsClosedBeforeCreatingAChild() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            knowledge.root.session.recoveryAdmissionMode = .mandatory
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            let probe = KnowledgeStartProbe()
            let withoutIdentity = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            await assertInvalidParams(contains: "MCP invocation identity", label: "no invocation identity") {
                _ = try await withoutIdentity.execute(args: knowledgeStartArgs())
            }
            let withIdentity = makeKnowledgeStartService(
                fixture,
                source: knowledge.root,
                probe: probe,
                toolInvocationID: UUID()
            )
            await assertInvalidParams(contains: "no current run attempt", label: "no parent run attempt") {
                _ = try await withIdentity.execute(args: knowledgeStartArgs())
            }
            XCTAssertTrue(probe.starts.isEmpty, "Nothing was dispatched")
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "No child target was created")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
        }
    }

    /// The real routed new-target creator under a recovery-tracked parent: by the time the scoped
    /// start runs, the new child is durable and the parent's link is committed under the exact
    /// invocation and attempt, and the TaskLocal fence names that child. The fence is released once
    /// the start returns. Fixture-only start; no provider.
    func testRecoveryTrackedParentStartCommitsChildAndLinkBeforeTheScopedStart() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            let viewModel = fixture.viewModel
            let recovery = try await installRecoveryAndClaimLane(fixture, root: knowledge.root)
            let root = knowledge.root.session
            root.runID = UUID()
            root.runState = .running
            let ownership = root.beginRunAttempt(source: "test.delegatedChildLink")
            let invocationID = UUID()
            let observed = DelegatedChildStartObservation()
            let service = makeKnowledgeStartService(
                fixture,
                source: knowledge.root,
                probe: KnowledgeStartProbe(),
                startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _, _ in
                    guard let sessionID = target.sessionID else {
                        throw MCPError.internalError("The created target has no session ID.")
                    }
                    observed.starts += 1
                    observed.childSessionID = sessionID
                    observed.persistedParentSessionID = try await agentModeVM.test_dataService
                        .loadAgentSession(id: sessionID, for: recovery.workspace)?.parentSessionID
                    observed.links = await recovery.lane.store.read(sessionID: recovery.lane.sessionID).record?.delegatedChildLinks ?? []
                    observed.fence = MCPDelegatedChildDispatchFence.current
                    observed.fenceArmedForChild = agentModeVM.mcpDelegatedChildDispatchFence(for: sessionID) != nil
                    return AgentExternalMCPRunStarter.StartOutcome(
                        snapshot: Self.knowledgeWorkerSnapshot(
                            sessionID: sessionID,
                            tabID: target.tabID,
                            parentSessionID: knowledge.root.sessionID,
                            agentRaw: agentRaw,
                            modelRaw: modelRaw,
                            reasoningEffortRaw: reasoningEffortRaw
                        ),
                        delivery: .startedRun
                    )
                },
                toolInvocationID: invocationID
            )
            _ = try await service.execute(args: knowledgeStartArgs())

            XCTAssertEqual(observed.starts, 1, "Exactly one start")
            let childSessionID = try XCTUnwrap(observed.childSessionID)
            XCTAssertEqual(observed.persistedParentSessionID, knowledge.root.sessionID, "The child was durable before the start")
            XCTAssertEqual(observed.links.map(\.invocationID), [invocationID], "The exact ingress invocation")
            XCTAssertEqual(observed.links.map(\.parentRunAttemptID), [ownership.attemptID])
            XCTAssertEqual(observed.links.map(\.childSessionID), [childSessionID], "Committed before the start")
            let fence = try XCTUnwrap(observed.fence, "The start ran under the linked fence")
            XCTAssertEqual(fence.linkedChildSessionID, childSessionID)
            XCTAssertTrue(observed.fenceArmedForChild)
            XCTAssertTrue(fence.isDispatchFenceReleased, "Released once the start returned")
            XCTAssertNil(MCPDelegatedChildDispatchFence.$current.withValue(fence) {
                viewModel.mcpDelegatedChildDispatchFence(for: childSessionID)
            })
        }
    }

    // MARK: - Knowledge research workers

    func testKnowledgeStartRejectsUnsupportedArgumentsBeforeCreatingAnything() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            let probe = KnowledgeStartProbe()
            let run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            let cases: [(label: String, extra: [String: Value], expected: String)] = [
                ("role label", ["model_id": .string("engineer")], "does not accept role labels"),
                ("explore label", ["model_id": .string("explore")], "does not accept role labels"),
                ("tab_id", ["tab_id": .string(fixture.main.tabID.uuidString)], "tab_id and other existing-session selectors are not supported"),
                ("_tabID", ["_tabID": .string(fixture.main.tabID.uuidString)], "tab_id and other existing-session selectors are not supported"),
                ("session_id", ["session_id": .string(knowledge.worker.sessionID.uuidString)], "agent_run.start always creates a new session"),
                ("workflow_name", ["workflow_name": .string("orchestrate")], "does not support workflows"),
                ("workflow_id", ["workflow_id": .string(UUID().uuidString)], "does not support workflows"),
                ("inherit_worktree", ["inherit_worktree": .bool(false)], "does not support worktree arguments"),
                ("worktree_create", ["worktree_create": .bool(true)], "does not support worktree arguments"),
                ("cursor", ["model_id": .string("cursor:auto")], "Knowledge research workers run only on"),
                ("openCode", ["model_id": .string("openCode:some-model")], "Knowledge research workers run only on"),
                ("ohMyPi", ["model_id": .string("ohMyPi:some-model")], "Knowledge research workers run only on")
            ]
            for testCase in cases {
                var args = knowledgeStartArgs()
                args.merge(testCase.extra) { _, new in new }
                await assertInvalidParams(contains: testCase.expected, label: testCase.label) {
                    _ = try await run.execute(args: args)
                }
            }
            XCTAssertTrue(probe.starts.isEmpty)
            XCTAssertTrue(probe.adoptions.isEmpty)
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
        }
    }

    func testKnowledgeCodexWorkerRequiresCodexWebSearchForExplicitAndInheritedModels() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            knowledge.root.session.selectedAgent = .codexExec
            knowledge.root.session.selectedModelRaw = "gpt-5.4"
            let probe = KnowledgeStartProbe()
            var run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            run.codexWebSearchEnabled = { false }
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            let cases: [(label: String, extra: [String: Value])] = [
                ("explicit", ["model_id": .string("codexExec:gpt-5.4")]),
                ("inherited", [:])
            ]
            for testCase in cases {
                var args = knowledgeStartArgs()
                args.merge(testCase.extra) { _, new in new }
                await assertInvalidParams(contains: "Codex web search is turned off", label: testCase.label) {
                    _ = try await run.execute(args: args)
                }
            }
            XCTAssertTrue(probe.starts.isEmpty)
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "No research worker tab is created")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)

            // The Codex toggle does not gate an explicit Claude Code worker.
            let claudeValue = try await run.execute(args: knowledgeStartArgs(modelID: "claudeCode:sonnet"))
            XCTAssertEqual(probe.starts.count, 1)
            XCTAssertEqual(probe.starts.first?.agentRaw, AgentProviderKind.claudeCode.rawValue)
            let receipt = try XCTUnwrap(claudeValue.objectValue?["knowledge_worker"]?.objectValue)
            XCTAssertEqual(receipt["model_source"]?.stringValue, "explicit")
            XCTAssertEqual(receipt["provider"]?.stringValue, AgentProviderKind.claudeCode.rawValue)
            XCTAssertEqual(receipt["model"]?.stringValue, probe.starts.first?.modelRaw)
            XCTAssertEqual(probe.starts.first?.targetProfile, .knowledge)
        }
    }

    func testKnowledgeStartInheritsFrozenParentSelectionAndAdoptsProfileBeforeBinding() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            knowledge.root.session.selectedAgent = .claudeCode
            knowledge.root.session.selectedModelRaw = "opus"
            knowledge.root.session.selectedReasoningEffortRaw = "high"
            let probe = KnowledgeStartProbe()
            fixture.viewModel.test_mcpBeforeChildSessionProfileAdoptionHook = { session in
                probe.adoptions.append(.init(
                    sessionID: session.activeAgentSessionID,
                    profile: session.profile,
                    parentSessionID: session.parentSessionID,
                    hasControlContext: session.mcpControlContext != nil
                ))
            }
            defer { fixture.viewModel.test_mcpBeforeChildSessionProfileAdoptionHook = nil }
            // The parent's selection changes after admission, while the launch source is resolved:
            // the worker must keep the selection frozen at admission.
            let run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe) {
                knowledge.root.session.selectedModelRaw = "sonnet"
                knowledge.root.session.selectedReasoningEffortRaw = "low"
            }
            let tabsBefore = composeTabIDs(fixture)

            let value = try await run.execute(args: knowledgeStartArgs())

            XCTAssertEqual(probe.adoptions.count, 1)
            let adoption = try XCTUnwrap(probe.adoptions.first)
            XCTAssertNil(adoption.sessionID, "The profile is adopted before the new tab is bound to an identity")
            XCTAssertEqual(adoption.profile, .standard)
            XCTAssertNil(adoption.parentSessionID, "The profile is adopted before the parent is recorded")
            XCTAssertFalse(adoption.hasControlContext)

            XCTAssertEqual(probe.starts.count, 1)
            let start = try XCTUnwrap(probe.starts.first)
            XCTAssertEqual(start.agentRaw, AgentProviderKind.claudeCode.rawValue)
            XCTAssertEqual(start.modelRaw, "opus")
            XCTAssertEqual(start.reasoningEffortRaw, "high")
            XCTAssertNil(start.taskLabelKind, "A Knowledge worker never resolves through a role default")
            XCTAssertTrue(start.workflowWasNil)
            XCTAssertEqual(start.expectedParentSessionID, knowledge.root.sessionID)
            XCTAssertEqual(start.targetProfile, .knowledge)
            XCTAssertEqual(start.targetParentSessionID, knowledge.root.sessionID)
            let targetSessionID = try XCTUnwrap(start.targetSessionID)
            XCTAssertEqual(fixture.viewModel.mcpDelegationSessionProfile(sessionID: targetSessionID), .knowledge)
            XCTAssertEqual(fixture.viewModel.mcpDelegationLineage(sessionID: targetSessionID), .resolved(depth: 1))
            XCTAssertEqual(composeTabIDs(fixture).subtracting(tabsBefore).count, 1)

            let receipt = try XCTUnwrap(value.objectValue?["knowledge_worker"]?.objectValue)
            XCTAssertEqual(receipt["profile"]?.stringValue, "knowledge")
            XCTAssertEqual(receipt["model_source"]?.stringValue, "inherited")
            XCTAssertEqual(receipt["provider"]?.stringValue, AgentProviderKind.claudeCode.rawValue)
            XCTAssertEqual(receipt["model"]?.stringValue, "opus")
            XCTAssertEqual(receipt["reasoning_effort"]?.stringValue, "high")

            // The new worker is the root's own worker for later control and observation.
            XCTAssertNoThrow(try fixture.viewModel.mcpValidateDelegationTarget(
                sourceTabID: knowledge.root.tabID,
                targetSessionID: targetSessionID,
                operation: "agent_run.wait"
            ))
        }
    }

    func testKnowledgeStartDiscardsNewTabWhenProfileAdoptionFails() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            knowledge.root.session.selectedAgent = .claudeCode
            knowledge.root.session.selectedModelRaw = "sonnet"
            let probe = KnowledgeStartProbe()
            fixture.viewModel.test_mcpBeforeChildSessionProfileAdoptionHook = { session in
                probe.adoptions.append(.init(
                    sessionID: session.activeAgentSessionID,
                    profile: session.profile,
                    parentSessionID: session.parentSessionID,
                    hasControlContext: session.mcpControlContext != nil
                ))
                // The placeholder is no longer untouched, so it cannot adopt a profile.
                session.hasSentFirstMessage = true
            }
            defer { fixture.viewModel.test_mcpBeforeChildSessionProfileAdoptionHook = nil }
            let run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count

            await assertInvalidParams(contains: "could not apply the knowledge profile", label: "adoption failure") {
                _ = try await run.execute(args: knowledgeStartArgs())
            }

            XCTAssertEqual(probe.adoptions.count, 1)
            XCTAssertTrue(probe.starts.isEmpty, "No provider starts for a worker whose profile was not applied")
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "The created tab is discarded")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
            XCTAssertEqual(
                fixture.viewModel.sessions.values.count(where: { $0.parentSessionID == knowledge.root.sessionID }),
                1,
                "Only the pre-existing worker is parented to the Knowledge root"
            )
        }
    }

    func testKnowledgeWorkerCannotStartOrControlAndRootRejectsUnsupportedOperations() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            let tabsBefore = composeTabIDs(fixture)
            let probe = KnowledgeStartProbe()
            let workerRun = makeKnowledgeStartService(fixture, source: knowledge.worker, probe: probe)
            let workerCalls: [(label: String, args: [String: Value])] = [
                ("start", knowledgeStartArgs()),
                ("start explicit", knowledgeStartArgs(modelID: "claudeCode:sonnet")),
                ("wait", ["op": .string("wait"), "session_id": .string(knowledge.root.sessionID.uuidString)]),
                ("poll", ["op": .string("poll"), "session_id": .string(knowledge.root.sessionID.uuidString)]),
                ("cancel", controlArgs("cancel", knowledge.root.sessionID)),
                ("steer", ["op": .string("steer"), "session_id": .string(knowledge.root.sessionID.uuidString), "message": .string("x")]),
                ("respond", controlArgs("respond", knowledge.root.sessionID))
            ]
            for call in workerCalls {
                await assertInvalidParams(
                    contains: "Knowledge research workers cannot start or control other agents",
                    label: "worker \(call.label)"
                ) {
                    _ = try await workerRun.execute(args: call.args)
                }
            }
            XCTAssertTrue(probe.starts.isEmpty)
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)

            let rootRun = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            await assertInvalidParams(contains: "is not available to Knowledge sessions", label: "unsupported op") {
                _ = try await rootRun.execute(args: ["op": .string("list")])
            }

            // A connection enforcing the Knowledge profile whose routed source is not a live Knowledge
            // session fails closed instead of running as a standard caller.
            for source in [Optional(fixture.main.tabID), nil] {
                var mismatched = makeRunService(fixture, sourceTabID: source)
                mismatched.resolveConnectionSessionProfile = { _ in .knowledge }
                await assertInvalidParams(contains: "could not resolve that session", label: "mismatched connection profile") {
                    _ = try await mismatched.execute(args: knowledgeStartArgs())
                }
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
        }
    }

    func testKnowledgeRootControlsAndObservesOnlyItsOwnWorkers() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            var run = makeRunService(fixture, sourceTabID: knowledge.root.tabID)
            run.currentSnapshotProvider = { sessionID, _ in
                Self.runningSnapshot(sessionID: sessionID)
            }
            let steerDispatch = DispatchProbe()
            run.testDispatchSteerInstruction = { _, _, _, _ in
                steerDispatch.count += 1
                throw MCPError.internalError("steer dispatch reached")
            }
            let foreignTargets: [(label: String, sessionID: UUID)] = [
                ("standard main", fixture.main.sessionID),
                ("standard worker", fixture.worker.sessionID),
                ("other Knowledge root", knowledge.otherRoot.sessionID),
                ("other root's Knowledge worker", knowledge.otherRootWorker.sessionID)
            ]
            let ownWorkerMessage = "may only target its own Knowledge research workers"
            for target in foreignTargets {
                for op in ["cancel", "respond"] {
                    await assertInvalidParams(contains: ownWorkerMessage, label: "\(op) \(target.label)") {
                        _ = try await run.execute(args: controlArgs(op, target.sessionID))
                    }
                }
                await assertInvalidParams(contains: ownWorkerMessage, label: "steer \(target.label)") {
                    _ = try await run.execute(args: [
                        "op": .string("steer"),
                        "session_id": .string(target.sessionID.uuidString),
                        "message": .string("continue")
                    ])
                }
                for op in ["wait", "poll"] {
                    await assertInvalidParams(contains: ownWorkerMessage, label: "\(op) session_id \(target.label)") {
                        _ = try await run.execute(args: [
                            "op": .string(op),
                            "session_id": .string(target.sessionID.uuidString)
                        ])
                    }
                    await assertInvalidParams(contains: ownWorkerMessage, label: "\(op) session_ids \(target.label)") {
                        _ = try await run.execute(args: [
                            "op": .string(op),
                            "session_ids": .array([
                                .string(knowledge.worker.sessionID.uuidString),
                                .string(target.sessionID.uuidString)
                            ])
                        ])
                    }
                }
            }
            await assertInvalidParams(contains: "cannot target the calling agent session itself", label: "poll self") {
                _ = try await run.execute(args: [
                    "op": .string("poll"),
                    "session_id": .string(knowledge.root.sessionID.uuidString)
                ])
            }
            XCTAssertEqual(steerDispatch.count, 0, "No steer is dispatched to a foreign session")

            // The root's own worker passes the gate for every allowlisted operation.
            let polled = try await run.execute(args: [
                "op": .string("poll"),
                "session_id": .string(knowledge.worker.sessionID.uuidString)
            ])
            XCTAssertNotNil(polled.objectValue)
            _ = try await run.execute(args: [
                "op": .string("poll"),
                "session_ids": .array([.string(knowledge.worker.sessionID.uuidString)])
            ])
            for args in [
                controlArgs("cancel", knowledge.worker.sessionID),
                controlArgs("respond", knowledge.worker.sessionID),
                [
                    "op": .string("steer"),
                    "session_id": .string(knowledge.worker.sessionID.uuidString),
                    "message": .string("continue")
                ]
            ] {
                do {
                    _ = try await run.execute(args: args)
                } catch {
                    XCTAssertFalse(String(describing: error).contains(ownWorkerMessage), String(describing: error))
                    XCTAssertFalse(String(describing: error).contains("cannot start or control"), String(describing: error))
                }
            }
        }
    }

    /// Live regression: a Knowledge root's detached `agent_run.start` runs the production starter,
    /// whose MCP control activation must admit the fresh Knowledge worker; a later steer from the root
    /// must reactivate that worker after its MCP control expired. For each provider and model source,
    /// and for either edit-approval setting, MCP control never forces auto-edit: the worker keeps its
    /// normal Knowledge-session setting in the session and the approval store through start,
    /// reactivation, and cleanup. The global sub-agent permission profile still governs native
    /// provider permissions, and the worker's run lease and prompt stay delegation leaves.
    func testKnowledgeWorkerStartActivatesControlThroughProductionStarterAndSteersAfterExpiry() async throws {
        // New sessions take the global edit-approval default; restore it after the test.
        let autoEditDefaultKey = "agentModeAutoEditEnabled"
        let previousAutoEditDefault = UserDefaults.standard.object(forKey: autoEditDefaultKey)
        defer {
            if let previousAutoEditDefault {
                UserDefaults.standard.set(previousAutoEditDefault, forKey: autoEditDefaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: autoEditDefaultKey)
            }
        }
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            let vm = fixture.viewModel
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            let dispatches = KnowledgeDispatchProbe()
            var run = makeKnowledgeStartService(
                fixture,
                source: knowledge.root,
                probe: KnowledgeStartProbe(),
                startRun: productionStartRun(recordingInto: dispatches)
            )
            run.testDispatchSteerInstruction = { sessionID, _, _, agentModeVM in
                let tabID = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID)?.tabID)
                await dispatches.records.append(self.knowledgeDispatchRecord(sessionID: sessionID, tabID: tabID, host: agentModeVM))
                return .startedRun
            }
            // Explicit variants select the other provider on the root, so the explicit model_id wins.
            let variants: [(label: String, worker: AgentProviderKind, root: (agent: AgentProviderKind, model: String, effort: String), modelID: String?)] = [
                ("Claude inherited", .claudeCode, (.claudeCode, "opus", "high"), nil),
                ("Claude explicit", .claudeCode, (.codexExec, "gpt-5.4", "high"), "claudeCode:sonnet"),
                ("Codex inherited", .codexExec, (.codexExec, "gpt-5.4", "high"), nil),
                ("Codex explicit", .codexExec, (.claudeCode, "opus", "high"), "codexExec:gpt-5.4")
            ]
            for autoEdit in [false, true] {
                for variant in variants {
                    let label = "\(variant.label), auto-edit \(autoEdit)"
                    ApplyEditsApprovalStore.setGlobalDefaultAutoEditEnabled(autoEdit)
                    knowledge.root.session.selectedAgent = variant.root.agent
                    knowledge.root.session.selectedModelRaw = variant.root.model
                    knowledge.root.session.selectedReasoningEffortRaw = variant.root.effort
                    let subagentProfile = vm.providerBindingService.permissionProfileForMCPActivation(
                        isSubagent: true,
                        provider: variant.worker.providerBindingID
                    )
                    let tabsBefore = composeTabIDs(fixture)
                    let dispatchesBefore = dispatches.records.count

                    let value = try await run.execute(args: knowledgeStartArgs(modelID: variant.modelID))

                    XCTAssertEqual(dispatches.records.count, dispatchesBefore + 1, "\(label): the production starter reached provider dispatch")
                    let started = try XCTUnwrap(dispatches.records.last, label)
                    XCTAssertEqual(started.parentSessionID, knowledge.root.sessionID, label)
                    assertKnowledgeWorkerDispatch(started, autoEdit: autoEdit, permissionProfile: subagentProfile, label: "\(label) start")
                    let workerID = started.sessionID
                    let worker = try XCTUnwrap(vm.mcpControlledSession(sessionID: workerID), label)
                    let receipt = try XCTUnwrap(value.objectValue?["knowledge_worker"]?.objectValue, label)
                    XCTAssertEqual(receipt["model_source"]?.stringValue, variant.modelID == nil ? "inherited" : "explicit", label)
                    XCTAssertEqual(receipt["provider"]?.stringValue, variant.worker.rawValue, label)
                    XCTAssertEqual(worker.selectedAgent, variant.worker, label)
                    XCTAssertEqual(worker.selectedModelRaw, receipt["model"]?.stringValue, label)
                    if variant.modelID == nil {
                        XCTAssertEqual(worker.selectedModelRaw, variant.root.model, label)
                        XCTAssertEqual(receipt["reasoning_effort"]?.stringValue, variant.root.effort, label)
                        // Codex keeps the inherited effort on the session; Claude effort is a
                        // per-model preference, so configuration clears the session field.
                        XCTAssertEqual(
                            worker.selectedReasoningEffortRaw,
                            variant.worker == .codexExec ? variant.root.effort : nil,
                            label
                        )
                    }
                    XCTAssertEqual(vm.mcpDelegationLineage(sessionID: workerID), .resolved(depth: 1), label)
                    XCTAssertEqual(composeTabIDs(fixture).subtracting(tabsBefore).count, 1, label)
                    try await AsyncTestWait.waitUntil("\(label): worker approval subscription installed") {
                        worker.applyEditsApprovalScopeGeneration != nil
                    }
                    await assertEditApproval(of: worker, is: autoEdit, in: vm, label: "\(label) after start")

                    // Control expires: cleanup restores user-configured provider permissions and
                    // leaves the edit-approval setting as it was.
                    await vm.mcpDeactivateControlContext(sessionID: workerID, cleanupSessionStore: true)
                    XCTAssertNil(vm.mcpControlledSession(sessionID: workerID), label)
                    XCTAssertEqual(worker.permissionProfile, .userConfigured, label)
                    await assertEditApproval(of: worker, is: autoEdit, in: vm, label: "\(label) after expiry")

                    // The root's later steer reactivates its own worker with the same posture.
                    _ = try await run.execute(args: steerArgs(workerID))
                    XCTAssertEqual(dispatches.records.count, dispatchesBefore + 2, "\(label): the steer reached dispatch after reactivation")
                    let steered = try XCTUnwrap(dispatches.records.last, label)
                    XCTAssertEqual(steered.sessionID, workerID, label)
                    assertKnowledgeWorkerDispatch(steered, autoEdit: autoEdit, permissionProfile: subagentProfile, label: "\(label) steer")
                    XCTAssertTrue(vm.mcpControlledSession(sessionID: workerID) === worker, label)

                    // A setting changed while the worker is controlled survives cleanup.
                    await vm.applyEditsApprovalStore.setAutoEditEnabled(
                        !autoEdit,
                        for: vm.applyEditsScope(for: worker.tabID),
                        updateGlobalDefault: false
                    )
                    try await AsyncTestWait.waitUntil("\(label): worker observed the changed setting") {
                        worker.autoEditEnabled == !autoEdit
                    }
                    await vm.mcpDeactivateControlContext(sessionID: workerID, cleanupSessionStore: true)
                    XCTAssertNil(vm.mcpControlledSession(sessionID: workerID), label)
                    XCTAssertEqual(worker.permissionProfile, .userConfigured, label)
                    await assertEditApproval(of: worker, is: !autoEdit, in: vm, label: "\(label) after changed-setting cleanup")
                }
            }
        }
    }

    /// Knowledge control activation admits only a Knowledge caller's verified worker: standard
    /// activation keeps rejecting every Knowledge session; a Knowledge expectation rejects roots,
    /// standard sessions, and unverifiable or deeper lineage; the production starter never infers
    /// the profile from a live tab; and standard or external steers still cannot reactivate a worker.
    func testKnowledgeControlActivationRejectsStandardExternalAndUnverifiedTargets() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            let vm = fixture.viewModel
            let standardMessage = "Knowledge sessions cannot be converted into MCP-controlled coding sessions. Start a standard Agent session instead."
            let workerMessage = "requires a verified Knowledge worker session started by a Knowledge session"
            // The existing worker's MCP control has expired.
            knowledge.worker.session.mcpControlContext = nil

            @MainActor func knowledgeSession(parentSessionID: UUID) async throws -> Node {
                let session = try await makeExtraSession(fixture)
                let sessionID = UUID()
                session.testInstallPersistentSessionBinding(sessionID: sessionID)
                session.hasLoadedPersistedState = true
                XCTAssertTrue(session.adoptSessionProfile(.knowledge))
                session.parentSessionID = parentSessionID
                return Node(tabID: session.tabID, sessionID: sessionID, session: session)
            }
            let unverifiedLineage = try await knowledgeSession(parentSessionID: UUID())
            let depthTwo = try await knowledgeSession(parentSessionID: knowledge.worker.sessionID)

            for (label, node) in [("Knowledge root", knowledge.root), ("Knowledge worker", knowledge.worker)] {
                await assertInvalidParams(contains: standardMessage, label: "standard activation of \(label)") {
                    _ = try await vm.mcpActivateControlContext(
                        forTabID: node.tabID,
                        sessionID: node.sessionID,
                        originatingConnectionID: nil
                    )
                }
                XCTAssertNil(node.session.mcpControlContext, label)
            }

            let nonWorkers: [(label: String, node: Node)] = [
                ("Knowledge root", knowledge.root),
                ("standard root", fixture.main),
                ("standard worker", fixture.worker),
                ("Knowledge session with unverifiable lineage", unverifiedLineage),
                ("depth-2 Knowledge session", depthTwo)
            ]
            for target in nonWorkers {
                let activationBefore = target.node.session.mcpControlContext?.activationID
                await assertInvalidParams(contains: workerMessage, label: "Knowledge activation of \(target.label)") {
                    _ = try await vm.mcpActivateControlContext(
                        forTabID: target.node.tabID,
                        sessionID: target.node.sessionID,
                        originatingConnectionID: nil,
                        expectedSessionProfile: .knowledge
                    )
                }
                XCTAssertEqual(target.node.session.mcpControlContext?.activationID, activationBefore, target.label)
            }

            // The starter takes a Knowledge expectation only from a target created with that profile.
            let dispatches = KnowledgeDispatchProbe()
            let startRun = productionStartRun(recordingInto: dispatches)
            for origin in [AgentModeViewModel.MCPSessionTarget.Origin.existingTab, .createdNewTab] {
                await assertInvalidParams(contains: standardMessage, label: "starter target \(origin)") {
                    _ = try await startRun(
                        AgentModeViewModel.MCPSessionTarget(
                            tabID: knowledge.worker.tabID,
                            sessionID: knowledge.worker.sessionID,
                            origin: origin
                        ),
                        "Research one perspective.",
                        metadata(fixture.window),
                        { _, _ in },
                        vm,
                        nil,
                        nil,
                        nil,
                        nil,
                        .empty,
                        nil,
                        knowledge.root.sessionID,
                        nil
                    )
                }
            }
            XCTAssertTrue(dispatches.records.isEmpty)
            XCTAssertNil(knowledge.worker.session.mcpControlContext)

            let steered = DispatchProbe()
            for (label, source) in [("standard root", Optional(fixture.main.tabID)), ("external", nil)] {
                var run = makeRunService(fixture, sourceTabID: source)
                run.testDispatchSteerInstruction = { _, _, _, _ in
                    steered.count += 1
                    return .startedRun
                }
                await assertInvalidParams(contains: standardMessage, label: "\(label) steer") {
                    _ = try await run.execute(args: steerArgs(knowledge.worker.sessionID))
                }
            }
            XCTAssertEqual(steered.count, 0)
            XCTAssertNil(vm.mcpControlledSession(sessionID: knowledge.worker.sessionID))
        }
    }

    /// A Knowledge root's steer reactivates its expired worker only for the caller frozen at
    /// admission: when the caller's identity or eligibility changes before reactivation commits, the
    /// steer never dispatches and no reactivated control outlives the refusal. Neither refusal nor the
    /// successful reactivation changes the worker's own edit-approval setting.
    func testKnowledgeSteerReactivationFailsClosedWhenTheCallerGoesStale() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            let vm = fixture.viewModel
            let root = knowledge.root
            let worker = knowledge.worker
            worker.session.mcpControlContext = nil
            // The worker's own setting requires edit approval.
            try await AsyncTestWait.waitUntil("worker approval subscription installed") {
                worker.session.applyEditsApprovalScopeGeneration != nil
            }
            await vm.applyEditsApprovalStore.setAutoEditEnabled(
                false,
                for: vm.applyEditsScope(for: worker.tabID),
                updateGlobalDefault: false
            )
            try await AsyncTestWait.waitUntil("worker observed its setting") {
                !worker.session.autoEditEnabled
            }
            var run = makeRunService(fixture, sourceTabID: root.tabID)
            let steered = DispatchProbe()
            run.testDispatchSteerInstruction = { _, _, _, _ in
                steered.count += 1
                return .startedRun
            }
            // `wait: true` resolves the wait context after control admission and before reactivation.
            @MainActor func steerWhileCallerChanges(_ change: @escaping @MainActor @Sendable () -> Void) async throws {
                var staleRun = run
                staleRun.resolveWaitPolicyContext = { metadata in
                    await MainActor.run { change() }
                    return .unresolved(metadata: metadata)
                }
                _ = try await staleRun.execute(args: steerArgs(worker.sessionID, wait: true))
            }

            // The caller's tab is rebound: its worker's lineage no longer verifies at activation.
            let replacementID = UUID()
            await assertInvalidParams(
                contains: "requires a verified Knowledge worker session",
                label: "caller rebound before reactivation"
            ) {
                try await steerWhileCallerChanges {
                    root.session.testInstallPersistentSessionBinding(sessionID: replacementID)
                }
            }
            XCTAssertEqual(steered.count, 0)
            XCTAssertNil(vm.mcpControlledSession(sessionID: worker.sessionID))
            XCTAssertEqual(worker.session.permissionProfile, .userConfigured)
            await assertEditApproval(of: worker.session, is: false, in: vm, label: "after rebound-caller refusal")
            root.session.testInstallPersistentSessionBinding(sessionID: root.sessionID)

            // The caller loses eligibility: reactivation succeeds, the dispatch recheck refuses, and
            // the reactivated control is removed.
            let exploreContext = controlContext(sessionID: root.sessionID, role: .explore)
            await assertInvalidParams(
                contains: "Explore agents cannot start or control other agents",
                label: "caller eligibility revoked before dispatch"
            ) {
                try await steerWhileCallerChanges {
                    root.session.mcpControlContext = exploreContext
                }
            }
            XCTAssertEqual(steered.count, 0)
            XCTAssertNil(vm.mcpControlledSession(sessionID: worker.sessionID))
            XCTAssertEqual(worker.session.permissionProfile, .userConfigured, "Cleanup restored provider permissions")
            await assertEditApproval(of: worker.session, is: false, in: vm, label: "after reactivated-control cleanup")
            root.session.mcpControlContext = nil

            // Unchanged, the same steer reactivates the worker and dispatches.
            _ = try await run.execute(args: steerArgs(worker.sessionID))
            XCTAssertEqual(steered.count, 1)
            let reactivated = try XCTUnwrap(vm.mcpControlledSession(sessionID: worker.sessionID))
            XCTAssertEqual(reactivated.profile, .knowledge)
            XCTAssertEqual(reactivated.mcpControlContext?.forceAutoEditEnabled, false)
            await assertEditApproval(of: worker.session, is: false, in: vm, label: "after reactivation")
        }
    }

    func testKnowledgeStartRejectsCallerReplacedBeforeInnerAdmission() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            for root in [knowledge.root, knowledge.otherRoot] {
                root.session.selectedAgent = .claudeCode
                root.session.selectedModelRaw = "sonnet"
            }
            let probe = KnowledgeStartProbe()
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            let startCalls: [(label: String, args: [String: Value])] = [
                ("explicit", knowledgeStartArgs(modelID: "claudeCode:sonnet")),
                ("inherited", knowledgeStartArgs())
            ]

            // Another identity takes the admitted root's tab after outer admission, before the start's
            // own admission: the replacement is never admitted or credited with the request.
            let replacementSessionID = UUID()
            let rebindHooks = CallerHookProbe()
            let rebindRun = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe, hooks: rebindHooks)
            for call in startCalls {
                rebindHooks.reset()
                rebindHooks.onSourceResolution[2] = {
                    knowledge.root.session.testInstallPersistentSessionBinding(sessionID: replacementSessionID)
                }
                await assertInvalidParams(contains: "changed while the request was in flight", label: "rebind \(call.label)") {
                    _ = try await rebindRun.execute(args: call.args)
                }
                XCTAssertEqual(rebindHooks.sourceResolutions, 2, "rebind \(call.label): replaced after outer admission")
                knowledge.root.session.testInstallPersistentSessionBinding(sessionID: knowledge.root.sessionID)
            }

            // The admitted root's tab now reads as a standard session: the request is never
            // downgraded to standard delegation.
            let downgradeHooks = CallerHookProbe()
            let downgradeRun = makeKnowledgeStartService(fixture, source: knowledge.otherRoot, probe: probe, hooks: downgradeHooks)
            for call in startCalls {
                downgradeHooks.reset()
                downgradeHooks.onSourceResolution[2] = {
                    XCTAssertTrue(knowledge.otherRoot.session.adoptSessionProfile(.standard))
                }
                await assertInvalidParams(contains: "is no longer a verified knowledge session", label: "downgrade \(call.label)") {
                    _ = try await downgradeRun.execute(args: call.args)
                }
                XCTAssertEqual(downgradeHooks.sourceResolutions, 2, "downgrade \(call.label): replaced after outer admission")
                XCTAssertTrue(knowledge.otherRoot.session.adoptSessionProfile(.knowledge))
            }

            XCTAssertTrue(probe.starts.isEmpty)
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "No research worker tab is created")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
            XCTAssertFalse(fixture.viewModel.sessions.values.contains { $0.parentSessionID == replacementSessionID })
        }
    }

    func testKnowledgeControlRejectsCallerReplacedBeforeControlAdmission() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            let hooks = CallerHookProbe()
            var run = makeRunService(fixture, sourceTabID: knowledge.root.tabID, hooks: hooks)
            run.currentSnapshotProvider = { sessionID, _ in
                Self.runningSnapshot(sessionID: sessionID)
            }
            let steerDispatch = DispatchProbe()
            run.testDispatchSteerInstruction = { _, _, _, _ in
                steerDispatch.count += 1
                throw MCPError.internalError("steer dispatch reached")
            }
            @MainActor
            func call(_ op: String, _ target: UUID) -> [String: Value] {
                switch op {
                case "steer":
                    ["op": .string(op), "session_id": .string(target.uuidString), "message": .string("continue")]
                case "poll":
                    ["op": .string(op), "session_id": .string(target.uuidString)]
                default:
                    controlArgs(op, target)
                }
            }
            /// Control ops are replaced on their own source resolution; poll on its own metadata capture.
            @MainActor
            func installReplacement(for op: String, _ replace: @escaping @MainActor () -> Void) {
                hooks.reset()
                if op == "poll" {
                    hooks.onMetadataCapture[2] = replace
                } else {
                    hooks.onSourceResolution[2] = replace
                }
            }
            let replacementSessionID = UUID()
            for op in ["cancel", "steer", "respond", "poll"] {
                // A replacement identity is never admitted in place of the admitted root, even for
                // the root's own worker.
                installReplacement(for: op) {
                    knowledge.root.session.testInstallPersistentSessionBinding(sessionID: replacementSessionID)
                }
                await assertInvalidParams(contains: "changed while the request was in flight", label: "\(op) rebind") {
                    _ = try await run.execute(args: call(op, knowledge.worker.sessionID))
                }
                XCTAssertEqual(hooks.metadataCaptures, 2, "\(op) rebind: replaced after outer admission")
                knowledge.root.session.testInstallPersistentSessionBinding(sessionID: knowledge.root.sessionID)

                // A standard replacement never gives the admitted Knowledge request standard depth-0
                // access to a standard session.
                installReplacement(for: op) {
                    XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.standard))
                }
                await assertInvalidParams(contains: "is no longer a verified knowledge session", label: "\(op) downgrade") {
                    _ = try await run.execute(args: call(op, fixture.main.sessionID))
                }
                XCTAssertEqual(hooks.metadataCaptures, 2, "\(op) downgrade: replaced after outer admission")
                XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.knowledge))
            }
            XCTAssertEqual(steerDispatch.count, 0, "No steer is dispatched for a replaced caller")
        }
    }

    func testKnowledgeStartRequestIDsArePartitionedByAdmittedCaller() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            let registry = MCPRequestIdempotencyRegistry()
            let probe = KnowledgeStartProbe()
            var args = knowledgeStartArgs(modelID: "claudeCode:sonnet")
            args["request_id"] = .string("shared-research-request")
            // A standard session sharing the client namespace already completed this request_id with
            // the identical payload.
            try await seedRecordedOutcome(
                registry,
                clientID: sharedIdempotencyClientID(fixture),
                op: "start",
                args: args,
                value: .object([
                    "session_id": .string(fixture.worker.sessionID.uuidString),
                    "standard_receipt": .bool(true)
                ])
            )
            var rootRun = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            rootRun.idempotencyRegistry = registry
            var otherRootRun = makeKnowledgeStartService(fixture, source: knowledge.otherRoot, probe: probe)
            otherRootRun.idempotencyRegistry = registry

            // Standard -> Knowledge: the standard outcome is never replayed; a fresh worker starts.
            let rootValue = try await rootRun.execute(args: args)
            XCTAssertNil(rootValue.objectValue?["_meta"]?.objectValue?["request_id_replay"])
            XCTAssertNil(rootValue.objectValue?["standard_receipt"])
            XCTAssertNotNil(rootValue.objectValue?["knowledge_worker"])
            XCTAssertEqual(probe.starts.count, 1)

            // Cross-root: the identical request from another Knowledge root starts its own worker.
            let otherValue = try await otherRootRun.execute(args: args)
            XCTAssertNil(otherValue.objectValue?["_meta"]?.objectValue?["request_id_replay"])
            XCTAssertNotNil(otherValue.objectValue?["knowledge_worker"])
            XCTAssertEqual(probe.starts.count, 2)
            let rootWorkerID = try XCTUnwrap(probe.starts.first?.targetSessionID)
            let otherWorkerID = try XCTUnwrap(probe.starts.last?.targetSessionID)
            XCTAssertNotEqual(rootWorkerID, otherWorkerID)
            XCTAssertEqual(probe.starts.first?.targetParentSessionID, knowledge.root.sessionID)
            XCTAssertEqual(probe.starts.last?.targetParentSessionID, knowledge.otherRoot.sessionID)

            // Same caller: the retry replays the root's own outcome without a second worker.
            let replay = try await rootRun.execute(args: args)
            XCTAssertEqual(replay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true))
            XCTAssertEqual(strippingMeta(replay), strippingMeta(rootValue))
            XCTAssertEqual(probe.starts.count, 2)

            // Each root's outcome lives in its own namespace beside the untouched shared entry.
            let entryCount = await registry.test_entryCount()
            XCTAssertEqual(entryCount, 3)
            for root in [knowledge.root, knowledge.otherRoot] {
                let key = try knowledgeIdempotencyKey(fixture, caller: root, requestID: "shared-research-request")
                let hasEntry = await registry.test_hasEntry(key: key)
                XCTAssertTrue(hasEntry)
            }
        }
    }

    func testKnowledgeRequestIDReplayAuthorizesTheAdmittedCallerFirst() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            let registry = MCPRequestIdempotencyRegistry()
            let probe = KnowledgeStartProbe()
            let hooks = CallerHookProbe()
            var run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe, hooks: hooks)
            run.idempotencyRegistry = registry
            var args = knowledgeStartArgs(modelID: "claudeCode:sonnet")
            args["request_id"] = .string("authorized-retry")
            let first = try await run.execute(args: args)
            XCTAssertEqual(probe.starts.count, 1)

            // The admitted root is replaced after outer admission, before the request_id lookup: the
            // recorded outcome is not replayed to the stale request.
            hooks.reset()
            hooks.onMetadataCapture[2] = {
                knowledge.root.session.testInstallPersistentSessionBinding(sessionID: UUID())
            }
            await assertInvalidParams(contains: "changed while the request was in flight", label: "rebind before replay") {
                _ = try await run.execute(args: args)
            }
            XCTAssertEqual(hooks.metadataCaptures, 2)
            knowledge.root.session.testInstallPersistentSessionBinding(sessionID: knowledge.root.sessionID)

            hooks.reset()
            hooks.onMetadataCapture[2] = {
                XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.standard))
            }
            await assertInvalidParams(contains: "is no longer a verified knowledge session", label: "downgrade before replay") {
                _ = try await run.execute(args: args)
            }
            XCTAssertEqual(hooks.metadataCaptures, 2)
            XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.knowledge))

            // Authorized again, the same caller's retry replays its own outcome.
            hooks.reset()
            let replay = try await run.execute(args: args)
            XCTAssertEqual(replay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true))
            XCTAssertEqual(strippingMeta(replay), strippingMeta(first))
            XCTAssertEqual(probe.starts.count, 1)

            // A control request_id is authorized against the own-worker rule before the caller's
            // namespace is consulted: a recorded respond to a foreign session is never replayed.
            var respondArgs = controlArgs("respond", fixture.main.sessionID)
            respondArgs["request_id"] = .string("foreign-respond")
            let rootKey = try knowledgeIdempotencyKey(fixture, caller: knowledge.root, requestID: "foreign-respond")
            try await seedRecordedOutcome(
                registry,
                clientID: rootKey.clientID,
                op: "respond",
                args: respondArgs,
                value: .object(["recorded": .bool(true)])
            )
            await assertInvalidParams(contains: "may only target its own Knowledge research workers", label: "foreign respond replay") {
                _ = try await run.execute(args: respondArgs)
            }
        }
    }

    func testStandardAndExternalRequestIDReplayKeepsSharedClientNamespace() async throws {
        try await withFixture { fixture in
            let registry = MCPRequestIdempotencyRegistry()
            let sharedClientID = try sharedIdempotencyClientID(fixture)
            XCTAssertEqual(
                AgentRunMCPToolService.idempotencyClientID(sharedClientID, knowledgeCaller: nil),
                sharedClientID
            )
            var args = controlArgs("respond", fixture.worker.sessionID)
            args["request_id"] = .string("standard-respond")
            try await seedRecordedOutcome(
                registry,
                clientID: sharedClientID,
                op: "respond",
                args: args,
                value: .object(["recorded": .bool(true)])
            )
            let callers: [(label: String, sourceTabID: UUID?)] = [
                ("standard main", fixture.main.tabID),
                ("external", nil)
            ]
            for caller in callers {
                var run = makeRunService(fixture, sourceTabID: caller.sourceTabID)
                run.idempotencyRegistry = registry
                let replay = try await run.execute(args: args)
                XCTAssertEqual(replay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true), caller.label)
                XCTAssertEqual(replay.objectValue?["recorded"], .bool(true), caller.label)
            }
        }
    }

    func testKnowledgeRequestIDReplayRevalidatesTheCallerAfterTheRegistryLookup() async throws {
        try await withFixture { fixture in
            let knowledge = try await makeKnowledgeTree(fixture)
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            let registry = MCPRequestIdempotencyRegistry()
            let probe = KnowledgeStartProbe()
            let lookup = LookupSuspensionProbe()
            var run = makeKnowledgeStartService(fixture, source: knowledge.root, probe: probe)
            run.idempotencyRegistry = registry
            run.testDuringIdempotencyLookup = {
                lookup.suspend()
            }
            var startArgs = knowledgeStartArgs(modelID: "claudeCode:sonnet")
            startArgs["request_id"] = .string("suspended-start")
            let first = try await run.execute(args: startArgs)
            XCTAssertEqual(probe.starts.count, 1)
            XCTAssertEqual(lookup.count, 1)

            // The caller passes the pre-lookup authorization, then is replaced or downgraded while the
            // registry lookup is suspended: the recorded outcome is never disclosed.
            lookup.reset {
                knowledge.root.session.testInstallPersistentSessionBinding(sessionID: UUID())
            }
            await assertInvalidParams(contains: "changed while the request was in flight", label: "rebind during lookup") {
                _ = try await run.execute(args: startArgs)
            }
            XCTAssertEqual(lookup.count, 1, "The caller was replaced at the lookup, after authorization")
            knowledge.root.session.testInstallPersistentSessionBinding(sessionID: knowledge.root.sessionID)

            lookup.reset {
                XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.standard))
            }
            await assertInvalidParams(contains: "is no longer a verified knowledge session", label: "downgrade during lookup") {
                _ = try await run.execute(args: startArgs)
            }
            XCTAssertEqual(lookup.count, 1, "The caller was downgraded at the lookup, after authorization")
            XCTAssertTrue(knowledge.root.session.adoptSessionProfile(.knowledge))

            // An in-flight marker or a conflict for the request_id is not disclosed to a stale caller.
            let rootClientID = try knowledgeIdempotencyKey(fixture, caller: knowledge.root, requestID: "unused").clientID
            var inFlightArgs = knowledgeStartArgs(modelID: "claudeCode:sonnet")
            inFlightArgs["request_id"] = .string("in-flight-start")
            guard case .new = await registry.begin(
                key: MCPRequestIdempotencyRegistry.Key(clientID: rootClientID, requestID: "in-flight-start"),
                fingerprint: idempotencyFingerprint(op: "start", args: inFlightArgs)
            ) else {
                return XCTFail("The in-flight request_id must be new")
            }
            var conflictArgs = startArgs
            conflictArgs["message"] = .string("A different research question.")
            let undisclosed: [(label: String, args: [String: Value])] = [
                ("in-flight", inFlightArgs),
                ("conflict", conflictArgs)
            ]
            for call in undisclosed {
                lookup.reset {
                    knowledge.root.session.testInstallPersistentSessionBinding(sessionID: UUID())
                }
                await assertInvalidParams(contains: "changed while the request was in flight", label: "\(call.label) during lookup") {
                    _ = try await run.execute(args: call.args)
                }
                XCTAssertEqual(lookup.count, 1, call.label)
                knowledge.root.session.testInstallPersistentSessionBinding(sessionID: knowledge.root.sessionID)
            }

            // The own-child target is re-checked too: the root's worker moves under another root
            // while a recorded respond is being looked up.
            var respondArgs = controlArgs("respond", knowledge.worker.sessionID)
            respondArgs["request_id"] = .string("suspended-respond")
            try await seedRecordedOutcome(
                registry,
                clientID: rootClientID,
                op: "respond",
                args: respondArgs,
                value: .object(["recorded": .bool(true)])
            )
            lookup.reset {
                knowledge.worker.session.parentSessionID = knowledge.otherRoot.sessionID
            }
            await assertInvalidParams(contains: "may only target its own Knowledge research workers", label: "retargeted worker during lookup") {
                _ = try await run.execute(args: respondArgs)
            }
            XCTAssertEqual(lookup.count, 1)
            knowledge.worker.session.parentSessionID = knowledge.root.sessionID

            // Unchanged, the same caller's retries replay their recorded outcomes.
            lookup.reset {}
            let replay = try await run.execute(args: startArgs)
            XCTAssertEqual(replay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true))
            XCTAssertEqual(strippingMeta(replay), strippingMeta(first))
            let respondReplay = try await run.execute(args: respondArgs)
            XCTAssertEqual(respondReplay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true))
            XCTAssertEqual(respondReplay.objectValue?["recorded"], .bool(true))
            XCTAssertEqual(probe.starts.count, 1, "No retry started a second worker")
        }
    }

    func testStandardRespondRevalidatesTheFrozenCallerAtDispatch() async throws {
        try await withFixture { fixture in
            let hooks = CallerHookProbe()
            let run = makeRunService(fixture, sourceTabID: fixture.worker.tabID, hooks: hooks)
            let respond = controlArgs("respond", fixture.subWorker.sessionID)
            let delegationFailures = ["changed while the request was in flight", "may only target sessions deeper"]

            // Unchanged, a standard worker's respond to its own sub-worker passes admission and the
            // dispatch recheck and reaches interaction resolution (which has nothing pending).
            do {
                _ = try await run.execute(args: respond)
            } catch {
                for failure in delegationFailures {
                    XCTAssertFalse(String(describing: error).contains(failure), String(describing: error))
                }
            }
            XCTAssertGreaterThanOrEqual(hooks.metadataCaptures, 3, "The respond reached its dispatch-boundary await")

            // The worker's tab is rebound to another identity during the await after control
            // admission: the stale respond never reaches interaction resolution.
            hooks.reset()
            hooks.onMetadataCapture[3] = {
                fixture.worker.session.testInstallPersistentSessionBinding(sessionID: UUID())
            }
            await assertInvalidParams(contains: "changed while the request was in flight", label: "standard respond rebind") {
                _ = try await run.execute(args: respond)
            }
            XCTAssertEqual(hooks.metadataCaptures, 3)
            fixture.worker.session.testInstallPersistentSessionBinding(sessionID: fixture.worker.sessionID)

            // The target leaves the caller's ceiling during the same await.
            hooks.reset()
            hooks.onMetadataCapture[3] = {
                fixture.subWorker.session.parentSessionID = fixture.main.sessionID
            }
            await assertInvalidParams(contains: "may only target sessions deeper", label: "standard respond retargeted") {
                _ = try await run.execute(args: respond)
            }
            XCTAssertEqual(hooks.metadataCaptures, 3)
            fixture.subWorker.session.parentSessionID = fixture.worker.sessionID

            // External callers have no routed source and keep their existing respond behavior.
            let external = makeRunService(fixture, sourceTabID: nil)
            do {
                _ = try await external.execute(args: controlArgs("respond", fixture.main.sessionID))
            } catch {
                for failure in delegationFailures {
                    XCTAssertFalse(String(describing: error).contains(failure), String(describing: error))
                }
            }
        }
    }

    // MARK: - Fixture

    /// Runs one installed action each time the service reaches its `request_id` lookup suspension.
    @MainActor
    private final class LookupSuspensionProbe {
        private(set) var count = 0
        private var action: @MainActor () -> Void = {}

        func reset(_ action: @escaping @MainActor () -> Void) {
            count = 0
            self.action = action
        }

        func suspend() {
            count += 1
            action()
        }
    }

    /// Counts the service's metadata captures and source resolutions for one call, and runs a hook on
    /// a chosen call. Call 1 of each is outer Knowledge admission; later calls are the operation's own.
    @MainActor
    private final class CallerHookProbe {
        private(set) var metadataCaptures = 0
        private(set) var sourceResolutions = 0
        var onMetadataCapture: [Int: @MainActor () -> Void] = [:]
        var onSourceResolution: [Int: @MainActor () -> Void] = [:]

        func reset() {
            metadataCaptures = 0
            sourceResolutions = 0
            onMetadataCapture = [:]
            onSourceResolution = [:]
        }

        func recordMetadataCapture() {
            metadataCaptures += 1
            onMetadataCapture[metadataCaptures]?()
        }

        func recordSourceResolution() {
            sourceResolutions += 1
            onSourceResolution[sourceResolutions]?()
        }
    }

    @MainActor
    private final class AdoptionProbe {
        var didAdopt = false
    }

    @MainActor
    private final class DispatchProbe {
        var count = 0
    }

    /// Provider dispatches reached through the production starter or a steer, with the target's state
    /// then: control, edit approval, permissions, and the run lease and prompt built for it.
    @MainActor
    private final class KnowledgeDispatchProbe {
        struct Record {
            let sessionID: UUID
            let profile: AgentSessionProfile?
            let parentSessionID: UUID?
            let hasControlContext: Bool
            let forceAutoEditEnabled: Bool?
            let autoEditEnabled: Bool?
            let approvalStoreAutoEditEnabled: Bool
            let permissionProfile: AgentModeViewModel.AgentPermissionProfile?
            let runToolPolicy: AgentDelegationPolicy.RunToolPolicy?
            let leaseSpec: MCPBootstrapLeaseSpec?
            let systemPrompt: String?
        }

        var records: [Record] = []
    }

    @MainActor
    private final class KnowledgeStartProbe {
        struct Start {
            let agentRaw: String?
            let modelRaw: String?
            let reasoningEffortRaw: String?
            let taskLabelKind: AgentModelCatalog.TaskLabelKind?
            let workflowWasNil: Bool
            let expectedParentSessionID: UUID?
            let targetSessionID: UUID?
            let targetProfile: AgentSessionProfile?
            let targetParentSessionID: UUID?
        }

        struct Adoption {
            let sessionID: UUID?
            let profile: AgentSessionProfile
            let parentSessionID: UUID?
            let hasControlContext: Bool
        }

        var starts: [Start] = []
        var adoptions: [Adoption] = []
    }

    private struct KnowledgeTree {
        let root: Node
        let worker: Node
        let otherRoot: Node
        let otherRootWorker: Node
    }

    private struct Node {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentTabSession
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let main: Node
        let worker: Node
        let sibling: Node
        let subWorker: Node
        let otherRoot: Node
        let otherRootChild: Node
        let loneRoot: Node
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDelegationServiceBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()
        do {
            try await runFixture(window: window, rootURL: rootURL, body)
        } catch {
            await teardown(window: window, rootURL: rootURL)
            throw error
        }
        await teardown(window: window, rootURL: rootURL)
    }

    private func teardown(window: WindowState, rootURL: URL) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func runFixture(
        window: WindowState,
        rootURL: URL,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let workspace = window.workspaceManager.createWorkspace(
            name: "Delegation Boundary \(UUID().uuidString.prefix(8))",
            repoPaths: [rootURL.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "agentDelegationServiceBoundaryTests")

        let names = ["Main", "Worker", "Sibling", "SubWorker", "OtherRoot", "OtherRootChild", "LoneRoot"]
        let ids = names.map { _ in (tabID: UUID(), sessionID: UUID()) }
        let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))
        window.workspaceManager.workspaces[workspaceIndex].composeTabs = zip(names, ids).map { name, id in
            ComposeTabState(id: id.tabID, name: name, activeAgentSessionID: id.sessionID)
        }
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = ids[0].tabID
        window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true)

        let viewModel = window.agentModeViewModel
        func node(_ index: Int, parent: Node?, role: AgentModelCatalog.TaskLabelKind?) throws -> Node {
            let id = ids[index]
            let session = try XCTUnwrap(viewModel.session(for: id.tabID, createIfNeeded: true))
            XCTAssertEqual(session.activeAgentSessionID, id.sessionID)
            session.hasLoadedPersistedState = true
            session.parentSessionID = parent?.sessionID
            if parent != nil {
                session.mcpControlContext = controlContext(sessionID: id.sessionID, role: role)
            }
            return Node(tabID: id.tabID, sessionID: id.sessionID, session: session)
        }
        let main = try node(0, parent: nil, role: nil)
        let worker = try node(1, parent: main, role: .engineer)
        let sibling = try node(2, parent: main, role: .engineer)
        let subWorker = try node(3, parent: worker, role: .engineer)
        let otherRoot = try node(4, parent: nil, role: nil)
        let otherRootChild = try node(5, parent: otherRoot, role: .engineer)
        let loneRoot = try node(6, parent: nil, role: nil)
        viewModel.setAgentModeActive(true)

        XCTAssertEqual(viewModel.mcpDelegationLineage(for: worker.session), .resolved(depth: 1))
        XCTAssertEqual(viewModel.mcpDelegationLineage(for: subWorker.session), .resolved(depth: 2))

        try await body(Fixture(
            window: window,
            rootURL: rootURL,
            viewModel: viewModel,
            main: main,
            worker: worker,
            sibling: sibling,
            subWorker: subWorker,
            otherRoot: otherRoot,
            otherRootChild: otherRootChild,
            loneRoot: loneRoot
        ))
    }

    private func controlContext(sessionID: UUID, role: AgentModelCatalog.TaskLabelKind?) -> AgentMCPControlContext {
        AgentMCPControlContext(
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
            taskLabelKind: role
        )
    }

    private func metadata(_ window: WindowState, toolInvocationID: UUID? = nil) -> MCPServerViewModel.RequestMetadata {
        MCPServerViewModel.RequestMetadata(
            connectionID: nil,
            clientName: "agent-delegation-boundary-tests",
            windowID: window.windowID,
            toolInvocationID: toolInvocationID,
            actorRoutedRunTab: nil
        )
    }

    private func makeManageService(
        _ fixture: Fixture,
        sourceTabID: UUID?,
        parentSessionID: @escaping () -> UUID?
    ) -> AgentManageMCPToolService {
        let window = fixture.window
        return AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { self.metadata(window) },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in parentSessionID() },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }

    private func makeRunService(
        _ fixture: Fixture,
        sourceTabID: UUID?,
        hooks: CallerHookProbe? = nil,
        beforeHeartbeatOperation: (@MainActor @Sendable () -> Void)? = nil
    ) -> AgentRunMCPToolService {
        let window = fixture.window
        return AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                hooks?.recordMetadataCapture()
                return self.metadata(window)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in
                hooks?.recordSourceResolution()
                return sourceTabID
            },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in
                if let beforeHeartbeatOperation {
                    await MainActor.run { beforeHeartbeatOperation() }
                }
                return try await operation()
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun is not used by delegation boundary tests")
            }
        )
    }

    private nonisolated static func runningSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: nil,
            tabID: nil,
            sessionName: "Running Root",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .running,
            statusText: "running",
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            lastInteractionResolution: nil
        )
    }

    private func controlArgs(_ op: String, _ sessionID: UUID) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string(op),
            "session_id": .string(sessionID.uuidString)
        ]
        if op == "respond" {
            args["interaction_id"] = .string(UUID().uuidString)
            args["answer"] = .string("yes")
        }
        return args
    }

    private func makeExtraSession(_ fixture: Fixture) async throws -> AgentTabSession {
        await fixture.window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await fixture.viewModel.ensureSessionReady(tabID: tabID)
    }

    /// A Knowledge root with one worker, and an unrelated Knowledge root with its own worker, beside
    /// the standard fixture tree. Profiles are adopted while each record is still a placeholder.
    private func makeKnowledgeTree(_ fixture: Fixture) async throws -> KnowledgeTree {
        func knowledgeNode(parent: Node?) async throws -> Node {
            let session = try await makeExtraSession(fixture)
            let sessionID = UUID()
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            session.hasLoadedPersistedState = true
            XCTAssertTrue(session.adoptSessionProfile(.knowledge))
            session.parentSessionID = parent?.sessionID
            if parent != nil {
                session.mcpControlContext = controlContext(sessionID: sessionID, role: nil)
            }
            return Node(tabID: session.tabID, sessionID: sessionID, session: session)
        }
        let root = try await knowledgeNode(parent: nil)
        let worker = try await knowledgeNode(parent: root)
        let otherRoot = try await knowledgeNode(parent: nil)
        let otherRootWorker = try await knowledgeNode(parent: otherRoot)
        XCTAssertEqual(fixture.viewModel.mcpDelegationDecision(for: root.session), .eligible(depth: 0))
        XCTAssertEqual(fixture.viewModel.mcpDelegationDecision(for: worker.session), .knowledgeLeaf(depth: 1))
        return KnowledgeTree(root: root, worker: worker, otherRoot: otherRoot, otherRootWorker: otherRootWorker)
    }

    private func knowledgeStartArgs(modelID: String? = nil) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string("start"),
            "message": .string("Research one perspective and report back."),
            "detach": .bool(true)
        ]
        if let modelID {
            args["model_id"] = .string(modelID)
        }
        return args
    }

    /// Routed start service for a Knowledge source session: it resolves the real spawn parent and
    /// frozen launch source, enables Codex search unless a test overrides it, and records every
    /// provider start (with the created target's profile and parent) instead of launching one.
    private func makeKnowledgeStartService(
        _ fixture: Fixture,
        source: Node,
        probe: KnowledgeStartProbe,
        hooks: CallerHookProbe? = nil,
        beforeLaunchSourceResolved: (@MainActor () -> Void)? = nil,
        startRun: AgentRunMCPToolService.StartRun? = nil,
        toolInvocationID: UUID? = nil
    ) -> AgentRunMCPToolService {
        let window = fixture.window
        let recordingStartRun: AgentRunMCPToolService.StartRun = { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, _, workflow, expectedParentSessionID, _ in
            let targetSession = agentModeVM.session(for: target.tabID, createIfNeeded: false)
            probe.starts.append(.init(
                agentRaw: agentRaw,
                modelRaw: modelRaw,
                reasoningEffortRaw: reasoningEffortRaw,
                taskLabelKind: taskLabelKind,
                workflowWasNil: workflow == nil,
                expectedParentSessionID: expectedParentSessionID,
                targetSessionID: target.sessionID,
                targetProfile: targetSession?.profile,
                targetParentSessionID: targetSession?.parentSessionID
            ))
            guard let sessionID = target.sessionID else {
                throw MCPError.internalError("Knowledge start target did not resolve a session ID.")
            }
            return AgentExternalMCPRunStarter.StartOutcome(
                snapshot: Self.knowledgeWorkerSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    parentSessionID: targetSession?.parentSessionID,
                    agentRaw: agentRaw,
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw
                ),
                delivery: .startedRun
            )
        }
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                hooks?.recordMetadataCapture()
                return self.metadata(window, toolInvocationID: toolInvocationID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in
                hooks?.recordSourceResolution()
                return source.tabID
            },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: startRun ?? recordingStartRun
        )
        service.resolveSpawnParentSessionIDFromSourceTabID = { (sourceTabID: UUID, window: WindowState) async -> UUID? in
            window.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
        }
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            beforeLaunchSourceResolved?()
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .runScoped,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: source.tabID,
                selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: source.tabID
                ),
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: source.sessionID,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: source.tabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: source.sessionID,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Synthetic Knowledge start fixture")
                ))
            )
        }
        service.codexWebSearchEnabled = { true }
        return service
    }

    /// `agent_run.start`'s production start seam (as wired by `MCPServerViewModel`): the real
    /// `AgentExternalMCPRunStarter` activates MCP control, configures, and binds the target; only the
    /// provider dispatch is recorded instead of launching a provider.
    private func productionStartRun(recordingInto dispatches: KnowledgeDispatchProbe) -> AgentRunMCPToolService.StartRun {
        { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, roleOhMyPiThinkingSelections, workflow, expectedParentSessionID, oracleReviewSource in
            try await AgentExternalMCPRunStarter.start(
                target: target,
                message: message,
                metadata: metadata,
                bindCurrentRequestToTab: bindCurrentRequestToTab,
                agentModeVM: agentModeVM,
                agentRaw: agentRaw,
                modelRaw: modelRaw,
                reasoningEffortRaw: reasoningEffortRaw,
                taskLabelKind: taskLabelKind,
                roleOhMyPiThinkingSelections: roleOhMyPiThinkingSelections,
                workflow: workflow,
                expectedParentSessionID: expectedParentSessionID,
                oracleReviewSource: oracleReviewSource,
                dispatchInstruction: { sessionID, tabID, _, _, host in
                    await dispatches.records.append(self.knowledgeDispatchRecord(sessionID: sessionID, tabID: tabID, host: host))
                    return .startedRun
                }
            )
        }
    }

    /// The dispatch target's state as the run would see it. The lease spec and prompt come from the
    /// production builders (`MCPBootstrapLeaseSpec.agentMode`, `SystemPromptService.agentModePrompt`)
    /// fed with the view model's own delegation run-tool policy, as the run service and coordinators do.
    private func knowledgeDispatchRecord(
        sessionID: UUID,
        tabID: UUID,
        host: AgentModeViewModel
    ) async -> KnowledgeDispatchProbe.Record {
        let session = host.session(for: tabID, createIfNeeded: false)
        let scope = host.applyEditsScope(for: tabID)
        let runToolPolicy = session.map { host.mcpDelegationRunToolPolicy(for: $0) }
        let leaseSpec = session.flatMap { session in
            runToolPolicy.map { policy in
                MCPBootstrapLeaseSpec.agentMode(
                    tabID: tabID,
                    runID: UUID(),
                    gateID: UUID(),
                    windowID: scope.windowID,
                    agent: session.selectedAgent,
                    sessionProfile: session.profile,
                    taskLabelKind: session.mcpControlContext?.taskLabelKind,
                    allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools,
                    additionalRestrictedTools: policy.additionalRestrictedTools
                )
            }
        }
        let systemPrompt = session.flatMap { session in
            runToolPolicy.map { policy in
                SystemPromptService.agentModePrompt(
                    agentKind: session.selectedAgent,
                    taskLabelKind: session.mcpControlContext?.taskLabelKind,
                    sessionProfile: session.profile,
                    delegationAudience: policy.promptAudience
                )
            }
        }
        return await KnowledgeDispatchProbe.Record(
            sessionID: sessionID,
            profile: session?.profile,
            parentSessionID: session?.parentSessionID,
            hasControlContext: session?.mcpControlContext?.sessionID == sessionID,
            forceAutoEditEnabled: session?.mcpControlContext?.forceAutoEditEnabled,
            autoEditEnabled: session?.autoEditEnabled,
            approvalStoreAutoEditEnabled: host.applyEditsApprovalStore.autoEditEnabled(for: scope),
            permissionProfile: session?.permissionProfile,
            runToolPolicy: runToolPolicy,
            leaseSpec: leaseSpec,
            systemPrompt: systemPrompt
        )
    }

    /// A dispatched Knowledge research worker: MCP-controlled without forced auto-edit, so the
    /// session and approval store keep its own edit-approval setting; on the global sub-agent
    /// permission profile; and a delegation leaf in both its run lease and its prompt.
    private func assertKnowledgeWorkerDispatch(
        _ record: KnowledgeDispatchProbe.Record,
        autoEdit: Bool,
        permissionProfile: AgentModeViewModel.AgentPermissionProfile,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(record.profile, .knowledge, label, file: file, line: line)
        XCTAssertTrue(record.hasControlContext, "\(label): MCP control is active at dispatch", file: file, line: line)
        XCTAssertEqual(record.forceAutoEditEnabled, false, label, file: file, line: line)
        XCTAssertEqual(record.autoEditEnabled, autoEdit, label, file: file, line: line)
        XCTAssertEqual(record.approvalStoreAutoEditEnabled, autoEdit, label, file: file, line: line)
        XCTAssertEqual(record.permissionProfile, permissionProfile, label, file: file, line: line)
        XCTAssertEqual(record.runToolPolicy, .leaf, label, file: file, line: line)
        guard let lease = record.leaseSpec, let prompt = record.systemPrompt else {
            return XCTFail("\(label): no lease or prompt was built", file: file, line: line)
        }
        XCTAssertEqual(lease.sessionProfile, .knowledge, label, file: file, line: line)
        XCTAssertEqual(lease.allowedToolsOverride, AgentModeMCPToolPolicy.knowledgeAllowedTools, label, file: file, line: line)
        XCTAssertTrue(
            AgentDelegationPolicy.delegationToolNames.isSubset(of: lease.restrictedTools),
            "\(label): the lease restricts every delegation tool",
            file: file,
            line: line
        )
        XCTAssertFalse(lease.allowsAgentExternalControlTools, label, file: file, line: line)
        XCTAssertTrue(prompt.contains(AgentModePrompts.Fragments.knowledgeResearchWorkerGuidance), label, file: file, line: line)
        XCTAssertFalse(prompt.contains(AgentModePrompts.Fragments.knowledgeResearchRootGuidance), label, file: file, line: line)
    }

    private func assertEditApproval(
        of session: AgentTabSession,
        is autoEdit: Bool,
        in vm: AgentModeViewModel,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertEqual(session.autoEditEnabled, autoEdit, "\(label): session", file: file, line: line)
        let stored = await vm.applyEditsApprovalStore.autoEditEnabled(for: vm.applyEditsScope(for: session.tabID))
        XCTAssertEqual(stored, autoEdit, "\(label): approval store", file: file, line: line)
    }

    private func steerArgs(_ sessionID: UUID, wait: Bool = false) -> [String: Value] {
        [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("Follow up on the strongest source."),
            "wait": .bool(wait)
        ]
    }

    private nonisolated static func knowledgeWorkerSnapshot(
        sessionID: UUID,
        tabID: UUID,
        parentSessionID: UUID?,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: nil,
            tabID: tabID,
            sessionName: "Knowledge Worker",
            agentRaw: agentRaw,
            agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
            modelRaw: modelRaw,
            reasoningEffortRaw: reasoningEffortRaw,
            status: .running,
            statusText: "running",
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: parentSessionID,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            lastInteractionResolution: nil
        )
    }

    /// Composes a real temporary recovery store into the fixture's view model (mandatory admission,
    /// as production composition does) and claims `root`'s lane through its first VM save.
    private func installRecoveryAndClaimLane(
        _ fixture: Fixture,
        root: Node
    ) async throws -> (lane: AgentRecoverySessionLane, workspace: WorkspaceModel) {
        let storageURL = fixture.rootURL.appendingPathComponent("RecoveryWorkspace", isDirectory: true)
        let recoveryRoot = fixture.rootURL.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let store = AgentRecoveryStore(rootURL: recoveryRoot)
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
        let startup = await coordinator.awaitStartup()
        XCTAssertEqual(startup, .ready)
        let workspace = WorkspaceModel(
            name: "Delegation Boundary Recovery",
            repoPaths: [fixture.rootURL.path],
            customStoragePath: storageURL
        )
        fixture.viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
        // Session persistence goes to this temporary workspace (never the window's own storage).
        fixture.viewModel.test_setActiveWorkspaceIDForSessionIndex(workspace.id)
        fixture.viewModel.test_establishPersistenceWorkspace(workspace)
        // The fixture marks every node loaded without captured persistence ownership; the root's
        // first save here is its genuine initial creation instead (then it is loaded again).
        root.session.hasLoadedPersistedState = false
        root.session.appendItem(.user("Earlier turn"))
        let outcome = await fixture.viewModel.flushSaveDetailed(for: root.tabID)
        root.session.hasLoadedPersistedState = true
        XCTAssertTrue(outcome.isCleanSuccess, "The root's first save: \(outcome)")
        let lane = try XCTUnwrap(root.session.recoveryLane, "The first save claims the root's lane")
        return (lane, workspace)
    }

    @MainActor
    private final class DelegatedChildStartObservation {
        var starts = 0
        var childSessionID: UUID?
        var persistedParentSessionID: UUID?
        var links: [AgentRecoveryDelegatedChildLink] = []
        var fence: MCPDelegatedChildLinkAdmission?
        var fenceArmedForChild = false
    }

    private func composeTabIDs(_ fixture: Fixture) -> Set<UUID> {
        Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
    }

    /// Client namespace every caller in this fixture shares (same client name, no connection ID).
    private func sharedIdempotencyClientID(_ fixture: Fixture) throws -> String {
        try XCTUnwrap(MCPClientIdentity.storageKey(metadata(fixture.window).clientName))
    }

    private func knowledgeIdempotencyKey(
        _ fixture: Fixture,
        caller: Node,
        requestID: String
    ) throws -> MCPRequestIdempotencyRegistry.Key {
        try MCPRequestIdempotencyRegistry.Key(
            clientID: AgentRunMCPToolService.idempotencyClientID(
                sharedIdempotencyClientID(fixture),
                knowledgeCaller: AgentRunMCPToolService.KnowledgeCaller(
                    sourceTabID: caller.tabID,
                    admittedCallerSessionID: caller.sessionID
                )
            ),
            requestID: requestID
        )
    }

    /// Records a completed mutation for `args` (keyed by its `request_id`) exactly as the service would.
    private func seedRecordedOutcome(
        _ registry: MCPRequestIdempotencyRegistry,
        clientID: String,
        op: String,
        args: [String: Value],
        value: Value
    ) async throws {
        let requestID = try XCTUnwrap(args["request_id"]?.stringValue)
        let key = MCPRequestIdempotencyRegistry.Key(clientID: clientID, requestID: requestID)
        guard case .new = await registry.begin(key: key, fingerprint: idempotencyFingerprint(op: op, args: args)) else {
            return XCTFail("The seeded request_id must be new")
        }
        await registry.complete(key: key, outcome: .success(value))
    }

    /// The fingerprint the service records for `args` under `op`.
    private func idempotencyFingerprint(op: String, args: [String: Value]) -> MCPRequestIdempotencyRegistry.Fingerprint {
        MCPRequestIdempotencyRegistry.Fingerprint(
            operation: op,
            payloadHashSHA256: MCPRequestIdempotencyRegistry.payloadHashHex(
                args: args,
                excluding: ["request_id", "response_mode"]
            )
        )
    }

    private func strippingMeta(_ value: Value) -> Value {
        guard var object = value.objectValue else { return value }
        object.removeValue(forKey: "_meta")
        return .object(object)
    }

    private func assertInvalidParams(
        contains expected: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(label): expected an error containing \"\(expected)\"", file: file, line: line)
        } catch {
            XCTAssertTrue(String(describing: error).contains(expected), "\(label): \(error)", file: file, line: line)
        }
    }
}
