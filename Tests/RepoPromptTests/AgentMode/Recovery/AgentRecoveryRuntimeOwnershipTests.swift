import Darwin
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Spec R6 integration of the runtime-ownership registry into recovery: startup adoption, send
/// admission, automatic-work (scheduler) gating by session and worktree, catalog items, Refresh /
/// Let finish, exit-driven clearing, and the global uncertainty warning. The registry runs over the
/// coordinator's temporary recovery store with scripted process boundaries; nothing inspects,
/// watches or signals a real process.
@MainActor
final class AgentRecoveryRuntimeOwnershipTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    private var root: URL!
    private var recoveryRoot: URL!
    private var processes: ScriptedProcessSystem!
    private var registry: AgentProcessRegistry?
    private var keysBySession: [UUID: [AgentRuntimeOwnershipKeys]] = [:]

    override func setUp() async throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryRuntimeOwnershipTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        processes = ScriptedProcessSystem()
        keysBySession = [:]
    }

    override func tearDown() async throws {
        await registry?.disposeWatches()
        registry = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Fixtures

    private func startedCoordinator(
        qualification: AgentRuntimeQualification = AgentRecoveryActivation.off.runtime,
        attachRegistry: Bool = true,
        reconciliation: AgentRecoveryStartupReconciliation = .empty
    ) async throws -> AgentRecoveryCoordinator {
        let store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in reconciliation },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        if attachRegistry {
            let registry = AgentProcessRegistry(store: store, qualification: qualification, system: processes.system)
            self.registry = registry
            coordinator.attachProcessRegistry(registry) { [weak self] sessionID in
                self?.keysBySession[sessionID] ?? []
            }
        }
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    /// A session bound to `conversationID` in `worktreePath`.
    private func session(conversationID: String?, worktreePath: String?) -> AgentRecoveryLifecycleBinding {
        let sessionID = UUID()
        keysBySession[sessionID] = [AgentRuntimeOwnershipKeys(conversationID: conversationID, worktreePath: worktreePath)]
        return AgentRecoveryLifecycleBinding(sessionID: sessionID, incarnationID: UUID(), transcriptResetGeneration: 0)
    }

    /// A previous instance's possible writer (root alive) on `conversationID` in `worktreePath`.
    @discardableResult
    private func seedWriter(pid: pid_t, conversationID: String, worktreePath: String) throws -> AgentRuntimeRecord {
        processes.add(processes.observation(pid: pid, group: pid))
        return try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: pid),
            rootGroup: pid,
            conversationIDs: [conversationID],
            worktreePaths: [worktreePath]
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func catalog(_ coordinator: AgentRecoveryCoordinator) -> AgentRecoveryCatalog {
        AgentRecoveryCatalogProjection.build(coordinator: coordinator, schedules: [], generation: 1)
    }

    // MARK: Tests

    func testExistingWriterRestrictsItsConversationWhileUnrelatedWorkContinues() async throws {
        let writer = try seedWriter(pid: 5000, conversationID: "conv-A", worktreePath: "/tmp/wt-a")
        let coordinator = try await startedCoordinator()
        let restricted = session(conversationID: "conv-A", worktreePath: "/tmp/elsewhere")
        let unrelated = session(conversationID: "conv-B", worktreePath: "/tmp/wt-b")
        let sameWorktree = session(conversationID: "conv-C", worktreePath: "/tmp/wt-a")

        XCTAssertTrue(coordinator.hasProcessRegistry)
        XCTAssertEqual(coordinator.runtimeRestrictions.restrictions.map(\.runtimeID), [writer.runtimeID])
        XCTAssertEqual(coordinator.runtimeRestrictions.restrictions.first?.state, .unknown, "registration is off, records are enforced")
        let refusal = await coordinator.admissionRefusal(for: restricted)
        guard case let .restricted(reason)? = refusal else {
            return XCTFail("Expected a runtime restriction, got \(String(describing: refusal))")
        }
        XCTAssertTrue(reason.contains("writing this conversation"), reason)
        let unrelatedRefusal = await coordinator.admissionRefusal(for: unrelated)
        XCTAssertNil(unrelatedRefusal, "unrelated conversations keep sending")
        let sameWorktreeRefusal = await coordinator.admissionRefusal(for: sameWorktree)
        XCTAssertNil(sameWorktreeRefusal, "an associated writer does not block other conversations' sends")

        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: restricted.sessionID))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: sameWorktree.sessionID), "the worktree is busy for automatic work")
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: unrelated.sessionID))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(worktreePath: "/tmp/wt-a"))
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(worktreePath: "/tmp/wt-b"))
        XCTAssertEqual(coordinator.runtimeSendRestriction(sessionID: restricted.sessionID)?.runtimeID, writer.runtimeID)

        let item = try XCTUnwrap(catalog(coordinator).item(id: AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: writer.runtimeID)))
        XCTAssertEqual(item.kind, .survivingProcess)
        XCTAssertNil(item.sessionID)
        XCTAssertNil(item.acknowledgement, "never dismissible")
        guard case let .survivingRuntime(restriction) = item.payload else {
            return XCTFail("Unexpected payload \(item.payload)")
        }
        XCTAssertEqual(restriction.conversationIDs, ["conv-A"])
    }

    func testToolsOnlySurvivorsBlockAutomaticWorkButNotSends() async throws {
        processes.add(processes.observation(pid: 5101, start: 200, parent: 1, executable: "/usr/bin/node", group: 5100))
        let survivor = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 5100),
            rootGroup: 5100,
            members: [AgentRuntimeMember(identity: processes.identity(pid: 5101, start: 200), processGroupID: 5100, role: .tool)],
            conversationIDs: ["conv-T"],
            worktreePaths: ["/tmp/wt-t"]
        )
        let coordinator = try await startedCoordinator(qualification: Fixtures.qualified())
        XCTAssertEqual(coordinator.runtimeRestrictions.restrictions.first?.kind, .toolsOnly)
        let own = session(conversationID: "conv-T", worktreePath: "/tmp/wt-t")
        let neighbour = session(conversationID: "conv-N", worktreePath: "/tmp/wt-t")
        let elsewhere = session(conversationID: "conv-E", worktreePath: "/tmp/wt-e")

        for binding in [own, neighbour, elsewhere] {
            let refusal = await coordinator.admissionRefusal(for: binding)
            XCTAssertNil(refusal, "tool-only survivors never block a send")
        }
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: own.sessionID))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: neighbour.sessionID))
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: elsewhere.sessionID))

        processes.processExited(pid: 5101)
        let cleared = await waitUntil { coordinator.runtimeRestrictions.restrictions.isEmpty }
        XCTAssertTrue(cleared, "the exit watch clears the survivor without polling")
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: own.sessionID))
        XCTAssertNil(catalog(coordinator).item(id: AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: survivor.runtimeID)))
    }

    func testRefreshAfterQualifiedExitLiftsTheRestriction() async throws {
        try seedWriter(pid: 5200, conversationID: "conv-R", worktreePath: "/tmp/wt-r")
        let coordinator = try await startedCoordinator(qualification: Fixtures.qualified())
        let binding = session(conversationID: "conv-R", worktreePath: "/tmp/wt-r")
        let refusal = await coordinator.admissionRefusal(for: binding)
        XCTAssertNotNil(refusal)

        processes.remove(pid: 5200) // Exits without a delivered watch event.
        await coordinator.refreshRuntimeOwnership()
        let cleared = await waitUntil { coordinator.runtimeRestrictions.restrictions.isEmpty }
        XCTAssertTrue(cleared)
        let afterRefresh = await coordinator.admissionRefusal(for: binding)
        XCTAssertNil(afterRefresh)
    }

    /// Refresh returns only once restrictions at least as new as its own snapshot are adopted, also
    /// when a second Refresh overlaps it; and an adoption never goes back to an older request's
    /// snapshot (an earlier request landing after a later one is ignored).
    func testRefreshAdoptsAtLeastItsOwnSnapshotBeforeReturningAndNeverGoesBackwards() async throws {
        try seedWriter(pid: 5700, conversationID: "conv-O", worktreePath: "/tmp/wt-o")
        let coordinator = try await startedCoordinator(qualification: Fixtures.qualified())
        let restricted = coordinator.runtimeRestrictions
        XCTAssertFalse(restricted.restrictions.isEmpty)
        processes.remove(pid: 5700) // Exits without a delivered watch event.
        let latch = RecoveryGateLatch()
        processes.inventoryHook = { await latch.pause() }
        let first = Task {
            await coordinator.refreshRuntimeOwnership()
            return coordinator.runtimeRestrictions.restrictions.isEmpty
        }
        await latch.waitUntilPaused()
        let second = Task {
            await coordinator.refreshRuntimeOwnership()
            return coordinator.runtimeRestrictions.restrictions.isEmpty
        }
        await latch.open()
        let firstSaw = await first.value
        let secondSaw = await second.value
        XCTAssertTrue(firstSaw, "the first Refresh returned with the exit adopted")
        XCTAssertTrue(secondSaw, "the overlapping Refresh returned with the exit adopted")

        let cleared = coordinator.runtimeRestrictions
        coordinator.adoptRuntimeRestrictions(restricted, request: coordinator.runtimeSnapshotAdopted)
        XCTAssertEqual(coordinator.runtimeRestrictions, cleared, "a request no newer than the adopted one is ignored")
        let later = coordinator.runtimeSnapshotRequest + 100
        coordinator.runtimeSnapshotRequest = later
        coordinator.adoptRuntimeRestrictions(restricted, request: later)
        XCTAssertEqual(coordinator.runtimeRestrictions, restricted, "the later request is adopted")
        coordinator.adoptRuntimeRestrictions(cleared, request: later - 1)
        XCTAssertEqual(coordinator.runtimeRestrictions, restricted, "an earlier request landing later never overwrites it")
    }

    /// Check and resolve with checks active shows the refreshing phase while its Refresh runs, then
    /// reports a captured survivor the adopted snapshot positively lacks as exited.
    func testCheckRefreshesOwnershipFirstAndReportsAProvenExit() async throws {
        let writer = try seedWriter(pid: 5800, conversationID: "conv-X", worktreePath: "/tmp/wt-x")
        let coordinator = try await startedCoordinator(qualification: Fixtures.qualified())
        let itemID = AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: writer.runtimeID)
        let captured = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        processes.remove(pid: 5800)
        let latch = RecoveryGateLatch()
        processes.inventoryHook = { await latch.pause() }
        let running = Task {
            await coordinator.checkCatalogItems([captured], checksActive: true) { _ in .notAttempted("never") }
        }
        await latch.waitUntilPaused()
        XCTAssertEqual(coordinator.recoveryCheck?.summaryText, "Refreshing process ownership…")
        await latch.open()
        let result = await running.value
        let status = try XCTUnwrap(result)
        XCTAssertEqual(status.entries.map(\.outcome), [.resolved("The process exited.")])
        XCTAssertEqual(status.summaryText, "Checked 1 of 1 · 1 resolved")
    }

    func testLetFinishPersistsAndKeepsTheRestriction() async throws {
        let writer = try seedWriter(pid: 5300, conversationID: "conv-L", worktreePath: "/tmp/wt-l")
        let coordinator = try await startedCoordinator()
        let binding = session(conversationID: "conv-L", worktreePath: "/tmp/wt-l")
        let revision = try XCTUnwrap(coordinator.runtimeRestrictions.restrictions.first?.revision)

        let failure = await coordinator.letRuntimeFinish(runtimeID: writer.runtimeID, expectedRevision: revision)
        XCTAssertNil(failure)
        let chosen = await waitUntil { coordinator.runtimeRestrictions.restrictions.first?.letFinish == true }
        XCTAssertTrue(chosen)
        let refusal = await coordinator.admissionRefusal(for: binding)
        XCTAssertNotNil(refusal, "Let finish keeps restricting until the family exits")

        let stale = await coordinator.letRuntimeFinish(runtimeID: writer.runtimeID, expectedRevision: revision)
        XCTAssertNotNil(stale, "a stale revision is refused")
    }

    func testUnidentifiableRecordsPauseOwnershipDependentWorkWithAGlobalWarning() async throws {
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("not-a-runtime.json"))
        let coordinator = try await startedCoordinator()
        let binding = session(conversationID: "conv-any", worktreePath: "/tmp/any")

        let refusal = await coordinator.admissionRefusal(for: binding)
        XCTAssertEqual(refusal, .restricted(AgentRecoveryCoordinator.runtimeGlobalUncertaintyReason))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: binding.sessionID))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(worktreePath: nil))
        let item = try XCTUnwrap(catalog(coordinator).item(id: AgentRecoveryCatalogProjection.runtimeOwnershipUnknownItemID))
        XCTAssertEqual(item.payload, .runtimeOwnershipUnknown(unidentifiedRecordCount: 1, failure: nil))
    }

    /// 9-live R7: app-scoped runtime items come before every session and workspace item (the sheet
    /// lists the live process first); their IDs don't change.
    func testRuntimeItemsPrecedeSessionItemsInTheCatalog() async throws {
        let writer = try seedWriter(pid: 5800, conversationID: "conv-O7", worktreePath: "/tmp/wt-o7")
        let coordinator = try await startedCoordinator()
        let sessionID = UUID()
        let workspaceID = UUID()
        let summary = AgentScheduledSendConfirmationSummary(
            sessionID: sessionID, tabID: nil, workspaceID: workspaceID, scheduleID: UUID(), attemptID: nil, reason: nil,
            notBefore: Date(timeIntervalSince1970: 1000), previewText: "later"
        )
        let catalog = AgentRecoveryCatalogProjection.build(
            coordinator: coordinator,
            schedules: [summary],
            unavailableScheduleIndexes: [AgentRecoveryWorkspaceDestination(id: UUID(), name: "Other", customStoragePath: nil)],
            generation: 1
        )
        let runtimeItemID = AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: writer.runtimeID)
        XCTAssertEqual(catalog.items.count, 3, "\(catalog.items.map(\.id))")
        XCTAssertEqual(catalog.items.first?.id, runtimeItemID, "\(catalog.items.map(\.id))")
        XCTAssertEqual(catalog.items.first?.kind, .survivingProcess)
        XCTAssertEqual(catalog.items.dropFirst().map(\.kind), [.scheduleNeedsConfirmation, .statusUnknown])
        XCTAssertTrue(catalog.items.dropFirst().allSatisfy { $0.kind != .survivingProcess })
    }

    /// 9-live R7: the global ownership warning also comes first.
    func testRuntimeOwnershipWarningPrecedesSessionItemsInTheCatalog() async throws {
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("not-a-runtime.json"))
        let coordinator = try await startedCoordinator()
        let summary = AgentScheduledSendConfirmationSummary(
            sessionID: UUID(), tabID: nil, workspaceID: UUID(), scheduleID: UUID(), attemptID: nil, reason: nil,
            notBefore: Date(timeIntervalSince1970: 1000), previewText: "later"
        )
        let catalog = AgentRecoveryCatalogProjection.build(coordinator: coordinator, schedules: [summary], generation: 1)
        XCTAssertEqual(
            catalog.items.map(\.id).first,
            AgentRecoveryCatalogProjection.runtimeOwnershipUnknownItemID,
            "\(catalog.items.map(\.id))"
        )
        XCTAssertEqual(catalog.items.last?.kind, .scheduleNeedsConfirmation)
    }

    /// 9-live R7, review B L4: the Needs Attention sheet's first "Needs action" row is the
    /// survivor, ahead of a session-independent startup item that is built before it would have
    /// been. (The catalog's only blocker is a session's crash hold; runtime items write none.)
    func testSurvivorIsTheFirstNeedsActionRowOfTheSheet() async throws {
        let writer = try seedWriter(pid: 5810, conversationID: "conv-S7", worktreePath: "/tmp/wt-s7")
        let failure = AgentRecoveryWorkspaceInventory.Failure(workspaceID: UUID(), location: "/tmp/ws-s7", reason: "unreadable")
        let coordinator = try await startedCoordinator(reconciliation: AgentRecoveryStartupReconciliation(workspaceFailures: [failure]))
        let viewModel = AgentModeViewModel(
            testWindowID: 5810,
            testWorkspacePath: root.path,
            testWorkspaceDirectory: root,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.installRecoveryCoordinator(coordinator)
        let needsAction = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil)
            .filter { $0.attention == .needsAction }
        XCTAssertEqual(
            needsAction.map(\.id),
            [AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: writer.runtimeID), "workspace-\(failure.workspaceID.uuidString)"]
        )
    }

    func testUnhostedSessionKeysFromTheCallerStillBlockAutomaticWork() async throws {
        try seedWriter(pid: 5500, conversationID: "conv-U", worktreePath: "/tmp/wt-u")
        let coordinator = try await startedCoordinator()
        let unhosted = UUID() // Installed in no window: composition yields no keys for it.

        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: unhosted))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unhosted,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-U", worktreePath: "/tmp/elsewhere")]
        ), "the hydrated session object's own conversation key restricts it")
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unhosted,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-u")]
        ), "a not-yet-bound session on the busy worktree is restricted")
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unhosted,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-V", worktreePath: "/tmp/wt-v")]
        ))
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unhosted,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-V", worktreePath: nil)],
            worktreeUnresolved: true
        ), "an unresolvable worktree could hide a tool-only or unassociated survivor: blocked")
    }

    func testUnresolvedWorktreeBlocksOnlyWhileARestrictionCarriesAWorktree() async throws {
        // Production shape: a registry attached, no runtime records (activation off). An unresolvable
        // worktree has nothing to overlap, so scheduled work is not held forever.
        let coordinator = try await startedCoordinator()
        XCTAssertTrue(coordinator.hasProcessRegistry)
        XCTAssertTrue(coordinator.runtimeRestrictions.restrictions.isEmpty)
        let unresolved = UUID()
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unresolved,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-W", worktreePath: nil)],
            worktreeUnresolved: true
        ), "no restriction at all: an unresolved worktree blocks nothing")
    }

    func testUnresolvedWorktreeIsNotBlockedByAWorktreeLessRestriction() async throws {
        // A restriction without any worktree cannot overlap an unresolved one.
        processes.add(processes.observation(pid: 5700, group: 5700))
        try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 5700),
            rootGroup: 5700,
            conversationIDs: ["conv-Y"]
        )
        let coordinator = try await startedCoordinator()
        let unresolved = UUID()
        XCTAssertEqual(coordinator.runtimeRestrictions.restrictions.count, 1)
        XCTAssertTrue(coordinator.runtimeRestrictions.restrictions.allSatisfy(\.worktreePaths.isEmpty))
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unresolved,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-W", worktreePath: nil)],
            worktreeUnresolved: true
        ), "a worktree-less restriction on another conversation leaves an unresolved worktree unblocked")
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(
            sessionID: unresolved,
            additionalKeys: [AgentRuntimeOwnershipKeys(conversationID: "conv-Y", worktreePath: nil)],
            worktreeUnresolved: true
        ), "its own conversation still blocks")
    }

    func testSessionAssociatedWriterRestrictsItsSessionBeforeAnyConversationIsKnown() async throws {
        processes.add(processes.observation(pid: 5600, group: 5600))
        let lifecycle = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        let writer = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 5600),
            rootGroup: 5600,
            associations: [AgentRuntimeAssociation(
                session: AgentRuntimeSessionAssociation(lifecycle: lifecycle, runAttemptID: UUID(), processRunID: nil),
                conversationID: nil,
                worktreePath: nil,
                permission: .claude(permissionMode: "default")
            )]
        )
        let coordinator = try await startedCoordinator()
        // The window composes no keys for either session (no conversation is bound yet).
        let reset = AgentRecoveryLifecycleBinding(sessionID: lifecycle.sessionID, incarnationID: UUID(), transcriptResetGeneration: 1)
        let other = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)

        let refusal = await coordinator.admissionRefusal(for: lifecycle)
        XCTAssertNotNil(refusal, "a writer associated with the session restricts it before any conversation exists")
        let resetRefusal = await coordinator.admissionRefusal(for: reset)
        XCTAssertNotNil(resetRefusal, "a transcript reset never evades a still-unresolved owner")
        let otherRefusal = await coordinator.admissionRefusal(for: other)
        XCTAssertNil(otherRefusal)
        XCTAssertEqual(coordinator.runtimeSendRestriction(sessionID: lifecycle.sessionID)?.runtimeID, writer.runtimeID)
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: lifecycle.sessionID))
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: other.sessionID))
    }

    /// F8 / review B VF-R1-2: deleting a session neither removes the item of a process that
    /// outlived it nor lifts that process's restriction. The registry owns both; deletion retires
    /// only the session's startup crash hold and startup restriction.
    func testDeletingASessionKeepsItsSurvivingProcessAndItsRestriction() async throws {
        processes.add(processes.observation(pid: 5800, group: 5800))
        let lifecycle = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        let writer = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 5800),
            rootGroup: 5800,
            associations: [AgentRuntimeAssociation(
                session: AgentRuntimeSessionAssociation(lifecycle: lifecycle, runAttemptID: UUID(), processRunID: nil),
                conversationID: "conv-D",
                worktreePath: "/tmp/wt-d",
                permission: .claude(permissionMode: "default")
            )],
            conversationIDs: ["conv-D"],
            worktreePaths: ["/tmp/wt-d"]
        )
        let coordinator = try await startedCoordinator()
        keysBySession[lifecycle.sessionID] = [AgentRuntimeOwnershipKeys(conversationID: "conv-D", worktreePath: "/tmp/wt-d")]
        let neighbour = session(conversationID: "conv-N", worktreePath: "/tmp/wt-d")
        let itemID = AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: writer.runtimeID)
        XCTAssertNotNil(coordinator.catalog.item(id: itemID))
        let restrictions = coordinator.runtimeRestrictions
        XCTAssertEqual(restrictions.restrictions.map(\.runtimeID), [writer.runtimeID])

        coordinator.noteSessionDeleted(lifecycle.sessionID)

        XCTAssertTrue(coordinator.deletedSessionIDs.contains(lifecycle.sessionID))
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID), "the surviving process stays listed")
        XCTAssertEqual(item.kind, .survivingProcess)
        XCTAssertEqual(coordinator.runtimeRestrictions, restrictions, "the process's restriction stays in force")
        XCTAssertEqual(coordinator.runtimeSendRestriction(sessionID: lifecycle.sessionID)?.runtimeID, writer.runtimeID)
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(worktreePath: "/tmp/wt-d"), "new sessions on its worktree stay paused")
        XCTAssertTrue(coordinator.runtimeBlocksAutomaticWork(sessionID: neighbour.sessionID), "its worktree stays busy for automatic work")
    }

    func testWithoutAnAttachedRegistryNothingIsRuntimeRestricted() async throws {
        try seedWriter(pid: 5400, conversationID: "conv-X", worktreePath: "/tmp/wt-x")
        let coordinator = try await startedCoordinator(attachRegistry: false)
        let binding = session(conversationID: "conv-X", worktreePath: "/tmp/wt-x")
        XCTAssertFalse(coordinator.hasProcessRegistry)
        let refusal = await coordinator.admissionRefusal(for: binding)
        XCTAssertNil(refusal)
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(sessionID: binding.sessionID))
        XCTAssertFalse(
            coordinator.runtimeBlocksAutomaticWork(sessionID: binding.sessionID, worktreeUnresolved: true),
            "legacy behavior without a registry is unchanged"
        )
        XCTAssertFalse(coordinator.runtimeBlocksAutomaticWork(worktreePath: "/tmp/wt-x"))
        XCTAssertFalse(catalog(coordinator).items.contains { $0.kind == .survivingProcess })
    }
}
