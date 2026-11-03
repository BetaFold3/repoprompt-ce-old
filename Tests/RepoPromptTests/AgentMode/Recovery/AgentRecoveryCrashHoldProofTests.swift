import Darwin
@testable import RepoPromptAgentCore
import XCTest

/// Step 9-activation-b: Check and resolve confirms a crash hold only from process-record proof.
/// An earlier launch records the held run (with or without the run-start registration mark) and
/// leaves runtime records; a later launch's coordinator (real startup sweep, scripted process
/// boundaries, a registry over the same recovery root) runs Check on the hold's card. Nothing
/// inspects, watches or signals a real process.
@MainActor
final class AgentRecoveryCrashHoldProofTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures
    private typealias Support = RecoveryTestSupport
    private typealias Text = AgentRecoveryCrashHoldCheckText

    private struct Launch {
        let store: AgentRecoveryStore
        let service: AgentSessionDataService
    }

    /// One earlier launch's held session, as the later launch sees it.
    private struct Held {
        let load: AgentSessionEditableLoad
        let binding: AgentRecoveryLifecycleBinding
        let runAttemptID: UUID
    }

    private static let conversation = "conv-held"
    private static let worktree = "/tmp/rpce-crash-hold-proof/wt-held"

    private var root: URL!
    private var recoveryRoot: URL!
    private var processes: ScriptedProcessSystem!
    private var registries: [AgentProcessRegistry] = []
    private var keysBySession: [UUID: [AgentRuntimeOwnershipKeys]] = [:]
    private var nextPID: pid_t = 7000

    override func setUp() async throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryCrashHoldProofTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        processes = ScriptedProcessSystem()
        registries = []
        keysBySession = [:]
    }

    override func tearDown() async throws {
        for registry in registries {
            await registry.disposeWatches()
        }
        registries = []
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Tests

    /// A closed session's hold whose registered run's processes are all proven exited is confirmed
    /// without opening the session; the exact acknowledgement is durable, so the next launch does
    /// not ask again. A `.stopped` record counts as exited (written only after a verified exit).
    func testClosedSessionHoldIsConfirmedFromProofWithoutOpeningAndStaysConfirmed() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        try seedRecord(held, state: .stopped)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        let itemID = try crashHoldItemID(coordinator, held)
        XCTAssertNotNil(coordinator.blockingCrashHold(for: held.binding))

        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .resolved(Text.confirmed))
        XCTAssertNil(coordinator.lane(for: held.load.session.id), "the session was never opened")
        XCTAssertNil(coordinator.blockingCrashHold(for: held.binding), "sending is no longer paused")
        let acknowledgement = await acknowledgement(now, held)
        XCTAssertTrue(hold.isCovered(by: acknowledgement), "the exact acknowledgement It stopped writes")
        XCTAssertNotEqual(coordinator.catalogActionStates[itemID], .working, "the row it marked working is released")

        let next = try await startedCoordinator(launch(), workspaces: [home])
        XCTAssertNotNil(next.crashHold(for: held.load.session.id), "the evidence is still presented")
        XCTAssertNil(next.blockingCrashHold(for: held.binding), "the identical hold stays acknowledged")
    }

    /// The run-start mark is required: a run started before activation (no mark) is never
    /// confirmed even though a record names it and every record is exited.
    func testRunWithoutTheRunStartMarkIsNeverConfirmed() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home, marked: false)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.notRegistered))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// An empty registry proves nothing: a marked run with no earlier-launch record naming it is
    /// not confirmed, nor is one named only by this launch's own record.
    func testEmptyRegistryOrOnlyCurrentLaunchRecordsProveNothing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let empty = try await heldSession(earlier, in: home)
        let currentOnly = try await heldSession(earlier, in: home)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        try await reserveCurrentLaunch(naming: currentOnly)

        let emptyOutcome = try await check(coordinator, empty)
        XCTAssertEqual(emptyOutcome, Text.needsYou(Text.notRecorded))
        await assertNotConfirmed(coordinator, now, empty)
        let currentOutcome = try await check(coordinator, currentOnly)
        XCTAssertEqual(currentOutcome, Text.needsYou(Text.notRecorded))
        await assertNotConfirmed(coordinator, now, currentOnly)
    }

    /// A current-launch record naming the held attempt (the shape of a Codex Reconcile's
    /// association) neither blocks nor counts: with the earlier launch's records exited, it confirms.
    func testCurrentLaunchRecordNamingTheHeldRunDoesNotBlock() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        try await reserveCurrentLaunch(naming: held)

        let outcome = try await check(coordinator, held)
        XCTAssertEqual(outcome, .resolved(Text.confirmed))
    }

    /// F1: every earlier-launch record that could belong to the session must be exited, also when
    /// the adopted snapshot would not restrict the session: a sessionless one, one naming the
    /// session at another incarnation, one sharing only its worktree, one sharing only its
    /// conversation (the closed session's keys come from its own records' associations).
    func testPossibleEarlierLaunchWritersRefuseTheProof() async throws {
        enum Writer: String, CaseIterable {
            case sessionless, otherIncarnation, sameWorktreeOnly, sameConversationOnly
        }
        for writer in Writer.allCases {
            recoveryRoot = root.appendingPathComponent("\(writer.rawValue)/AgentRecovery/v1", isDirectory: true)
            let earlier = launch()
            let home = try makeWorkspace("home-\(writer.rawValue)")
            let held = try await heldSession(earlier, in: home)
            try seedRecord(held, state: .exited)
            switch writer {
            case .sessionless:
                try seedLiveWriter(session: nil, conversationID: "conv-other", worktreePath: "/tmp/rpce-crash-hold-proof/other")
            case .otherIncarnation:
                try seedLiveWriter(
                    session: Fixtures.session(held.load.session.id, incarnationID: UUID(), runAttemptID: nil),
                    conversationID: "conv-other",
                    worktreePath: "/tmp/rpce-crash-hold-proof/other"
                )
            case .sameWorktreeOnly:
                try seedLiveWriter(session: Fixtures.session(), conversationID: "conv-other", worktreePath: Self.worktree)
            case .sameConversationOnly:
                try seedLiveWriter(session: Fixtures.session(), conversationID: Self.conversation, worktreePath: "/tmp/rpce-crash-hold-proof/other")
            }

            let now = launch()
            let coordinator = try await startedCoordinator(now, workspaces: [home])
            if writer == .sessionless || writer == .sameWorktreeOnly {
                XCTAssertNil(coordinator.runtimeSendRestriction(sessionID: held.load.session.id), "\(writer): the snapshot alone would allow it")
            }
            let outcome = try await check(coordinator, held)
            XCTAssertEqual(outcome, Text.needsYou(Text.mayBeRunning), "\(writer)")
            await assertNotConfirmed(coordinator, now, held)
        }
    }

    /// B A5: a record naming the session whose association carries no keys still contributes its
    /// record-level worktree: a live earlier-launch record of another session in that worktree
    /// refuses the proof (the closed session has no window keys).
    func testRecordLevelWorktreeOfTheSessionsOwnRecordIsTouched() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited, associationKeys: false)
        try seedLiveWriter(session: Fixtures.session(), conversationID: "conv-other", worktreePath: Self.worktree)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        XCTAssertNil(coordinator.runtimeSendRestriction(sessionID: held.load.session.id), "the snapshot alone would allow it")
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.mayBeRunning))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// Every process must have exited: an earlier-launch record of the held run whose root exited
    /// but whose tool still runs (`toolsRemaining`) refuses.
    func testToolsRemainingEarlierLaunchRecordRefuses() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        let rootPID = nextPID
        nextPID += 2
        let record = try Fixtures.seed(
            rootURL: recoveryRoot,
            state: .toolsRemaining,
            root: processes.identity(pid: rootPID),
            rootGroup: rootPID,
            members: [AgentRuntimeMember(identity: processes.identity(pid: rootPID + 1, start: 200), processGroupID: rootPID, role: .tool)],
            associations: [association(held, runAttemptID: held.runAttemptID, keys: true)],
            conversationIDs: [Self.conversation],
            worktreePaths: [Self.worktree]
        )
        processes.add(processes.observation(
            pid: rootPID + 1, start: 200, parent: 1, executable: "/usr/bin/node", group: rootPID, marker: record.runtimeID
        ))

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        XCTAssertEqual(Fixtures.record(now.store, record.runtimeID)?.state, .toolsRemaining, "its tool still runs")
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.mayBeRunning))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// An unreadable runtime record naming the session makes ownership uncertain.
    func testUnreadableRecordNamingTheSessionRefuses() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = #"{"schemaVersion":99,"conversationIDs":[],"worktreePaths":[],"associations":[{"session":{"sessionID":"\#(held.load.session.id.uuidString)"}}]}"#
        try Data(bytes.utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.ownershipUncertain))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// F4: a hold left by two crashed launches (each run marked, each run's records exited) is
    /// confirmed; no instance needs to match another.
    func testMixedInstanceHoldIsConfirmed() async throws {
        let first = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(first, in: home)
        let second = launch()
        let loaded = try await second.service.loadAgentSessionForEditing(id: held.load.session.id, for: home)
        let secondLoad = try XCTUnwrap(loaded)
        let laterRun = try await openRun(second, secondLoad)
        try seedRecord(held, state: .exited)
        try seedRecord(held, runAttemptID: laterRun, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        XCTAssertEqual(coordinator.crashHold(for: held.load.session.id)?.uncertainRunAttemptIDs, [held.runAttemptID, laterRun])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .resolved(Text.confirmed))
    }

    /// O43 (deliberate contract change from "any uncertain input refuses"): uncertain input whose
    /// attempt isn't tied to a run attempt (a send left dispatching with no run reference) is never
    /// settled, so the hold is not confirmed automatically.
    func testHoldWithUncertainInputNotTiedToTheRunIsNotConfirmed() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: nil)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.messageNotOnProvenRun))
        await assertNotConfirmed(coordinator, now, held)
        let state = await deliveryState(now, held, intentID)
        XCTAssertEqual(state, .dispatching)
    }

    /// O43, the Claude shape: an earlier launch's registered run with a message still `dispatching`
    /// on it (Claude acceptance arrives only with the turn's result). With every process of the run
    /// proven exited, Check confirms the hold, lifts it, and in the same write settles the message
    /// to `deliveryUnknown`; its card becomes informational and never offers a resend.
    func testClaudeShapedHoldWithADispatchingMessageIsConfirmedAndSettled() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: held.runAttemptID)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        XCTAssertEqual(hold.uncertainIntentIDs, [intentID])
        let itemID = "intent-\(held.load.session.id.uuidString)-\(intentID.uuidString)"
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.attention, .needsAction, "before the proof it needs a decision")

        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .resolved(Text.confirmed))
        XCTAssertNil(coordinator.blockingCrashHold(for: held.binding), "sending is no longer paused")
        let record = await now.store.read(sessionID: held.load.session.id).record
        XCTAssertTrue(hold.isCovered(by: record?.crashHoldAcknowledgement))
        XCTAssertEqual(record?.intent(id: intentID)?.deliveryState, .deliveryUnknown)
        XCTAssertEqual(record?.intent(id: intentID)?.payload.text, "uncertain send", "the message text is kept")
        XCTAssertEqual(record?.attempts(forIntent: intentID).map(\.outcome?.outcome), [.deliveryUnknown])
        let settled = await waitUntil {
            coordinator.catalog.item(id: itemID)?.actionFacts.settledByExitProof == true
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.attention, .informational)

        let next = try await startedCoordinator(launch(), workspaces: [home])
        XCTAssertNil(next.blockingCrashHold(for: held.binding), "the identical hold stays acknowledged")
        let informationalNextLaunch = await waitUntil { next.catalog.item(id: itemID)?.attention == .informational }
        XCTAssertTrue(informationalNextLaunch, "the next launch still shows it as a note")
    }

    /// O43: the same shape with a process of the run still alive is refused; nothing is settled.
    func testDispatchingMessageOfARunWithALiveProcessIsNotSettled() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        try seedLiveWriter(
            session: AgentRuntimeSessionAssociation(lifecycle: held.binding, runAttemptID: held.runAttemptID, processRunID: nil),
            conversationID: Self.conversation,
            worktreePath: Self.worktree
        )
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: held.runAttemptID)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.mayBeRunning))
        await assertNotConfirmed(coordinator, now, held)
        let state = await deliveryState(now, held, intentID)
        XCTAssertEqual(state, .dispatching)
    }

    /// O43: a `queued` message of the same session is not part of the hold and stays untouched.
    func testQueuedMessageBesideTheSettledOneIsUntouched() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: held.runAttemptID)
        let queued = Support.submission("still queued")
        try await transact(earlier, held.load) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: queued,
                consumption: nil
            )
        }

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .resolved(Text.confirmed))
        let settledState = await deliveryState(now, held, intentID)
        XCTAssertEqual(settledState, .deliveryUnknown)
        let queuedState = await deliveryState(now, held, queued.intentID)
        XCTAssertEqual(queuedState, .queued)
        let queuedItem = coordinator.catalog.item(id: "intent-\(held.load.session.id.uuidString)-\(queued.intentID.uuidString)")
        XCTAssertEqual(queuedItem?.actionFacts.settledByExitProof, false)
        XCTAssertEqual(queuedItem?.attention, .needsAction)
    }

    /// O46: "It stopped" goes through the same settle as the proof (one row state).
    func testItStoppedSettlesTheRunsDispatchingMessageInTheSameWrite() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: held.runAttemptID)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        let lane = try await openLane(now, coordinator, held, in: home)

        let confirmed = await coordinator.confirmCrashHold(hold, lane: lane)

        XCTAssertTrue(confirmed)
        XCTAssertNil(coordinator.blockingCrashHold(for: lane.binding))
        let record = await now.store.read(sessionID: held.load.session.id).record
        XCTAssertTrue(hold.isCovered(by: record?.crashHoldAcknowledgement))
        XCTAssertEqual(record?.intent(id: intentID)?.deliveryState, .deliveryUnknown)
        XCTAssertEqual(record?.isSettledByCrashHoldExitProof(intentID: intentID), true)
    }

    /// Review B P2-3: Remove on the settled message narrows the next launch's hold (the run stays
    /// open evidence, the message is no longer uncertain). The narrower hold is covered by the
    /// acknowledgement, so sending isn't paused again for the same run.
    func testRemovingTheSettledMessageKeepsTheNarrowerHoldAcknowledgedOnTheNextLaunch() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)
        let intentID = try await dispatchingIntent(earlier, held, runAttemptID: held.runAttemptID)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held)
        XCTAssertEqual(outcome, .resolved(Text.confirmed))
        let lane = try await openLane(now, coordinator, held, in: home)
        let removed = await lane.withdraw(intentID: intentID)
        guard case .success = removed else { return XCTFail("Remove failed: \(removed)") }
        let state = await deliveryState(now, held, intentID)
        XCTAssertEqual(state, .withdrawn)

        let next = try await startedCoordinator(launch(), workspaces: [home])
        let hold = try XCTUnwrap(next.crashHold(for: held.load.session.id), "the run is still open evidence")
        XCTAssertEqual(hold.uncertainRunAttemptIDs, [held.runAttemptID])
        XCTAssertTrue(hold.uncertainIntentIDs.isEmpty, "the removed message is no longer part of the hold")
        XCTAssertNil(next.blockingCrashHold(for: held.binding), "the narrower hold stays acknowledged")
    }

    /// Before activation nothing is confirmed: the hold is reported as the user's choice.
    func testChecksInactiveConfirmsNothing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let outcome = try await check(coordinator, held, checksActive: false)

        XCTAssertEqual(outcome, .needsYou("Confirm the previous run stopped"))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// An open session's hold is confirmed through its live lane (same publication as It stopped).
    func testOpenSessionHoldIsConfirmedThroughItsLane() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let lane = try await openLane(now, coordinator, held, in: home)

        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .resolved(Text.confirmed))
        XCTAssertNil(coordinator.blockingCrashHold(for: lane.binding))
        let acknowledgement = await acknowledgement(now, held)
        XCTAssertNotNil(acknowledgement)
    }

    /// Another recovery action on the session (its shared hold) makes the confirmation wait for the
    /// user: nothing is written.
    func testRecoveryActionOnTheSessionRefusesAsBusy() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let lane = try await openLane(now, coordinator, held, in: home)
        let card = try XCTUnwrap(coordinator.catalog.item(id: crashHoldItemID(coordinator, held))?.acknowledgement)
        let request = try await AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: card.key,
            kind: .reconcileOnly,
            expectedRevision: now.store.currentRevision(sessionID: held.load.session.id),
            sourceRunAttemptID: held.runAttemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: Self.conversation)
        )
        guard case let .acquired(authorization) = coordinator.beginRecoveryAction(request, lane: lane) else {
            return XCTFail("the recovery action's hold is acquired")
        }
        defer { coordinator.endRecoveryAction(authorization) }

        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .couldNotCheck(Text.busy))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// A failed acknowledgement write is reported as failed and publishes nothing.
    func testFailedWriteReportsSaveFailedAndPublishesNothing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let failures = RecoveryStoreWriteFailureSwitch()
        let now = launch(failures: failures)
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        coordinator.test_crashHoldProofAtCommit = {
            failures.failingWritePathFragment = held.load.session.id.uuidString
        }

        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .failed(Text.saveFailed))
        failures.failingWritePathFragment = nil
        await assertNotConfirmed(coordinator, now, held)
    }

    /// F5 / B A2: Stop pressed before the commit starts writes nothing. The report says Stop came
    /// while confirming (true either side of the commit); the confirmation's own late result is
    /// "Stopped before confirming." and it releases the row it marked `.working` itself.
    func testStopBeforeTheCommitWritesNothing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let itemID = try crashHoldItemID(coordinator, held)
        coordinator.test_crashHoldProofBeforeCommit = { [weak coordinator] in
            XCTAssertEqual(coordinator?.catalogActionStates[itemID], .working, "the row is busy while it confirms")
            coordinator?.requestRecoveryCheckCancel()
        }
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .couldNotCheck(AgentRecoveryCheckStatus.stoppedWhileConfirmingText))
        let released = await waitUntil { coordinator.catalogActionStates[itemID] != .working }
        XCTAssertTrue(released, "the confirmation releases its own row")
        await assertNotConfirmed(coordinator, now, held)

        let wait = AgentRecoveryCheckItemWait()
        coordinator.test_crashHoldProofBeforeCommit = { wait.finish(nil) }
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        let direct = await coordinator.confirmCrashHoldFromRegistryProof(item, hold: hold, wait: wait)
        XCTAssertEqual(direct, .couldNotCheck(Text.stoppedBeforeConfirming))
        await assertNotConfirmed(coordinator, now, held)
    }

    /// F5: Stop pressed once nothing re-checks any more (the commit is starting) lets it land; the
    /// report says Stop came while confirming, the confirmation is published, and the row stays
    /// `.working` until the confirmation itself ends (B A8).
    func testStopAfterTheCommitStartedLetsItLand() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let itemID = try crashHoldItemID(coordinator, held)
        coordinator.test_crashHoldProofAtCommit = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            coordinator.requestRecoveryCheckCancel()
            // Let Check's Stop branch run (it finishes the report) while this confirmation waits
            // here, before its write: the row is still `.working` only if Stop left it alone.
            let stopped = await waitUntil { coordinator.recoveryCheck?.isRunning == false }
            XCTAssertTrue(stopped, "Check finished its report on Stop")
            XCTAssertEqual(coordinator.catalogActionStates[itemID], .working, "Stop leaves the confirmation's row to it")
        }
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .couldNotCheck(AgentRecoveryCheckStatus.stoppedWhileConfirmingText))
        let confirmed = await waitUntil { coordinator.blockingCrashHold(for: held.binding) == nil }
        XCTAssertTrue(confirmed, "the commit in flight finished and was published")
        let acknowledgement = await acknowledgement(now, held)
        XCTAssertNotNil(acknowledgement)
        let released = await waitUntil { coordinator.catalogActionStates[itemID] != .working }
        XCTAssertTrue(released)
    }

    /// B-R1-02: a row already `.working` (another action, or an earlier confirmation still writing
    /// after a Stop) is refused as busy; the confirmation neither shares nor clears that state.
    func testRowAlreadyWorkingRefusesAsBusyAndKeepsItsState() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let itemID = try crashHoldItemID(coordinator, held)
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        coordinator.setCatalogActionState(.working, for: itemID)

        let outcome = await coordinator.confirmCrashHoldFromRegistryProof(item, hold: hold, wait: AgentRecoveryCheckItemWait())

        XCTAssertEqual(outcome, .couldNotCheck(Text.busy))
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .working, "the other action's state is left alone")
        coordinator.setCatalogActionState(nil, for: itemID)
        await assertNotConfirmed(coordinator, now, held)
    }

    /// A Dismiss of the card between the proof and the final re-check changes it: nothing is written.
    func testCardChangedBeforeTheCommitRefusesWithoutWriting() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let itemID = try crashHoldItemID(coordinator, held)
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        coordinator.test_crashHoldProofBeforeCommit = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            coordinator.test_crashHoldProofBeforeCommit = nil
            let failure = await coordinator.dismissCatalogItem(item)
            XCTAssertNil(failure)
            let adopted = await waitUntil { coordinator.catalog.item(id: itemID)?.isDismissed == true }
            XCTAssertTrue(adopted, "the dismissal reached the catalog")
        }
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, .couldNotCheck(Text.changed))
        XCTAssertNotNil(coordinator.blockingCrashHold(for: held.binding), "Dismiss lifts nothing")
        let acknowledgement = await acknowledgement(now, held)
        XCTAssertNil(acknowledgement)
    }

    /// A P1-01: a Dismiss that commits after the coordinator's final re-check (before its catalog
    /// update could be seen) is caught atomically by the acknowledgement write itself, for a closed
    /// session and for an open one: no crash-hold acknowledgement is written.
    func testDismissCommittedAfterTheFinalCheckIsRefusedAtTheWrite() async throws {
        for open in [false, true] {
            recoveryRoot = root.appendingPathComponent("\(open ? "open" : "closed")/AgentRecovery/v1", isDirectory: true)
            let earlier = launch()
            let home = try makeWorkspace("home-\(open)")
            let held = try await heldSession(earlier, in: home)
            try seedRecord(held, state: .exited)

            let now = launch()
            let coordinator = try await startedCoordinator(now, workspaces: [home])
            if open { _ = try await openLane(now, coordinator, held, in: home) }
            let itemID = try crashHoldItemID(coordinator, held)
            let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
            final class Dismissal {
                var failure: String??
            }
            let dismissal = Dismissal()
            coordinator.test_crashHoldProofAtCommit = { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.test_crashHoldProofAtCommit = nil
                dismissal.failure = await coordinator.dismissCatalogItem(item)
            }

            let outcome = try await check(coordinator, held)

            XCTAssertEqual(dismissal.failure, .some(nil), "open: \(open): the Dismiss committed inside the window")
            XCTAssertEqual(outcome, .couldNotCheck(Text.changed), "open: \(open)")
            let record = await now.store.read(sessionID: held.load.session.id).record
            XCTAssertNil(record?.crashHoldAcknowledgement, "open: \(open): no crash-hold acknowledgement")
            XCTAssertEqual(record.map { $0.isCardAcknowledged(item.acknowledgement!.key, freshness: item.acknowledgement!.freshness) }, true)
            XCTAssertNotNil(coordinator.blockingCrashHold(for: held.binding), "open: \(open): sending stays paused")
        }
    }

    /// F8: the adopted snapshot lags the registry; a restriction it still holds refuses ("still being
    /// updated") until the registry's snapshot is adopted.
    func testSnapshotLagRefusesUntilAdopted() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let item = try XCTUnwrap(coordinator.catalog.item(id: crashHoldItemID(coordinator, held)))
        let hold = try XCTUnwrap(coordinator.crashHold(for: held.load.session.id))
        coordinator.runtimeRestrictions = AgentRuntimeRestrictionSnapshot(restrictions: [AgentRuntimeRestriction(
            runtimeID: UUID(),
            kind: .possibleWriter,
            family: .claudeNative,
            provider: .claude(.standard),
            state: .live,
            isPreviousInstance: true,
            isUnreadable: false,
            providerHome: nil,
            conversationIDs: [Self.conversation],
            worktreePaths: [Self.worktree],
            sessionIDs: [held.load.session.id],
            associations: [],
            rootPID: 1,
            memberCount: 1,
            letFinish: false,
            revision: nil,
            createdAt: nil
        )])

        let lagging = await coordinator.confirmCrashHoldFromRegistryProof(item, hold: hold, wait: AgentRecoveryCheckItemWait())
        XCTAssertEqual(lagging, Text.needsYou(Text.ownershipUpdating))
        await assertNotConfirmed(coordinator, now, held)

        await coordinator.refreshRuntimeOwnership()
        let adopted = await coordinator.confirmCrashHoldFromRegistryProof(item, hold: hold, wait: AgentRecoveryCheckItemWait())
        XCTAssertEqual(adopted, .resolved(Text.confirmed))
    }

    /// F8: a registry over a store of another app instance cannot tell earlier launches from this
    /// one, so it proves nothing.
    func testRegistryOverAnotherStoreInstanceProvesNothing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let held = try await heldSession(earlier, in: home)
        try seedRecord(held, state: .exited)

        let now = launch()
        let coordinator = try await startedCoordinator(
            now,
            workspaces: [home],
            registryStore: AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        )
        let outcome = try await check(coordinator, held)

        XCTAssertEqual(outcome, Text.needsYou(Text.ownershipUncertain))
        await assertNotConfirmed(coordinator, now, held)
    }

    // MARK: Fixtures

    private func launch(failures: RecoveryStoreWriteFailureSwitch = RecoveryStoreWriteFailureSwitch()) -> Launch {
        let store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID(), fileOperations: failures.fileOperations())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        return Launch(store: store, service: service)
    }

    private func makeWorkspace(_ name: String) throws -> AgentRecoveryWorkspaceDestination {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AgentRecoveryWorkspaceDestination(id: UUID(), name: name, customStoragePath: url)
    }

    private func transact(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        _ body: @Sendable (AgentRecoveryStore, AgentRecoveryLifecycleBinding) async throws -> Void
    ) async throws {
        let gate = try launch.service.recoveryLifecycleGate(for: load.persistenceState)
        let store = launch.store
        let binding = gate.binding
        try await gate.performRecoveryTransaction {
            try await body(store, binding)
        }
    }

    /// A session of `launch` with one open run attempt, marked as registered unless `marked` is false.
    private func heldSession(
        _ launch: Launch,
        in workspace: AgentRecoveryWorkspaceDestination,
        marked: Bool = true
    ) async throws -> Held {
        let session = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: "Held")
            .withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        let load = try await launch.service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let binding = try launch.service.recoveryLifecycleGate(for: load.persistenceState).binding
        let runAttemptID = try await openRun(launch, load, marked: marked)
        return Held(load: load, binding: binding, runAttemptID: runAttemptID)
    }

    /// A message of `launch` left `dispatching`, its one attempt on `runAttemptID` (none: untied).
    private func dispatchingIntent(_ launch: Launch, _ held: Held, runAttemptID: UUID?) async throws -> UUID {
        let submission = Support.submission("uncertain send")
        try await transact(launch, held.load) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
            _ = try await store.beginDispatch(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: submission.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: runAttemptID),
                authorization: .liveQueue
            )
        }
        return submission.intentID
    }

    private func deliveryState(_ launch: Launch, _ held: Held, _ intentID: UUID) async -> AgentRecoveryDeliveryState? {
        await launch.store.read(sessionID: held.load.session.id).record?.intent(id: intentID)?.deliveryState
    }

    /// Records an open run attempt as `launch` (that launch's app instance owns it).
    private func openRun(_ launch: Launch, _ load: AgentSessionEditableLoad, marked: Bool = true) async throws -> UUID {
        let ownership = Support.ownership(sessionID: load.session.id)
        try await transact(launch, load) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: AgentProviderKind.claudeCode.rawValue,
                runtimeRegistrationRaw: marked ? AgentRecoveryRunAttempt.registeredRuntimeRegistration : nil
            )
        }
        return ownership.attemptID
    }

    /// This launch's live lane for the held session (opened as a window would).
    private func openLane(
        _ launch: Launch,
        _ coordinator: AgentRecoveryCoordinator,
        _ held: Held,
        in workspace: AgentRecoveryWorkspaceDestination
    ) async throws -> AgentRecoverySessionLane {
        let load = try await launch.service.loadAgentSessionForEditing(id: held.load.session.id, for: workspace)
        let lane = try coordinator.claimLane(owner: self, persistenceState: XCTUnwrap(load?.persistenceState))
        keysBySession[held.load.session.id] = [AgentRuntimeOwnershipKeys(conversationID: Self.conversation, worktreePath: Self.worktree)]
        return lane
    }

    /// The held run's association; `keys: false` leaves its conversation and worktree to the record.
    private func association(_ held: Held, runAttemptID: UUID, keys: Bool) -> AgentRuntimeAssociation {
        AgentRuntimeAssociation(
            session: AgentRuntimeSessionAssociation(lifecycle: held.binding, runAttemptID: runAttemptID, processRunID: nil),
            conversationID: keys ? Self.conversation : nil,
            worktreePath: keys ? Self.worktree : nil,
            permission: .unavailable
        )
    }

    /// An earlier launch's record (its own random app instance) naming the held run attempt.
    private func seedRecord(
        _ held: Held,
        runAttemptID: UUID? = nil,
        state: AgentRuntimeRecord.State,
        associationKeys: Bool = true
    ) throws {
        let pid = nextPID
        nextPID += 1
        try Fixtures.seed(
            rootURL: recoveryRoot,
            state: state,
            root: processes.identity(pid: pid),
            rootGroup: pid,
            associations: [association(held, runAttemptID: runAttemptID ?? held.runAttemptID, keys: associationKeys)],
            conversationIDs: [Self.conversation],
            worktreePaths: [Self.worktree]
        )
    }

    /// An earlier launch's possible writer (its root still alive).
    private func seedLiveWriter(session: AgentRuntimeSessionAssociation?, conversationID: String, worktreePath: String) throws {
        let pid = nextPID
        nextPID += 1
        processes.add(processes.observation(pid: pid, group: pid))
        try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: pid),
            rootGroup: pid,
            associations: [AgentRuntimeAssociation(
                session: session,
                conversationID: conversationID,
                worktreePath: worktreePath,
                permission: .unavailable
            )],
            conversationIDs: [conversationID],
            worktreePaths: [worktreePath]
        )
    }

    /// This launch's own reservation naming the held run attempt.
    private func reserveCurrentLaunch(naming held: Held) async throws {
        let registry = try XCTUnwrap(registries.last)
        _ = try await registry.reserveLaunch(Fixtures.context(
            .codexAppServer,
            session: .session(AgentRuntimeSessionAssociation(lifecycle: held.binding, runAttemptID: held.runAttemptID, processRunID: nil)),
            worktreePath: "/tmp/rpce-crash-hold-proof/current"
        ))
    }

    /// A coordinator composed as in production (real sweep), with a registry over `registryStore`
    /// (the coordinator's own store unless given), started and awaited to `.ready`.
    private func startedCoordinator(
        _ launch: Launch,
        workspaces: [AgentRecoveryWorkspaceDestination],
        registryStore: AgentRecoveryStore? = nil
    ) async throws -> AgentRecoveryCoordinator {
        let service = launch.service
        let coordinator = try AgentRecoveryCoordinator(
            store: launch.store,
            dataService: service,
            reconcile: { report in
                await AgentRecoveryStartupSweep.run(
                    inventory: AgentRecoveryWorkspaceInventory(workspaces: workspaces),
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
        let registry = AgentProcessRegistry(store: registryStore ?? launch.store, qualification: Fixtures.qualified(), system: processes.system)
        registries.append(registry)
        coordinator.attachProcessRegistry(registry) { [weak self] sessionID in
            self?.keysBySession[sessionID] ?? []
        }
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    private func crashHoldItemID(_ coordinator: AgentRecoveryCoordinator, _ held: Held) throws -> String {
        try XCTUnwrap(coordinator.catalog.items.first { $0.kind == .crashHold && $0.sessionID == held.load.session.id }).id
    }

    /// Runs Check and resolve on the held session's crash-hold card; its one outcome.
    private func check(
        _ coordinator: AgentRecoveryCoordinator,
        _ held: Held,
        checksActive: Bool = true
    ) async throws -> AgentRecoveryCheckOutcome {
        let item = try XCTUnwrap(coordinator.catalog.item(id: crashHoldItemID(coordinator, held)))
        let status = await coordinator.checkCatalogItems([item], checksActive: checksActive) { _ in
            XCTFail("a crash hold is never reconciled")
            return .notAttempted("no reconcile")
        }
        return try XCTUnwrap(status?.entries.first).outcome
    }

    private func acknowledgement(_ launch: Launch, _ held: Held) async -> AgentRecoveryCrashHoldAcknowledgement? {
        await launch.store.read(sessionID: held.load.session.id).record?.crashHoldAcknowledgement
    }

    private func assertNotConfirmed(
        _ coordinator: AgentRecoveryCoordinator,
        _ launch: Launch,
        _ held: Held,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertNotNil(coordinator.blockingCrashHold(for: held.binding), "sending stays paused", file: file, line: line)
        let acknowledgement = await acknowledgement(launch, held)
        XCTAssertNil(acknowledgement, "nothing was written", file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
