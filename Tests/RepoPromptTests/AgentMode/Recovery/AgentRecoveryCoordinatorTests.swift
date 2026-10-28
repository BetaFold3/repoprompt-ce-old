@testable import RepoPromptAgentCore
import XCTest

/// Recovery composition (lossless restart Phase 1b, inactive in production): the coordinator, its
/// startup barrier and launch mark, crash holds, one lane per durable session, restore-before-edits,
/// and explicit held-composer resolution. Every store, DataService, tombstone root, and workspace is
/// an injected temporary directory behind the real `AgentSessionDataService` gate.
@MainActor
final class AgentRecoveryCoordinatorTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private struct Workspace: AgentWorkspaceStorageReference {
        let id = UUID()
        let name = "Recovery Coordinator"
        let customStoragePath: URL?
    }

    private final class Owner {}

    /// Controllable reconciliation step: optionally fails, optionally suspends until released.
    @MainActor
    private final class ReconcileProbe {
        var failure: Error?
        var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        var suspends = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var arrived = false

        func run(_: AgentRecoveryStartupReport) async throws {
            calls += 1
            if suspends {
                arrived = true
                arrival?.resume()
                arrival = nil
                await withCheckedContinuation { gate = $0 }
            }
            if let failure { throw failure }
        }

        func waitUntilSuspended() async {
            guard !arrived else { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private struct ReconcileFailure: Error {}

    private var root: URL!
    private var recoveryRoot: URL!
    private var workspace: Workspace!
    private var failures: RecoveryStoreWriteFailureSwitch!

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryCoordinatorTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        workspace = Workspace(customStoragePath: root.appendingPathComponent("workspace", isDirectory: true))
        failures = RecoveryStoreWriteFailureSwitch()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Fixtures

    private func makeStore(instance: UUID = UUID()) -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: instance, fileOperations: failures.fileOperations())
    }

    private func makeService(store: AgentRecoveryStore) -> AgentSessionDataService {
        AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
    }

    /// Timers never fire on their own; tests flush explicitly.
    private func makeCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        probe: ReconcileProbe? = nil
    ) throws -> AgentRecoveryCoordinator {
        let probe = probe ?? ReconcileProbe()
        // The production sweep over this test's single workspace.
        let destination = AgentRecoveryWorkspaceDestination(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath
        )
        return try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { report in
                try await probe.run(report)
                return await AgentRecoveryStartupSweep.run(
                    inventory: AgentRecoveryWorkspaceInventory(workspaces: [destination]),
                    entries: report.discovered,
                    dataService: service
                )
            },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
    }

    /// Composer deadlines on a controllable clock: sleeps resume only when the test fires them, and
    /// the coordinator's first-unsaved instants use the same clock.
    private func timedCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        clock: RecoveryTestClock,
        sleeper: RecoveryManualSleeper
    ) async throws -> AgentRecoveryCoordinator {
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { try await sleeper.sleep(until: $0) },
                    clockNow: { clock.now }
                )
            },
            clockNow: { clock.now }
        )
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    @MainActor
    private final class LaneBox {
        var lane: AgentRecoverySessionLane?
    }

    private func startedCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService
    ) async throws -> AgentRecoveryCoordinator {
        let coordinator = try makeCoordinator(store: store, service: service)
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    private func makeSession(_ service: AgentSessionDataService) async throws -> AgentSessionEditableLoad {
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Recovery"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
    }

    private func resetTranscript(
        _ service: AgentSessionDataService,
        _ load: AgentSessionEditableLoad
    ) async throws -> AgentSessionSaveCommit {
        try await service.saveAgentSession(
            load.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: load.persistenceState
        )
    }

    private func admission(
        _ lane: AgentRecoverySessionLane,
        _ text: String,
        origin: AgentRecoveryIntentOrigin = .mcp
    ) -> AgentRecoveryAdmission {
        AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: origin,
            target: .session,
            original: Support.content(text)
        )
    }

    private func storedComposerText(_ store: AgentRecoveryStore, _ sessionID: UUID) async -> String? {
        await store.read(sessionID: sessionID).record?.composer?.content.text
    }

    private func assertRefused(
        _ result: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>,
        _ expected: AgentRecoveryAdmissionRefusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(.refused(refusal)) = result else {
            return XCTFail("expected refusal \(expected), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(refusal, expected, file: file, line: line)
    }

    // MARK: Composition

    func testCompositionRejectsDataServiceBackedByAnotherStore() throws {
        let store = makeStore()
        let other = AgentRecoveryStore(rootURL: root.appendingPathComponent("other/v1", isDirectory: true))
        XCTAssertThrowsError(try makeCoordinator(store: store, service: makeService(store: other))) { error in
            XCTAssertEqual(error as? AgentRecoveryCompositionError, .dataServiceStoreMismatch)
        }
        XCTAssertThrowsError(try makeCoordinator(store: store, service: AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true)
        )))
    }

    // MARK: Startup barrier and launch state

    func testAdmissionStaysClosedUntilStartupIsReady() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.suspends = true
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)

        // Never started: closed, nothing written.
        let early = await lane.admitQueued(admission(lane, "early"))
        assertRefused(early, .startupNotReady)
        let beforeStart = await store.read(sessionID: load.session.id)
        XCTAssertEqual(beforeStart, .absent)

        coordinator.startIfNeeded()
        await probe.waitUntilSuspended()
        XCTAssertEqual(coordinator.startupState, .loading)
        let pending = Task { await lane.admitQueued(self.admission(lane, "waits for barrier")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let whileLoading = await store.read(sessionID: load.session.id)
        XCTAssertEqual(whileLoading, .absent, "admission waits on the startup barrier")
        probe.release()
        guard case let .success(admitted) = await pending.value else {
            return XCTFail("admission should open once startup is ready")
        }
        XCTAssertEqual(admitted.receipt.intent.deliveryState, .queued)
        XCTAssertNil(admitted.submittedComposerRevision)
    }

    func testReconciliationFailureKeepsAdmissionClosedUntilRetrySucceeds() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.failure = ReconcileFailure()
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        coordinator.startIfNeeded()
        guard case .failed = await coordinator.awaitStartup() else {
            return XCTFail("reconciliation failure must fail startup")
        }
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let refused = await lane.admitQueued(admission(lane, "refused"))
        guard case .failure(.refused(.startupFailed)) = refused else {
            return XCTFail("expected startupFailed, got \(refused)")
        }
        let afterFailure = await store.read(sessionID: load.session.id)
        XCTAssertEqual(afterFailure, .absent)

        probe.failure = nil
        coordinator.retryStartup()
        let retried = await coordinator.awaitStartup()
        XCTAssertEqual(retried, .ready)
        XCTAssertEqual(probe.calls, 2)
        guard case .success = await lane.admitQueued(admission(lane, "after retry")) else {
            return XCTFail("admission opens after a successful retry")
        }
    }

    func testUnwritableLaunchMarkFailsStartupClosed() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        failures.shouldFailWrites = true
        let coordinator = try makeCoordinator(store: store, service: service)
        coordinator.startIfNeeded()
        guard case .failed = await coordinator.awaitStartup() else {
            return XCTFail("an unwritable launch mark must fail startup")
        }
        failures.shouldFailWrites = false
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let refused = await lane.admitQueued(admission(lane, "refused"))
        guard case .failure(.refused(.startupFailed)) = refused else {
            return XCTFail("expected startupFailed, got \(refused)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.launchStateFileURL.path))
        let record = await store.read(sessionID: load.session.id)
        XCTAssertEqual(record, .absent)
    }

    func testPreviousLaunchMarkIsReadBeforeReplacementAndClassifiedUnclean() async throws {
        let previousInstance = UUID()
        let previousStore = makeStore(instance: previousInstance)
        _ = try await previousStore.recordCurrentLaunchRunning()

        let currentInstance = UUID()
        let store = makeStore(instance: currentInstance)
        let coordinator = try await startedCoordinator(store: store, service: makeService(store: store))
        let report = try XCTUnwrap(coordinator.startupReport)
        guard case let .mark(previous) = report.previousLaunch else {
            return XCTFail("expected the previous mark, got \(report.previousLaunch)")
        }
        XCTAssertEqual(previous.appInstanceID, previousInstance)
        XCTAssertEqual(previous.state, .running)
        XCTAssertFalse(report.previousLaunch.provesCleanExit(currentInstanceID: currentInstance))
        XCTAssertEqual(report.currentLaunch.appInstanceID, currentInstance)
        XCTAssertEqual(report.currentLaunch.state, .running)
        let onDisk = await store.readLaunchMark()
        XCTAssertEqual(onDisk, .mark(report.currentLaunch), "this launch's unclean mark replaced the previous one")
    }

    func testMissingOrUnreadableLaunchMarkIsConservativelyUnclean() async throws {
        let instance = UUID()
        let store = makeStore(instance: instance)
        let missing = await store.readLaunchMark()
        XCTAssertEqual(missing, .none)
        XCTAssertFalse(missing.provesCleanExit(currentInstanceID: instance))

        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":2}".utf8).write(to: store.launchStateFileURL)
        let unreadable = await store.readLaunchMark()
        guard case .unreadable = unreadable else {
            return XCTFail("future or malformed marks are unreadable, got \(unreadable)")
        }
        XCTAssertFalse(unreadable.provesCleanExit(currentInstanceID: instance))
    }

    // MARK: Crash holds

    func testPreviousInstanceOpenEvidenceHoldsAdmissionUntilExplicitConfirmation() async throws {
        let previousStore = makeStore(instance: UUID())
        let previousService = makeService(store: previousStore)
        let load = try await makeSession(previousService)
        let previousGate = try previousService.recoveryLifecycleGate(for: load.persistenceState)
        let ownership = Support.ownership(sessionID: load.session.id)
        let submission = Support.submission("in flight at crash")
        let attemptID = UUID()
        try await previousGate.performRecoveryTransaction {
            _ = try await previousStore.ensureRunAttempt(
                binding: previousGate.binding, expectedRevision: nil, ownership: ownership,
                processRunID: nil, transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await previousStore.commitDispatchingIntent(
                binding: previousGate.binding,
                expectedRevision: previousStore.currentRevision(sessionID: load.session.id),
                submission: submission,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: ownership.attemptID),
                consumption: nil
            )
        }

        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let hold = try XCTUnwrap(coordinator.crashHold(for: load.session.id))
        XCTAssertEqual(hold.uncertainRunAttemptIDs, [ownership.attemptID])
        XCTAssertEqual(hold.uncertainIntentIDs, [submission.intentID])
        XCTAssertFalse(hold.previousExitProvenClean)

        // After relaunch the session is reloaded through this launch's service (fresh stamp).
        let reloaded = try await service.loadAgentSessionForEditing(id: load.session.id, for: workspace)
        let relaunchState = try XCTUnwrap(reloaded?.persistenceState)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: relaunchState)
        let beforeRevision = await store.read(sessionID: load.session.id).record?.revision
        let blocked = await lane.admitQueued(admission(lane, "blocked"))
        assertRefused(blocked, .crashHeld(hold))
        let dispatch = await lane.beginDispatch(
            intentID: submission.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()),
            authorization: .explicitUserAction
        )
        guard case .failure(.refused(.crashHeld)) = dispatch else {
            return XCTFail("every route checks the crash hold, got \(dispatch)")
        }
        let unchanged = await store.read(sessionID: load.session.id).record?.revision
        XCTAssertEqual(unchanged, beforeRevision, "refusals write nothing")

        let stale = AgentRecoveryCrashHold(
            sessionID: hold.sessionID,
            incarnationID: hold.incarnationID,
            transcriptResetGeneration: hold.transcriptResetGeneration,
            uncertainRunAttemptIDs: [UUID()],
            uncertainIntentIDs: hold.uncertainIntentIDs,
            previousExitProvenClean: false
        )
        XCTAssertEqual(
            coordinator.unresolvedSessionSummary(inWorkspace: workspace.id, excluding: UUID()),
            AgentRecoveryWorkspaceUnresolvedSummary(crashHeldSessionIDs: [load.session.id]),
            "F2: the scheduler's new-session gate is itemized as one interrupted session"
        )
        let staleConfirmed = await coordinator.confirmCrashHold(stale, lane: lane)
        XCTAssertFalse(staleConfirmed, "confirmation binds the exact uncertain attempts")
        XCTAssertNotNil(coordinator.blockingCrashHold(for: lane.binding))
        XCTAssertTrue(coordinator.hasUnresolvedSession(inWorkspace: workspace.id, excluding: UUID()))
        let staleRecord = await store.read(sessionID: load.session.id).record
        XCTAssertNil(staleRecord?.crashHoldAcknowledgement, "A stale confirmation writes nothing")
        let holdConfirmed = await coordinator.confirmCrashHold(hold, lane: lane)
        XCTAssertTrue(holdConfirmed)
        XCTAssertNil(coordinator.blockingCrashHold(for: lane.binding))
        XCTAssertTrue(coordinator.unresolvedSessionSummary(inWorkspace: workspace.id, excluding: UUID()).isEmpty)
        XCTAssertFalse(coordinator.hasUnresolvedSession(inWorkspace: workspace.id, excluding: UUID()))
        // F-2: the acknowledgement is durable and exact.
        let acknowledgedRead = await store.read(sessionID: load.session.id)
        let acknowledged = try XCTUnwrap(acknowledgedRead.record)
        let acknowledgement = try XCTUnwrap(acknowledged.crashHoldAcknowledgement)
        XCTAssertTrue(hold.isCovered(by: acknowledgement))
        XCTAssertEqual(acknowledgement.runAttemptIDs, [ownership.attemptID])
        XCTAssertEqual(acknowledgement.intentIDs, [submission.intentID])
        XCTAssertEqual(acknowledged.runAttempt(id: ownership.attemptID)?.terminal, nil, "No run outcome is invented")
        let confirmed = await lane.admitQueued(admission(lane, "after confirmation"))
        guard case .success = confirmed else {
            return XCTFail("admission opens after explicit confirmation, got \(confirmed)")
        }
        // Confirmation is not a retry: the uncertain intent keeps its state.
        let intent = await store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertEqual(intent?.deliveryState, .dispatching)

        // A later launch with the identical uncertainty does not ask again; changed uncertainty is
        // not covered by this decision.
        let nextStore = makeStore(instance: UUID())
        let nextCoordinator = try await startedCoordinator(store: nextStore, service: makeService(store: nextStore))
        let nextHold = try XCTUnwrap(nextCoordinator.crashHold(for: load.session.id), "The evidence is still presented")
        XCTAssertEqual(nextHold.uncertainRunAttemptIDs, hold.uncertainRunAttemptIDs)
        XCTAssertEqual(nextHold.uncertainIntentIDs, hold.uncertainIntentIDs)
        XCTAssertNil(nextCoordinator.blockingCrashHold(for: lane.binding), "The identical hold stays acknowledged")
        let widened = AgentRecoveryCrashHold(
            sessionID: hold.sessionID,
            incarnationID: hold.incarnationID,
            transcriptResetGeneration: hold.transcriptResetGeneration,
            uncertainRunAttemptIDs: hold.uncertainRunAttemptIDs.union([UUID()]),
            uncertainIntentIDs: hold.uncertainIntentIDs,
            previousExitProvenClean: false
        )
        XCTAssertFalse(widened.isCovered(by: acknowledgement), "Additional uncertainty needs another confirmation")
    }

    // MARK: Lane ownership

    func testOneLanePerDurableSessionRetiresPredecessorAfterFlushingIt() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let firstOwner = Owner()
        let first = try coordinator.claimLane(owner: firstOwner, persistenceState: load.persistenceState)
        XCTAssertTrue(try coordinator.claimLane(owner: firstOwner, persistenceState: load.persistenceState) === first)
        _ = await first.restoreComposer()
        XCTAssertNotNil(first.composerDidChange(Support.content("typed by the first owner")))

        let secondOwner = Owner()
        let second = try coordinator.claimLane(owner: secondOwner, persistenceState: load.persistenceState)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isRetired, "retired synchronously before the replacement is returned")
        XCTAssertTrue(coordinator.lane(for: load.session.id) === second)
        XCTAssertNil(first.composerDidChange(Support.content("late edit")))
        let late = await first.admitQueued(admission(first, "late"))
        assertRefused(late, .laneRetired)

        // The successor restores only after the predecessor's pending composer was flushed.
        let restored = await second.restoreComposer()
        let storedComposer = await store.read(sessionID: load.session.id).record?.composer
        XCTAssertEqual(restored, .restored(storedComposer))
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "typed by the first owner")
        let flushAfterRetire = await first.flushComposer()
        XCTAssertEqual(flushAfterRetire, .nothingPending)
    }

    func testRetirementDuringBarrierAwaitRefusesWithoutWriting() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.suspends = true
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        coordinator.startIfNeeded()
        await probe.waitUntilSuspended()
        let pending = Task { await first.admitQueued(self.admission(first, "target lost during await")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        _ = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        probe.release()
        let lost = await pending.value
        assertRefused(lost, .laneRetired)
        let record = await store.read(sessionID: load.session.id)
        XCTAssertEqual(record, .absent)
    }

    func testResetYieldsNewLaneAndOldGenerationLaneCannotWrite() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("old generation draft"))
        guard case .committed = await old.flushComposer() else {
            return XCTFail("the old generation draft is stored before the reset")
        }
        let reset = try await resetTranscript(service, load)
        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        XCTAssertTrue(old.isRetired)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1)
        let outcome = await fresh.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("the old-generation composer is held, got \(outcome)")
        }
        XCTAssertEqual(held.content.text, "old generation draft")
        XCTAssertEqual(fresh.composerState, .held(held))
    }

    // MARK: Unsaved input across owner replacement

    /// Fixture 1: replacement during restore. The predecessor's buffered input reaches disk before
    /// its controller retires, the successor's newer typing wins afterward, and a healthy hand-over
    /// leaves no failure entry.
    func testReplacementDuringRestoreWritesBufferedInputAndSuccessorTypingWinsAfterward() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let pendingRestore = Task { await first.restoreComposer() }
        XCTAssertNil(first.composerDidChange(Support.content("typed while restore was in flight")), "buffered")
        XCTAssertNotNil(first.bufferedFirstUnsavedAt, "the buffered input owns its first-unsaved instant")

        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(second.composerDidChange(Support.content("successor typing")), "successor buffers behind the hand-over")
        let firstRestore = await pendingRestore.value
        XCTAssertEqual(firstRestore, .failed(.retired))
        let restored = await second.restoreComposer()
        XCTAssertEqual(restored, .superseded, "the predecessor snapshot never replaces successor typing")
        XCTAssertTrue(second.unsavedPredecessorInputs.isEmpty, "a successful hand-over leaves no failure entry")
        XCTAssertTrue(first.composer.isRetired)
        XCTAssertFalse(first.composer.hasPendingChanges)
        let handedOver = await storedComposerText(store, load.session.id)
        XCTAssertEqual(handedOver, "typed while restore was in flight", "written before the predecessor retired")

        guard case .committed = await second.flushComposer() else {
            return XCTFail("the successor writes against the handed-over baseline")
        }
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "successor typing")
        guard case .success = await second.admitQueued(admission(second, "after hand-over")) else {
            return XCTFail("admission is open after a healthy hand-over")
        }
    }

    func testPredecessorFlushFailureSurvivesReplacementWithItsErrorAndKeepsSuccessorTyping() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        // A current-launch intent whose live projection was removed is presented as held input.
        guard case let .success(heldAdmission) = await first.admitQueued(admission(first, "no longer queued")) else {
            return XCTFail("admission is open")
        }
        let heldIntentID = heldAdmission.receipt.intent.intentID
        first.noteProjectionRemoved(intentIDs: [heldIntentID], reason: "its run ended")
        failures.shouldFailWrites = true
        XCTAssertNotNil(first.composerDidChange(Support.content("unsaved before replacement")))

        // Another owner (for example another window) takes the session over.
        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertEqual(second.heldIntents[heldIntentID], "its run ended", "ownership transfer never hides held input")
        let refused = await second.admitQueued(admission(second, "blocked"))
        assertRefused(refused, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(second.unsavedPredecessorInputs.first)
        XCTAssertEqual(inherited.content.text, "unsaved before replacement")
        XCTAssertEqual(inherited.binding, first.binding)
        XCTAssertNotNil(inherited.failure, "the predecessor's write failure stays visible")

        failures.shouldFailWrites = false
        _ = await second.restoreComposer()
        second.composerDidChange(Support.content("successor typing"))
        let overwrite = await second.resolveUnsavedPredecessorInput(
            .restoreToComposer,
            expected: inherited,
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(overwrite, .failure(.liveComposerHasUnsavedContent), "never overwrites successor typing")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited], "kept until resolved")
        let notDisplayed = AgentRecoveryUnsavedComposerInput(
            binding: inherited.binding,
            content: Support.content("something else"),
            failure: inherited.failure
        )
        let wrongEntry = await second.resolveUnsavedPredecessorInput(.discard, expected: notDisplayed, liveComposerIsEmpty: false)
        XCTAssertEqual(wrongEntry, .failure(.heldInputChanged), "only the exact displayed payload is discarded")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited])
        let discarded = await second.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        _ = await second.flushComposer()
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "successor typing")

        // The owner goes away with input it could not save: published with no lane (never kept
        // only inside a parked retirement), then inherited and presented by the next owner.
        failures.shouldFailWrites = true
        second.composerDidChange(Support.content("unsaved when the tab closed"))
        await coordinator.releaseLane(second).value
        XCTAssertNil(coordinator.lane(for: load.session.id))
        let ownerless = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[load.session.id])
        XCTAssertEqual(ownerless.workspaceID, workspace.id)
        XCTAssertEqual(ownerless.inputs.map(\.content.text), ["unsaved when the tab closed"])
        XCTAssertNotNil(ownerless.inputs.first?.failure, "the persistence failure stays visible")
        XCTAssertEqual(
            coordinator.heldIntents(sessionID: load.session.id, incarnationID: first.binding.incarnationID)[heldIntentID],
            "its run ended",
            "held input stays visible while no lane owns the session"
        )
        failures.shouldFailWrites = false

        let third = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[load.session.id], "the next owner presents it instead")
        _ = await third.restoreComposer()
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["unsaved when the tab closed"])
        XCTAssertEqual(third.heldIntents[heldIntentID], "its run ended", "a same-launch reclaim never hides held input")

        // Resolving the held intent (withdrawal commit) retires its presentation.
        let reclaimed = try XCTUnwrap(third.unsavedPredecessorInputs.first)
        _ = await third.resolveUnsavedPredecessorInput(.discard, expected: reclaimed, liveComposerIsEmpty: true)
        guard case .success = await third.withdraw(intentID: heldIntentID) else {
            return XCTFail("the held intent can be withdrawn")
        }
        for _ in 0 ..< 500 where third.heldIntents[heldIntentID] != nil {
            await Task.yield()
        }
        XCTAssertNil(third.heldIntents[heldIntentID], "withdrawn input needs no decision")
    }

    func testDiscardedOwnerlessInputIsNeverInheritedByTheNextOwner() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        failures.shouldFailWrites = true
        first.composerDidChange(Support.content("unsaved when the tab closed"))
        await coordinator.releaseLane(first).value
        failures.shouldFailWrites = false
        let entry = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[load.session.id]?.inputs.first)
        let stale = AgentRecoveryUnsavedComposerInput(binding: entry.binding, content: Support.content("other"), failure: nil)
        XCTAssertFalse(coordinator.discardOwnerlessUnsavedInput(sessionID: load.session.id, expected: stale))
        XCTAssertTrue(coordinator.discardOwnerlessUnsavedInput(sessionID: load.session.id, expected: entry))
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[load.session.id])

        let next = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await next.restoreComposer()
        XCTAssertTrue(next.unsavedPredecessorInputs.isEmpty, "an explicitly discarded payload never comes back")
        guard case .success = await next.admitQueued(admission(next, "after discard")) else {
            return XCTFail("admission is open after the explicit discard")
        }
    }

    func testResetKeepsOldGenerationUnsavedInputWithoutWritingItUnderEitherAuthority() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("old generation, never flushed"))
        let reset = try await resetTranscript(service, load)

        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let refused = await fresh.admitQueued(admission(fresh, "blocked"))
        assertRefused(refused, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(fresh.unsavedPredecessorInputs.first)
        XCTAssertEqual(inherited.content.text, "old generation, never flushed")
        XCTAssertEqual(inherited.binding.transcriptResetGeneration, 0)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1)
        let restored = await fresh.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        let stored = await store.read(sessionID: load.session.id).record?.composer
        XCTAssertNil(stored, "not flushed by the retired authority nor carried into the new generation")
        _ = await fresh.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: true)
        guard case .success = await fresh.admitQueued(admission(fresh, "after discard")) else {
            return XCTFail("admission reopens after explicit discard")
        }
    }

    /// Fixture 2: reset preparation. A failed preservation write vetoes the reset and keeps the
    /// input usable; a successful retry freezes admission, the reset commits once, and the written
    /// old-generation composer is held (never adopted) by the new generation.
    func testResetPreparationVetoesOnWriteFailureAndRetryResetsOnceLeavingTheOldComposerHeld() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        failures.shouldFailWrites = true
        XCTAssertNotNil(old.composerDidChange(Support.content("draft before reset")))

        let vetoed = await old.prepareForTranscriptReset()
        guard case .failure(.composerNotPersisted(.some)) = vetoed else {
            return XCTFail("a failed preservation write vetoes the reset, got \(vetoed)")
        }
        XCTAssertFalse(old.isResetPreparationActive, "a veto reopens admission")
        XCTAssertFalse(old.isRetired)
        XCTAssertEqual(old.composer.pendingContent?.text, "draft before reset", "the input stays usable")
        XCTAssertNotNil(old.composer.lastWriteFailure, "the failure stays visible")
        XCTAssertEqual(coordinator.lane(for: load.session.id)?.binding.transcriptResetGeneration, 0)

        failures.shouldFailWrites = false
        guard case .success = await old.prepareForTranscriptReset() else {
            return XCTFail("the retry preserves the composer")
        }
        XCTAssertTrue(old.isResetPreparationActive)
        let frozen = await old.admitQueued(admission(old, "during reset"))
        assertRefused(frozen, .resetPreparationInProgress)
        let preserved = await storedComposerText(store, load.session.id)
        XCTAssertEqual(preserved, "draft before reset", "written under the old generation before it advances")

        let reset = try await resetTranscript(service, load)
        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        XCTAssertTrue(old.isRetired)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1, "the generation advanced exactly once")
        let outcome = await fresh.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("the preserved composer is held, never adopted, got \(outcome)")
        }
        XCTAssertEqual(held.content.text, "draft before reset")
        XCTAssertTrue(fresh.unsavedPredecessorInputs.isEmpty, "nothing is retained only in memory")
        guard case .failure(.laneRetired) = await old.prepareForTranscriptReset() else {
            return XCTFail("the committed reset is not prepared twice")
        }
    }

    /// Fixture 3: first draft with an image. Delayed creation and promotion coalesce later typing
    /// into one obligation, authority comes from normal exclusive creation, and the write is due at
    /// the original first mutation plus 2 seconds.
    func testFirstDraftWithImageCoalescesThroughDelayedCreationAndPromotionAndKeepsTheOriginalDeadline() async throws {
        let clock = RecoveryTestClock()
        let sleeper = RecoveryManualSleeper()
        let store = makeStore()
        let service = makeService(store: store)
        let coordinator = try await timedCoordinator(store: store, service: service, clock: clock, sleeper: sleeper)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let imageSource = try Support.makeImageSource(in: sources)
        let owner = Owner()
        let t0 = clock.now

        // First typing in an unsaved tab: the image is not representable yet, the obligation is not.
        let obligation = coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: nil)
        XCTAssertEqual(obligation.firstUnsavedAt, t0)
        let creation = RecoveryGateLatch()
        let box = LaneBox()
        let started = coordinator.startComposerPreparation(owner: owner) { [self] _ in
            await creation.pause()
            guard let load = try? await makeSession(service),
                  let lane = try? coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
            else { return .authorityUnavailable("creation") }
            box.lane = lane
            let image: AgentRecoveryImageReference
            do {
                image = try await store.importManagedImage(sessionID: lane.sessionID, sourceURL: imageSource)
            } catch {
                return .imagePromotionFailed(String(describing: error))
            }
            let content = Support.content("caption typed while preparing", images: [image])
            if case let .failure(failure) = coordinator.completeComposerPreparation(owner: owner, forwardingTo: lane, content: content) {
                return failure
            }
            return nil
        }
        XCTAssertTrue(started)
        await creation.waitUntilPaused()

        clock.advance(by: .milliseconds(1500))
        let coalesced = coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: nil)
        XCTAssertTrue(coalesced === obligation, "later typing joins the same obligation")
        XCTAssertEqual(coalesced.firstUnsavedAt, t0, "coalescing never moves the first-unsaved instant")
        let duplicate = coordinator.startComposerPreparation(owner: owner) { _ in
            XCTFail("one preparation per owner")
            return nil
        }
        XCTAssertFalse(duplicate)

        await creation.open()
        let preparation = try XCTUnwrap(obligation.preparationTask)
        await preparation.value
        XCTAssertNil(obligation.failure)
        XCTAssertNil(coordinator.composerPreparation(for: owner), "handed to the lane")
        let lane = try XCTUnwrap(box.lane)
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0, "buffered behind restore under the original instant")
        let record = await store.read(sessionID: lane.sessionID)
        XCTAssertNil(record.record?.composer, "not written before its deadline")

        let restored = await lane.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        XCTAssertEqual(lane.composer.maximumDelayDeadline, t0 + AgentRecoveryComposerPersistenceController.maximumDelay)
        let armed = await Support.eventually { await sleeper.pendingDeadlines.contains(t0 + AgentRecoveryComposerPersistenceController.maximumDelay) }
        XCTAssertTrue(armed, "the 2-second bound runs from the first mutation, not from preparation")
        await sleeper.fire(through: t0 + AgentRecoveryComposerPersistenceController.maximumDelay)
        let written = await Support.eventually { await self.storedComposerText(store, lane.sessionID) == "caption typed while preparing" }
        XCTAssertTrue(written)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.images.count, 1, "the promoted image is part of the snapshot")
    }

    /// Fixture 4: delayed restore and a late owner completion. The replacement's buffered typing
    /// keeps its own original deadline (written at once when overdue, no restarted bound); the late
    /// completion never adopts into the replacement and keeps its payload with a visible failure.
    func testDelayedRestoreKeepsTheDeadlineAndLateOwnerCompletionNeverAdoptsIntoTheReplacement() async throws {
        let clock = RecoveryTestClock()
        let sleeper = RecoveryManualSleeper()
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await timedCoordinator(store: store, service: service, clock: clock, sleeper: sleeper)
        let original = Owner()
        let replacement = Owner()
        let t0 = clock.now

        coordinator.recordComposerMutationAwaitingPreparation(owner: original, content: Support.content("typed by the original owner"))
        let late = RecoveryGateLatch()
        coordinator.startComposerPreparation(owner: original) { _ in
            await late.pause()
            guard let current = coordinator.lane(for: load.session.id) else { return .ownerReplaced }
            if case let .failure(failure) = coordinator.completeComposerPreparation(
                owner: original,
                forwardingTo: current,
                content: Support.content("typed by the original owner")
            ) {
                return failure
            }
            return nil
        }
        await late.waitUntilPaused()

        let lane = try coordinator.claimLane(owner: replacement, persistenceState: load.persistenceState)
        clock.advance(by: .seconds(1))
        XCTAssertNil(lane.composerDidChange(Support.content("replacement typing")), "buffered until restore")
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0 + .seconds(1))

        await late.open()
        let obligation = try XCTUnwrap(coordinator.composerPreparation(for: original))
        await obligation.preparationTask?.value
        XCTAssertEqual(obligation.failure, .ownerReplaced, "the late completion is a visible failure")
        XCTAssertEqual(obligation.latestContent?.text, "typed by the original owner", "its payload is retained")
        XCTAssertEqual(obligation.firstUnsavedAt, t0)
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0 + .seconds(1), "no stale adoption into the replacement")

        // The restore is delayed past the replacement's own 2-second bound.
        clock.advance(by: .milliseconds(2500))
        let restored = await lane.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        let written = await Support.eventually { await self.storedComposerText(store, load.session.id) == "replacement typing" }
        XCTAssertTrue(written, "an overdue obligation is written at once")
        let requested = await sleeper.requestedDeadlines
        XCTAssertFalse(
            requested.contains(clock.now + AgentRecoveryComposerPersistenceController.maximumDelay),
            "the deadline is never restarted after the delayed restore"
        )
        XCTAssertNotNil(coordinator.composerPreparation(for: original), "kept until explicitly resolved")
    }

    // MARK: Restore before edits

    func testTypingBeforeRestoreIsBufferedAndSupersedesTheStoredComposer() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("durable draft"))
        _ = await seed.flushComposer()

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(lane.composerDidChange(Support.content("newer typing")), "buffered until restore")
        let outcome = await lane.restoreComposer()
        XCTAssertEqual(outcome, .superseded, "restore never overwrites newer typing")
        guard case .committed = await lane.flushComposer() else {
            return XCTFail("buffered typing is written after the restore")
        }
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "newer typing")
    }

    func testSubmissionCapturedBeforeRestoreConsumesOnlyItsOwnContent() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("stored before relaunch"))
        _ = await seed.flushComposer()

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let token = lane.beginComposerSubmission(Support.content("submitted"))
        XCTAssertNil(token.revision)
        lane.composerDidChange(Support.content("typed after submit"))
        let admissionValue = AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .composer,
            target: .session,
            original: token.content
        )
        guard case let .success(admitted) = await lane.admitQueued(admissionValue, composerToken: token) else {
            return XCTFail("composer submission should commit")
        }
        XCTAssertEqual(admitted.submittedComposerRevision, token.revision)
        XCTAssertNotNil(token.revision)
        XCTAssertTrue(admitted.receipt.intent.composerConsumed, "the stored older composer was consumed")
        _ = await lane.flushComposer()
        let state = await store.read(sessionID: load.session.id)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.intent(id: admissionValue.intentID)?.payload.text, "submitted")
        XCTAssertEqual(record.composer?.content.text, "typed after submit", "later typing is never consumed")
    }

    // MARK: Held composer resolution

    private func heldLane() async throws -> (AgentRecoveryStore, AgentRecoverySessionLane, AgentRecoveryComposerSnapshot) {
        let fixture = try await heldLaneWithGate()
        return (fixture.store, fixture.lane, fixture.held)
    }

    /// A held-composer lane plus the session's real DataService recovery gate (for holding it).
    private func heldLaneWithGate() async throws -> (
        store: AgentRecoveryStore,
        lane: AgentRecoverySessionLane,
        held: AgentRecoveryComposerSnapshot,
        gate: any AgentRecoveryLifecycleGate
    ) {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        guard case let .heldForOtherGeneration(held) = await lane.restoreComposer() else {
            throw XCTSkip("fixture did not produce a held composer")
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        return (store, lane, held, gate)
    }

    func testHeldComposerIsNeverReplacedImplicitlyAndDiscardWritesLiveTyping() async throws {
        let (store, lane, held) = try await heldLane()
        lane.composerDidChange(Support.content("live typing"))
        let blocked = await lane.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = blocked else {
            return XCTFail("ordinary writes refuse to replace held input, got \(blocked)")
        }
        let unresolved = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(unresolved, held)

        let restoreRefused = await lane.resolveHeldComposer(
            .restoreToComposer,
            expectedHeldRevision: held.revision,
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(restoreRefused, .failure(.liveComposerHasUnsavedContent))
        let notDisplayed = await lane.resolveHeldComposer(
            .discard,
            expectedHeldRevision: AgentRecoveryComposerRevision.make(),
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(notDisplayed, .failure(.heldInputChanged), "only the exact displayed held draft is resolved")
        let stillHeld = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stillHeld, held, "a refused resolution changes nothing")

        let discarded = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        XCTAssertEqual(lane.composerState, .ready)
        XCTAssertNil(lane.composer.lastWriteFailure)
        XCTAssertFalse(lane.composer.hasPendingChanges, "the live typing was stored by the discard itself")
        let state = await store.read(sessionID: lane.sessionID)
        let stored = try XCTUnwrap(state.record?.composer)
        XCTAssertEqual(stored.content.text, "live typing")
        XCTAssertEqual(stored.transcriptResetGeneration, 1)
    }

    func testRestoreHeldComposerMovesItIntoTheCurrentGenerationExplicitly() async throws {
        let (store, lane, held) = try await heldLane()
        let result = await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        guard case let .success(restored?) = result else {
            return XCTFail("expected restored content, got \(result)")
        }
        XCTAssertEqual(restored.content, held.content)
        XCTAssertEqual(restored.transcriptResetGeneration, 1)
        XCTAssertNotEqual(restored.revision, held.revision)
        XCTAssertEqual(lane.composer.liveRevision, restored.revision)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, restored)

        // Later edits write against the adopted revision.
        lane.composerDidChange(Support.content("edited after restore"))
        guard case .committed = await lane.flushComposer() else {
            return XCTFail("edits after restoring held input write normally")
        }
        let again = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        XCTAssertEqual(again, .failure(.noHeldComposer))
    }

    /// Restore freeze at the lane through the real session gate: a change while the restore waits
    /// for the gate wins the message box, the held draft stays stored and presented (nothing is
    /// memory-only beyond ordinary typing), and the explicit Discard then stores the typing.
    func testTypingWhileHeldRestoreWaitsForTheSessionGateKeepsTheHeldDraftDurable() async throws {
        let fixture = try await heldLaneWithGate()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await fixture.gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        lane.composerDidChange(Support.content("typed during restore"))
        await latch.open()
        try await holder.value
        let result = await resolution.value

        XCTAssertEqual(result, .failure(.composerChangedDuringRestore))
        XCTAssertEqual(lane.composerState, .held(held), "the held draft is still presented")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty, "no draft is left memory-only")
        XCTAssertTrue(lane.composer.hasPendingChanges, "the typing stays in the message box")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let discarded = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        let afterDiscard = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(afterDiscard?.content.text, "typed during restore")
        XCTAssertEqual(lane.composerState, .ready)
    }

    // MARK: R02: failed rollback of a raced held restore across owners

    private struct FailedRollbackFixture {
        let store: AgentRecoveryStore
        let coordinator: AgentRecoveryCoordinator
        let persistenceState: AgentSessionPersistenceState
        let lane: AgentRecoverySessionLane
        let held: AgentRecoveryComposerSnapshot
        let protected: AgentRecoveryUnsavedComposerInput
        let gate: AgentSessionRecoveryLifecycleGate
    }

    /// A held draft is restored, a change lands right after the restore commit, and the rollback
    /// write fails (storage keeps failing until the test clears it). The restored draft is durable as
    /// the current composer and its visible copy carries the rollback obligation.
    private func laneWithFailedHeldRestoreRollback() async throws -> FailedRollbackFixture {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            XCTFail("expected a held composer, got \(outcome)")
            throw ReconcileFailure()
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        let fence = try XCTUnwrap(lane.composer.activeResolutionFence)
        let failureSwitch = try XCTUnwrap(failures)
        store.commitPublisher.setHandler { _ in
            // Only the restore commit: the change lands after it, and storage then fails.
            guard !failureSwitch.shouldFailWrites else { return }
            fence.noteComposerMutation()
            failureSwitch.shouldFailWrites = true
        }
        await latch.open()
        try await holder.value
        let result = await resolution.value
        store.commitPublisher.setHandler(nil)

        XCTAssertEqual(result, .success(nil), "the unreverted restore is kept visible, not adopted")
        let protected = try XCTUnwrap(lane.unsavedPredecessorInputs.first)
        XCTAssertEqual(protected.content, held.content)
        XCTAssertNotNil(protected.restoreRollback, "the visible copy carries the owed rollback")
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "the original draft is durable as the restored composer")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
        return FailedRollbackFixture(
            store: store,
            coordinator: coordinator,
            persistenceState: reset.persistenceState,
            lane: lane,
            held: held,
            protected: protected,
            gate: gate
        )
    }

    /// R02 same-binding hand-over: another owner claims the session while the rollback write still
    /// fails. The successor adopts the obligation; its typing never replaces the restored draft; once
    /// storage recovers its next flush rolls back, the draft is held again, the successor typing stays
    /// pending, and a relaunched store reads the original draft.
    func testSameBindingHandOverKeepsAFailedRollbackProtectedUntilTheSuccessorRollsItBack() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, held) = (fixture.store, fixture.held)
        fixture.lane.composerDidChange(Support.content("newer typing"))

        let second = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await second.restoreComposer()
        XCTAssertTrue(second.composer.isRestoredDraftAwaitingRollback, "the successor adopted the rollback obligation")
        XCTAssertEqual(second.unsavedPredecessorInputs.first, fixture.protected)
        XCTAssertEqual(second.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"], "newer typing stays visible")
        var stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")

        second.composerDidChange(Support.content("successor typing"))
        let failing = await second.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        XCTAssertNotNil(second.composer.lastWriteFailure, "the failure is visible for Retry")
        stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "successor typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await second.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("the successor rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(second.composerState, .held(held), "the draft is presented once, as held")
        XCTAssertFalse(second.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(second.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        XCTAssertTrue(second.composer.hasPendingChanges, "the successor typing stays in the message box")
        stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02 ownerless release and reclaim: the released lane's protected copy is published but cannot
    /// be discarded without a lane; the reclaiming lane adopts the obligation. Its explicit Discard is
    /// durable: while storage fails nothing is resolved (entry, protection, and stored copy kept,
    /// admission still blocked); once it commits the live typing replaces the copy and admission opens.
    func testOwnerlessReclaimKeepsAFailedRollbackProtectedAndDiscardResolvesItDurably() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator) = (fixture.store, fixture.coordinator)
        let sessionID = fixture.lane.sessionID
        await coordinator.releaseLane(fixture.lane).value
        let ownerless = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[sessionID])
        XCTAssertEqual(ownerless.inputs, [fixture.protected])
        XCTAssertFalse(
            coordinator.discardOwnerlessUnsavedInput(sessionID: sessionID, expected: fixture.protected),
            "only a lane resolves the protected copy, durably"
        )

        let reclaimed = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await reclaimed.restoreComposer()
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[sessionID])
        XCTAssertTrue(reclaimed.composer.isRestoredDraftAwaitingRollback, "the reclaiming lane adopted the obligation")
        XCTAssertEqual(reclaimed.unsavedPredecessorInputs, [fixture.protected])
        reclaimed.composerDidChange(Support.content("reclaimed typing"))

        let refused = await reclaimed.resolveUnsavedPredecessorInput(.discard, expected: fixture.protected, liveComposerIsEmpty: false)
        guard case .failure(.store) = refused else {
            return XCTFail("a discard that cannot be written resolves nothing, got \(refused)")
        }
        XCTAssertEqual(reclaimed.unsavedPredecessorInputs, [fixture.protected], "the copy stays until its resolution is durable")
        XCTAssertTrue(reclaimed.composer.isRestoredDraftAwaitingRollback)
        var stored = await store.read(sessionID: sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")
        let blocked = await reclaimed.admitQueued(admission(reclaimed, "blocked"))
        assertRefused(blocked, .unsavedPredecessorInput)

        failures.shouldFailWrites = false
        let discarded = await reclaimed.resolveUnsavedPredecessorInput(.discard, expected: fixture.protected, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        XCTAssertTrue(reclaimed.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(reclaimed.composer.isRestoredDraftAwaitingRollback)
        stored = await store.read(sessionID: sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "reclaimed typing", "the discard stored the live typing in its place")
        guard case .success = await reclaimed.admitQueued(admission(reclaimed, "after resolution")) else {
            return XCTFail("admission opens once the resolution is durable")
        }
    }

    /// R02: Restore of the protected copy into the empty composer is durable before protection ends;
    /// a failed write keeps the entry, the protection, and the stored copy.
    func testRestoringAProtectedCopyIntoTheComposerIsDurableBeforeProtectionEnds() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane) = (fixture.store, fixture.lane)
        let refused = await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        guard case .failure(.store) = refused else {
            return XCTFail("a restore that cannot be written resolves nothing, got \(refused)")
        }
        XCTAssertEqual(lane.unsavedPredecessorInputs, [fixture.protected])
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(lane.composer.pendingContent?.text ?? "", "", "the live composer is left empty as shown")

        failures.shouldFailWrites = false
        let restored = await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        XCTAssertEqual(restored, .success(fixture.held.content))
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertFalse(lane.composer.hasPendingChanges, "the placed draft is durable as the live composer")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content, fixture.held.content)
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
    }

    /// R02 rapid same-binding chain A→B→C while the rollback write still fails: B is replaced before
    /// its predecessor settlement runs (no suspension between the claims), so B is a transit-only,
    /// already-retired owner. B must still forward the obligation; C adopts it, C's typing never
    /// replaces the original, and once storage recovers C rolls back and the original is held again.
    func testRapidThreeOwnerChainForwardsAFailedRollbackThroughATransitOnlyOwner() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator, held) = (fixture.store, fixture.coordinator, fixture.held)
        fixture.lane.composerDidChange(Support.content("newer typing"))

        let transit = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        let third = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        XCTAssertTrue(transit.isRetired, "B retired before its predecessor settlement could run")

        _ = await third.restoreComposer()
        XCTAssertTrue(third.composer.isRestoredDraftAwaitingRollback, "C adopted the obligation forwarded through B")
        XCTAssertEqual(third.unsavedPredecessorInputs.first, fixture.protected)
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"], "newer typing stays visible")

        third.composerDidChange(Support.content("third owner typing"))
        let failing = await third.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        var stored = await store.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "C's typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await third.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("C rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(third.composerState, .held(held))
        XCTAssertFalse(third.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        XCTAssertTrue(third.composer.hasPendingChanges, "C's typing stays in the message box")
        stored = await store.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02-R1 in-flight transfer: a successor claims the session while the held restore (and so its
    /// failing rollback) is still in flight. The retired lane never appends the protected copy, so its
    /// retirement must carry the obligation created during that resolution; the successor adopts it,
    /// its typing never replaces the original, and once storage recovers the original is held again.
    func testSuccessorClaimedWhileAHeldRestoreIsInFlightInheritsItsFailedRollback() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("expected a held composer, got \(outcome)")
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        let fence = try XCTUnwrap(lane.composer.activeResolutionFence)
        let failureSwitch = try XCTUnwrap(failures)
        store.commitPublisher.setHandler { _ in
            guard !failureSwitch.shouldFailWrites else { return }
            fence.noteComposerMutation()
            failureSwitch.shouldFailWrites = true
        }

        let successor = try coordinator.claimLane(owner: Owner(), persistenceState: reset.persistenceState)
        XCTAssertTrue(lane.isRetired, "the original lane retired while its restore is in flight")
        await latch.open()
        try await holder.value
        _ = await resolution.value
        store.commitPublisher.setHandler(nil)
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "the restore committed and its rollback failed")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)

        _ = await successor.restoreComposer()
        XCTAssertTrue(successor.composer.isRestoredDraftAwaitingRollback, "the in-flight obligation reached the successor")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["held draft"])
        XCTAssertEqual(successor.unsavedPredecessorInputs.first?.restoreRollback, successor.composer.outstandingRestoreRollback)

        successor.composerDidChange(Support.content("successor typing"))
        let failing = await successor.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "successor typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await successor.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("the successor rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertTrue(successor.unsavedPredecessorInputs.isEmpty)
        XCTAssertEqual(successor.composer.pendingContent?.text, "successor typing")
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// Starts a protected Restore whose placement write is captured and then suspended on the held
    /// gate (the controller clears its write deadline when it captures the snapshot), changes the
    /// composer (newer typing by default), runs `beforeRelease`, and releases the gate.
    private func restoreProtectedCopyWithTypingDuringItsWrite(
        _ fixture: FailedRollbackFixture,
        change: @MainActor (AgentRecoverySessionLane) -> Void = { $0.composerDidChange(Support.content("newer typing")) },
        beforeRelease: @MainActor () -> Void = {}
    ) async throws -> Result<AgentRecoveryInputContent?, AgentRecoveryControllerFailure> {
        let lane = fixture.lane
        let gate = fixture.gate
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let restore = Task { @MainActor in
            await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        }
        let placed = await Support.eventually { lane.composer.pendingContent == fixture.held.content }
        XCTAssertTrue(placed, "the placement is staged")
        let suspended = await Support.eventually { lane.composer.maximumDelayDeadline == nil }
        XCTAssertTrue(suspended, "the placement write captured its snapshot and waits for the gate")
        change(lane)
        beforeRelease()
        await latch.open()
        try await holder.value
        return await restore.value
    }

    /// R02-R2, failed write: newer typing during the suspended placement write is never cleared; the
    /// protection and the stored original stay; a handover after storage recovers keeps both.
    func testNewerTypingDuringAFailedProtectedRestoreWriteSurvivesRetryAndHandOver() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture)
        guard case .failure(.store) = result else {
            return XCTFail("the placement write fails on storage, got \(result)")
        }
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing", "a failure never clears newer typing")
        XCTAssertEqual(lane.unsavedPredecessorInputs, [fixture.protected])
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")

        failures.shouldFailWrites = false
        let successor = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composerState, .held(held), "the retiring flush rolled the original back to the held slot")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"], "the newer typing is handed over")
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
    }

    /// R02-R2, committed write: newer typing during the suspended placement write never yields
    /// success or a stale placement; the committed placement goes back to the held slot, the typing
    /// stays pending, and a retry and a handover keep both.
    func testNewerTypingDuringACommittedProtectedRestoreWriteNeverAdoptsTheStalePlacement() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture)
        XCTAssertEqual(result, .failure(.composerChangedDuringRestore), "no stale placement is returned")
        XCTAssertEqual(lane.composerState, .held(held), "the original is held again")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let retried = await lane.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = retried else {
            return XCTFail("the typing waits behind the held draft, got \(retried)")
        }
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        let successor = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02-R2 fence: an image awaiting promotion (not representable, so no new live revision) during
    /// the suspended placement write still trips the placement fence. The committed placement is put
    /// back, no stale placement is returned, and the pending attachment obligation is kept.
    func testUnrepresentableChangeDuringAProtectedRestoreWriteNeverAdoptsTheStalePlacement() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture, change: { $0.composerContentUnrepresentable() })
        XCTAssertEqual(result, .failure(.composerChangedDuringRestore), "no stale placement is returned")
        XCTAssertEqual(lane.composerState, .held(held), "the original is held again")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertTrue(lane.hasUnrepresentableComposerEdit, "the pending attachment obligation is kept")
        XCTAssertEqual(lane.composer.pendingContent?.text ?? "", "", "the never-placed content is not left pending")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(persisted, held)
    }

    /// R02-R2 (B R3-2): the placement commits, typing raced it, and the put-back fails. The committed
    /// placement becomes the protected revision (a new obligation) carried by the visible copy and
    /// across a hand-over; once storage recovers the successor rolls it back to the held slot.
    func testCommittedPlacementWhosePutBackFailsStaysProtectedAcrossHandOver() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator, lane, held) = (fixture.store, fixture.coordinator, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let failureSwitch = try XCTUnwrap(failures)
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture, beforeRelease: {
            store.commitPublisher.setHandler { _ in
                // Only the placement commit: storage fails for the put-back that follows.
                failureSwitch.shouldFailWrites = true
            }
        })
        store.commitPublisher.setHandler(nil)
        guard case .failure(.store) = result else {
            return XCTFail("the put-back fails on storage, got \(result)")
        }
        let renewed = try XCTUnwrap(lane.composer.outstandingRestoreRollback, "the committed placement is protected")
        XCTAssertNotEqual(renewed, fixture.protected.restoreRollback)
        XCTAssertEqual(lane.unsavedPredecessorInputs.map(\.restoreRollback), [renewed], "the visible copy carries the new obligation")
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.revision, renewed.restoredRevision, "the placement is the stored protected revision")
        XCTAssertEqual(stored?.content, held.content)

        let successor = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composer.outstandingRestoreRollback, renewed, "the successor adopted the new obligation")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored?.revision, renewed.restoredRevision)

        failures.shouldFailWrites = false
        let recovered = await successor.flushComposer()
        XCTAssertEqual(recovered, .nothingPending, "the rollback succeeds with nothing pending in the successor")
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    // MARK: Recovery catalog (Phase 2)

    /// Saved questions are catalog items once their request ended (an earlier launch's, or this
    /// launch's after a preserving end); a live one stays in its live card only. Dismiss is durable
    /// through the live lane and removes nothing.
    func testCatalogListsEndedQuestionsExcludesLiveOnesAndDismissesDurably() async throws {
        let earlierStore = makeStore()
        let earlierService = makeService(store: earlierStore)
        let load = try await makeSession(earlierService)
        let earlier = try await startedCoordinator(store: earlierStore, service: earlierService)
        let earlierLane = try earlier.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let earlierQuestion = questionSnapshot(earlierStore)
        _ = try await earlierLane.questionPersistence.commitCreation(earlierQuestion).get()

        let store = makeStore()
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let sessionID = load.session.id
        let earlierItemID = "question-\(sessionID.uuidString)-\(earlierQuestion.interactionID.uuidString)"
        let listed = try XCTUnwrap(coordinator.catalog.item(id: earlierItemID))
        XCTAssertEqual(listed.kind, .unansweredQuestion)
        XCTAssertEqual(listed.payload, .question(earlierQuestion, isCurrentLaunch: false))
        XCTAssertFalse(listed.isDismissed)
        XCTAssertEqual(coordinator.catalog.bannerItems(sessionID: sessionID, workspaceID: workspace.id).map(\.id), [earlierItemID])

        // This launch's live question is never a recovery item while its request is live.
        let owner = Owner()
        let reloaded = try await service.loadAgentSessionForEditing(id: sessionID, for: workspace)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: XCTUnwrap(reloaded?.persistenceState))
        _ = await lane.restoreComposer()
        let liveQuestion = questionSnapshot(store)
        _ = try await lane.questionPersistence.commitCreation(liveQuestion).get()
        let liveItemID = "question-\(sessionID.uuidString)-\(liveQuestion.interactionID.uuidString)"
        let committed = await Support.eventually {
            guard case let .supported(record)? = coordinator.liveRecordState(for: sessionID) else { return false }
            return record.questions.count == 2
        }
        XCTAssertTrue(committed)
        XCTAssertNil(coordinator.catalog.item(id: liveItemID), "A live question stays in its live card")

        // Its request ends without an answer (window close): it becomes historical now.
        lane.questionPersistence.end([liveQuestion.interactionID], preserving: true)
        let ended = try XCTUnwrap(coordinator.catalog.item(id: liveItemID))
        XCTAssertEqual(ended.payload, .question(liveQuestion, isCurrentLaunch: true))

        // Dismiss writes only the acknowledgement; the question is kept and stays listable.
        let failure = await coordinator.dismissCatalogItem(listed)
        XCTAssertNil(failure)
        let dismissed = await Support.eventually { coordinator.catalog.item(id: earlierItemID)?.isDismissed == true }
        XCTAssertTrue(dismissed)
        XCTAssertFalse(coordinator.catalog.bannerItems(sessionID: sessionID, workspaceID: workspace.id).contains { $0.id == earlierItemID })
        XCTAssertEqual(coordinator.catalog.needsAttentionItems(includeDismissed: true).count { $0.id == earlierItemID }, 1)
        let stored = await store.read(sessionID: sessionID).record
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(Set(record.questions.map(\.interactionID)), [earlierQuestion.interactionID, liveQuestion.interactionID])
        XCTAssertEqual(record.cardAcknowledgements.map(\.key.kind), [.question])

        // A repeated Dismiss of the same state succeeds without another write.
        let revision = record.revision
        let repeated = await coordinator.dismissCatalogItem(listed)
        XCTAssertNil(repeated)
        let unchanged = await store.read(sessionID: sessionID).record?.revision
        XCTAssertEqual(unchanged, revision)
    }

    /// Review A F05: a closed session whose record holds only a saved draft is discoverable from
    /// that record, by composer revision. While a live lane owns the session its composer state
    /// represents the draft instead; when the lane is released the record lists it again.
    func testCatalogListsDurableDraftsOfSessionsWithoutALiveLane() async throws {
        let earlierStore = makeStore()
        let earlierService = makeService(store: earlierStore)
        let load = try await makeSession(earlierService)
        let earlier = try await startedCoordinator(store: earlierStore, service: earlierService)
        let earlierLane = try earlier.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await earlierLane.restoreComposer()
        earlierLane.composerDidChange(Support.content("draft left in a closed session"))
        guard case .committed = await earlierLane.flushComposer() else {
            return XCTFail("the draft is saved")
        }
        let saved = await earlierStore.read(sessionID: load.session.id).record?.composer
        let snapshot = try XCTUnwrap(saved)

        let store = makeStore()
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let sessionID = load.session.id
        let itemID = AgentRecoveryCatalogProjection.heldDraftItemID(sessionID: sessionID, revision: snapshot.revision)
        let listed = try XCTUnwrap(coordinator.catalog.item(id: itemID), "a draft-only closed session is listed")
        XCTAssertEqual(listed.kind, .savedDraft)
        XCTAssertEqual(listed.payload, .closedSessionDraft(snapshot, fromClearedConversation: false))
        XCTAssertEqual(listed.workspaceID, workspace.id, "Open routes to its workspace")
        XCTAssertEqual(listed.acknowledgement?.key.entityID, String(describing: snapshot.revision))

        // A live lane's composer represents it while the session is open.
        let reloaded = try await service.loadAgentSessionForEditing(id: sessionID, for: workspace)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: XCTUnwrap(reloaded?.persistenceState))
        _ = await lane.restoreComposer()
        let represented = await Support.eventually { coordinator.catalog.item(id: itemID) == nil }
        XCTAssertTrue(represented, "no duplicate row while the lane owns the composer")

        // Released (the tab closed): the durable record lists it again.
        await coordinator.releaseLane(lane).value
        let relisted = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(relisted)
        guard case .closedSessionDraft(snapshot, fromClearedConversation: false)? = coordinator.catalog.item(id: itemID)?.payload else {
            return XCTFail("the same saved draft, by its revision")
        }
    }

    /// Review R1 (A P2): a session created this launch (absent from the startup results) and then
    /// closed keeps its compose tab with its workspace, so its durable items offer Open.
    func testClosedSessionOfThisLaunchKeepsItsComposeTabForOpen() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let load = try await makeSession(service)
        let sessionID = load.session.id
        XCTAssertNil(coordinator.reconciliation.resolution(for: sessionID), "not in the startup results")
        let tab = AgentTabSession(tabID: UUID())
        let lane = try coordinator.claimLane(owner: tab, persistenceState: load.persistenceState)
        _ = await lane.restoreComposer()
        lane.composerDidChange(Support.content("draft of a closed new session"))
        guard case .committed = await lane.flushComposer() else {
            return XCTFail("the draft is saved")
        }
        let saved = await store.read(sessionID: sessionID).record?.composer
        let snapshot = try XCTUnwrap(saved)

        await coordinator.releaseLane(lane).value
        XCTAssertEqual(coordinator.knownComposeTabID(for: sessionID), tab.tabID)
        let itemID = AgentRecoveryCatalogProjection.heldDraftItemID(sessionID: sessionID, revision: snapshot.revision)
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed, "the closed session's saved draft is listed")
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(item.workspaceID, workspace.id)
        XCTAssertEqual(item.composeTabID, tab.tabID, "Open targets the session's compose tab")
    }

    /// Review A F04 / B F1: a run of this launch that ends after startup with an interruption cause
    /// (provider process loss) is listed from the current committed record, by run attempt, on
    /// the latest turn it dispatched into: a steer's own turn, not the run's opening turn. An
    /// ordinary terminal is never listed, and an active run has no terminal evidence to list.
    func testCatalogListsLiveRunInterruptionsAfterStartupOnTheSteeredTurn() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let sessionID = load.session.id

        // An ordinary failure of another run is not an interruption.
        let ordinary = Support.ownership(sessionID: sessionID)
        let ordinaryTurnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ordinary, processRunID: nil, transcriptTurnID: ordinaryTurnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ordinary, state: .failed, cause: .ordinary),
            transcriptTurnID: ordinaryTurnID
        ).value

        // The interrupted run: opened on one turn, then steered into a second one.
        let ownership = Support.ownership(sessionID: sessionID)
        let openingTurnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: openingTurnID, providerKindRaw: nil).get()
        XCTAssertNil(coordinator.catalog.item(id: "turn-\(sessionID.uuidString)-\(openingTurnID.uuidString)"), "An active run is never listed")
        let steer = try await lane.admitQueued(admission(lane, "steer")).get()
        _ = try await lane.beginDispatch(
            intentID: steer.receipt.intent.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: ownership.attemptID),
            authorization: .liveQueue
        ).get()
        let steerTurnID = steer.admission.userItemID
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: steerTurnID
        ).value

        let itemID = "turn-\(sessionID.uuidString)-\(steerTurnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed, "listed on the steered turn the terminal closed")
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(item.kind, .interruptedTurn)
        guard case let .turn(turn) = item.payload else { return XCTFail("a turn row, got \(item.payload)") }
        XCTAssertEqual(turn.turnID, steerTurnID)
        XCTAssertEqual(turn.interruption.reason, .providerProcessLost)
        XCTAssertEqual(turn.interruption.runAttemptID, ownership.attemptID)
        XCTAssertTrue(turn.status.isInterruption)
        XCTAssertEqual(item.acknowledgement?.key.entityID, ownership.attemptID.uuidString, "Identified by its run attempt")

        let runItems = coordinator.catalog.needsAttentionItems(includeDismissed: true).filter {
            $0.sessionID == sessionID && ($0.id.hasPrefix("turn-") || $0.id.hasPrefix("run-"))
        }
        XCTAssertEqual(runItems.map(\.id), [itemID], "Neither the opening turn nor the ordinary failure is listed")
    }

    /// A Dismiss of an item whose displayed state no longer matches is refused (never applied to the
    /// changed item), and a non-dismissible item offers no acknowledgement.
    func testCatalogDismissRefusesChangedAndNonDismissibleItems() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let question = questionSnapshot(store)
        _ = try await lane.questionPersistence.commitCreation(question).get()
        lane.questionPersistence.end([question.interactionID], preserving: true)
        let itemID = "question-\(load.session.id.uuidString)-\(question.interactionID.uuidString)"
        let present = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(present)
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        let itemKey = try XCTUnwrap(item.acknowledgement).key
        let changed = AgentRecoveryCatalogItem(
            id: item.id,
            kind: item.kind,
            sessionID: item.sessionID,
            workspaceID: item.workspaceID,
            sessionName: item.sessionName,
            composeTabID: item.composeTabID,
            payload: item.payload,
            acknowledgement: AgentRecoveryCatalogAcknowledgement(
                key: itemKey,
                freshness: AgentRecoveryCardFreshness("an older state"),
                isAcknowledged: false
            )
        )
        let refusal = await coordinator.dismissCatalogItem(changed)
        XCTAssertEqual(refusal, "This item changed. Review it again.")
        let nonDismissible = AgentRecoveryCatalogItem(
            id: "workspace-x", kind: .statusUnknown, sessionID: nil, workspaceID: workspace.id, sessionName: nil,
            composeTabID: nil, payload: .workspaceFailure(reason: "x"), acknowledgement: nil
        )
        let notOffered = await coordinator.dismissCatalogItem(nonDismissible)
        XCTAssertNotNil(notOffered)
        let record = await store.read(sessionID: load.session.id).record
        XCTAssertEqual(record?.cardAcknowledgements.count ?? 0, 0, "Nothing was written")
    }

    // MARK: Attention classification (Step 8-attention, O34-3)

    /// Every payload's class: run cards are informational notes, everything else needs action
    /// (including a closed session's draft and an unchecked schedule index). The classifier's switch
    /// is exhaustive, so this table covers every case that compiles.
    func testCatalogAttentionClassifiesEveryPayload() {
        let id = UUID()
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        let run = AgentRecoveryRunAttempt(runAttemptID: id, transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: nil, startedAt: stamp)
        let turn = AgentRecoveryInterruptedTurn(
            turnID: id,
            interruption: AgentTranscriptTurnInterruption(reason: .appCrash, observedAt: stamp.date, runAttemptID: id),
            status: .interrupted,
            isLastTurn: true
        )
        let intent = AgentRecoveryIntent(
            intentID: id, userItemID: id, origin: .composer, target: .session, createdAt: stamp, appInstanceID: id,
            transcriptResetGeneration: 0, deliveryState: .queued, payload: Support.content("saved"), scheduleReference: nil
        )
        let question = AgentRecoveryQuestionSnapshot(
            interactionID: id, kind: .askUser, runAttemptID: id, transcriptResetGeneration: 0, appInstanceID: id,
            askedAt: stamp, title: "Question", message: nil, items: [], extras: [:]
        )
        let proposal = AgentRecoveryEditProposal(
            reviewID: id, runAttemptID: id, transcriptResetGeneration: 0, appInstanceID: id, proposedAt: stamp,
            physicalPath: "/tmp/a.txt", displayPath: "a.txt", unifiedDiff: "", proposedText: "b", base: .preview(originalText: nil)
        )
        let unsaved = AgentRecoveryUnsavedComposerInput(
            binding: AgentRecoveryLifecycleBinding(sessionID: id, incarnationID: id, transcriptResetGeneration: 0),
            content: Support.content("unsaved"),
            failure: nil
        )
        let summary = AgentScheduledSendConfirmationSummary(
            sessionID: id, tabID: nil, workspaceID: id, scheduleID: id, attemptID: nil, reason: nil, notBefore: stamp.date, previewText: "later"
        )
        let restriction = AgentRuntimeRestriction(
            runtimeID: id, kind: .possibleWriter, family: nil, provider: nil, state: .reserved, isPreviousInstance: true,
            isUnreadable: false, providerHome: nil, conversationIDs: [], worktreePaths: [], sessionIDs: [id], associations: [],
            rootPID: nil, memberCount: 0, letFinish: false, revision: nil, createdAt: nil
        )
        let table: [(String, AgentRecoveryCatalogPayload, AgentRecoveryCatalogAttention)] = [
            ("workspaceFailure", .workspaceFailure(reason: "x"), .needsAction),
            ("nonactionable", .nonactionable(.authorityMismatch), .needsAction),
            ("duplicateDestination", .duplicateDestination, .needsAction),
            ("noDestination", .noDestination, .needsAction),
            ("crashHold", .crashHold(AgentRecoveryCrashHold(
                sessionID: id, incarnationID: id, transcriptResetGeneration: 0,
                uncertainRunAttemptIDs: [id], uncertainIntentIDs: [], previousExitProvenClean: false
            )), .needsAction),
            ("scheduleTransfer", .scheduleTransfer(message: "held"), .needsAction),
            ("turn", .turn(turn), .informational),
            ("outcomeTurn", .outcomeTurn(AgentRecoveryOutcomeTurn(turnID: id, runAttempt: run)), .informational),
            ("recoveryOnlyRun", .recoveryOnlyRun(run), .informational),
            ("intent", .intent(intent, AgentRecoveryCatalogIntentContext(isEarlierLaunch: true, heldReason: nil, sameGeneration: true, isRemote: false)), .needsAction),
            ("question", .question(question, isCurrentLaunch: false), .needsAction),
            ("editProposal", .editProposal(proposal, isCurrentLaunch: false), .needsAction),
            ("heldDraft", .heldDraft(Support.snapshot("held")), .needsAction),
            ("closedSessionDraft", .closedSessionDraft(Support.snapshot("closed"), fromClearedConversation: false), .needsAction),
            ("composerRestoreFailed", .composerRestoreFailed(.retired), .needsAction),
            ("unsavedPredecessor", .unsavedPredecessor(unsaved, count: 1), .needsAction),
            ("composerWriteFailed", .composerWriteFailed(.retired), .needsAction),
            ("ownerlessDraft", .ownerlessDraft(unsaved), .needsAction),
            ("composerPreparationFailed", .composerPreparationFailed(.ownerReplaced), .needsAction),
            ("questionSaveFailed", .questionSaveFailed(nil, unsentAnswer: true), .needsAction),
            ("scheduleNeedsConfirmation", .scheduleNeedsConfirmation(summary), .needsAction),
            ("scheduleIndexUnavailable", .scheduleIndexUnavailable(workspaceName: "W"), .needsAction),
            ("survivingRuntime", .survivingRuntime(restriction), .needsAction),
            ("runtimeOwnershipUnknown", .runtimeOwnershipUnknown(unidentifiedRecordCount: 1, failure: nil), .needsAction)
        ]
        XCTAssertEqual(table.count, 24, "one row per payload case")
        let unfinished = AgentRecoveryCatalogActionFacts(hasUnfinishedAction: true)
        let unsent = AgentRecoveryCatalogActionFacts(hasUnsentContinuation: true)
        for (name, payload, expected) in table {
            XCTAssertEqual(AgentRecoveryCatalogProjection.attention(for: payload, facts: AgentRecoveryCatalogActionFacts()), expected, name)
            // An unfinished recovery action or an unsent typed continuation makes a run card need
            // action and never downgrades others.
            XCTAssertEqual(AgentRecoveryCatalogProjection.attention(for: payload, facts: unfinished), .needsAction, name)
            XCTAssertEqual(AgentRecoveryCatalogProjection.attention(for: payload, facts: unsent), .needsAction, name)
        }
        // Other facts never promote a run note.
        let resolved = AgentRecoveryCatalogActionFacts(resolvedByAction: true, runNeverHandedOff: true)
        XCTAssertEqual(AgentRecoveryCatalogProjection.attention(for: .recoveryOnlyRun(run), facts: resolved), .informational)
    }

    /// A run card is a note until a recovery action reserved on it has no recorded outcome ("Resume
    /// was interrupted; status unknown"); once the outcome is recorded it is a note again. Dismissed
    /// and informational items are never counted as open needs-action items.
    func testRunCardWithAnUnfinishedRecoveryActionNeedsAction() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let sessionID = load.session.id

        let ownership = Support.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        let note = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(note.attention, .informational)
        XCTAssertFalse(note.isOpenNeedsAction)
        XCTAssertFalse(coordinator.catalog.items.contains { $0.sessionID == sessionID && $0.isOpenNeedsAction })
        XCTAssertEqual(coordinator.catalog.openNeedsActionCount, 0, "\(coordinator.catalog.items.map { "\($0.id) \($0.attention)" })")

        // A reserved action without an outcome makes the card need action.
        let key = try XCTUnwrap(note.acknowledgement?.key)
        let revision = try await store.currentRevision(sessionID: sessionID)
        let request = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: .reconcileOnly,
            expectedRevision: revision,
            sourceRunAttemptID: ownership.attemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")
        )
        _ = try await lane.reserveRecoveryAction(request).get()
        let promoted = await Support.eventually { coordinator.catalog.item(id: itemID)?.attention == .needsAction }
        XCTAssertTrue(promoted)
        let open = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertTrue(open.actionFacts.hasUnfinishedAction)
        XCTAssertTrue(open.isOpenNeedsAction)
        XCTAssertEqual(coordinator.catalog.openNeedsActionCount, 1)

        // Its recorded outcome makes it a note again.
        _ = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: .importedUnconfirmed, reason: nil).get()
        let settled = await Support.eventually { coordinator.catalog.item(id: itemID)?.attention == .informational }
        XCTAssertTrue(settled)
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.actionFacts.hasUnfinishedAction, false)
        XCTAssertEqual(coordinator.catalog.openNeedsActionCount, 0)
    }

    /// Review B ATT1-3: the action's shared hold pauses the session from before its reservation is
    /// written; the card it acts on needs action for the whole hold, not only once reserved.
    func testRunCardNeedsActionWhileARecoveryActionHoldsItsSession() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let sessionID = load.session.id
        let ownership = Support.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        let note = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(note.attention, .informational)

        let request = try await AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: XCTUnwrap(note.acknowledgement?.key),
            kind: .reconcileOnly,
            expectedRevision: store.currentRevision(sessionID: sessionID),
            sourceRunAttemptID: ownership.attemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")
        )
        guard case let .acquired(authorization) = coordinator.beginRecoveryAction(request, lane: lane) else {
            return XCTFail("the hold is acquired")
        }
        XCTAssertTrue(coordinator.isCoveredByRecoveryAction(sessionID: sessionID))
        let held = try XCTUnwrap(coordinator.catalog.item(id: itemID), "nothing is reserved yet")
        XCTAssertEqual(held.attention, .needsAction)
        XCTAssertTrue(held.actionFacts.hasUnfinishedAction)
        let reserved = await store.read(sessionID: sessionID).record?.actions ?? []
        XCTAssertTrue(reserved.isEmpty, "the hold alone, before any reservation")

        coordinator.revokeRecoveryAction(authorization)
        coordinator.endRecoveryAction(authorization)
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.attention, .informational)
    }

    /// An interrupted run's card (informational) on a claimed lane, for the continuation tests.
    @MainActor
    private struct RunCardFixture {
        let store: AgentRecoveryStore
        let coordinator: AgentRecoveryCoordinator
        let lane: AgentRecoverySessionLane
        let sessionID: UUID
        let attemptID: UUID
        let itemID: String
        let key: AgentRecoveryCardKey
        let load: AgentSessionEditableLoad
        let service: AgentSessionDataService
        let target = AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")

        var item: AgentRecoveryCatalogItem? {
            coordinator.catalog.item(id: itemID)
        }

        func request(
            text: String? = nil,
            plannedUserItemID: UUID? = nil,
            supersedesActionID: UUID? = nil
        ) async throws -> AgentRecoveryActionRequest {
            try await AgentRecoveryActionRequest(
                actionID: UUID(),
                itemKey: key,
                kind: text == nil ? .reconcileOnly : .continueWithText,
                expectedRevision: store.currentRevision(sessionID: sessionID),
                sourceRunAttemptID: attemptID,
                target: target,
                text: text,
                plannedUserItemID: text == nil ? nil : (plannedUserItemID ?? UUID()),
                supersedesActionID: supersedesActionID
            )
        }

        /// Reserves `request` and records `outcome`, returning once the catalog reflects the outcome.
        func perform(_ request: AgentRecoveryActionRequest, outcome: AgentRecoveryActionOutcomeKind) async throws {
            _ = try await lane.reserveRecoveryAction(request).get()
            _ = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: outcome, reason: nil).get()
            let adopted = await waitForRecord { $0.action(id: request.actionID)?.outcome != nil }
            XCTAssertTrue(adopted, "the outcome reached the coordinator's live record")
        }

        /// Waits until the coordinator adopted a record commit satisfying `condition` (adoption and
        /// catalog invalidation happen together, so the catalog then reflects it).
        func waitForRecord(_ condition: @escaping (AgentRecoveryRecord) -> Bool) async -> Bool {
            await Support.eventually {
                guard case let .supported(record)? = coordinator.liveRecordState(for: sessionID) else { return false }
                return condition(record)
            }
        }
    }

    private func makeRunCardFixture() async throws -> RunCardFixture {
        try await makeRunCardFixtures(count: 1)[0]
    }

    /// `count` sessions' informational run cards on one coordinator (sessions saved before startup).
    private func makeRunCardFixtures(count: Int) async throws -> [RunCardFixture] {
        let store = makeStore()
        let service = makeService(store: store)
        var loads: [AgentSessionEditableLoad] = []
        for _ in 0 ..< count {
            try await loads.append(makeSession(service))
        }
        let coordinator = try await startedCoordinator(store: store, service: service)
        var fixtures: [RunCardFixture] = []
        for load in loads {
            try await fixtures.append(addRunCard(load: load, store: store, service: service, coordinator: coordinator))
        }
        return fixtures
    }

    private func addRunCard(
        load: AgentSessionEditableLoad,
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        coordinator: AgentRecoveryCoordinator
    ) async throws -> RunCardFixture {
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let sessionID = load.session.id
        let ownership = Support.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(item.attention, .informational)
        return try RunCardFixture(
            store: store,
            coordinator: coordinator,
            lane: lane,
            sessionID: sessionID,
            attemptID: ownership.attemptID,
            itemID: itemID,
            key: XCTUnwrap(item.acknowledgement?.key),
            load: load,
            service: service
        )
    }

    /// Records a typed continuation as not sent, with no saved intent holding its text.
    private func recordUnsentContinuation(_ fixture: RunCardFixture, plannedUserItemID: UUID = UUID()) async throws {
        let continuation = try await fixture.request(text: "please continue from the last step", plannedUserItemID: plannedUserItemID)
        try await fixture.perform(continuation, outcome: .notDispatched)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertTrue(item.actionFacts.hasUnsentContinuation)
        XCTAssertEqual(item.actionFacts.unsentContinuationText, "please continue from the last step", "9-live R4b: the typed text itself")
        XCTAssertFalse(item.actionFacts.hasUnfinishedAction)
        XCTAssertFalse(item.actionFacts.resolvedByAction)
        XCTAssertEqual(item.attention, .needsAction)
        XCTAssertEqual(fixture.coordinator.catalog.openNeedsActionCount, 1)
    }

    /// Review B ATT1-1 / A ATT1-R1-1: a typed continuation recorded as not sent, whose text never
    /// became a saved intent, keeps the run card needing action (the text exists only on the
    /// action). A later Reconcile that does not resolve the card only checked history: neither a
    /// failed (`notDispatched`) nor an unconfirmed (`importedUnconfirmed`) one discards the text.
    func testRunCardWithAnUnsentContinuationNeedsAction() async throws {
        let fixture = try await makeRunCardFixture()
        try await recordUnsentContinuation(fixture)

        for outcome in [AgentRecoveryActionOutcomeKind.notDispatched, .importedUnconfirmed] {
            try await fixture.perform(fixture.request(), outcome: outcome)
            let item = try XCTUnwrap(fixture.item)
            XCTAssertTrue(item.actionFacts.hasUnsentContinuation, "\(outcome)")
            XCTAssertEqual(
                item.actionFacts.unsentContinuationText,
                "please continue from the last step",
                "a later textless Reconcile never replaces the typed text: \(outcome)"
            )
            XCTAssertFalse(item.actionFacts.hasUnfinishedAction, "\(outcome)")
            XCTAssertEqual(item.attention, .needsAction, "\(outcome)")
            XCTAssertEqual(fixture.coordinator.catalog.openNeedsActionCount, 1, "\(outcome)")
        }

        // Review B ATT1-R2-5: empty text is no typed text (the store refuses it; decoded records may
        // still carry it).
        let emptyText = AgentRecoveryAction(
            actionID: UUID(),
            itemKey: fixture.key,
            kindRaw: AgentRecoveryActionKind.continueWithText.rawValue,
            expectedRevision: nil,
            incarnationID: fixture.key.incarnationID,
            transcriptResetGeneration: 0,
            sourceIntentIDs: [],
            sourceRunAttemptID: fixture.attemptID,
            sourceInteractionID: nil,
            target: fixture.target,
            text: "",
            plannedUserItemID: UUID(),
            appInstanceID: UUID(),
            reservedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            outcome: AgentRecoveryActionOutcome(kind: .notDispatched, reason: nil, recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000))
        )
        let emptyTextRecord = AgentRecoveryRecord(
            sessionID: fixture.sessionID,
            revision: .make(),
            incarnationID: fixture.key.incarnationID,
            transcriptResetGeneration: 0,
            updatedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000),
            composer: nil,
            intents: [],
            attempts: [],
            runAttempts: [],
            actions: [emptyText]
        )
        XCTAssertFalse(emptyTextRecord.hasUnsentContinuation(for: fixture.key))
        XCTAssertNil(emptyTextRecord.unsentContinuationText(for: fixture.key))
    }

    /// 9-live R4b: a newer unsent typed continuation decides the text over an older unsent one.
    func testUnsentContinuationTextIsTheNewestUnsentTypedText() async throws {
        let fixture = try await makeRunCardFixture()
        try await recordUnsentContinuation(fixture)

        try await fixture.perform(fixture.request(text: "continue, second try"), outcome: .notDispatched)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertTrue(item.actionFacts.hasUnsentContinuation)
        XCTAssertEqual(item.actionFacts.unsentContinuationText, "continue, second try")
    }

    /// Review A/B ATT1-R2-2 (a): a previous launch's typed continuation that never got an outcome,
    /// replaced by a textless Reconcile of this launch that does not resolve the card, is unsent
    /// text: the card needs action through it, not through an unfinished action.
    func testSupersededOutcomelessContinuationStaysUnsentAfterAnUnresolvingReconcile() async throws {
        let fixture = try await makeRunCardFixture()
        // The earlier launch: another store instance on the same recovery root.
        let earlierStore = makeStore()
        let continuation = try await fixture.request(text: "please continue from the last step")
        let binding = fixture.lane.binding
        _ = try await earlierStore.reserveRecoveryAction(binding: binding, request: continuation)

        let superseding = try await fixture.request(supersedesActionID: continuation.actionID)
        try await fixture.perform(superseding, outcome: .notDispatched)
        for outcome in [AgentRecoveryActionOutcomeKind.notDispatched, .importedUnconfirmed] {
            if outcome == .importedUnconfirmed {
                try await fixture.perform(fixture.request(), outcome: outcome)
            }
            let record = await fixture.store.read(sessionID: fixture.sessionID).record
            XCTAssertNotNil(record?.action(id: continuation.actionID), "the old continuation is kept")
            XCTAssertNil(record?.action(id: continuation.actionID)?.outcome, "the old continuation has no outcome")
            let item = try XCTUnwrap(fixture.item)
            XCTAssertTrue(item.actionFacts.hasUnsentContinuation, "\(outcome)")
            XCTAssertEqual(item.actionFacts.unsentContinuationText, "please continue from the last step", "\(outcome)")
            XCTAssertFalse(item.actionFacts.hasUnfinishedAction, "\(outcome)")
            XCTAssertEqual(item.attention, .needsAction, "\(outcome)")
        }
    }

    /// Review A/B ATT1-R2-2 (b): an open typed continuation is not "unsent"; the card needs action
    /// only through its unfinished action.
    func testOpenContinuationNeedsActionOnlyThroughItsUnfinishedAction() async throws {
        let fixture = try await makeRunCardFixture()
        let continuation = try await fixture.request(text: "please continue from the last step")
        _ = try await fixture.lane.reserveRecoveryAction(continuation).get()
        let adopted = await fixture.waitForRecord { $0.action(id: continuation.actionID) != nil }
        XCTAssertTrue(adopted)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertFalse(item.actionFacts.hasUnsentContinuation)
        XCTAssertNil(item.actionFacts.unsentContinuationText)
        XCTAssertTrue(item.actionFacts.hasUnfinishedAction)
        XCTAssertEqual(item.attention, .needsAction)
    }

    /// Review A/B ATT1-R2-2 (c): a newer typed continuation that was sent decides the card over an
    /// older unsent one.
    func testNewerSentContinuationClearsAnOlderUnsentOne() async throws {
        let fixture = try await makeRunCardFixture()
        try await recordUnsentContinuation(fixture)

        try await fixture.perform(fixture.request(text: "continue, second try"), outcome: .dispatched)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertFalse(item.actionFacts.hasUnsentContinuation)
        XCTAssertNil(item.actionFacts.unsentContinuationText)
        XCTAssertTrue(item.actionFacts.resolvedByAction)
        XCTAssertEqual(item.attention, .informational)
    }

    /// A saved intent carrying the continuation's text (its planned transcript item) holds the
    /// text: the run card is a note again (the intent's own item asks for the decision).
    func testUnsentContinuationClearsWhenASavedIntentCarriesItsText() async throws {
        let fixture = try await makeRunCardFixture()
        let plannedUserItemID = UUID()
        try await recordUnsentContinuation(fixture, plannedUserItemID: plannedUserItemID)

        let submission = Support.submission("please continue from the last step", userItemID: plannedUserItemID)
        _ = try await fixture.lane.transaction { store, binding in
            try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
        }.get()
        let adopted = await fixture.waitForRecord { $0.intents.contains { $0.userItemID == plannedUserItemID } }
        XCTAssertTrue(adopted)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertFalse(item.actionFacts.hasUnsentContinuation)
        XCTAssertNil(item.actionFacts.unsentContinuationText)
        XCTAssertEqual(item.attention, .informational)
    }

    /// A later action that resolves the card (here a Reconcile proving the turn finished) decides it.
    func testUnsentContinuationClearsWhenALaterActionResolvesTheCard() async throws {
        let fixture = try await makeRunCardFixture()
        try await recordUnsentContinuation(fixture)

        try await fixture.perform(fixture.request(), outcome: .importedCompleted)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertTrue(item.actionFacts.resolvedByAction)
        XCTAssertFalse(item.actionFacts.hasUnsentContinuation)
        XCTAssertNil(item.actionFacts.unsentContinuationText)
        XCTAssertEqual(item.attention, .informational)
        XCTAssertEqual(fixture.coordinator.catalog.openNeedsActionCount, 0)
    }

    /// Between an action's outcome write and the release of its hold the session is still paused;
    /// the card it acts on needs action until the hold ends.
    func testRunCardNeedsActionAfterTheOutcomeWriteUntilTheHoldIsReleased() async throws {
        let fixture = try await makeRunCardFixture()
        let request = try await fixture.request()
        guard case let .acquired(authorization) = fixture.coordinator.beginRecoveryAction(request, lane: fixture.lane) else {
            return XCTFail("the hold is acquired")
        }
        try await fixture.perform(request, outcome: .importedUnconfirmed)
        XCTAssertTrue(fixture.coordinator.isCoveredByRecoveryAction(sessionID: fixture.sessionID))
        let held = try XCTUnwrap(fixture.item)
        XCTAssertTrue(held.actionFacts.hasUnfinishedAction, "the outcome is recorded; the hold is not released")
        XCTAssertEqual(held.attention, .needsAction)

        fixture.coordinator.revokeRecoveryAction(authorization)
        fixture.coordinator.endRecoveryAction(authorization)
        let released = try XCTUnwrap(fixture.item)
        XCTAssertFalse(released.actionFacts.hasUnfinishedAction)
        XCTAssertEqual(released.attention, .informational)
    }

    // MARK: Automatic clearing (Step 8-attention-2)

    /// The pure clearing rule, first match wins: resolved by an action, then an older reset
    /// generation than current, then a later attempt of the same generation in `runAttempts`
    /// (first-record order). Nothing else clears; there is no age-based expiry.
    func testAutomaticClearRuleOrder() {
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        func attempt(_ id: UUID, _ generation: UInt64) -> AgentRecoveryRunAttempt {
            AgentRecoveryRunAttempt(runAttemptID: id, transcriptResetGeneration: generation, processRunID: nil, transcriptTurnID: nil, startedAt: stamp)
        }
        func clear(
            resolved: Bool = false,
            _ id: UUID?,
            _ attempts: [AgentRecoveryRunAttempt],
            current: UInt64
        ) -> AgentRecoveryCatalogAutomaticClear? {
            AgentRecoveryCatalogProjection.automaticClear(resolvedByAction: resolved, runAttemptID: id, runAttempts: attempts, currentGeneration: current)
        }
        let (first, second, third) = (UUID(), UUID(), UUID())
        let sameGeneration = [attempt(first, 0), attempt(second, 0)]
        XCTAssertEqual(clear(resolved: true, nil, [], current: 0), .resolved, "a legacy turn is cleared by its action alone")
        XCTAssertEqual(clear(resolved: true, first, sameGeneration, current: 1), .resolved, "first match wins")
        XCTAssertEqual(clear(first, sameGeneration, current: 1), .conversationCleared)
        XCTAssertEqual(clear(first, sameGeneration, current: 0), .sessionContinued)
        XCTAssertNil(clear(second, sameGeneration, current: 0), "the latest attempt is not continued")
        XCTAssertNil(clear(UUID(), sameGeneration, current: 0), "an attempt missing from the record")
        XCTAssertNil(clear(nil, sameGeneration, current: 0))
        // A later attempt of another generation is no continuation of this one.
        XCTAssertNil(clear(second, [attempt(second, 1), attempt(third, 2)], current: 1))
        XCTAssertEqual(clear(third, [attempt(first, 0), attempt(third, 1)], current: 1), nil)
    }

    /// Review B F4: a run with delegated-child links is never cleared (its card is their only
    /// discovery pointer), whichever rule would match.
    func testAutomaticClearNeverClearsARunWithDelegatedChildren() {
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        let (first, second) = (UUID(), UUID())
        let attempts = [first, second].map {
            AgentRecoveryRunAttempt(runAttemptID: $0, transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: nil, startedAt: stamp)
        }
        for (resolved, current) in [(false, UInt64(0)), (false, 1), (true, 0)] {
            XCTAssertNotNil(AgentRecoveryCatalogProjection.automaticClear(
                resolvedByAction: resolved, runAttemptID: first, runAttempts: attempts, currentGeneration: current
            ), "the rule matches without links")
            XCTAssertNil(AgentRecoveryCatalogProjection.automaticClear(
                resolvedByAction: resolved, runAttemptID: first, runAttempts: attempts, currentGeneration: current,
                hasDelegatedChildren: true
            ), "resolved: \(resolved), current generation: \(current)")
        }
    }

    /// Review B F4: a later attempt that verifiably never delivered its input continues nothing, so
    /// it never clears the earlier run as "session continued"; a delivered one still does.
    func testAutomaticClearIgnoresALaterAttemptThatWasNeverHandedOff() {
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        let (first, neverHandedOff, delivered) = (UUID(), UUID(), UUID())
        func attempts(_ ids: [UUID]) -> [AgentRecoveryRunAttempt] {
            ids.map { AgentRecoveryRunAttempt(runAttemptID: $0, transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: nil, startedAt: stamp) }
        }
        func clear(_ ids: [UUID]) -> AgentRecoveryCatalogAutomaticClear? {
            AgentRecoveryCatalogProjection.automaticClear(
                resolvedByAction: false, runAttemptID: first, runAttempts: attempts(ids), currentGeneration: 0,
                isVerifiedNeverHandedOff: { $0 == neverHandedOff }
            )
        }
        XCTAssertNil(clear([first, neverHandedOff]))
        XCTAssertEqual(clear([first, neverHandedOff, delivered]), .sessionContinued)
    }

    /// A later run attempt in the same conversation generation clears the earlier run's note from
    /// ordinary presentation: still in the catalog, hidden from the sheet's default rows, listed
    /// with "Show dismissed and cleared", and never counted. Nothing is written.
    func testRunCardIsClearedWhenALaterRunAttemptExists() async throws {
        let fixture = try await makeRunCardFixture()
        XCTAssertNil(fixture.item?.automaticClear)
        let before = await fixture.store.read(sessionID: fixture.sessionID).record
        XCTAssertEqual(before?.cardAcknowledgements.count ?? 0, 0)

        let later = Support.ownership(sessionID: fixture.sessionID)
        _ = try await fixture.lane.ensureRunAttempt(ownership: later, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        let cleared = await Support.eventually { fixture.item?.automaticClear == .sessionContinued }
        XCTAssertTrue(cleared, "\(String(describing: fixture.item?.actionFacts))")
        let item = try XCTUnwrap(fixture.item, "a cleared note stays in the catalog")
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(item.isDismissed)
        XCTAssertEqual(item.attention, .informational)
        let catalog = fixture.coordinator.catalog
        XCTAssertFalse(catalog.needsAttentionItems(includeDismissed: false).contains { $0.id == fixture.itemID })
        XCTAssertTrue(catalog.needsAttentionItems(includeDismissed: true).contains { $0.id == fixture.itemID })
        XCTAssertEqual(catalog.openNeedsActionCount, 0)
        let after = await fixture.store.read(sessionID: fixture.sessionID).record
        XCTAssertEqual(after?.cardAcknowledgements.count ?? 0, 0, "clearing is projection-only")
    }

    /// A recovery action that resolved the card (here a Reconcile proving the turn finished) clears it.
    func testRunCardIsClearedWhenAnActionResolvedIt() async throws {
        let fixture = try await makeRunCardFixture()
        try await fixture.perform(fixture.request(), outcome: .importedCompleted)
        let item = try XCTUnwrap(fixture.item)
        XCTAssertTrue(item.actionFacts.resolvedByAction)
        XCTAssertEqual(item.automaticClear, .resolved)
        XCTAssertTrue(item.isHidden)
    }

    /// Clearing the conversation after the run clears its note (the run's reset generation is older
    /// than the session's current one).
    func testRunCardIsClearedWhenTheConversationWasClearedAfterIt() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let lane = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        let ownership = Support.ownership(sessionID: load.session.id)
        let turnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(load.session.id.uuidString)-\(turnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        XCTAssertNil(coordinator.catalog.item(id: itemID)?.automaticClear)

        let reset = try await resetTranscript(service, load)
        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1)
        let cleared = await Support.eventually { coordinator.catalog.item(id: itemID)?.automaticClear == .conversationCleared }
        XCTAssertTrue(cleared, "\(coordinator.catalog.items.map { "\($0.id) \(String(describing: $0.automaticClear))" })")
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.isHidden, true)
    }

    /// A needs-action run card is never cleared, even when a clearing rule matches: not with an
    /// unfinished recovery action, and not with an unsent typed continuation.
    func testNeedsActionRunCardIsNeverCleared() async throws {
        let fixtures = try await makeRunCardFixtures(count: 2)
        let (unfinished, unsent) = (fixtures[0], fixtures[1])
        let open = try await unfinished.request(text: "please continue from the last step")
        _ = try await unfinished.lane.reserveRecoveryAction(open).get()
        _ = try await unfinished.lane.ensureRunAttempt(ownership: Support.ownership(sessionID: unfinished.sessionID), processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        let matched = await Support.eventually { unfinished.item?.actionFacts.automaticClear == .sessionContinued }
        XCTAssertTrue(matched, "the rule matches")
        let held = try XCTUnwrap(unfinished.item)
        XCTAssertEqual(held.attention, .needsAction)
        XCTAssertNil(held.automaticClear, "never cleared while an action is unfinished")
        XCTAssertFalse(held.isHidden)
        XCTAssertTrue(unfinished.coordinator.catalog.needsAttentionItems(includeDismissed: false).contains { $0.id == unfinished.itemID })

        let continuation = try await unsent.request(text: "please continue from the last step")
        try await unsent.perform(continuation, outcome: .notDispatched)
        XCTAssertTrue(unsent.item?.actionFacts.hasUnsentContinuation == true)
        _ = try await unsent.lane.ensureRunAttempt(ownership: Support.ownership(sessionID: unsent.sessionID), processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        let unsentMatched = await Support.eventually { unsent.item?.actionFacts.automaticClear == .sessionContinued }
        XCTAssertTrue(unsentMatched)
        let kept = try XCTUnwrap(unsent.item)
        XCTAssertEqual(kept.attention, .needsAction)
        XCTAssertNil(kept.automaticClear, "never cleared while its typed text was not sent")
        XCTAssertEqual(unsent.coordinator.catalog.openNeedsActionCount, 2, "both cards are counted")
    }

    // MARK: Bulk Dismiss (Step 8-attention-2)

    /// Every captured item is either dismissed or skipped with its reason: no Dismiss, busy, or
    /// changed since shown. A changed item is never dismissed in its new form. A dismissed (hidden)
    /// item is not captured at all: it is neither counted nor skipped.
    func testBulkDismissSkipsIneligibleAndChangedItems() async throws {
        let cards = try await makeRunCardFixtures(count: 5)
        let (eligible, dismissedCard, busyCard, changedCard, staleCard) = (cards[0], cards[1], cards[2], cards[3], cards[4])
        let (store, coordinator) = (eligible.store, eligible.coordinator)

        let dismissFirst = try await coordinator.dismissCatalogItem(XCTUnwrap(dismissedCard.item))
        XCTAssertNil(dismissFirst)
        let dismissedCaptured = try XCTUnwrap(dismissedCard.item)
        XCTAssertTrue(dismissedCaptured.isDismissed)
        let noDismiss = AgentRecoveryCatalogItem(
            id: "draft-savefail-\(UUID().uuidString)", kind: .saveFailure, sessionID: UUID(), workspaceID: nil,
            sessionName: nil, composeTabID: nil, payload: .composerWriteFailed(.retired), acknowledgement: nil
        )
        // Captured as an informational note; it then needs action (an action is reserved on it).
        let changedCaptured = try XCTUnwrap(changedCard.item)
        _ = try await changedCard.lane.reserveRecoveryAction(changedCard.request()).get()
        let promoted = await Support.eventually { changedCard.item?.attention == .needsAction }
        XCTAssertTrue(promoted)
        // Captured in a state the catalog no longer shows.
        let current = try XCTUnwrap(staleCard.item)
        let staleAcknowledgement = try XCTUnwrap(current.acknowledgement)
        let staleCaptured = AgentRecoveryCatalogItem(
            id: current.id, kind: current.kind, sessionID: current.sessionID, workspaceID: current.workspaceID,
            sessionName: current.sessionName, composeTabID: current.composeTabID, payload: current.payload,
            acknowledgement: AgentRecoveryCatalogAcknowledgement(
                key: staleAcknowledgement.key, freshness: AgentRecoveryCardFreshness("older"), isAcknowledged: false
            ),
            actionFacts: current.actionFacts
        )
        coordinator.setCatalogActionState(.working, for: busyCard.itemID)
        let captured = try [XCTUnwrap(eligible.item), noDismiss, dismissedCaptured, XCTUnwrap(busyCard.item), changedCaptured, staleCaptured]

        let result = await coordinator.dismissCatalogItems(captured, section: .informational)
        let status = try XCTUnwrap(result)
        XCTAssertFalse(status.isRunning)
        XCTAssertFalse(coordinator.isBulkDismissRunning)
        XCTAssertEqual(status.total, 5)
        XCTAssertEqual(status.dismissed, 1)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.skipped, [
            AgentRecoveryBulkDismissSkip(itemID: noDismiss.id, reason: .noDismiss),
            AgentRecoveryBulkDismissSkip(itemID: busyCard.itemID, reason: .busy),
            AgentRecoveryBulkDismissSkip(itemID: changedCard.itemID, reason: .changed),
            AgentRecoveryBulkDismissSkip(itemID: staleCard.itemID, reason: .changed)
        ])
        XCTAssertEqual(
            status.summaryText,
            "Information: Dismissed 1 of 5 · 4 skipped (1 can't be dismissed, 1 busy, 2 changed)"
        )
        XCTAssertEqual(coordinator.bulkDismiss, status, "the summary stays until the sheet closes or the next bulk")
        coordinator.clearBulkDismissSummary()
        XCTAssertNil(coordinator.bulkDismiss, "closing the sheet clears a finished summary")
        XCTAssertEqual(eligible.item?.isDismissed, true)
        XCTAssertEqual(coordinator.catalogActionStates[busyCard.itemID], .working, "a busy row's own action state is untouched")
        for skipped in [busyCard, changedCard, staleCard] {
            let record = await store.read(sessionID: skipped.sessionID).record
            XCTAssertEqual(record?.cardAcknowledgements.count ?? 0, 0, "\(skipped.itemID) is not dismissed")
            XCTAssertEqual(skipped.item?.isDismissed, false)
        }
        XCTAssertEqual(changedCard.item?.attention, .needsAction, "still listed in its new form")
    }

    /// A failed Dismiss stays on its row (shared action state) and is counted; the rest continue.
    func testBulkDismissReportsPartialFailureOnTheRow() async throws {
        let cards = try await makeRunCardFixtures(count: 2)
        let (first, second, coordinator) = (cards[0], cards[1], cards[0].coordinator)
        let captured = try [XCTUnwrap(first.item), XCTUnwrap(second.item)]
        // Storage fails for the second session's record only.
        failures.failingWritePathFragment = second.sessionID.uuidString
        let result = await coordinator.dismissCatalogItems(captured, section: .informational)
        failures.failingWritePathFragment = nil
        let status = try XCTUnwrap(result)
        XCTAssertEqual(status.dismissed, 1)
        XCTAssertEqual(status.failed, 1)
        XCTAssertTrue(status.skipped.isEmpty)
        XCTAssertEqual(status.summaryText, "Information: Dismissed 1 of 2 · 1 failed")
        XCTAssertEqual(first.item?.isDismissed, true)
        XCTAssertNil(coordinator.catalogActionStates[first.itemID])
        XCTAssertEqual(second.item?.isDismissed, false, "the failed card stays listed")
        guard case .failed? = coordinator.catalogActionStates[second.itemID] else {
            return XCTFail("the failure stays on its row: \(String(describing: coordinator.catalogActionStates[second.itemID]))")
        }
    }

    /// Cancel stops before the next item: committed Dismisses stay, the rest are untouched, and only
    /// one bulk Dismiss runs at a time.
    func testBulkDismissCancelStopsBeforeTheNextItemAndKeepsCommittedOnes() async throws {
        let cards = try await makeRunCardFixtures(count: 3)
        let (store, service, coordinator) = (cards[0].store, cards[0].service, cards[0].coordinator)
        let captured = try cards.map { try XCTUnwrap($0.item) }
        // The first Dismiss waits on its session's persistence gate while the cancel is requested.
        let gate = try service.recoveryLifecycleGate(for: cards[0].load.persistenceState)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let running = Task { await coordinator.dismissCatalogItems(captured, section: .informational) }
        let started = await Support.eventually { coordinator.catalogActionStates[cards[0].itemID] == .working }
        XCTAssertTrue(started)
        XCTAssertTrue(coordinator.isBulkDismissRunning)
        XCTAssertTrue(coordinator.bulkDismiss?.summaryText.hasPrefix("Information: Dismissing 1 of 3") == true, String(describing: coordinator.bulkDismiss?.summaryText))
        coordinator.clearBulkDismissSummary()
        XCTAssertNotNil(coordinator.bulkDismiss, "closing the sheet keeps a running bulk's status")
        let concurrent = await coordinator.dismissCatalogItems(captured, section: .needsAction)
        XCTAssertNil(concurrent, "one bulk Dismiss at a time")
        coordinator.requestBulkDismissCancel()
        XCTAssertEqual(coordinator.bulkDismiss?.cancelRequested, true)
        await latch.open()
        _ = try await holder.value
        let result = await running.value
        let status = try XCTUnwrap(result)
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.dismissed, 1, "the item in progress settles and stays dismissed")
        XCTAssertEqual(status.notAttempted, 2)
        XCTAssertEqual(status.summaryText, "Information: Dismissed 1 of 3 · stopped, 2 not attempted")
        XCTAssertEqual(cards.map { $0.item?.isDismissed }, [true, false, false])
        for card in cards.dropFirst() {
            let record = await store.read(sessionID: card.sessionID).record
            XCTAssertEqual(record?.cardAcknowledgements.count ?? 0, 0)
        }
    }

    /// Review A ATT2-01: the set is frozen when the bulk is chosen. A card busy with its own Dismiss
    /// then is a `.busy` skip and is never promoted into the batch, even when its own Dismiss fails
    /// (so it is no longer busy and unchanged) while the bulk's first write is still blocked.
    func testBulkDismissActsOnlyOnTheItemsEligibleWhenConfirmed() async throws {
        let cards = try await makeRunCardFixtures(count: 2)
        let (first, busy, coordinator) = (cards[0], cards[1], cards[0].coordinator)
        func hold(_ card: RunCardFixture, _ latch: RecoveryGateLatch) throws -> Task<Void, Error> {
            let gate = try card.service.recoveryLifecycleGate(for: card.load.persistenceState)
            return Task { _ = try await gate.performRecoveryTransaction { await latch.pause() } }
        }
        // The busy card's own Dismiss (as its row runs it) waits on its session's gate, then fails.
        let busyLatch = RecoveryGateLatch()
        let busyHolder = try hold(busy, busyLatch)
        await busyLatch.waitUntilPaused()
        failures.failingWritePathFragment = busy.sessionID.uuidString
        let busyItem = try XCTUnwrap(busy.item)
        coordinator.setCatalogActionState(.working, for: busy.itemID)
        let individual = Task {
            let failure = await coordinator.dismissCatalogItem(busyItem)
            coordinator.setCatalogActionState(failure.map { .failed($0) }, for: busy.itemID)
            return failure
        }

        let capture = try coordinator.bulkDismissCapture([XCTUnwrap(first.item), busyItem])
        XCTAssertEqual(capture.items.map(\.id), [first.itemID], "the confirmed count is 1")
        XCTAssertEqual(capture.skipped, [AgentRecoveryBulkDismissSkip(itemID: busy.itemID, reason: .busy)])

        let firstLatch = RecoveryGateLatch()
        let firstHolder = try hold(first, firstLatch)
        await firstLatch.waitUntilPaused()
        let running = Task { await coordinator.dismissCatalogItems(capture, section: .needsAction) }
        let started = await Support.eventually { coordinator.catalogActionStates[first.itemID] == .working }
        XCTAssertTrue(started)

        await busyLatch.open()
        _ = try await busyHolder.value
        let individualFailure = await individual.value
        XCTAssertNotNil(individualFailure, "the card's own Dismiss failed")
        failures.failingWritePathFragment = nil
        XCTAssertNotEqual(coordinator.catalogActionStates[busy.itemID], .working, "no longer busy")
        XCTAssertEqual(busy.item?.acknowledgement, busyItem.acknowledgement, "and unchanged")
        XCTAssertTrue(coordinator.isBulkDismissRunning, "the bulk's first write is still blocked")
        XCTAssertEqual(coordinator.catalogActionStates[first.itemID], .working)

        await firstLatch.open()
        _ = try await firstHolder.value
        let result = await running.value
        let status = try XCTUnwrap(result)
        XCTAssertEqual(status.total, 2)
        XCTAssertEqual(status.dismissed, 1, "only the confirmed card")
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.skipped, [AgentRecoveryBulkDismissSkip(itemID: busy.itemID, reason: .busy)])
        XCTAssertEqual(status.summaryText, "Needs action: Dismissed 1 of 2 · 1 skipped (1 busy)")
        XCTAssertEqual(first.item?.isDismissed, true)
        XCTAssertEqual(busy.item?.isDismissed, false, "never promoted into the batch")
        let record = await busy.store.read(sessionID: busy.sessionID).record
        XCTAssertEqual(record?.cardAcknowledgements.count ?? 0, 0)
        guard case .failed? = coordinator.catalogActionStates[busy.itemID] else {
            return XCTFail("its own failure stays on its row: \(String(describing: coordinator.catalogActionStates[busy.itemID]))")
        }
    }

    // MARK: Check and resolve (Step 9-check)

    @MainActor
    private final class CheckCalls {
        var ids: [String] = []
    }

    @MainActor
    private final class LateReconcile {
        var result: AgentRecoveryActionResult?
    }

    /// Before activation (production qualification: Reconcile unavailable) Check refreshes and
    /// reconciles nothing, writes nothing, and reports the items from the catalog only with the
    /// "not active" header; nothing is resolved.
    func testCheckBeforeActivationReportsNotActiveAndWritesNothing() async throws {
        let production = AgentRecoveryActionRunner(activation: .production, registrationActive: { true })
        XCTAssertFalse(production.isAvailable(.reconcileOnly), "the window's checksActive is off in production")
        let cards = try await makeRunCardFixtures(count: 2)
        let (store, coordinator) = (cards[0].store, cards[0].coordinator)
        let captured = try cards.map { try XCTUnwrap($0.item) }
        let gone = AgentRecoveryCatalogItem(
            id: "intent-\(UUID().uuidString)", kind: .savedInput, sessionID: UUID(), workspaceID: nil,
            sessionName: "Gone", composeTabID: nil, payload: .scheduleIndexUnavailable(workspaceName: "W"), acknowledgement: nil
        )
        var revisions: [AgentRecoveryRecordRevision?] = []
        for card in cards {
            try await revisions.append(store.currentRevision(sessionID: card.sessionID))
        }
        var reconciled = 0
        let result = await coordinator.checkCatalogItems(captured + [gone], checksActive: false) { _ in
            reconciled += 1
            return .notAttempted("never")
        }
        let status = try XCTUnwrap(result)
        XCTAssertEqual(reconciled, 0, "no provider history is read")
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.headerText, "Process and provider-history checks are not active. Items are reported as they are; nothing was changed.")
        XCTAssertFalse(status.headerText.contains(AgentRecoveryCheckStatus.restrictionWarningText))
        XCTAssertEqual(status.entries.map(\.outcome), [
            .couldNotCheck("Provider history checks are not active."),
            .couldNotCheck("Provider history checks are not active."),
            .couldNotCheck("It is no longer listed.")
        ])
        XCTAssertEqual(status.summaryText, "Checked 3 of 3 · 3 could not check")
        XCTAssertEqual(status.entries.last?.label, "Saved message · Gone")
        for (card, revision) in zip(cards, revisions) {
            let after = try await store.currentRevision(sessionID: card.sessionID)
            XCTAssertEqual(after, revision, "nothing is written")
            XCTAssertEqual(card.item, captured.first { $0.id == card.itemID }, "the card is unchanged")
            XCTAssertNil(coordinator.catalogActionStates[card.itemID])
        }
        coordinator.clearRecoveryCheckReport()
        XCTAssertNil(coordinator.recoveryCheck, "closing the sheet clears a finished report")
    }

    /// One check at a time, one item at a time; Stop ends the check at once and the report says it
    /// was cancelled: the item in progress is no longer waited for (Step 9-activation), its late
    /// result never reaches the finished report, and nothing after it is checked.
    func testCheckStopHaltsBeforeTheNextItemAndRunsOneAtATime() async throws {
        let cards = try await makeRunCardFixtures(count: 3)
        let coordinator = cards[0].coordinator
        let captured = try cards.map { try XCTUnwrap($0.item) }
        let latch = RecoveryGateLatch()
        let calls = CheckCalls()
        let running = Task {
            await coordinator.checkCatalogItems(captured, checksActive: true) { item in
                calls.ids.append(item.id)
                await latch.pause()
                return .notAttempted("Open this session to check its provider history.")
            }
        }
        await latch.waitUntilPaused()
        XCTAssertTrue(coordinator.isRecoveryCheckRunning)
        XCTAssertEqual(calls.ids, [cards[0].itemID], "one item at a time")
        XCTAssertEqual(coordinator.recoveryCheck?.summaryText, "Checking 1 of 3…")
        XCTAssertTrue(coordinator.recoveryCheck?.headerText.contains(AgentRecoveryCheckStatus.restrictionWarningText) == true)
        let concurrent = await coordinator.checkCatalogItems(captured, checksActive: false) { _ in .notAttempted("never") }
        XCTAssertNil(concurrent, "one check at a time app-wide")
        coordinator.clearRecoveryCheckReport()
        XCTAssertNotNil(coordinator.recoveryCheck, "closing the sheet keeps a running check")
        coordinator.requestRecoveryCheckCancel()
        XCTAssertEqual(coordinator.recoveryCheck?.summaryText, "Checking 1 of 3… Stopping…")
        coordinator.requestRecoveryCheckCancel() // A repeated Stop is ignored.
        let result = await running.value
        let status = try XCTUnwrap(result)
        XCTAssertEqual(calls.ids, [cards[0].itemID], "nothing after Stop")
        XCTAssertEqual(status.entries.map(\.outcome), [.couldNotCheck(AgentRecoveryCheckStatus.abandonedText)])
        XCTAssertEqual(status.notChecked, 2)
        XCTAssertEqual(status.summaryText, "Cancelled: checked 1 of 3, 2 not checked · 1 could not check")
        XCTAssertEqual(cards.map(\.item), captured, "the remaining items are untouched")
        await latch.open()
        await Task.yield()
        XCTAssertEqual(coordinator.recoveryCheck, status, "the late result never reaches the finished report")
    }

    /// Step 9-activation (re-review blocker): a Reconcile that never returns cannot keep Check
    /// running. Stop ends the wait without cancelling the work: the report finishes, the row's
    /// `.working` state is released, the session's recovery action hold still refuses another
    /// dispatch, and when the work finally ends its result reaches the card, not the report.
    func testCheckStopAbandonsAHungReconcileButKeepsItsActionHold() async throws {
        let cards = try await makeRunCardFixtures(count: 2)
        let (card, coordinator) = (cards[0], cards[0].coordinator)
        let captured = try cards.map { try XCTUnwrap($0.item) }
        let runner = AgentRecoveryActionRunner(
            activation: .claudeAndCodex,
            registrationActive: { true }
        )
        let latch = RecoveryGateLatch()
        let calls = CheckCalls()
        let reconcileRequest = try await card.request()
        let hung = AgentRecoveryActionPerformers(reconcile: { _ in
            await latch.pause()
            return .nothingImported("Nothing new.")
        }, dispatch: { _, _ in .notDispatched("never") })
        let late = LateReconcile()
        let running = Task {
            await coordinator.checkCatalogItems(captured, checksActive: true) { item in
                calls.ids.append(item.id)
                coordinator.setCatalogActionState(.working, for: item.id)
                let result = await runner.perform(reconcileRequest, lane: card.lane, performers: hung)
                // The card's own state, as the window's Reconcile records it.
                coordinator.setCatalogActionState(.failed("late result"), for: item.id)
                late.result = result
                return .performed(result, observed: nil)
            }
        }
        await latch.waitUntilPaused()
        XCTAssertEqual(coordinator.catalogActionStates[card.itemID], .working)
        XCTAssertTrue(coordinator.isCoveredByRecoveryAction(sessionID: card.sessionID))

        coordinator.requestRecoveryCheckCancel()
        let finishedStatus = await running.value
        XCTAssertEqual(finishedStatus?.isRunning, false, "Stop finishes the report without the hung Reconcile")
        let status = try XCTUnwrap(coordinator.recoveryCheck)
        XCTAssertEqual(status.entries.map(\.outcome), [.couldNotCheck(AgentRecoveryCheckStatus.abandonedText)])
        XCTAssertEqual(status.notChecked, 1)
        XCTAssertEqual(calls.ids, [card.itemID])
        XCTAssertNil(coordinator.catalogActionStates[card.itemID], "the row's working state is released")

        // The hold persists: another choice in that session is refused, nothing reserved or sent.
        XCTAssertTrue(coordinator.isCoveredByRecoveryAction(sessionID: card.sessionID))
        let continuation = try await card.request(text: "continue")
        let refused = await runner.perform(continuation, lane: card.lane, performers: hung)
        XCTAssertEqual(refused, .refused(AgentRecoveryActionRunner.sessionActionInFlightText))

        XCTAssertNil(late.result, "the hung Reconcile is still running")
        await latch.open()
        let ended = await Support.eventually { late.result != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(late.result, .completed(.notDispatched, reason: "Nothing new."), "the work ran to its own end")
        XCTAssertEqual(coordinator.catalogActionStates[card.itemID], .failed("late result"), "the late result reaches the card")
        XCTAssertEqual(coordinator.recoveryCheck, status, "and never the finished report")
        let released = await Support.eventually { !coordinator.isCoveredByRecoveryAction(sessionID: card.sessionID) }
        XCTAssertTrue(released, "the hold ends only when the work really ends")
    }

    /// Round-0 review (A F1, B P2-1): Stop that lands after an item's work was queued but before it
    /// ran never starts a Reconcile afterwards, and leaves a `.working` state Check didn't set
    /// (another action's) alone. Stopping the only item gives the cancelled heading (A F3), and the
    /// item is reported stopped before checking, never as a check that continues.
    func testCheckStopBeforeTheItemsWorkStartsNeverReconcilesAndKeepsAnotherActionsWorkingState() async throws {
        let cards = try await makeRunCardFixtures(count: 1)
        let (card, coordinator) = (cards[0], cards[0].coordinator)
        let captured = try XCTUnwrap(card.item)
        coordinator.test_recoveryCheckItemQueued = { coordinator.requestRecoveryCheckCancel() }
        defer { coordinator.test_recoveryCheckItemQueued = nil }
        let calls = CheckCalls()
        let check: @MainActor () async throws -> AgentRecoveryCheckStatus = {
            let result = await coordinator.checkCatalogItems([captured], checksActive: true) { item in
                calls.ids.append(item.id)
                return .notAttempted("never")
            }
            let status = try XCTUnwrap(result)
            // No promise of a later result: the item's check never starts (round-1 A F2).
            XCTAssertEqual(status.entries.map(\.outcome), [.couldNotCheck(AgentRecoveryCheckStatus.stoppedBeforeCheckingText)])
            XCTAssertEqual(status.notChecked, 0)
            XCTAssertEqual(status.summaryText, "Cancelled: checked 1 of 1 · 1 could not check")
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(coordinator.recoveryCheck, status)
            return status
        }

        // The row is free: without the guard the queued work would start a Reconcile after Stop.
        _ = try await check()
        XCTAssertEqual(calls.ids, [], "the queued work saw Stop and never started a Reconcile")
        XCTAssertNil(coordinator.catalogActionStates[card.itemID])

        // Another action (not Check) is working on the row: abandoning doesn't clear its state.
        coordinator.setCatalogActionState(.working, for: card.itemID)
        _ = try await check()
        XCTAssertEqual(calls.ids, [])
        XCTAssertEqual(coordinator.catalogActionStates[card.itemID], .working, "another action's working state is kept")
    }

    /// A F3: Stop that abandons the only item mid-Reconcile reports cancelled (not "Checked 1 of
    /// 1") and releases the `.working` state that item's own Reconcile set.
    func testCheckStopOnTheOnlyItemReportsCancelled() async throws {
        let cards = try await makeRunCardFixtures(count: 1)
        let (card, coordinator) = (cards[0], cards[0].coordinator)
        let captured = try XCTUnwrap(card.item)
        let latch = RecoveryGateLatch()
        let running = Task {
            await coordinator.checkCatalogItems([captured], checksActive: true) { item in
                coordinator.setCatalogActionState(.working, for: item.id)
                await latch.pause()
                coordinator.setCatalogActionState(nil, for: item.id)
                return .notAttempted("late")
            }
        }
        await latch.waitUntilPaused()
        XCTAssertEqual(coordinator.recoveryCheck?.summaryText, "Checking 1 of 1…")
        coordinator.requestRecoveryCheckCancel()
        let result = await running.value
        let status = try XCTUnwrap(result)
        XCTAssertEqual(status.entries.map(\.outcome), [.couldNotCheck(AgentRecoveryCheckStatus.abandonedText)])
        XCTAssertEqual(status.notChecked, 0)
        XCTAssertEqual(status.summaryText, "Cancelled: checked 1 of 1 · 1 could not check")
        XCTAssertNil(coordinator.catalogActionStates[card.itemID], "Check's own working state is released")
        await latch.open()
        let settled = await Support.eventually { coordinator.catalogActionStates[card.itemID] == nil }
        XCTAssertTrue(settled)
        XCTAssertEqual(coordinator.recoveryCheck, status, "the late result never reaches the finished report")
    }

    /// After activation (checks active, injected), each run card still as captured goes to the
    /// window's Reconcile and is reported from the runner's typed result, never a catalog re-read
    /// (record commits reach the catalog asynchronously). A captured card that changed meanwhile, or
    /// that another action cleared before its turn, is never reconciled; a captured survivor that
    /// left the catalog without registry proof of exit is not claimed to have exited.
    func testCheckAfterActivationReportsEachReconcileResult() async throws {
        let cards = try await makeRunCardFixtures(count: 5)
        let coordinator = cards[0].coordinator
        let captured = try cards.map { try XCTUnwrap($0.item) }
        let (changed, clearedLater) = (cards[3], cards[4])
        _ = try await changed.lane.reserveRecoveryAction(changed.request()).get()
        let promoted = await Support.eventually { changed.item?.attention == .needsAction }
        XCTAssertTrue(promoted)
        let restriction = AgentRuntimeRestriction(
            runtimeID: UUID(), kind: .possibleWriter, family: nil, provider: nil, state: .reserved, isPreviousInstance: true,
            isUnreadable: false, providerHome: nil, conversationIDs: [], worktreePaths: [], sessionIDs: [], associations: [],
            rootPID: nil, memberCount: 0, letFinish: false, revision: nil, createdAt: nil
        )
        let goneSurvivor = AgentRecoveryCatalogItem(
            id: AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: restriction.runtimeID), kind: .survivingProcess,
            sessionID: nil, workspaceID: nil, sessionName: nil, composeTabID: nil,
            payload: .survivingRuntime(restriction), acknowledgement: nil
        )
        let confirmed = AgentRecoveryReconcileCompletion.confirmed(runAttemptID: cards[0].attemptID)
        var reconciled: [String] = []
        let result = await coordinator.checkCatalogItems(captured + [goneSurvivor], checksActive: true) { item in
            reconciled.append(item.id)
            switch item.id {
            case cards[0].itemID:
                // Another window resolves a later captured card meanwhile.
                try? await clearedLater.perform(clearedLater.request(), outcome: .importedCompleted)
                return .performed(.completed(.importedCompleted, reason: nil), observed: .imported(completion: confirmed, rowCount: 2))
            case cards[1].itemID:
                return .performed(
                    .completed(.importedCompleted, reason: "The session couldn't be saved."),
                    observed: .blocked("The session couldn't be saved.", completion: confirmed)
                )
            case cards[2].itemID:
                return .performed(
                    .completed(.notDispatched, reason: "Codex has no matching record of the interrupted turn."),
                    observed: .nothingImported("Codex has no matching record of the interrupted turn.")
                )
            default:
                return .notAttempted("Open this session to check its provider history.")
            }
        }
        let status = try XCTUnwrap(result)
        XCTAssertEqual(reconciled, cards.prefix(3).map(\.itemID), "the changed and the cleared cards are never reconciled")
        XCTAssertEqual(status.entries.map(\.outcome), [
            .resolved("Provider history shows the turn finished."),
            .failed("The turn had finished, but its history couldn't be saved: The session couldn't be saved."),
            .needsYou("Continue it or dismiss the note. Codex has no matching record of the interrupted turn."),
            .needsYou("Check the conversation, then continue it or dismiss the card"),
            .resolved("A recovery action resolved it."),
            .couldNotCheck("It is no longer listed.")
        ])
        XCTAssertEqual(status.summaryText, "Checked 6 of 6 · 2 resolved · 2 need you · 1 could not check · 1 failed")
        XCTAssertEqual(
            status.headerText,
            "Checks process ownership and provider history, and confirms a paused session stopped when process records prove its processes exited. Clearing a restriction or confirming a paused session may let already-authorized scheduled sends run."
        )
    }

    /// The runner's typed result maps to one report: refusals and providers without history could
    /// not be checked; transport/read failures and unrecorded outcomes failed; unconfirmed or
    /// unassociated observations need the user.
    func testCheckMapsTheRunnersTypedReconcileResult() {
        let unconfirmed = AgentRecoveryCheckReconcile.unconfirmedChoice
        let inFlight = AgentRecoveryActionRunner.sessionActionInFlightText
        let inactive = AgentRecoveryActionRunner.registrationInactiveText
        let noHistory = "Provider history is unavailable."
        let finishedUnrecorded = "The turn had finished, but that couldn't be recorded."
        let unconfirmedImport = AgentRecoveryReconcileResult.imported(completion: .unconfirmed, rowCount: 1)
        let unassociated = AgentRecoveryReconcileResult.associationUnavailable(.baselineUnavailable, "a")
        let table: [(AgentRecoveryCheckReconcile, AgentRecoveryCheckOutcome)] = [
            (.performed(.refused(inFlight), observed: nil), .couldNotCheck(inFlight)),
            (.performed(.disabled(inactive), observed: nil), .couldNotCheck(inactive)),
            (.performed(.completed(.importedUnconfirmed, reason: nil), observed: unconfirmedImport), .needsYou(unconfirmed)),
            (.performed(.completed(.notDispatched, reason: "a"), observed: unassociated), .needsYou("Continue it or dismiss the note. a")),
            (.performed(.completed(.notDispatched, reason: "read failed"), observed: .blocked("read failed")), .failed("read failed")),
            (.performed(.completed(.notDispatched, reason: noHistory), observed: nil), .couldNotCheck(noHistory)),
            (.performed(.outcomeUnrecorded(.importedCompleted, reason: nil), observed: nil), .failed(finishedUnrecorded)),
            (.performed(.joined(.unknown), observed: nil), .couldNotCheck(AgentRecoveryCheckReconcile.alreadyChosenText)),
            (.notAttempted("why"), .couldNotCheck("why"))
        ]
        for (reconcile, expected) in table {
            XCTAssertEqual(reconcile.outcome, expected, "\(reconcile)")
        }
    }

    /// Representative items are reported from the catalog alone with the named choice, or why they
    /// can't be checked.
    func testCheckClassifiesRepresentativeItems() {
        let id = UUID()
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        let intent = AgentRecoveryIntent(
            intentID: id, userItemID: id, origin: .composer, target: .session, createdAt: stamp, appInstanceID: id,
            transcriptResetGeneration: 0, deliveryState: .queued, payload: Support.content("saved"), scheduleReference: nil
        )
        let question = AgentRecoveryQuestionSnapshot(
            interactionID: id, kind: .askUser, runAttemptID: id, transcriptResetGeneration: 0, appInstanceID: id,
            askedAt: stamp, title: "Question", message: nil, items: [], extras: [:]
        )
        let restriction = AgentRuntimeRestriction(
            runtimeID: id, kind: .possibleWriter, family: nil, provider: nil, state: .reserved, isPreviousInstance: true,
            isUnreadable: false, providerHome: nil, conversationIDs: [], worktreePaths: [], sessionIDs: [id], associations: [],
            rootPID: nil, memberCount: 0, letFinish: false, revision: nil, createdAt: nil
        )
        let run = AgentRecoveryRunAttempt(runAttemptID: id, transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: nil, startedAt: stamp)
        let note = AgentRecoveryCheckOutcome.couldNotCheck("note")
        let context = AgentRecoveryCatalogIntentContext(isEarlierLaunch: true, heldReason: nil, sameGeneration: true, isRemote: false)
        let table: [(AgentRecoveryCatalogPayload, AgentRecoveryCatalogActionFacts, AgentRecoveryCheckOutcome)] = [
            (.intent(intent, context), .init(), .needsYou("Send or discard the saved message")),
            (.question(question, isCurrentLaunch: false), .init(), .needsYou("Answer the question")),
            (.survivingRuntime(restriction), .init(), .needsYou("Let it finish or Stop")),
            (.closedSessionDraft(Support.snapshot("closed"), fromClearedConversation: false), .init(), .needsYou("Restore or discard the draft")),
            (.scheduleIndexUnavailable(workspaceName: "W"), .init(), .couldNotCheck("Scheduled sends in W couldn't be read.")),
            (.composerWriteFailed(.retired), .init(), .couldNotCheck("A save failed. Retry it from its card.")),
            (.recoveryOnlyRun(run), .init(), note),
            (.recoveryOnlyRun(run), .init(hasUnsentContinuation: true), .needsYou("Send your continuation again or dismiss the card"))
        ]
        for (payload, facts, expected) in table {
            let item = AgentRecoveryCatalogItem(
                id: "item", kind: .savedInput, sessionID: id, workspaceID: nil, sessionName: nil, composeTabID: nil,
                payload: payload, acknowledgement: nil, actionFacts: facts
            )
            XCTAssertEqual(item.checkOutcome(unresolvedRun: note), expected, "\(payload)")
        }
    }

    // MARK: Indexed schedules (sessions no window hosts)

    @MainActor
    private final class HydratedSessions {
        var ids: Set<UUID> = []
    }

    private struct IndexedSchedule {
        let sessionID: UUID
        let tabID: UUID
        let scheduleID: UUID

        var itemID: String {
            "schedule-\(sessionID.uuidString)-\(scheduleID.uuidString)"
        }
    }

    private func sessionIndexURL(_ storage: URL) -> URL {
        storage.appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSessionIndex.json")
    }

    /// An earlier launch's session file whose saved schedule is in `state` (nothing hydrates it).
    private func writeScheduledSession(
        _ service: AgentSessionDataService,
        in workspace: AgentRecoveryWorkspaceDestination,
        storage: URL,
        name: String,
        state: AgentScheduledSendPersist.State,
        notBefore: Date,
        attempt: AgentScheduledSendPersist.Attempt? = nil
    ) async throws -> IndexedSchedule {
        let tabID = UUID()
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: tabID, name: name)
                .withItems([AgentChatItem.user("hello", sequenceIndex: 0)]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let schedule = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: notBefore.addingTimeInterval(-60),
            updatedAt: notBefore,
            notBefore: notBefore,
            state: state,
            confirmationReason: state == .needsConfirmation ? .missedWhileClosed : nil,
            rawText: "scheduled \(name)",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            attempt: attempt
        )
        let sessionURL = storage
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(load.session.id.uuidString).json")
        var saved = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        saved.scheduledSend = .v1(schedule)
        try AgentSessionDataCodec.encodeSession(saved).write(to: sessionURL, options: .atomic)
        return IndexedSchedule(sessionID: load.session.id, tabID: tabID, scheduleID: schedule.id)
    }

    /// Review B F4: a previous build's schema-7 index (same schedule summary shape, no recovery hint)
    /// still lists its schedules read-only instead of a permanent "couldn't be checked" item, and
    /// is neither rewritten nor rebuilt; an older, incompatible schema stays not checked.
    func testScheduleCompatibleOlderIndexIsReadForScheduleDiscoveryWithoutRewriting() async throws {
        let storage = root.appendingPathComponent("schema7", isDirectory: true)
        let legacyStorage = root.appendingPathComponent("schema6", isDirectory: true)
        let workspace = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Schema 7", customStoragePath: storage)
        let legacy = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Schema 6", customStoragePath: legacyStorage)
        let earlier = makeService(store: makeStore())
        let notBefore = Date(timeIntervalSince1970: 1000)
        let schedule = try await writeScheduledSession(
            earlier, in: workspace, storage: storage, name: "Old index", state: .needsConfirmation, notBefore: notBefore
        )
        _ = try await writeScheduledSession(
            earlier, in: legacy, storage: legacyStorage, name: "Older index", state: .needsConfirmation, notBefore: notBefore
        )
        for (folder, version) in [(storage, 7), (legacyStorage, 6)] {
            try? FileManager.default.removeItem(at: sessionIndexURL(folder))
            let builder = makeService(store: makeStore())
            let target = folder == storage ? workspace : legacy
            _ = try await builder.indexedAgentSessionMetadataRecords(for: target)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sessionIndexURL(folder))) as? [String: Any])
            json["schemaVersion"] = version
            json["entries"] = (json["entries"] as? [[String: Any]])?.map { entry in
                var entry = entry
                entry.removeValue(forKey: "recoveryHint")
                return entry
            }
            try JSONSerialization.data(withJSONObject: json).write(to: sessionIndexURL(folder), options: .atomic)
        }
        let olderBytes = try Data(contentsOf: sessionIndexURL(storage))

        let store = makeStore()
        let service = makeService(store: store)
        let compatible = await service.recoveryIndexedSessionRecords(for: workspace)
        let records = try XCTUnwrap(compatible, "A schema-7 index is read for schedule discovery")
        XCTAssertEqual(records.compactMap(\.scheduledSendSummary?.id), [schedule.scheduleID])
        let incompatible = await service.recoveryIndexedSessionRecords(for: legacy)
        XCTAssertNil(incompatible, "An older, incompatible schema is not read")

        let coordinator = try await startedCoordinator(store: store, service: service)
        coordinator.attachScheduler(
            AgentScheduledSendCoordinator(startupAdmission: .open),
            hydratedSessionIDs: { [] },
            indexWorkspaces: { [workspace, legacy] }
        )
        await coordinator.indexedScheduleRefresh?.value
        XCTAssertNotNil(coordinator.catalog.item(id: schedule.itemID), "The schema-7 index's schedule is listed")
        XCTAssertNil(coordinator.catalog.item(id: "schedule-index-\(workspace.id.uuidString)"), "No permanent not-checked item")
        XCTAssertNotNil(coordinator.catalog.item(id: "schedule-index-\(legacy.id.uuidString)"))
        XCTAssertEqual(try Data(contentsOf: sessionIndexURL(storage)), olderBytes, "Discovery never rewrites or rebuilds an index")
    }

    /// Review A F08: an index-sourced confirmation names its schedule attempt, so its card freshness
    /// equals the hydrated schedule's and a Dismiss survives the session hydrating.
    func testIndexedScheduleCardKeepsItsOccurrenceFreshnessAcrossHydration() async throws {
        let storage = root.appendingPathComponent("closed-attempt", isDirectory: true)
        let closed = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Closed", customStoragePath: storage)
        let earlier = makeService(store: makeStore())
        let notBefore = Date(timeIntervalSince1970: 1000)
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: notBefore)
        let attempted = try await writeScheduledSession(
            earlier, in: closed, storage: storage, name: "Attempted", state: .needsConfirmation, notBefore: notBefore, attempt: attempt
        )
        try? FileManager.default.removeItem(at: sessionIndexURL(storage))

        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.indexedAgentSessionMetadataRecords(for: closed)
        let coordinator = try await startedCoordinator(store: store, service: service)
        coordinator.attachScheduler(
            AgentScheduledSendCoordinator(startupAdmission: .open),
            hydratedSessionIDs: { [] },
            indexWorkspaces: { [closed] }
        )
        await coordinator.indexedScheduleRefresh?.value

        let item = try XCTUnwrap(coordinator.catalog.item(id: attempted.itemID))
        guard case let .scheduleNeedsConfirmation(indexed) = item.payload else {
            return XCTFail("Unexpected payload \(item.payload)")
        }
        XCTAssertEqual(indexed.attemptID, attempt.attemptID, "The index names the confirmation's attempt")
        // The hydrated scheduler's summary of the same occurrence (its attempt, reason, and time).
        let hydrated = AgentScheduledSendConfirmationSummary(
            sessionID: attempted.sessionID,
            tabID: attempted.tabID,
            workspaceID: closed.id,
            scheduleID: attempted.scheduleID,
            attemptID: attempt.attemptID,
            reason: .missedWhileClosed,
            notBefore: notBefore,
            previewText: "scheduled Attempted",
            sessionName: "Attempted"
        )
        XCTAssertEqual(
            AgentRecoveryCatalogProjection.scheduleFreshness(indexed),
            AgentRecoveryCatalogProjection.scheduleFreshness(hydrated),
            "Hydration never makes the same confirmation occurrence look fresh"
        )
        if let acknowledgement = item.acknowledgement {
            XCTAssertEqual(acknowledgement.freshness, AgentRecoveryCatalogProjection.scheduleFreshness(hydrated))
        }
    }

    /// Review R1 (A F08 residual): an index-read confirmation without its occurrence identity (no
    /// attempt, as a legacy entry decodes) offers Open but no Dismiss, so hydration supplying the
    /// attempt can never resurface a dismissed card; one naming its attempt stays dismissable.
    func testIndexedScheduleWithoutAttemptRequiresOpenBeforeDismiss() async throws {
        let storage = try XCTUnwrap(workspace.customStoragePath)
        let destination = AgentRecoveryWorkspaceDestination(id: workspace.id, name: workspace.name, customStoragePath: storage)
        let earlier = makeService(store: makeStore())
        let notBefore = Date(timeIntervalSince1970: 1000)
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: notBefore)
        let attempted = try await writeScheduledSession(
            earlier, in: destination, storage: storage, name: "Attempted", state: .needsConfirmation, notBefore: notBefore, attempt: attempt
        )
        let legacy = try await writeScheduledSession(
            earlier, in: destination, storage: storage, name: "Legacy", state: .needsConfirmation, notBefore: notBefore.addingTimeInterval(60)
        )
        try? FileManager.default.removeItem(at: sessionIndexURL(storage))

        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.indexedAgentSessionMetadataRecords(for: destination)
        let coordinator = try await startedCoordinator(store: store, service: service)
        coordinator.attachScheduler(
            AgentScheduledSendCoordinator(startupAdmission: .open),
            hydratedSessionIDs: { [] },
            indexWorkspaces: { [destination] }
        )
        await coordinator.indexedScheduleRefresh?.value
        // Lanes (not hydration) supply each session's incarnation, so cards can be keyed; the index
        // stays their schedule source.
        for sessionID in [attempted.sessionID, legacy.sessionID] {
            let reloaded = try await service.loadAgentSessionForEditing(id: sessionID, for: workspace)
            _ = try coordinator.claimLane(owner: Owner(), persistenceState: XCTUnwrap(reloaded?.persistenceState))
        }

        let attemptedItem = try XCTUnwrap(coordinator.catalog.item(id: attempted.itemID))
        XCTAssertNotNil(attemptedItem.acknowledgement, "An index entry naming its attempt stays dismissable")
        let legacyItem = try XCTUnwrap(coordinator.catalog.item(id: legacy.itemID))
        guard case let .scheduleNeedsConfirmation(summary) = legacyItem.payload else {
            return XCTFail("Unexpected payload \(legacyItem.payload)")
        }
        XCTAssertNil(summary.attemptID)
        XCTAssertTrue(summary.requiresOpenBeforeDismiss)
        XCTAssertNil(legacyItem.acknowledgement, "No Dismiss without the occurrence identity")
        XCTAssertEqual(legacyItem.composeTabID, legacy.tabID, "Open stays available")
        let refused = await coordinator.dismissCatalogItem(legacyItem)
        XCTAssertNotNil(refused, "Dismiss is refused until the session is opened")
        XCTAssertFalse(coordinator.catalog.item(id: legacy.itemID)?.isDismissed ?? true)
    }

    /// Schedules awaiting confirmation in sessions no window hosts (here a workspace no window has
    /// open) are listed from that workspace's metadata index, one item per schedule identity. A
    /// hydrated session, or a schedule whose exact attempt is held for transfer, withdraws exactly its
    /// own item. A workspace with session files but no index is listed as not checked. Discovery
    /// creates, rebuilds, registers, hydrates, and confirms nothing.
    func testCatalogListsIndexedScheduleConfirmationsOfUnhostedSessionsByScheduleIdentity() async throws {
        let closedStorage = root.appendingPathComponent("closed", isDirectory: true)
        let unindexedStorage = root.appendingPathComponent("unindexed", isDirectory: true)
        let emptyStorage = root.appendingPathComponent("empty", isDirectory: true)
        let closed = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Closed", customStoragePath: closedStorage)
        let unindexed = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Unindexed", customStoragePath: unindexedStorage)
        let empty = AgentRecoveryWorkspaceDestination(id: UUID(), name: "Empty", customStoragePath: emptyStorage)

        // Earlier launch: session files with saved schedules, written after their index entries.
        let earlier = makeService(store: makeStore())
        let base = Date(timeIntervalSince1970: 1000)
        let first = try await writeScheduledSession(
            earlier, in: closed, storage: closedStorage, name: "Closed 1", state: .needsConfirmation, notBefore: base
        )
        let second = try await writeScheduledSession(
            earlier, in: closed, storage: closedStorage, name: "Closed 2", state: .needsConfirmation, notBefore: base.addingTimeInterval(60)
        )
        let third = try await writeScheduledSession(
            earlier, in: closed, storage: closedStorage, name: "Closed 3", state: .needsConfirmation, notBefore: base.addingTimeInterval(120)
        )
        let pending = try await writeScheduledSession(
            earlier, in: closed, storage: closedStorage, name: "Closed 4", state: .scheduled, notBefore: base.addingTimeInterval(180)
        )
        _ = try await writeScheduledSession(
            earlier, in: unindexed, storage: unindexedStorage, name: "Unindexed", state: .needsConfirmation, notBefore: base
        )
        try? FileManager.default.removeItem(at: sessionIndexURL(closedStorage))
        try? FileManager.default.removeItem(at: sessionIndexURL(unindexedStorage))

        // This launch: the closed workspace's index is current (an ordinary sidebar read rebuilt it);
        // the other workspace has none.
        let store = makeStore()
        let service = makeService(store: store)
        _ = try await service.indexedAgentSessionMetadataRecords(for: closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionIndexURL(closedStorage).path))
        let coordinator = try await startedCoordinator(store: store, service: service)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .open)
        let hydrated = HydratedSessions()
        coordinator.attachScheduler(
            scheduler,
            hydratedSessionIDs: { hydrated.ids },
            indexWorkspaces: { [closed, unindexed, empty] }
        )
        await coordinator.indexedScheduleRefresh?.value

        let item = try XCTUnwrap(coordinator.catalog.item(id: first.itemID))
        XCTAssertEqual(item.kind, .scheduleNeedsConfirmation)
        XCTAssertEqual(item.sessionID, first.sessionID)
        XCTAssertEqual(item.workspaceID, closed.id)
        XCTAssertEqual(item.sessionName, "Closed 1")
        XCTAssertEqual(item.composeTabID, first.tabID)
        guard case let .scheduleNeedsConfirmation(summary) = item.payload else {
            return XCTFail("Unexpected payload \(item.payload)")
        }
        XCTAssertEqual(summary.scheduleID, first.scheduleID)
        XCTAssertEqual(summary.reason, .missedWhileClosed)
        XCTAssertNil(summary.attemptID)
        XCTAssertEqual(summary.notBefore, base)
        XCTAssertNotNil(coordinator.catalog.item(id: second.itemID))
        XCTAssertNotNil(coordinator.catalog.item(id: third.itemID))
        XCTAssertNil(coordinator.catalog.item(id: pending.itemID), "A schedule not awaiting confirmation is not listed")
        let unchecked = try XCTUnwrap(coordinator.catalog.item(id: "schedule-index-\(unindexed.id.uuidString)"))
        XCTAssertEqual(unchecked.kind, .statusUnknown)
        XCTAssertNil(unchecked.acknowledgement)
        XCTAssertNil(coordinator.catalog.item(id: "schedule-index-\(empty.id.uuidString)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionIndexURL(unindexedStorage).path), "Discovery never rebuilds an index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyStorage.path), "Discovery creates nothing")
        XCTAssertTrue(scheduler.confirmationSummaries().isEmpty, "Nothing was registered or hydrated for the catalog")

        // A hydrated session's owner is authoritative: only its own index item is withdrawn. (In
        // production hydration registers with the scheduler, whose dashboard change re-projects.)
        hydrated.ids = [first.sessionID]
        coordinator.invalidateCatalog()
        XCTAssertNil(coordinator.catalog.item(id: first.itemID))
        XCTAssertNotNil(coordinator.catalog.item(id: second.itemID))

        // A transfer hold on one schedule's exact attempt withdraws that schedule only, through the
        // scheduler's own dashboard notification.
        let hold = AgentScheduledSendTransferHold(
            sessionID: second.sessionID,
            scheduleID: second.scheduleID,
            scheduleAttemptID: UUID(),
            reason: .awaitingRecovery
        )
        scheduler.holdTransfer(hold)
        let held = await Support.eventually { coordinator.catalog.item(id: second.itemID) == nil }
        XCTAssertTrue(held, "A held attempt is presented by its transfer, not as a confirmation")
        XCTAssertNotNil(coordinator.catalog.item(id: third.itemID), "A different schedule stays listed")
        scheduler.releaseTransferHold(scheduleID: hold.scheduleID, scheduleAttemptID: hold.scheduleAttemptID)
        let released = await Support.eventually { coordinator.catalog.item(id: second.itemID) != nil }
        XCTAssertTrue(released)
    }

    // MARK: Deleted sessions

    // MARK: Shutdown (R4 two-stage quit / window close)

    private func questionSnapshot(
        _ store: AgentRecoveryStore,
        secretAnswer: String? = nil
    ) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: UUID(),
            kind: .userInput,
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: store.appInstanceID,
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            title: "Deploy?",
            message: nil,
            items: [
                AgentRecoveryQuestionItem(
                    questionID: "target",
                    header: "Target",
                    text: "Which environment?",
                    options: ["staging", "production"],
                    isSecret: false,
                    answer: "staging"
                ),
                AgentRecoveryQuestionItem(
                    questionID: "token",
                    header: nil,
                    text: "Paste the token",
                    options: [],
                    isSecret: true,
                    answer: secretAnswer
                )
            ]
        )
    }

    /// Scoped admission refusal on every route (queued, direct, dispatch commit, handoff): only the
    /// covered owner is frozen, an app-wide freeze covers lanes claimed later, and ending the freeze
    /// (Stage A Cancel) reopens everything.
    func testShutdownFreezeRefusesEveryRouteForCoveredOwnersOnlyAndCancelReopens() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let loadA = try await makeSession(service)
        let loadB = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let ownerA = Owner()
        let ownerB = Owner()
        let laneA = try coordinator.claimLane(owner: ownerA, persistenceState: loadA.persistenceState)
        let laneB = try coordinator.claimLane(owner: ownerB, persistenceState: loadB.persistenceState)
        _ = await laneA.restoreComposer()
        _ = await laneB.restoreComposer()
        guard case let .success(queued) = await laneA.admitQueued(admission(laneA, "queued before the freeze")) else {
            return XCTFail("admission is open before the freeze")
        }
        let dispatch = [AgentRecoveryDispatchRequest(
            intentID: queued.receipt.intent.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID())
        )]

        let token = coordinator.beginShutdownFreeze(scope: .owners([ObjectIdentifier(ownerA)]))
        XCTAssertTrue(laneA.isShutdownFrozen)
        XCTAssertFalse(laneB.isShutdownFrozen, "a window close freezes only its own owners")
        let frozenQueued = await laneA.admitQueued(admission(laneA, "queued"))
        assertRefused(frozenQueued, .shutdownInProgress)
        let direct = await laneA.admitDirect(admission(laneA, "direct"), attempt: AgentRecoveryAttemptStart(attemptID: UUID()))
        guard case .failure(.refused(.shutdownInProgress)) = direct else {
            return XCTFail("direct admission is refused while frozen, got \(direct)")
        }
        let frozenDispatch = await laneA.beginDispatches(dispatch, authorization: .liveQueue)
        guard case .failure(.refused(.shutdownInProgress)) = frozenDispatch else {
            return XCTFail("a dispatch commit is refused while frozen, got \(frozenDispatch)")
        }
        XCTAssertFalse(laneA.isValidForHandoff, "no provider handoff while frozen")
        XCTAssertTrue(laneB.isValidForHandoff)
        guard case .success = await laneB.admitQueued(admission(laneB, "other window")) else {
            return XCTFail("an unaffected owner keeps admitting")
        }

        coordinator.endShutdownFreeze(token)
        XCTAssertFalse(laneA.isShutdownFrozen)
        XCTAssertTrue(laneA.isValidForHandoff)
        guard case .success = await laneA.admitQueued(admission(laneA, "after cancel")) else {
            return XCTFail("Cancel reopens admission")
        }
        guard case .success = await laneA.beginDispatches(dispatch, authorization: .liveQueue) else {
            return XCTFail("Cancel reopens dispatch commits")
        }

        let appToken = coordinator.beginShutdownFreeze(scope: .application)
        let loadC = try await makeSession(service)
        let laneC = try coordinator.claimLane(owner: Owner(), persistenceState: loadC.persistenceState)
        XCTAssertTrue(laneB.isShutdownFrozen)
        XCTAssertTrue(laneC.isShutdownFrozen, "an app quit also covers lanes claimed after it began")
        coordinator.endShutdownFreeze(appToken)
        XCTAssertFalse(coordinator.hasShutdownFreeze)
    }

    /// Stage A vetoes on input an unsaved predecessor holds only in memory, leaves the lane usable,
    /// and on success writes the composer, the pending-question snapshots (never a secret answer),
    /// and the run's shutdown reason (the first reason is kept across attempts).
    func testShutdownPreparationVetoesUnsavedPredecessorThenPersistsQuestionsAndRunReason() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        failures.shouldFailWrites = true
        XCTAssertNotNil(first.composerDidChange(Support.content("unsaved before replacement")))
        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        // Joins the predecessor's (failing) hand-over flush.
        let blocked = await second.admitQueued(admission(second, "blocked"))
        assertRefused(blocked, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(second.unsavedPredecessorInputs.first)
        failures.shouldFailWrites = false
        _ = await second.restoreComposer()

        let vetoed = await second.prepareForShutdown(questions: .init(upserting: [questionSnapshot(store)]), run: nil)
        guard case .failure(.composer(.unsavedPredecessorInput)) = vetoed else {
            return XCTFail("input held only in memory vetoes Stage A, got \(vetoed)")
        }
        XCTAssertFalse(second.isRetired, "a veto leaves the lane usable")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited])
        let afterVeto = await store.read(sessionID: load.session.id).record?.questions ?? []
        XCTAssertTrue(afterVeto.isEmpty, "nothing after the veto was written")

        _ = await second.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: true)
        second.composerDidChange(Support.content("typed before quitting"))
        let snapshot = questionSnapshot(store, secretAnswer: "s3cr3t")
        XCTAssertNil(snapshot.items[1].answer, "a secret answer is structurally absent")
        let ownership = Support.ownership(sessionID: load.session.id)
        let run = AgentRecoverySessionLane.ShutdownRunEvidence(
            ownership: ownership,
            processRunID: nil,
            reason: .windowClose,
            lastConfirmedActivityAt: nil
        )
        guard case .success = await second.prepareForShutdown(questions: .init(upserting: [snapshot]), run: run) else {
            return XCTFail("Stage A succeeds once nothing is held only in memory")
        }
        let prepared = await store.read(sessionID: load.session.id).record
        let record = try XCTUnwrap(prepared)
        XCTAssertEqual(record.composer?.content.text, "typed before quitting")
        XCTAssertEqual(record.questions, [snapshot])
        XCTAssertEqual(record.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .windowClose)
        XCTAssertNil(record.runAttempt(id: ownership.attemptID)?.terminal, "a shutdown reason is not a stop")

        // A later attempt (window close cancelled, then app quit) keeps the first reason.
        let laterRun = AgentRecoverySessionLane.ShutdownRunEvidence(
            ownership: ownership,
            processRunID: nil,
            reason: .appQuit,
            lastConfirmedActivityAt: nil
        )
        let resolved = AgentRecoveryStore.QuestionSnapshotUpdate(removing: [snapshot.interactionID])
        guard case .success = await second.prepareForShutdown(questions: resolved, run: laterRun) else {
            return XCTFail("a repeated preparation succeeds")
        }
        let repeatedRecord = await store.read(sessionID: load.session.id).record
        let repeated = try XCTUnwrap(repeatedRecord)
        XCTAssertEqual(repeated.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .windowClose)
        XCTAssertTrue(repeated.questions.isEmpty, "a resolved question is removed by its interaction ID")
        guard case .success = await second.admitQueued(admission(second, "still usable")) else {
            return XCTFail("preparation never retires the lane or keeps admission closed")
        }
    }

    /// R4-01: question writes name exact interactions. A question another owner preserved, from an
    /// earlier launch or from a window closed earlier in this same launch (its snapshot carries
    /// this launch's instance ID), survives a reopened owner's preparation without live questions.
    /// Only an exact removal (live resolution, the recovery list) erases a snapshot; re-upserting a
    /// stored question replaces it in place and reports it as already stored.
    func testQuestionWritesNameExactInteractionsAndKeepOtherOwnersSnapshots() async throws {
        let previousStore = makeStore(instance: UUID())
        let previousService = makeService(store: previousStore)
        let load = try await makeSession(previousService)
        let previousGate = try previousService.recoveryLifecycleGate(for: load.persistenceState)
        let earlier = questionSnapshot(previousStore)
        try await previousGate.performRecoveryTransaction {
            _ = try await previousStore.updateQuestionSnapshots(
                binding: previousGate.binding,
                expectedRevision: previousStore.currentRevision(sessionID: load.session.id),
                update: .init(upserting: [earlier])
            )
        }

        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let reloaded = try await service.loadAgentSessionForEditing(id: load.session.id, for: workspace)
        let persistenceState = try XCTUnwrap(reloaded?.persistenceState)
        let closedOwner = try coordinator.claimLane(owner: Owner(), persistenceState: persistenceState)
        _ = await closedOwner.restoreComposer()

        // A window of this launch preserves its live question, then closes.
        let closed = questionSnapshot(store)
        guard case let .success(alreadyStored) = await closedOwner.prepareForShutdown(
            questions: .init(upserting: [closed]),
            run: nil
        ) else {
            return XCTFail("the closing window's preparation succeeds")
        }
        XCTAssertEqual(alreadyStored, [])
        XCTAssertEqual(closed.appInstanceID, store.appInstanceID, "the closed window's snapshot is this launch's")

        // The session reopens in another window of the same launch, with no live question.
        let reopened = try coordinator.claimLane(owner: Owner(), persistenceState: persistenceState)
        _ = await reopened.restoreComposer()
        guard case .success = await reopened.prepareForShutdown(questions: .init(), run: nil) else {
            return XCTFail("preparation without live questions succeeds")
        }
        var stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, closed], "no live question erases neither launch's preserved question")

        let live = questionSnapshot(store)
        guard case let .success(newlyStored) = await reopened.prepareForShutdown(
            questions: .init(upserting: [live]),
            run: nil
        ) else {
            return XCTFail("preparation with a live question succeeds")
        }
        XCTAssertEqual(newlyStored, [], "a new live question is not already stored")
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, closed, live])

        var revised = closed
        revised.extras["revision"] = .string("2")
        guard case let .success(restored) = await reopened.prepareForShutdown(
            questions: .init(upserting: [revised]),
            run: nil
        ) else {
            return XCTFail("re-upserting a stored question succeeds")
        }
        XCTAssertEqual(restored, [closed.interactionID], "a re-upserted question is reported as already stored")
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, revised, live], "replaced in place")

        // Live resolution removes exactly its interaction.
        guard case .success = await reopened.updateQuestionSnapshots(.init(removing: [live.interactionID])) else {
            return XCTFail("live refresh succeeds")
        }
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, revised])

        // The recovery list removes exactly the question it resolved.
        guard case .success = await reopened.updateQuestionSnapshots(.init(removing: [earlier.interactionID])) else {
            return XCTFail("the recovery list removes its question")
        }
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [revised])
    }

    /// Question snapshots round-trip through a fresh store; a secret answer stored on disk makes the
    /// record unreadable instead of being adopted.
    func testQuestionSnapshotsRoundTripAndAStoredSecretAnswerIsUnreadable() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await lane.restoreComposer()
        var snapshot = questionSnapshot(store)
        snapshot.extras["futureField"] = .string("kept")
        guard case .success = await lane.updateQuestionSnapshots(.init(upserting: [snapshot])) else {
            return XCTFail("question snapshots are written")
        }
        let reread = await makeStore().read(sessionID: load.session.id).record
        XCTAssertEqual(reread?.questions, [snapshot], "unknown fields and every item survive a round trip")

        let fileURL = store.recordFileURL(sessionID: load.session.id)
        let data = try Data(contentsOf: fileURL)
        guard case .success = AgentRecoveryRecordCodec.decode(data, expectedSessionID: load.session.id) else {
            return XCTFail("the written record decodes")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        var items = try XCTUnwrap(questions[0]["items"] as? [[String: Any]])
        XCTAssertNil(items[1]["answer"], "no secret answer was written")
        items[1]["answer"] = "leaked"
        questions[0]["items"] = items
        object["questions"] = questions
        let tampered = try JSONSerialization.data(withJSONObject: object)
        guard case .failure = AgentRecoveryRecordCodec.decode(tampered, expectedSessionID: load.session.id) else {
            return XCTFail("a stored secret answer is never adopted")
        }
    }

    func testDeletedSessionNeverRestoresOrAdmits() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("draft before deletion"))
        _ = await seed.flushComposer()

        let deletion = try AgentSessionDeletionCandidate(
            composeTabID: XCTUnwrap(load.session.composeTabID),
            persistenceState: load.persistenceState
        )
        let deleted = try await service.deleteAgentSession(ifCurrent: deletion, for: workspace)
        XCTAssertEqual(deleted, .deleted)

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case .failed(.lifecycleRejected) = outcome else {
            return XCTFail("a tombstoned session never restores, got \(outcome)")
        }
        let refused = await lane.admitQueued(admission(lane, "after deletion"))
        guard case .failure(.commitFailed(.lifecycleRejected)) = refused else {
            return XCTFail("a tombstoned session never admits, got \(refused)")
        }
    }

    /// A session whose earlier launch crashed mid-dispatch: on relaunch it has a crash hold, its
    /// card and its run's rows, all from the startup snapshot.
    private func makeSessionCrashedInAnEarlierLaunch() async throws -> AgentSessionEditableLoad {
        let previousStore = makeStore(instance: UUID())
        let previousService = makeService(store: previousStore)
        let load = try await makeSession(previousService)
        let previousGate = try previousService.recoveryLifecycleGate(for: load.persistenceState)
        let ownership = Support.ownership(sessionID: load.session.id)
        try await previousGate.performRecoveryTransaction {
            _ = try await previousStore.ensureRunAttempt(
                binding: previousGate.binding, expectedRevision: nil, ownership: ownership,
                processRunID: nil, transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await previousStore.commitDispatchingIntent(
                binding: previousGate.binding,
                expectedRevision: previousStore.currentRevision(sessionID: load.session.id),
                submission: Support.submission("in flight at crash"),
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: ownership.attemptID),
                consumption: nil
            )
        }
        return load
    }

    /// Counts one notification posted by one object (delivered on the posting thread).
    private final class NotificationCount: @unchecked Sendable {
        private(set) var value = 0
        private var token: (any NSObjectProtocol)?

        init(_ name: Notification.Name, object: AnyObject) {
            token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                self?.value += 1
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Delivers every catalog-change post already scheduled before counting starts. Posts are
    /// coalesced, so one more invalidation joins any pending post; its delivery shows none is left.
    private func drainCatalogChanges(_ coordinator: AgentRecoveryCoordinator) async {
        let drained = NotificationCount(.agentRecoveryCatalogDidChange, object: coordinator)
        coordinator.invalidateCatalog()
        let delivered = await Support.eventually { drained.value >= 1 }
        XCTAssertTrue(delivered, "a pending catalog-change post never ran")
    }

    /// Once the awaited notification arrived, lets a later one land before an exact count is
    /// asserted (only the upper bound depends on it).
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    /// F8: deleting a session takes its Needs Attention items out of the open app's catalog at once
    /// (every window and the badge read it), including the rows built from this launch's startup
    /// snapshot, and its crash hold no longer pauses its workspace's other sessions.
    func testDeletedSessionLeavesTheCatalogAndReleasesItsCrashHold() async throws {
        let load = try await makeSessionCrashedInAnEarlierLaunch()
        let otherSessionID = UUID()
        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let sessionID = load.session.id
        XCTAssertNotNil(coordinator.crashHold(for: sessionID))
        XCTAssertEqual(coordinator.catalog.blockers[sessionID], .crashHold)
        XCTAssertTrue(coordinator.catalog.items.contains { $0.sessionID == sessionID && $0.id == "crash-\(sessionID.uuidString)" })
        XCTAssertGreaterThan(coordinator.catalog.openNeedsActionCount, 0)
        XCTAssertTrue(coordinator.hasUnresolvedSession(inWorkspace: workspace.id, excluding: otherSessionID))
        await drainCatalogChanges(coordinator)
        let coordinatorChanges = NotificationCount(.agentRecoveryCoordinatorDidChange, object: coordinator)
        let catalogChanges = NotificationCount(.agentRecoveryCatalogDidChange, object: coordinator)

        try await service.deleteAgentSession(id: sessionID, for: workspace)

        let removed = await Support.eventually {
            !coordinator.catalog.items.contains { $0.sessionID == sessionID }
        }
        XCTAssertTrue(removed, "\(coordinator.catalog.items.map(\.id))")
        XCTAssertTrue(coordinator.deletedSessionIDs.contains(sessionID))
        XCTAssertEqual(coordinator.catalog.openNeedsActionCount, 0, "the badge no longer counts them")
        XCTAssertTrue(coordinator.catalog.needsAttentionItems(includeDismissed: true).isEmpty)
        XCTAssertNil(coordinator.catalog.blockers[sessionID])
        XCTAssertNil(coordinator.crashHold(for: sessionID))
        XCTAssertFalse(coordinator.hasUnresolvedSession(inWorkspace: workspace.id, excluding: otherSessionID))
        XCTAssertTrue(coordinator.unresolvedSessionSummary(inWorkspace: workspace.id, excluding: otherSessionID).isEmpty)
        // Windows and the badge are told: one coordinator change for the deletion; the catalog
        // change is coalesced, and this deletion's record removal may add at most one more.
        let announced = await Support.eventually { catalogChanges.value >= 1 }
        XCTAssertTrue(announced)
        try await settle()
        XCTAssertEqual(coordinatorChanges.value, 1)
        XCTAssertTrue((1 ... 2).contains(catalogChanges.value), "\(catalogChanges.value)")

        // The next launch agrees: the tombstone retires the session.
        let nextStore = makeStore(instance: UUID())
        let nextCoordinator = try await startedCoordinator(store: nextStore, service: makeService(store: nextStore))
        XCTAssertFalse(nextCoordinator.catalog.items.contains { $0.sessionID == sessionID })
        XCTAssertNil(nextCoordinator.crashHold(for: sessionID))
    }

    /// F8: an unreadable record is preserved on deletion and publishes no record commit; the
    /// tombstone alone takes its status row and session restriction away, announcing it once.
    func testDeletedSessionWithAnUnreadableRecordLeavesTheCatalog() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let sessionID = load.session.id
        let recordURL = store.recordFileURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a recovery record".utf8).write(to: recordURL)

        let coordinator = try await startedCoordinator(store: store, service: service)
        let statusItemID = "status-\(sessionID.uuidString)"
        XCTAssertNotNil(coordinator.catalog.item(id: statusItemID), "\(coordinator.catalog.items.map(\.id))")
        XCTAssertNotNil(coordinator.restrictions.sessionRestriction(sessionID))
        await drainCatalogChanges(coordinator)
        let coordinatorChanges = NotificationCount(.agentRecoveryCoordinatorDidChange, object: coordinator)
        let catalogChanges = NotificationCount(.agentRecoveryCatalogDidChange, object: coordinator)

        try await service.deleteAgentSession(id: sessionID, for: workspace)

        let removed = await Support.eventually { coordinator.catalog.item(id: statusItemID) == nil }
        XCTAssertTrue(removed)
        XCTAssertFalse(coordinator.catalog.items.contains { $0.sessionID == sessionID })
        XCTAssertNil(coordinator.restrictions.sessionRestriction(sessionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "unreadable bytes are preserved")
        let announced = await Support.eventually { catalogChanges.value >= 1 }
        XCTAssertTrue(announced)
        try await settle()
        XCTAssertEqual(coordinatorChanges.value, 1)
        XCTAssertEqual(catalogChanges.value, 1, "windows and the badge are told once")

        // A repeated note of the same deletion changes and announces nothing.
        coordinator.noteSessionDeleted(sessionID)
        try await settle()
        XCTAssertEqual(coordinatorChanges.value, 1)
        XCTAssertEqual(catalogChanges.value, 1)
    }

    /// F8: a deletion noted while startup is still loading, after the sweep read the session and
    /// before startup publishes, leaves no crash hold, restriction or item once startup is ready.
    func testSessionDeletedWhileStartupIsLoadingStaysRetired() async throws {
        let load = try await makeSessionCrashedInAnEarlierLaunch()
        let sessionID = load.session.id
        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let probe = ReconcileProbe()
        probe.suspends = true
        let destination = AgentRecoveryWorkspaceDestination(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { report in
                // The sweep reads the session before the deletion; startup publishes after it.
                let results = await AgentRecoveryStartupSweep.run(
                    inventory: AgentRecoveryWorkspaceInventory(workspaces: [destination]),
                    entries: report.discovered,
                    dataService: service
                )
                try await probe.run(report)
                return results
            }
        )
        coordinator.startIfNeeded()
        await probe.waitUntilSuspended()
        XCTAssertEqual(coordinator.startupState, .loading)

        try await service.deleteAgentSession(id: sessionID, for: workspace)
        let noted = await Support.eventually { coordinator.deletedSessionIDs.contains(sessionID) }
        XCTAssertTrue(noted)
        probe.release()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)

        XCTAssertNotNil(coordinator.startupReport?.crashHolds[sessionID], "the sweep saw the session before its deletion")
        XCTAssertNil(coordinator.crashHold(for: sessionID))
        XCTAssertNil(coordinator.restrictions.sessionRestriction(sessionID))
        XCTAssertFalse(coordinator.catalog.items.contains { $0.sessionID == sessionID }, "\(coordinator.catalog.items.map(\.id))")
        XCTAssertNil(coordinator.catalog.blockers[sessionID])
        XCTAssertFalse(coordinator.hasUnresolvedSession(inWorkspace: workspace.id, excluding: UUID()))
    }

    /// F8 / review B VF-8: a deleted session's ownerless unsaved input can never be saved or
    /// restored, and its row is gone, so quit no longer refuses over it.
    func testDeletedSessionNoLongerHoldsQuitOverItsUnsavedInput() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let sessionID = load.session.id
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await lane.restoreComposer()
        failures.shouldFailWrites = true
        lane.composerDidChange(Support.content("unsaved when the tab closed"))
        await coordinator.releaseLane(lane).value
        failures.shouldFailWrites = false
        XCTAssertNotNil(coordinator.ownerlessUnsavedInputs[sessionID])
        let unsavedBefore = await coordinator.settleReleasedRetirements()
        XCTAssertTrue(unsavedBefore.contains(sessionID))
        await drainCatalogChanges(coordinator)
        let coordinatorChanges = NotificationCount(.agentRecoveryCoordinatorDidChange, object: coordinator)
        let composerChanges = NotificationCount(.agentRecoveryComposerStateDidChange, object: coordinator)
        let catalogChanges = NotificationCount(.agentRecoveryCatalogDidChange, object: coordinator)

        coordinator.noteSessionDeleted(sessionID)

        XCTAssertNil(coordinator.ownerlessUnsavedInputs[sessionID])
        // Review B VF-R1-7: the deletion is announced once to each kind of observer; the composer
        // change (the session's composer state) is a separate notification, not a second
        // coordinator change, and the catalog change is coalesced.
        let announced = await Support.eventually { catalogChanges.value >= 1 }
        XCTAssertTrue(announced)
        try await settle()
        XCTAssertEqual(coordinatorChanges.value, 1)
        XCTAssertEqual(composerChanges.value, 1)
        XCTAssertEqual(catalogChanges.value, 1)
        let unsavedAfter = await coordinator.settleReleasedRetirements()
        XCTAssertFalse(unsavedAfter.contains(sessionID))
        XCTAssertFalse(coordinator.catalog.items.contains { $0.sessionID == sessionID })
    }
}
