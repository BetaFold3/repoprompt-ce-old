import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class AgentScheduledSendCoordinatorTests: XCTestCase {
    func testDashboardNotificationCoalescesAndSkipsUnchangedEvaluation() async {
        let start = Date(timeIntervalSince1970: 900)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(600))
        host.addScheduledSession(record: record)
        let counter = DashboardChangeCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .agentScheduledSendDashboardDidChange,
            object: coordinator,
            queue: nil
        ) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        coordinator.register(host)
        await drainTasks()
        let initial = counter.value
        XCTAssertEqual(initial, 1)

        coordinator.evaluate()
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(counter.value, initial, "An unchanged evaluation does not invalidate the dashboard")

        host.updateRecord(scheduleID: record.id) { $0.updatedAt = start.addingTimeInterval(1) }
        coordinator.recordDidChange()
        coordinator.evaluate()
        await drainTasks()
        XCTAssertEqual(counter.value, initial + 1, "One turn of changes posts only once")
    }

    func testNotBeforeTimerDoesNotDispatchEarly() async {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.addScheduledSession(
            record: makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60))
        )

        coordinator.register(host)
        await drainTasks()

        clock.advance(to: start.addingTimeInterval(59))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        clock.advance(to: start.addingTimeInterval(60))
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)
    }

    func testLeavingWorkspaceAcrossDeadlineRequiresConfirmationOnReturn() async throws {
        let start = Date(timeIntervalSince1970: 1500)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start.addingTimeInterval(1),
            notBefore: start.addingTimeInterval(60)
        )
        let workspaceID = UUID()
        let tabID = host.addScheduledSession(workspaceID: workspaceID, record: record)
        coordinator.register(host)
        await drainTasks()

        // The workspace is no longer represented by a live host at the deadline.
        host.setCandidateSuppressed(true, tabID: tabID)
        coordinator.recordDidChange()
        clock.advance(to: record.notBefore.addingTimeInterval(1))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        host.holdMutations = true
        host.setCandidateSuppressed(false, tabID: tabID)
        coordinator.workspaceDidLoad()
        try await waitUntil("confirmation write held") { host.heldMutationCount == 1 }
        XCTAssertEqual(coordinator.dashboardPendingConfirmations(in: workspaceID).map(\.scheduleID), [record.id])
        XCTAssertTrue(coordinator.dashboardPendingConfirmations(in: UUID()).isEmpty)
        XCTAssertTrue(host.dispatches.isEmpty)

        host.releaseHeldMutation(with: nil)
        await drainTasks()
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .needsConfirmation)
        XCTAssertEqual(host.record(scheduleID: record.id)?.confirmationReason, .destinationUnavailable)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testWaitingForUserPendingInstructionsAndCancellationSettlingBlockFollowUp() async throws {
        let start = Date(timeIntervalSince1970: 2000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let runID = UUID()
        let waitingRecord = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        let waitingTabID = host.addScheduledSession(
            record: waitingRecord,
            busyState: AgentScheduledSendBusyState(
                runID: runID,
                runState: .waitingForUser
            )
        )

        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(10))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        host.setBusyState(
            AgentScheduledSendBusyState(runID: runID, runState: .completed),
            tabID: waitingTabID
        )
        try coordinator.runStateDidChange(
            sessionID: XCTUnwrap(host.sessionID(tabID: waitingTabID)),
            runID: runID,
            state: .completed
        )
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [waitingRecord.id])

        let instructionsRecord = makeRecord(
            createdAt: clock.now,
            notBefore: clock.now.addingTimeInterval(10),
            isNewSessionStart: false
        )
        let instructionsTabID = host.addScheduledSession(
            record: instructionsRecord,
            busyState: AgentScheduledSendBusyState(hasPendingInstructions: true)
        )
        coordinator.recordDidChange()
        clock.advance(to: instructionsRecord.notBefore)
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)

        host.setBusyState(AgentScheduledSendBusyState(), tabID: instructionsTabID)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(
            host.dispatches.map(\.scheduleID),
            [waitingRecord.id, instructionsRecord.id]
        )

        let cancellationRecord = makeRecord(
            createdAt: clock.now,
            notBefore: clock.now.addingTimeInterval(10),
            isNewSessionStart: false
        )
        let cancellationTabID = host.addScheduledSession(
            record: cancellationRecord,
            busyState: AgentScheduledSendBusyState(cancellationIsSettling: true)
        )
        coordinator.recordDidChange()
        clock.advance(to: cancellationRecord.notBefore)
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 2)

        host.setBusyState(AgentScheduledSendBusyState(), tabID: cancellationTabID)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(
            host.dispatches.map(\.scheduleID),
            [waitingRecord.id, instructionsRecord.id, cancellationRecord.id]
        )
    }

    func testWorkspaceGateAggregatesAcrossHostsAndRunAlongsideOverridesIt() async {
        let start = Date(timeIntervalSince1970: 3000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let scheduledHost = FakeScheduledSendHost()
        let busyHost = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: true
        )
        scheduledHost.addScheduledSession(workspaceID: workspaceID, record: record)
        busyHost.addSession(
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )

        coordinator.register(scheduledHost)
        coordinator.register(busyHost)
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertTrue(scheduledHost.dispatches.isEmpty)

        scheduledHost.updateRecord(scheduleID: record.id) {
            $0.runAlongsideOtherSessions = true
            $0.updatedAt = clock.now
        }
        coordinator.recordDidChange()
        await drainTasks()

        XCTAssertEqual(scheduledHost.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(scheduledHost.dispatches.first?.lease.runAlongsideOtherSessions, true)
    }

    func testSimultaneousDueNewSessionsAcrossHostsAreAdmittedInStableOrderOneAtATime() async {
        let start = Date(timeIntervalSince1970: 4000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let firstHost = FakeScheduledSendHost()
        let secondHost = FakeScheduledSendHost()
        firstHost.holdDispatches = true
        secondHost.holdDispatches = true
        let workspaceID = UUID()
        let due = start.addingTimeInterval(10)
        let first = makeRecord(
            createdAt: start,
            notBefore: due,
            isNewSessionStart: true
        )
        let second = makeRecord(
            createdAt: start.addingTimeInterval(1),
            notBefore: due,
            isNewSessionStart: true
        )
        firstHost.addScheduledSession(workspaceID: workspaceID, record: first)
        secondHost.addScheduledSession(workspaceID: workspaceID, record: second)

        coordinator.register(firstHost)
        coordinator.register(secondHost)
        clock.advance(to: due)
        await drainTasks()

        XCTAssertEqual(firstHost.dispatches.map(\.scheduleID), [first.id])
        XCTAssertTrue(secondHost.dispatches.isEmpty)
        XCTAssertEqual(firstHost.pendingDispatchCount, 1)

        firstHost.completeNextDispatch(with: .accepted)
        await drainTasks()
        XCTAssertEqual(secondHost.dispatches.map(\.scheduleID), [second.id])
        XCTAssertEqual(secondHost.pendingDispatchCount, 1)

        secondHost.completeNextDispatch(with: .accepted)
        await drainTasks()
    }

    func testSuspendedGapCrossingDeadlineRequiresConfirmation() async throws {
        let start = Date(timeIntervalSince1970: 5000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(60)
        )
        host.addScheduledSession(record: record)

        coordinator.register(host)
        clock.advance(
            to: start.addingTimeInterval(90),
            probe: SchedulerClockProbe(suspendedGap: 60)
        )
        await drainTasks()

        let updated = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(updated.state, .needsConfirmation)
        XCTAssertEqual(updated.confirmationReason, .missedDuringSleep)
        XCTAssertTrue(host.dispatches.isEmpty)
        XCTAssertGreaterThan(host.persistCount, 0)
    }

    func testWallClockJumpCrossingDeadlineRequiresConfirmation() async throws {
        let start = Date(timeIntervalSince1970: 6000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(60)
        )
        host.addScheduledSession(record: record)

        coordinator.register(host)
        clock.advance(
            to: start.addingTimeInterval(120),
            probe: SchedulerClockProbe(wallClockAdjustment: 120)
        )
        await drainTasks()

        let updated = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(updated.state, .needsConfirmation)
        XCTAssertEqual(updated.confirmationReason, .clockChanged)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testAwakeDueFollowUpSurvivesWakeOnlyAfterCapturedRunCompletes() async throws {
        let start = Date(timeIntervalSince1970: 7000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let runID = UUID()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        let tabID = host.addScheduledSession(
            record: record,
            busyState: AgentScheduledSendBusyState(runID: runID, runState: .running)
        )
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))

        coordinator.register(host)
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        coordinator.didWake()
        await drainTasks()
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .scheduled)

        host.setBusyState(
            AgentScheduledSendBusyState(runID: runID, runState: .completed),
            tabID: tabID
        )
        coordinator.runStateDidChange(
            sessionID: sessionID,
            runID: runID,
            state: .completed
        )
        await drainTasks()

        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
    }

    func testAwakeDueFollowUpNeedsConfirmationWhenCapturedRunDoesNotComplete() async throws {
        for terminalState in [AgentSessionRunState.failed, .cancelled] {
            let start = Date(timeIntervalSince1970: terminalState == .failed ? 8000 : 9000)
            let clock = FakeScheduledSendClock(now: start)
            let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
            let host = FakeScheduledSendHost()
            let runID = UUID()
            let record = makeRecord(
                createdAt: start,
                notBefore: start.addingTimeInterval(10),
                isNewSessionStart: false
            )
            let tabID = host.addScheduledSession(
                record: record,
                busyState: AgentScheduledSendBusyState(runID: runID, runState: .running)
            )
            let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))

            coordinator.register(host)
            clock.advance(to: record.notBefore)
            await drainTasks()
            coordinator.didWake()

            host.setBusyState(
                AgentScheduledSendBusyState(runID: runID, runState: terminalState),
                tabID: tabID
            )
            coordinator.runStateDidChange(
                sessionID: sessionID,
                runID: runID,
                state: terminalState
            )
            await drainTasks()

            let updated = try XCTUnwrap(host.record(scheduleID: record.id))
            XCTAssertEqual(updated.state, .needsConfirmation, "terminal state: \(terminalState)")
            XCTAssertEqual(
                updated.confirmationReason,
                .runNotCompleted,
                "terminal state: \(terminalState)"
            )
            XCTAssertTrue(host.dispatches.isEmpty, "terminal state: \(terminalState)")
        }
    }

    func testOverdueAtLaunchDoesNotSubmitUntilExplicitInMemoryConfirmation() async throws {
        let launch = Date(timeIntervalSince1970: 10000)
        let clock = FakeScheduledSendClock(now: launch)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: launch.addingTimeInterval(-120),
            notBefore: launch.addingTimeInterval(-60)
        )
        host.addScheduledSession(record: record)

        coordinator.register(host)
        await drainTasks()

        let updated = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(updated.state, .needsConfirmation)
        XCTAssertEqual(updated.confirmationReason, .missedWhileClosed)
        XCTAssertTrue(host.dispatches.isEmpty)

        coordinator.confirmAndSendNow(scheduleID: record.id)
        await drainTasks()

        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(host.dispatches.first?.lease.allowsNeedsConfirmation, true)
    }

    func testTwoHostsOwningSameSessionReceiveOnlyOneAdmissionLease() async {
        let start = Date(timeIntervalSince1970: 11000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let sessionID = UUID()
        let tabID = UUID()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        let firstHost = FakeScheduledSendHost()
        let secondHost = FakeScheduledSendHost()
        firstHost.addScheduledSession(
            sessionID: sessionID,
            tabID: tabID,
            workspaceID: workspaceID,
            record: record
        )
        secondHost.addScheduledSession(
            sessionID: sessionID,
            tabID: tabID,
            workspaceID: workspaceID,
            record: record
        )

        coordinator.register(firstHost)
        coordinator.register(secondHost)
        clock.advance(to: record.notBefore)
        await drainTasks()
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(firstHost.dispatches.count + secondHost.dispatches.count, 1)
        let lease = firstHost.dispatches.first?.lease ?? secondHost.dispatches.first?.lease
        XCTAssertEqual(lease?.sessionID, sessionID)
        XCTAssertEqual(lease?.scheduleID, record.id)
    }

    func testEvaluateCoalescesSynchronousReentrancyAndProcessesRerun() async {
        let start = Date(timeIntervalSince1970: 12000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        host.onCandidatesRead = {
            host.addScheduledSession(record: record)
            coordinator.evaluate()
        }

        coordinator.register(host)
        XCTAssertGreaterThanOrEqual(host.candidateReadCount, 2)

        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
    }

    func testDueStubHydratesThenRevalidatesBeforeDispatch() async {
        let start = Date(timeIntervalSince1970: 13000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        host.addScheduledSession(record: record, isHydrated: false)

        coordinator.register(host)
        clock.advance(to: record.notBefore)
        await drainTasks()

        XCTAssertEqual(host.hydrationCount, 1)
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
    }

    func testRescheduleAfterAdmissionRevokesOldLeaseAndWaitsForNewDeadline() async throws {
        let start = Date(timeIntervalSince1970: 14000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let due = start.addingTimeInterval(10)
        let record = makeRecord(createdAt: start, notBefore: due)
        let tabID = host.addScheduledSession(record: record)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))

        coordinator.register(host)
        clock.advance(to: due)
        coordinator.evaluate()

        let admitted = try XCTUnwrap(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(admitted.admittedUpdatedAt, record.updatedAt)
        XCTAssertEqual(admitted.admittedNotBefore, due)
        XCTAssertEqual(admitted.effectiveDueAt, due)
        XCTAssertTrue(coordinator.isValid(admitted, for: record))

        let editedAt = due.addingTimeInterval(1)
        let rescheduledDeadline = due.addingTimeInterval(60)
        host.updateRecord(scheduleID: record.id) {
            $0.updatedAt = editedAt
            $0.notBefore = rescheduledDeadline
        }
        let edited = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertFalse(coordinator.isValid(admitted, for: edited))

        coordinator.recordDidChange()
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertFalse(coordinator.isValid(admitted))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        clock.advance(to: rescheduledDeadline)
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(host.dispatches.first?.lease.admittedUpdatedAt, editedAt)
        XCTAssertEqual(host.dispatches.first?.lease.admittedNotBefore, rescheduledDeadline)
        XCTAssertEqual(host.dispatches.first?.lease.effectiveDueAt, rescheduledDeadline)
    }

    func testFailedRevisionCanBeRescheduledWithoutSendNow() async {
        let start = Date(timeIntervalSince1970: 15000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .failedBeforeHandoff
        let due = start.addingTimeInterval(10)
        let record = makeRecord(createdAt: start, notBefore: due)
        host.addScheduledSession(record: record)

        coordinator.register(host)
        clock.advance(to: due)
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .failed)

        let rescheduledAt = due.addingTimeInterval(1)
        let rescheduledDeadline = due.addingTimeInterval(30)
        host.updateRecord(scheduleID: record.id) {
            $0.state = .scheduled
            $0.confirmationReason = nil
            $0.updatedAt = rescheduledAt
            $0.notBefore = rescheduledDeadline
        }
        coordinator.recordDidChange()

        clock.advance(to: rescheduledDeadline)
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id, record.id])
        XCTAssertEqual(host.dispatches.last?.lease.admittedUpdatedAt, rescheduledAt)
    }

    func testAuthoritativeNewRevisionIsNotStarvedByRetiredStaleProjection() async {
        let start = Date(timeIntervalSince1970: 16000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let sessionID = UUID()
        let firstTabID = UUID()
        let staleTabID = UUID()
        let firstHost = FakeScheduledSendHost()
        let staleHost = FakeScheduledSendHost()
        let first = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10)
        )
        firstHost.addScheduledSession(
            sessionID: sessionID,
            tabID: firstTabID,
            workspaceID: workspaceID,
            record: first
        )
        staleHost.addScheduledSession(
            sessionID: sessionID,
            tabID: staleTabID,
            workspaceID: workspaceID,
            record: first
        )

        coordinator.register(firstHost)
        coordinator.register(staleHost)
        clock.advance(to: first.notBefore)
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(firstHost.dispatches.map(\.scheduleID), [first.id])
        XCTAssertEqual(staleHost.record(scheduleID: first.id)?.id, first.id)

        let secondCreatedAt = clock.now.addingTimeInterval(1)
        let second = makeRecord(
            createdAt: secondCreatedAt,
            notBefore: clock.now.addingTimeInterval(30)
        )
        firstHost.addScheduledSession(
            sessionID: sessionID,
            tabID: firstTabID,
            workspaceID: workspaceID,
            record: second
        )
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(firstHost.dispatches.map(\.scheduleID), [first.id])

        clock.advance(to: second.notBefore)
        coordinator.evaluate()
        await drainTasks()

        XCTAssertEqual(firstHost.dispatches.map(\.scheduleID), [first.id, second.id])
        XCTAssertTrue(staleHost.dispatches.isEmpty)
    }

    func testLiveAdmissionLookupPreventsDispatchingProjectionNormalization() async throws {
        let start = Date(timeIntervalSince1970: 17000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let sessionID = UUID()
        let ownerTabID = UUID()
        let hydratingTabID = UUID()
        let ownerHost = FakeScheduledSendHost()
        let hydratingHost = FakeScheduledSendHost()
        ownerHost.holdDispatches = true
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10)
        )
        ownerHost.addScheduledSession(
            sessionID: sessionID,
            tabID: ownerTabID,
            workspaceID: workspaceID,
            record: record
        )

        coordinator.register(ownerHost)
        coordinator.register(hydratingHost)
        clock.advance(to: record.notBefore)
        coordinator.evaluate()
        await drainTasks()

        let admitted = try XCTUnwrap(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(ownerHost.pendingDispatchCount, 1)

        var liveDispatching = record
        liveDispatching.state = .dispatching
        liveDispatching.updatedAt = clock.now.addingTimeInterval(1)
        liveDispatching.attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: UUID(),
            startedAt: clock.now
        )
        hydratingHost.addScheduledSession(
            sessionID: sessionID,
            tabID: hydratingTabID,
            workspaceID: workspaceID,
            record: liveDispatching,
            isHydrated: false
        )
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID))
        let didHydrate = await hydratingHost.ensureHydrated(tabID: hydratingTabID)
        XCTAssertTrue(didHydrate)

        coordinator.recordDidChange()
        await drainTasks()

        XCTAssertEqual(coordinator.activeAdmission(sessionID: sessionID), admitted)
        XCTAssertEqual(
            hydratingHost.record(scheduleID: record.id)?.state,
            .dispatching
        )
        XCTAssertEqual(hydratingHost.persistCount, 0)

        hydratingHost.addSession(
            sessionID: sessionID,
            tabID: hydratingTabID,
            workspaceID: workspaceID,
            record: nil,
            isHydrated: true,
            busyState: AgentScheduledSendBusyState()
        )
        coordinator.recordDidChange()
        ownerHost.completeNextDispatch(with: .accepted)
        await drainTasks()
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
    }

    func testUnhydratedOverdueRecordHydratesBeforeConfirmationMutation() async throws {
        let launch = Date(timeIntervalSince1970: 18000)
        let clock = FakeScheduledSendClock(now: launch)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: launch.addingTimeInterval(-120),
            notBefore: launch.addingTimeInterval(-60)
        )
        host.addScheduledSession(record: record, isHydrated: false)

        coordinator.register(host)
        await drainTasks()

        let updated = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(host.hydrationCount, 1)
        XCTAssertEqual(host.unhydratedMutationAttemptCount, 0)
        XCTAssertEqual(updated.state, .needsConfirmation)
        XCTAssertEqual(updated.confirmationReason, .missedWhileClosed)
        XCTAssertGreaterThan(host.persistCount, 0)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testFinalHandoffValidatorAggregatesHostsAndExcludesOnlyOwnerDispatchReservation() async throws {
        let start = Date(timeIntervalSince1970: 19000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let ownerHost = FakeScheduledSendHost()
        let foreignHost = FakeScheduledSendHost()
        ownerHost.holdDispatches = true
        let workspaceID = UUID()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: true
        )
        let ownerTabID = ownerHost.addScheduledSession(
            workspaceID: workspaceID,
            record: record
        )

        coordinator.register(ownerHost)
        coordinator.register(foreignHost)
        clock.advance(to: record.notBefore)
        await drainTasks()

        let lease = try XCTUnwrap(ownerHost.dispatches.first?.lease)
        ownerHost.setBusyState(
            AgentScheduledSendBusyState(hasStartOrDispatchReservation: true),
            tabID: ownerTabID
        )
        let validator = try XCTUnwrap(
            coordinator.finalHandoffValidator(for: lease)
        )
        XCTAssertTrue(coordinator.isValid(validator))

        ownerHost.setBusyState(
            AgentScheduledSendBusyState(
                hasPendingApproval: true,
                hasStartOrDispatchReservation: true
            ),
            tabID: ownerTabID
        )
        XCTAssertFalse(coordinator.isValid(validator))

        ownerHost.setBusyState(
            AgentScheduledSendBusyState(hasStartOrDispatchReservation: true),
            tabID: ownerTabID
        )
        let foreignTabID = foreignHost.addSession(
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(
                runID: UUID(),
                runState: .running
            )
        )
        coordinator.recordDidChange()

        XCTAssertFalse(coordinator.isValid(validator))

        foreignHost.setBusyState(AgentScheduledSendBusyState(), tabID: foreignTabID)
        ownerHost.addSession(
            sessionID: UUID(),
            tabID: ownerTabID,
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(
                hasStartOrDispatchReservation: true
            )
        )
        XCTAssertFalse(coordinator.isValid(validator))

        ownerHost.completeNextDispatch(with: .deferredBusy)
        await drainTasks()
    }

    func testAcceptedButUnfinalizedAttemptBlocksNormalizationUntilExactRevisionCompletes() async throws {
        let start = Date(timeIntervalSince1970: 20000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let sessionID = UUID()
        let ownerTabID = UUID()
        let peerTabID = UUID()
        let ownerHost = FakeScheduledSendHost()
        let peerHost = FakeScheduledSendHost()
        ownerHost.holdDispatches = true
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10)
        )
        ownerHost.addScheduledSession(
            sessionID: sessionID,
            tabID: ownerTabID,
            workspaceID: workspaceID,
            record: record
        )
        peerHost.addScheduledSession(
            sessionID: sessionID,
            tabID: peerTabID,
            workspaceID: workspaceID,
            record: record
        )

        coordinator.register(ownerHost)
        coordinator.register(peerHost)
        clock.advance(to: record.notBefore)
        await drainTasks()

        let lease = try XCTUnwrap(ownerHost.dispatches.first?.lease)
        var peerDispatching = record
        peerDispatching.state = .dispatching
        peerDispatching.updatedAt = record.notBefore.addingTimeInterval(1)
        peerDispatching.attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: UUID(),
            startedAt: clock.now
        )
        peerHost.updateRecord(scheduleID: record.id) {
            $0 = peerDispatching
        }

        ownerHost.completeNextDispatch(with: .unknownAfterHandoff)
        await drainTasks()
        ownerHost.setCandidateSuppressed(true, tabID: ownerTabID)
        coordinator.recordDidChange()
        await drainTasks()

        XCTAssertEqual(coordinator.activeAdmission(sessionID: sessionID), lease)
        XCTAssertEqual(peerHost.record(scheduleID: record.id)?.state, .dispatching)
        XCTAssertEqual(peerHost.persistCount, 0)

        coordinator.scheduledSendFinalizationDidComplete(
            sessionID: sessionID,
            scheduleID: record.id,
            admittedUpdatedAt: lease.admittedUpdatedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(coordinator.activeAdmission(sessionID: sessionID), lease)

        coordinator.scheduledSendFinalizationDidComplete(
            sessionID: sessionID,
            scheduleID: record.id,
            admittedUpdatedAt: lease.admittedUpdatedAt
        )
        await drainTasks()

        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(peerHost.record(scheduleID: record.id)?.state, .needsConfirmation)
        XCTAssertEqual(
            peerHost.record(scheduleID: record.id)?.confirmationReason,
            .deliveryUnknown
        )
        XCTAssertEqual(ownerHost.dispatches.count, 1)
        XCTAssertTrue(peerHost.dispatches.isEmpty)
    }

    func testFinalizationCompletionBeforeUnknownOutcomeDoesNotLeaveProtection() async throws {
        let start = Date(timeIntervalSince1970: 21000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdDispatches = true
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10)
        )
        let tabID = host.addScheduledSession(record: record)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))

        coordinator.register(host)
        clock.advance(to: record.notBefore)
        await drainTasks()

        let lease = try XCTUnwrap(host.dispatches.first?.lease)
        coordinator.scheduledSendFinalizationDidComplete(
            sessionID: sessionID,
            scheduleID: record.id,
            admittedUpdatedAt: lease.admittedUpdatedAt
        )
        host.completeNextDispatch(with: .unknownAfterHandoff)
        await drainTasks()

        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .needsConfirmation)
        XCTAssertEqual(
            host.record(scheduleID: record.id)?.confirmationReason,
            .deliveryUnknown
        )
    }

    func testSuppressedOwnerAdmissionSurvivesOlderUnhydratedProjectionAndRequestsRefresh() async throws {
        let start = Date(timeIntervalSince1970: 22000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let sessionID = UUID()
        let ownerTabID = UUID()
        let staleTabID = UUID()
        let ownerHost = FakeScheduledSendHost()
        let staleHost = FakeScheduledSendHost()
        let first = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10)
        )
        ownerHost.addScheduledSession(
            sessionID: sessionID,
            tabID: ownerTabID,
            workspaceID: workspaceID,
            record: first
        )
        staleHost.addScheduledSession(
            sessionID: sessionID,
            tabID: staleTabID,
            workspaceID: workspaceID,
            record: first,
            isHydrated: false
        )

        coordinator.register(ownerHost)
        coordinator.register(staleHost)
        clock.advance(to: first.notBefore)
        await drainTasks()
        XCTAssertEqual(ownerHost.dispatches.map(\.scheduleID), [first.id])

        let second = makeRecord(
            createdAt: clock.now.addingTimeInterval(1),
            notBefore: clock.now.addingTimeInterval(30)
        )
        ownerHost.addScheduledSession(
            sessionID: sessionID,
            tabID: ownerTabID,
            workspaceID: workspaceID,
            record: second
        )
        ownerHost.holdDispatches = true
        ownerHost.suppressCandidatesWhileDispatching = true
        ownerHost.onDispatchStarted = {
            coordinator.recordDidChange()
        }
        coordinator.recordDidChange()

        clock.advance(to: second.notBefore)
        await drainTasks()

        let lease = try XCTUnwrap(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(lease.scheduleID, second.id)
        XCTAssertEqual(ownerHost.pendingDispatchCount, 1)
        XCTAssertEqual(
            staleHost.projectionRefreshes,
            [FakeScheduledSendHost.ProjectionRefresh(
                tabID: staleTabID,
                sessionID: sessionID
            )]
        )

        ownerHost.completeNextDispatch(with: .accepted)
        await drainTasks()
        XCTAssertEqual(
            ownerHost.dispatches.map(\.scheduleID),
            [first.id, second.id]
        )
        XCTAssertTrue(staleHost.dispatches.isEmpty)
    }

    func testWakeBeforeDeadlineProcessesEpochAndDispatchesNormallyAtDeadline() async {
        let start = Date(timeIntervalSince1970: 23000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(60)
        )
        host.addScheduledSession(record: record, isHydrated: false)

        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(30))
        coordinator.didWake()
        await drainTasks()

        XCTAssertEqual(host.hydrationCount, 0)
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .scheduled)

        clock.advance(to: record.notBefore)
        await drainTasks()

        XCTAssertEqual(host.hydrationCount, 1)
        XCTAssertEqual(host.unhydratedMutationAttemptCount, 0)
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
    }

    func testSendNowSurvivesBusyFirstEligibleUpdateForEveryConfirmableState() async throws {
        let cases: [(state: AgentScheduledSendPersist.State, future: Bool)] = [
            (.needsConfirmation, false),
            (.failed, false),
            (.scheduled, true)
        ]

        for (index, testCase) in cases.enumerated() {
            let start = Date(timeIntervalSince1970: 24000 + Double(index * 100))
            let clock = FakeScheduledSendClock(now: start)
            let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
            let host = FakeScheduledSendHost()
            var record = makeRecord(
                createdAt: start.addingTimeInterval(-20),
                notBefore: testCase.future
                    ? start.addingTimeInterval(60)
                    : start.addingTimeInterval(-10)
            )
            record.state = testCase.state
            if testCase.state == .needsConfirmation {
                record.confirmationReason = .deliveryUnknown
            }
            let tabID = host.addScheduledSession(
                record: record,
                busyState: AgentScheduledSendBusyState(
                    hasPendingInstructions: true
                )
            )

            coordinator.register(host)
            coordinator.confirmAndSendNow(scheduleID: record.id)
            await drainTasks()

            let waiting = try XCTUnwrap(host.record(scheduleID: record.id))
            XCTAssertEqual(waiting.firstEligibleAt, start, "case \(testCase.state)")
            XCTAssertGreaterThan(waiting.updatedAt, record.updatedAt, "the acknowledged mutation is a distinct revision — case \(testCase.state)")
            XCTAssertTrue(host.dispatches.isEmpty, "case \(testCase.state)")

            host.setBusyState(AgentScheduledSendBusyState(), tabID: tabID)
            coordinator.recordDidChange()
            await drainTasks()

            XCTAssertEqual(host.dispatches.count, 1, "case \(testCase.state)")
            XCTAssertEqual(
                host.dispatches.first?.lease.effectiveDueAt,
                start,
                "case \(testCase.state)"
            )
            XCTAssertEqual(
                host.dispatches.first?.lease.allowsNeedsConfirmation,
                true,
                "case \(testCase.state)"
            )
        }
    }

    // MARK: - Lossless-restart startup barrier and R9 transfer holds

    func testClosedStartupAdmissionBlocksEvaluationHydrationAndConsentUntilOpened() async {
        let start = Date(timeIntervalSince1970: 60000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, startupAdmission: .awaitingRecovery)
        XCTAssertTrue(coordinator.closeStartupAdmission(), "Closed before any host registered")
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(20))
        host.addScheduledSession(record: record)
        let stub = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(1))
        host.addScheduledSession(record: stub, isHydrated: false)

        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(2))
        coordinator.evaluate()
        coordinator.confirmAndSendNow(scheduleID: record.id)
        await drainTasks()
        XCTAssertFalse(coordinator.isStartupAdmissionOpen)
        XCTAssertFalse(coordinator.closeStartupAdmission(), "A late close reports the ordering violation")
        XCTAssertTrue(host.dispatches.isEmpty)
        XCTAssertEqual(host.hydrationCount, 0, "No hydration (and so no hydration normalization) before the barrier")
        XCTAssertTrue(host.mutationRequests.isEmpty)

        coordinator.openStartupAdmission()
        await drainTasks()
        XCTAssertFalse(
            host.dispatches.contains { $0.scheduleID == record.id },
            "Send-now consent offered before the barrier was refused, so the future deadline still applies"
        )
    }

    func testOpeningStartupAdmissionReleasesFutureDeadlinesUnchanged() async {
        let start = Date(timeIntervalSince1970: 61000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, startupAdmission: .awaitingRecovery)
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(30))
        host.addScheduledSession(record: record)
        coordinator.register(host)
        await drainTasks()

        let opened = Task { await coordinator.awaitStartupAdmission() }
        coordinator.openStartupAdmission()
        let didOpen = await opened.value
        XCTAssertTrue(didOpen)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "A future deadline still waits for its deadline")

        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
    }

    func testFailedStartupAdmissionStaysClosedAndResumesWaitersWithFailure() async {
        let start = Date(timeIntervalSince1970: 61500)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, startupAdmission: .awaitingRecovery)
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(5))
        host.addScheduledSession(record: record)
        coordinator.register(host)

        let waiter = Task { await coordinator.awaitStartupAdmission() }
        await drainTasks()
        coordinator.failStartupAdmission("reconciliation failed")
        let opened = await waiter.value
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.startupAdmission, .recoveryFailed("reconciliation failed"))
        clock.advance(to: record.notBefore)
        coordinator.evaluate()
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testTransferHoldSuppressesDeliveryUnknownConfirmationConsentAndDispatch() async {
        let start = Date(timeIntervalSince1970: 62000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let workspaceID = UUID()
        let sessionID = UUID()
        var record = makeRecord(createdAt: start, notBefore: start)
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        record.state = .dispatching
        record.attempt = attempt
        host.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        let hold = AgentScheduledSendTransferHold(
            sessionID: sessionID,
            scheduleID: record.id,
            scheduleAttemptID: attempt.attemptID,
            reason: .awaitingRecovery
        )
        coordinator.holdTransfer(hold)

        coordinator.register(host)
        coordinator.confirmAndSendNow(scheduleID: record.id)
        await drainTasks()
        XCTAssertEqual(coordinator.transferHold(sessionID: sessionID), hold)
        XCTAssertTrue(host.mutationRequests.isEmpty, "No duplicate delivery-unknown confirmation for a held transfer")
        XCTAssertTrue(coordinator.dashboardPendingConfirmations(in: workspaceID).isEmpty)
        XCTAssertTrue(host.dispatches.isEmpty)

        // A different attempt cannot release this hold.
        coordinator.releaseTransferHold(scheduleID: record.id, scheduleAttemptID: UUID())
        XCTAssertNotNil(coordinator.transferHold(scheduleID: record.id))

        // No linked intent: the legacy delivery-unknown normalization applies once released.
        coordinator.releaseTransferHold(scheduleID: record.id, scheduleAttemptID: attempt.attemptID)
        await drainTasks()
        XCTAssertNil(coordinator.transferHold(scheduleID: record.id))
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .needsConfirmation)
        XCTAssertEqual(host.record(scheduleID: record.id)?.confirmationReason, .deliveryUnknown)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testMandatoryTransferResolutionHydratesDispatchingStubInsteadOfConfirmingIt() async {
        let start = Date(timeIntervalSince1970: 63000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        coordinator.dispatchingRecordsRequireTransferResolution = true
        let host = FakeScheduledSendHost()
        host.holdHydration = true
        let workspaceID = UUID()
        var record = makeRecord(createdAt: start, notBefore: start)
        record.state = .dispatching
        record.attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        host.addScheduledSession(workspaceID: workspaceID, record: record, isHydrated: false)

        coordinator.register(host)
        await drainTasks()
        XCTAssertEqual(host.heldHydrationCount, 1, "Only the hydrated host may decide the transfer")
        XCTAssertTrue(host.mutationRequests.isEmpty)
        XCTAssertTrue(coordinator.dashboardPendingConfirmations(in: workspaceID).isEmpty)
        XCTAssertTrue(host.dispatches.isEmpty)
        host.releaseHeldHydrations()
        await drainTasks()
    }

    func testHeldForRecoveryOutcomeNeverConfirmsRedrivesOrCreatesAttentionRecord() async {
        let start = Date(timeIntervalSince1970: 63500)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        coordinator.dispatchingRecordsRequireTransferResolution = true
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .heldForRecovery
        let workspaceID = UUID()
        let sessionID = UUID()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(5))
        host.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        // The real host places the exact-attempt transfer hold before reporting the outcome.
        host.onDispatchEntered = { [coordinator] _ in
            coordinator.holdTransfer(AgentScheduledSendTransferHold(
                sessionID: sessionID,
                scheduleID: record.id,
                scheduleAttemptID: UUID(),
                reason: .unresolved("Delivery of this scheduled message could not be confirmed.")
            ))
        }

        coordinator.register(host)
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .dispatching, "The pending schedule stays projected as-is")
        XCTAssertNotNil(coordinator.transferHold(scheduleID: record.id))
        XCTAssertNil(coordinator.recoveryStatus(sessionID: sessionID), "The hold, not a needs-attention record, owns presentation")
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))

        coordinator.confirmAndSendNow(scheduleID: record.id)
        clock.advance(to: record.notBefore.addingTimeInterval(60))
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1, "A held attempt is never re-driven")
        XCTAssertTrue(host.mutationRequests.isEmpty, "No delivery-unknown confirmation is written for a held attempt")
        XCTAssertTrue(coordinator.dashboardPendingConfirmations(in: workspaceID).isEmpty)
    }

    func testUnresolvedRecoveryBlocksNewSessionStartEvenWhenRunningAlongside() async {
        let start = Date(timeIntervalSince1970: 64000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let scheduledHost = FakeScheduledSendHost()
        let recoveryHost = FakeScheduledSendHost()
        recoveryHost.unresolvedRecoveryWorkspaceIDs = [workspaceID]
        let record = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: true,
            runAlongsideOtherSessions: true
        )
        scheduledHost.addScheduledSession(workspaceID: workspaceID, record: record)
        XCTAssertTrue(AgentScheduledSendBusyState(hasUnresolvedRecovery: true).isBusy)

        coordinator.register(scheduledHost)
        coordinator.register(recoveryHost)
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertTrue(scheduledHost.dispatches.isEmpty)

        recoveryHost.unresolvedRecoveryWorkspaceIDs = []
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(scheduledHost.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(scheduledHost.dispatches.first?.lease.runAlongsideOtherSessions, true)
    }

    /// Lossless restart F2: Send now (both menu items) on an overdue new-session start held by a
    /// crash hold, a session restriction, or a workspace restriction elsewhere in the workspace
    /// records consent and reports `blocked` with that reason, never a silent no-op. Only clearing
    /// the blocker (It stopped, in the real host) admits it, and the consent dispatches once.
    func testSendNowOnRecoveryBlockedNewSessionReportsBlockedUntilBlockerClears() async {
        let cases: [(String, AgentScheduledSendRecoveryBlocker)] = [
            ("crash hold", AgentScheduledSendRecoveryBlocker(interruptedSessionIDs: [UUID(), UUID()])),
            ("session restriction", AgentScheduledSendRecoveryBlocker(restrictedSessionIDs: [UUID()])),
            ("workspace restriction", AgentScheduledSendRecoveryBlocker(workspaceRestriction: "unreadable"))
        ]
        for (index, (label, expected)) in cases.enumerated() {
            let launch = Date(timeIntervalSince1970: 64500 + Double(index) * 1000)
            let clock = FakeScheduledSendClock(now: launch)
            let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
            let workspaceID = UUID()
            let scheduledHost = FakeScheduledSendHost()
            let recoveryHost = FakeScheduledSendHost()
            recoveryHost.recoveryBlockers[workspaceID] = expected
            var record = makeRecord(
                createdAt: launch.addingTimeInterval(-120),
                notBefore: launch.addingTimeInterval(-60),
                isNewSessionStart: true
            )
            record.state = .needsConfirmation
            record.confirmationReason = .missedWhileClosed
            let sessionID = UUID()
            scheduledHost.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
            let changes = DashboardChangeCounter()
            let observer = NotificationCenter.default.addObserver(
                forName: .agentScheduledSendDispositionDidChange,
                object: coordinator,
                queue: nil
            ) { notification in
                if notification.userInfo?["sessionID"] as? UUID == sessionID { changes.increment() }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            coordinator.register(scheduledHost)
            coordinator.register(recoveryHost)
            await drainTasks()
            XCTAssertEqual(coordinator.disposition(scheduleID: record.id), .progressing, "\(label): unconsented")

            for runAlongside in [false, true] {
                let revision = scheduledHost.record(scheduleID: record.id)?.updatedAt
                let result = coordinator.confirmAndSendNow(
                    scheduleID: record.id,
                    runAlongsideOtherSessions: runAlongside,
                    committedRevision: revision
                )
                XCTAssertEqual(result, .blocked(expected), "\(label), runAlongside \(runAlongside)")
                await drainTasks()
                XCTAssertTrue(scheduledHost.dispatches.isEmpty, "\(label): the recovery gate holds, Run alongside included")
                XCTAssertEqual(coordinator.disposition(scheduleID: record.id), .blocked(expected), label)
                XCTAssertEqual(coordinator.recoveryBlocker(scheduleID: record.id), expected, label)
            }
            XCTAssertEqual(changes.value, 1, "\(label): one change notification while the blocker is unchanged")

            // The same blocker on every evaluation (Dismiss changes nothing the gate reads).
            coordinator.recordDidChange()
            await drainTasks()
            XCTAssertTrue(scheduledHost.dispatches.isEmpty, label)

            // It stopped (or the restriction's resolution) clears the blocker.
            recoveryHost.recoveryBlockers = [:]
            coordinator.recordDidChange()
            await drainTasks()
            XCTAssertEqual(scheduledHost.dispatches.map(\.scheduleID), [record.id], label)
            XCTAssertEqual(scheduledHost.dispatches.first?.lease.allowsNeedsConfirmation, true, "\(label): the recorded consent")
            XCTAssertEqual(scheduledHost.dispatches.first?.lease.runAlongsideOtherSessions, true, label)
            XCTAssertNil(coordinator.recoveryBlocker(scheduleID: record.id), label)
            XCTAssertEqual(changes.value, 2, "\(label): the cleared blocker is announced")
            coordinator.recordDidChange()
            await drainTasks()
            XCTAssertEqual(scheduledHost.dispatches.count, 1, "\(label): exactly once")
        }
    }

    /// Lossless restart F2: a schedule held by its own session's unresolved recovery (here a
    /// workspace restriction) reports `blocked` with the destination flagged.
    func testOwnSessionUnresolvedRecoveryReportsBlockedDisposition() async {
        let start = Date(timeIntervalSince1970: 68000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let workspaceID = UUID()
        let host = FakeScheduledSendHost()
        host.recoveryBlockers[workspaceID] = AgentScheduledSendRecoveryBlocker(workspaceRestriction: "unreadable")
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(5))
        let tabID = host.addScheduledSession(
            workspaceID: workspaceID,
            record: record,
            busyState: AgentScheduledSendBusyState(hasUnresolvedRecovery: true)
        )
        coordinator.register(host)
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)
        XCTAssertEqual(
            coordinator.recoveryBlocker(scheduleID: record.id),
            AgentScheduledSendRecoveryBlocker(workspaceRestriction: "unreadable", destinationUnresolved: true)
        )

        host.recoveryBlockers = [:]
        host.setBusyState(AgentScheduledSendBusyState(), tabID: tabID)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [record.id])
        XCTAssertEqual(coordinator.disposition(scheduleID: record.id), .progressing)
    }

    /// Lossless restart F2: every early return of `confirmAndSendNow` reports its reason.
    func testConfirmAndSendNowReportsEveryRefusalWithoutInstallingConsent() async {
        let launch = Date(timeIntervalSince1970: 69000)
        let clock = FakeScheduledSendClock(now: launch)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, startupAdmission: .awaitingRecovery)
        let host = FakeScheduledSendHost()
        let future = makeRecord(createdAt: launch, notBefore: launch.addingTimeInterval(600))
        host.addScheduledSession(record: future)
        coordinator.register(host)

        XCTAssertEqual(
            coordinator.confirmAndSendNow(scheduleID: future.id),
            .rejected(.startupAdmissionClosed(.awaitingRecovery))
        )
        coordinator.failStartupAdmission("reconciliation failed")
        XCTAssertEqual(
            coordinator.confirmAndSendNow(scheduleID: future.id),
            .rejected(.startupAdmissionClosed(.recoveryFailed("reconciliation failed")))
        )
        coordinator.openStartupAdmission()
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "Refused consent was never installed")

        let hold = AgentScheduledSendTransferHold(
            sessionID: UUID(),
            scheduleID: future.id,
            scheduleAttemptID: UUID(),
            reason: .awaitingRecovery
        )
        coordinator.holdTransfer(hold)
        XCTAssertEqual(coordinator.confirmAndSendNow(scheduleID: future.id), .rejected(.transferHeld))
        coordinator.releaseTransferHold(scheduleID: future.id, scheduleAttemptID: hold.scheduleAttemptID)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)

        // An overdue-at-launch record gets a confirmation obligation whose save is still in flight.
        host.holdMutations = true
        let overdue = makeRecord(createdAt: launch.addingTimeInterval(-120), notBefore: launch.addingTimeInterval(-60))
        host.addScheduledSession(record: overdue)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertNotNil(coordinator.pendingConfirmationStatus(scheduleID: overdue.id))
        XCTAssertEqual(coordinator.confirmAndSendNow(scheduleID: overdue.id), .rejected(.confirmationPending))
        XCTAssertEqual(coordinator.disposition(scheduleID: overdue.id), .rejected(.confirmationPending))

        XCTAssertEqual(coordinator.confirmAndSendNow(scheduleID: UUID()), .rejected(.scheduleNotFound))

        XCTAssertEqual(coordinator.confirmAndSendNow(scheduleID: future.id), .progressing)
        await drainTasks()
        XCTAssertEqual(host.dispatches.map(\.scheduleID), [future.id], "An accepted Send now still dispatches")
        host.holdMutations = false
        host.releaseHeldMutation(with: nil)
        await drainTasks()
    }

    private func makeRecord(
        id: UUID = UUID(),
        createdAt: Date,
        notBefore: Date,
        isNewSessionStart: Bool = false,
        runAlongsideOtherSessions: Bool = false
    ) -> AgentScheduledSendPersist {
        AgentScheduledSendPersist(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            notBefore: notBefore,
            state: .scheduled,
            confirmationReason: nil,
            rawText: "scheduled message",
            attachments: [],
            taggedFileAttachments: [],
            workflow: nil,
            interviewFirst: false,
            isNewSessionStart: isNewSessionStart,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )
    }

    private func drainTasks(iterations: Int = 20) async {
        for _ in 0 ..< iterations {
            await Task.yield()
        }
    }

    // MARK: - Final gate policy, consent rollback, clock rollback, accepted recovery (R3)

    func testFollowUpHandoffIgnoresOtherBusySessionsButNotBusyDestinationOnPeerHost() async throws {
        let start = Date(timeIntervalSince1970: 30000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let ownerHost = FakeScheduledSendHost()
        let foreignHost = FakeScheduledSendHost()
        ownerHost.holdDispatches = true
        let workspaceID = UUID()
        let sessionID = UUID()
        let followUp = makeRecord(
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            isNewSessionStart: false
        )
        ownerHost.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: followUp)
        // An unrelated session runs in the same workspace on the other host.
        foreignHost.addSession(
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )

        coordinator.register(ownerHost)
        coordinator.register(foreignHost)
        clock.advance(to: followUp.notBefore)
        await drainTasks()

        let lease = try XCTUnwrap(ownerHost.dispatches.first?.lease)
        XCTAssertFalse(lease.requiresWorkspaceGate)
        XCTAssertNotNil(
            coordinator.finalHandoffValidator(for: lease),
            "A follow-up waits only on its own session; unrelated busy sessions never revoke it"
        )

        // The same durable session busy on the peer host is a destination blocker even with the override.
        let peerTabID = foreignHost.addSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )
        XCTAssertNil(coordinator.finalHandoffValidator(for: lease), "A busy destination on any host revokes the handoff")
        foreignHost.setBusyState(AgentScheduledSendBusyState(), tabID: peerTabID)
        XCTAssertNotNil(coordinator.finalHandoffValidator(for: lease))
        ownerHost.completeNextDispatch(with: .accepted)
        await drainTasks()
        XCTAssertEqual(ownerHost.dispatches.count, 1)

        // A workspace-gated new-session start carries the gate to the handoff.
        let newStartHost = FakeScheduledSendHost()
        newStartHost.holdDispatches = true
        let newStart = makeRecord(
            createdAt: clock.now,
            notBefore: clock.now.addingTimeInterval(10),
            isNewSessionStart: true
        )
        newStartHost.addScheduledSession(workspaceID: workspaceID, record: newStart)
        coordinator.register(newStartHost)
        try foreignHost.setBusyState(AgentScheduledSendBusyState(), tabID: XCTUnwrap(foreignHost.busyTabIDs.first))
        clock.advance(to: newStart.notBefore)
        await drainTasks()
        let newStartLease = try XCTUnwrap(newStartHost.dispatches.first?.lease)
        XCTAssertTrue(newStartLease.requiresWorkspaceGate)
        XCTAssertNotNil(coordinator.finalHandoffValidator(for: newStartLease))
        foreignHost.addSession(
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )
        XCTAssertNil(coordinator.finalHandoffValidator(for: newStartLease), "Late foreign busy session revokes a workspace-gated start")
        newStartHost.completeNextDispatch(with: .deferredBusy)
        await drainTasks()
    }

    func testSendNowConsentSurvivesExactLeaseRollbackAfterLateBlocker() async throws {
        let start = Date(timeIntervalSince1970: 31000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdDispatches = true
        var failed = makeRecord(
            createdAt: start.addingTimeInterval(-600),
            notBefore: start.addingTimeInterval(-300),
            isNewSessionStart: false
        )
        failed.state = .failed
        host.addScheduledSession(record: failed)
        coordinator.register(host)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "A failed record is not eligible without confirmation")

        coordinator.confirmAndSendNow(scheduleID: failed.id)
        await drainTasks()
        let firstLease = try XCTUnwrap(host.dispatches.first?.lease)
        XCTAssertTrue(firstLease.allowsNeedsConfirmation)

        // A late blocker appears while the attempt is persisted; the host rolls the attempt back
        // to a new revision without any user edit and reports deferral.
        let revertedAt = clock.now.addingTimeInterval(1)
        host.updateRecord(scheduleID: failed.id) { record in
            record.state = .failed
            record.updatedAt = revertedAt
        }
        coordinator.admissionRolledBack(lease: firstLease, revertedUpdatedAt: revertedAt)
        host.completeNextDispatch(with: .deferredBusy)
        await drainTasks()

        // Consent carried: the record is re-admitted at the reverted revision, still confirmed.
        XCTAssertEqual(host.dispatches.count, 2, "The confirmed send is retried, not silently dropped")
        let secondLease = try XCTUnwrap(host.dispatches.last?.lease)
        XCTAssertEqual(secondLease.admittedUpdatedAt, revertedAt)
        XCTAssertTrue(secondLease.allowsNeedsConfirmation)
        host.completeNextDispatch(with: .accepted)
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 2)

        // A user edit after rollback still withdraws consent.
        var edited = makeRecord(createdAt: clock.now, notBefore: clock.now.addingTimeInterval(-1), isNewSessionStart: false)
        edited.state = .needsConfirmation
        let editedTabID = host.addScheduledSession(record: edited)
        coordinator.recordDidChange()
        coordinator.confirmAndSendNow(scheduleID: edited.id)
        await drainTasks()
        let editedLease = try XCTUnwrap(host.dispatches.last?.lease)
        XCTAssertEqual(editedLease.scheduleID, edited.id)
        let userEditAt = clock.now.addingTimeInterval(2)
        host.updateRecord(scheduleID: edited.id) { record in
            record.state = .needsConfirmation
            record.notBefore = clock.now.addingTimeInterval(600)
            record.updatedAt = userEditAt
        }
        host.completeNextDispatch(with: .deferredBusy)
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 3, "An edited revision is not re-admitted on the stale consent")
        _ = editedTabID
    }

    func testClockRollbackWhileHydrationIsHeldRetainsConfirmationUntilDurableMutation() async throws {
        let start = Date(timeIntervalSince1970: 32000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdHydration = true
        let record = makeRecord(
            createdAt: start.addingTimeInterval(5),
            notBefore: start.addingTimeInterval(60),
            isNewSessionStart: false
        )
        host.addScheduledSession(record: record, isHydrated: false)
        coordinator.register(host)
        await drainTasks()

        // Deadline passes while unhydrated: hydration is requested and held.
        clock.advance(to: record.notBefore.addingTimeInterval(30))
        await drainTasks()
        XCTAssertEqual(host.heldHydrationCount, 1)
        XCTAssertTrue(host.dispatches.isEmpty)

        // The wall clock rolls back so the deadline is in the future again (uncertain crossing).
        clock.setNow(
            record.notBefore.addingTimeInterval(-120),
            probe: SchedulerClockProbe(suspendedGap: 0, wallClockAdjustment: -150)
        )
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.unhydratedMutationAttemptCount, 0, "No durable mutation is attempted on an unhydrated projection")
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .scheduled)

        // Hydration completes: the parked confirmation is applied before any deadline can fire.
        host.releaseHeldHydrations()
        await drainTasks()
        let normalized = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(normalized.state, .needsConfirmation)
        XCTAssertEqual(normalized.confirmationReason, .clockChanged)
        XCTAssertGreaterThan(host.persistCount, 0)

        clock.advance(to: record.notBefore.addingTimeInterval(1))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "An uncertain crossing never auto-dispatches at the rolled-back deadline")
    }

    // MARK: - Durable confirmation obligations (R3-5)

    func testClockConfirmationWriteFailureRetainsObligationBlocksDispatchAndRetriesBounded() async throws {
        let start = Date(timeIntervalSince1970: 42000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdHydration = true
        let record = makeRecord(createdAt: start.addingTimeInterval(5), notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        let tabID = host.addScheduledSession(record: record, isHydrated: false)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))
        coordinator.register(host)
        await drainTasks()
        clock.advance(to: record.notBefore.addingTimeInterval(30))
        await drainTasks()
        XCTAssertEqual(host.heldHydrationCount, 1)

        // Backward clock: the decision is installed as a retained obligation, not consumed.
        clock.setNow(record.notBefore.addingTimeInterval(-120), probe: SchedulerClockProbe(suspendedGap: 0, wallClockAdjustment: -150))
        coordinator.recordDidChange()
        await drainTasks()
        let installed = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(installed.reason, .clockChanged)
        XCTAssertEqual(installed.phase, .waitingForOwner)
        XCTAssertEqual(host.unhydratedMutationAttemptCount, 0)

        // Two write failures once an owner exists: exact retries on the coordinator clock.
        host.mutationOutcomeQueue = [.failed("disk full"), .failed("disk full")]
        host.releaseHeldHydrations()
        await drainTasks()
        var status = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(status.attemptCount, 1)
        guard case .waitingToRetry(nextAttemptNumber: 2, notBefore: let firstRetryAt) = status.phase else {
            return XCTFail("Expected waitingToRetry after the first failure, got \(status.phase)")
        }
        XCTAssertEqual(firstRetryAt, clock.now.addingTimeInterval(1))
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .scheduled, "No optimistic projection of an unacknowledged mutation")

        // Reconciliation ticks and epoch refreshes do not consume the budget or admit.
        for _ in 0 ..< 3 {
            coordinator.recordDidChange()
            await drainTasks()
        }
        XCTAssertEqual(coordinator.pendingConfirmationStatus(sessionID: sessionID)?.attemptCount, 1)
        XCTAssertEqual(host.mutationRequests.count, 1)

        // The rolled-back deadline passes while the obligation is pending: never dispatched.
        clock.advance(to: record.notBefore.addingTimeInterval(1))
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "A pending confirmation blocks admission at the deadline")
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))

        // Second attempt fails (after 1s), third commits (after 2s more).
        status = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(status.attemptCount, 2)
        guard case .waitingToRetry(nextAttemptNumber: 3, notBefore: let secondRetryAt) = status.phase else {
            return XCTFail("Expected waitingToRetry after the second failure, got \(status.phase)")
        }
        clock.advance(to: secondRetryAt)
        await drainTasks()
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID), "Exact acknowledgement clears the obligation")
        let durable = try XCTUnwrap(host.record(scheduleID: record.id))
        XCTAssertEqual(durable.state, .needsConfirmation)
        XCTAssertEqual(durable.confirmationReason, .clockChanged)
        XCTAssertEqual(host.mutationRequests.count, 3)
        XCTAssertEqual(host.mutationRequests.map(\.replacement), Array(repeating: host.mutationRequests[0].replacement, count: 3), "The exact replacement is retained across retries")
        clock.advance(to: record.notBefore.addingTimeInterval(120))
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "A durable needsConfirmation record stays ineligible without user confirmation")
    }

    func testClockConfirmationExhaustionParksInAttentionUntilManualRetry() async throws {
        let start = Date(timeIntervalSince1970: 43000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        let tabID = host.addScheduledSession(record: record)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))
        host.mutationOutcomeQueue = [.failed("1"), .failed("2"), .failed("3")]
        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(90), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        for _ in 0 ..< 2 {
            guard case let .waitingToRetry(_, notBefore)? = coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase else {
                return XCTFail("Expected a parked retry")
            }
            clock.advance(to: notBefore)
            await drainTasks()
        }
        let exhausted = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(exhausted.phase, .needsAttention(lastFailure: "3"))
        XCTAssertEqual(host.mutationRequests.count, 3)
        XCTAssertEqual(host.record(scheduleID: record.id)?.state, .scheduled)
        clock.advance(to: clock.now.addingTimeInterval(600))
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty, "Attention retains the dispatch block with no running worker")
        XCTAssertEqual(host.mutationRequests.count, 3, "No automatic attempt after exhaustion")

        XCTAssertFalse(coordinator.retryPendingConfirmation(sessionID: UUID()))
        XCTAssertTrue(coordinator.retryPendingConfirmation(sessionID: sessionID))
        await drainTasks()
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(host.record(scheduleID: record.id)?.confirmationReason, .missedDuringSleep)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testStaleConfirmationWriteCannotClearNewerDecision() async throws {
        let start = Date(timeIntervalSince1970: 44000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdMutations = true
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        let tabID = host.addScheduledSession(record: record)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))
        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(90), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        let first = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(first.phase, .saving(attemptNumber: 1))
        XCTAssertEqual(host.heldMutationCount, 1)

        // A newer decision (clock change) arrives while the first write is outstanding.
        clock.setNow(clock.now.addingTimeInterval(-200), probe: SchedulerClockProbe(suspendedGap: 0, wallClockAdjustment: -200))
        coordinator.recordDidChange()
        await drainTasks()
        let second = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertNotEqual(second.decisionID, first.decisionID)
        XCTAssertEqual(second.reason, .clockChanged)
        XCTAssertEqual(host.heldMutationCount, 1, "One writer per session: no second request while the first is outstanding")

        // The old write completes durably: real, but it clears nothing newer.
        host.releaseHeldMutation(with: nil)
        await drainTasks()
        let stillPending = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(stillPending.decisionID, second.decisionID, "The newer obligation remains")
        XCTAssertEqual(host.record(scheduleID: record.id)?.confirmationReason, .missedDuringSleep, "The stale durable write is not rolled back")
        XCTAssertEqual(host.heldMutationCount, 1, "The newer decision issues its own exact request against current authority")
        host.releaseHeldMutation(with: nil)
        await drainTasks()
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(host.record(scheduleID: record.id)?.confirmationReason, .clockChanged)
        XCTAssertTrue(host.dispatches.isEmpty)
    }

    func testUserSupersessionClearsCurrentDecisionButNotANewerOne() async throws {
        let start = Date(timeIntervalSince1970: 45000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdMutations = true
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        let tabID = host.addScheduledSession(record: record)
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))
        coordinator.register(host)
        clock.advance(to: start.addingTimeInterval(90), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        XCTAssertEqual(host.heldMutationCount, 1)

        // The user confirms while the automatic write is outstanding: the write fails, the
        // user's durable action supersedes the decision, consent is installed at the durable
        // revision, and exactly one dispatch follows.
        let token = coordinator.beginUserSupersession(sessionID: sessionID, scheduleID: record.id)
        host.releaseHeldMutation(with: .failed("outstanding write failed"))
        await drainTasks()
        XCTAssertEqual(host.heldMutationCount, 0, "The reservation prevents another automatic mutation")
        XCTAssertNotNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertTrue(coordinator.completeUserSupersession(token, committedRevision: record.updatedAt))
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        coordinator.confirmAndSendNow(scheduleID: record.id, committedRevision: record.updatedAt)
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)
        XCTAssertEqual(host.dispatches.first?.lease.admittedUpdatedAt, record.updatedAt)

        // A second schedule: the token captured before a newer decision cannot clear it.
        let later = makeRecord(createdAt: clock.now, notBefore: clock.now.addingTimeInterval(60), isNewSessionStart: false)
        let laterTabID = host.addScheduledSession(record: later)
        let laterSessionID = try XCTUnwrap(host.sessionID(tabID: laterTabID))
        host.holdMutations = false
        host.mutationOutcomeQueue = [.failed("x")]
        coordinator.recordDidChange()
        clock.advance(to: later.notBefore.addingTimeInterval(30), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        let firstDecision = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: laterSessionID))
        XCTAssertEqual(firstDecision.reason, .missedDuringSleep)
        let staleToken = coordinator.beginUserSupersession(sessionID: laterSessionID, scheduleID: later.id)
        let requestsBeforeRollback = host.mutationRequests.count

        // A newer clock decision replaces the reserved one while the user action is in progress.
        clock.setNow(clock.now.addingTimeInterval(-300), probe: SchedulerClockProbe(suspendedGap: 0, wallClockAdjustment: -300))
        coordinator.recordDidChange()
        await drainTasks()
        let newerDecision = try XCTUnwrap(coordinator.pendingConfirmationStatus(sessionID: laterSessionID), "The newer decision is pending before the token is used")
        XCTAssertNotEqual(newerDecision.decisionID, firstDecision.decisionID)
        XCTAssertEqual(newerDecision.reason, .clockChanged)
        XCTAssertEqual(host.mutationRequests.count, requestsBeforeRollback, "The reservation keeps automatic writes from racing the user action")

        XCTAssertFalse(coordinator.completeUserSupersession(staleToken, committedRevision: later.updatedAt), "An older token cannot clear a newer decision")
        XCTAssertEqual(coordinator.pendingConfirmationStatus(sessionID: laterSessionID)?.decisionID, newerDecision.decisionID)
        coordinator.confirmAndSendNow(scheduleID: later.id, committedRevision: later.updatedAt)
        clock.advance(to: later.notBefore.addingTimeInterval(400))
        await drainTasks()
        XCTAssertFalse(host.dispatches.contains { $0.scheduleID == later.id }, "A pending obligation is never bypassed by consent")
        // Once the user action exits, the newer decision is persisted exactly and stays ineligible.
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: laterSessionID))
        XCTAssertEqual(host.record(scheduleID: later.id)?.confirmationReason, .clockChanged)
    }

    func testMultipleHostsProjectingOneScheduleUseASingleConfirmationWriter() async {
        let start = Date(timeIntervalSince1970: 46000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let hostA = FakeScheduledSendHost()
        let hostB = FakeScheduledSendHost()
        let sessionID = UUID()
        let workspaceID = UUID()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        hostA.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        let tabB = hostB.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        coordinator.register(hostA)
        coordinator.register(hostB)
        clock.advance(to: start.addingTimeInterval(90), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(hostA.mutationRequests.count + hostB.mutationRequests.count, 1, "Exactly one owner writes the confirmation")
        if hostA.mutationRequests.isEmpty {
            XCTAssertEqual(hostA.projectionRefreshes.count, 1, "The other host is asked to refresh the retired revision")
        } else {
            XCTAssertEqual(hostB.projectionRefreshes, [FakeScheduledSendHost.ProjectionRefresh(tabID: tabB, sessionID: sessionID)])
        }
        XCTAssertTrue(hostA.dispatches.isEmpty && hostB.dispatches.isEmpty)
    }

    func testFirstEligibilityConsentAdvancesOnlyFromTheCommittedRevision() async throws {
        let start = Date(timeIntervalSince1970: 47000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        host.holdMutations = true
        // Hold the eventual dispatch so the durable record stays observable after admission.
        host.holdDispatches = true
        let runID = UUID()
        var confirmed = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(-10), isNewSessionStart: false)
        confirmed.state = .needsConfirmation
        let tabID = host.addScheduledSession(record: confirmed, busyState: AgentScheduledSendBusyState(runID: runID, runState: .running))
        let sessionID = try XCTUnwrap(host.sessionID(tabID: tabID))
        coordinator.register(host)
        coordinator.confirmAndSendNow(scheduleID: confirmed.id)
        await drainTasks()
        XCTAssertEqual(host.heldMutationCount, 1, "firstEligibleAt is written through one acknowledged mutation")
        XCTAssertEqual(host.record(scheduleID: confirmed.id)?.firstEligibleAt, nil, "No speculative projection")

        // The blocker clears while the write is unresolved: admission never targets the
        // speculative revision, and consent advances only once the commit is acknowledged.
        host.setBusyState(AgentScheduledSendBusyState(runID: runID, runState: .completed), tabID: tabID)
        coordinator.runStateDidChange(sessionID: sessionID, runID: runID, state: .completed)
        await drainTasks()
        XCTAssertTrue(host.dispatches.isEmpty)
        host.releaseHeldMutation(with: nil)
        await drainTasks()
        let committed = try XCTUnwrap(host.record(scheduleID: confirmed.id))
        XCTAssertNotNil(committed.firstEligibleAt)
        XCTAssertEqual(host.dispatches.count, 1)
        XCTAssertEqual(host.dispatches.first?.lease.admittedUpdatedAt, committed.updatedAt, "Consent moved to the committed revision")
        XCTAssertTrue(host.dispatches.first?.lease.allowsNeedsConfirmation == true)
        host.completeNextDispatch(with: .accepted)
        await drainTasks()
    }

    func testCrossHostSendNowDrainsHeldSuccessfulConfirmationWriteBeforeConsentIsInstalled() async throws {
        let start = Date(timeIntervalSince1970: 48000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let hostA = FakeScheduledSendHost()
        let hostB = FakeScheduledSendHost()
        hostA.holdMutations = true
        let sessionID = UUID()
        let workspaceID = UUID()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(60), isNewSessionStart: false)
        hostA.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        coordinator.register(hostA)
        clock.advance(to: start.addingTimeInterval(90), probe: SchedulerClockProbe(suspendedGap: 60))
        await drainTasks()
        XCTAssertEqual(hostA.heldMutationCount, 1, "Host A's confirmation write is outstanding")
        let heldReplacement = try XCTUnwrap(hostA.mutationRequests.first?.replacement)

        // Host B projects the pre-decision revision and the user presses Send now there.
        hostB.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        coordinator.register(hostB)
        let earlyToken = coordinator.beginUserSupersession(sessionID: sessionID, scheduleID: record.id)
        XCTAssertFalse(
            coordinator.completeUserSupersession(earlyToken, committedRevision: record.updatedAt),
            "Consent is never installed while an older confirmation write is outstanding"
        )
        let drained = DrainProbe()
        let drainTask = Task { @MainActor in
            await coordinator.drainOutstandingHostMutation(sessionID: sessionID)
            drained.completed = true
        }
        await drainTasks()
        XCTAssertFalse(drained.completed, "Draining waits for the held write")

        // The older write commits successfully; its acknowledgement clears the decision.
        hostA.releaseHeldMutation(with: nil)
        await drainTask.value
        XCTAssertTrue(drained.completed)
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        XCTAssertEqual(hostA.record(scheduleID: record.id)?.confirmationReason, .missedDuringSleep)
        // Host B refreshes to the committed revision (as the VM's resync does) before consenting.
        hostB.updateRecord(scheduleID: record.id) { $0 = heldReplacement }
        let token = coordinator.beginUserSupersession(sessionID: sessionID, scheduleID: record.id)
        XCTAssertTrue(coordinator.completeUserSupersession(token, committedRevision: heldReplacement.updatedAt))
        coordinator.confirmAndSendNow(scheduleID: record.id, committedRevision: heldReplacement.updatedAt)
        await drainTasks()
        let dispatches = hostA.dispatches + hostB.dispatches
        XCTAssertEqual(dispatches.count, 1, "Send now after the drained write dispatches exactly once")
        XCTAssertEqual(dispatches.first?.lease.admittedUpdatedAt, heldReplacement.updatedAt, "Consent targets the committed revision, not the superseded one")
        XCTAssertTrue(dispatches.first?.lease.allowsNeedsConfirmation == true)
    }

    func testFirstEligibilityWriteFailureBacksOffInsteadOfHotLooping() async throws {
        let start = Date(timeIntervalSince1970: 49000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let host = FakeScheduledSendHost()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(10), isNewSessionStart: false)
        let tabID = host.addScheduledSession(
            record: record,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )
        host.mutationOutcomeQueue = Array(repeating: .failed("disk full"), count: 6)
        coordinator.register(host)
        // Armed before its deadline, then due while the destination is busy: the informational
        // first-eligibility write is issued and fails.
        clock.advance(to: record.notBefore)
        await drainTasks()
        XCTAssertEqual(host.mutationRequests.count, 1, "One informational write attempt")
        XCTAssertNil(host.record(scheduleID: record.id)?.firstEligibleAt)

        // Reconciliation ticks and busy-state churn without a clock advance never re-issue.
        for _ in 0 ..< 4 {
            coordinator.recordDidChange()
            try coordinator.runStateDidChange(sessionID: XCTUnwrap(host.sessionID(tabID: tabID)), runID: nil, state: .running)
            await drainTasks()
        }
        XCTAssertEqual(host.mutationRequests.count, 1, "Failure never loops on the same revision")

        // The bounded backoff elapses: exactly one more attempt.
        clock.advance(to: clock.now.addingTimeInterval(1))
        await drainTasks()
        XCTAssertEqual(host.mutationRequests.count, 2)

        // Storage recovers: the next scheduled attempt commits and marks first eligibility.
        host.mutationOutcomeQueue = []
        clock.advance(to: clock.now.addingTimeInterval(1))
        await drainTasks()
        XCTAssertEqual(host.mutationRequests.count, 3)
        XCTAssertNotNil(host.record(scheduleID: record.id)?.firstEligibleAt)
        XCTAssertTrue(host.dispatches.isEmpty, "Still busy: no admission")
    }

    func testAdmissionAppliesProcessWideDestinationBusyPredicateBeforeAnyAttemptWrite() async {
        let start = Date(timeIntervalSince1970: 40000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let ownerHost = FakeScheduledSendHost()
        let peerHost = FakeScheduledSendHost()
        let sessionID = UUID()
        let workspaceID = UUID()
        let record = makeRecord(createdAt: start, notBefore: start.addingTimeInterval(10), isNewSessionStart: false)
        ownerHost.addScheduledSession(sessionID: sessionID, workspaceID: workspaceID, record: record)
        // A peer bound to the same durable session is busy and projects no schedule at all.
        let peerTabID = peerHost.addSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            record: nil,
            busyState: AgentScheduledSendBusyState(runID: UUID(), runState: .running)
        )
        coordinator.register(ownerHost)
        coordinator.register(peerHost)

        clock.advance(to: record.notBefore)
        await drainTasks()
        for _ in 0 ..< 3 {
            coordinator.recordDidChange()
            await drainTasks()
        }
        XCTAssertTrue(ownerHost.dispatches.isEmpty, "Admission applies the final gate's destination predicate: no attempt write")
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(ownerHost.record(scheduleID: record.id)?.state, .scheduled)
        XCTAssertNotNil(ownerHost.record(scheduleID: record.id)?.firstEligibleAt, "The record waits visibly for the busy destination")

        peerHost.setBusyState(AgentScheduledSendBusyState(), tabID: peerTabID)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(ownerHost.dispatches.count, 1, "Exactly one attempt once the destination is idle everywhere")
    }

    // MARK: - Process-owned accepted recovery (plan P1.3)

    // These cases drive the real `AgentSessionDataService` (isolated instance, temporary
    // workspace): ownership is reserved inside the final handoff gate, acceptance transfers the
    // immutable payload synchronously, one coordinator worker owns persistence, bounded failure
    // retains payload and protection with a persistence-only retry, and missing-file handling is
    // decided by gated explicit-deletion evidence.

    func testAcceptedRecoveryIsProcessOwnedAndSurvivesTabCloseAndHostRemoval() async throws {
        let start = Date(timeIntervalSince1970: 33000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        let fixture = try await makeRecoveryFixture(name: "Recovery", createdAt: start, notBefore: start.addingTimeInterval(10))
        let failures = RecoveryFailureSwitch()
        await fixture.service.test_setScheduledSendRecoveryFailureInjector { [failures] _ in failures.next() }
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)

        let registrationID = coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("provider handoff completed") { host.dispatches.count == 1 && handoff.payload != nil }
        let payload = try XCTUnwrap(handoff.payload)
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Accepted-but-unfinalized ownership is retained")
        try await waitUntil("first persistence attempt failed and parked") {
            failures.callCount == 1 && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
        }
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.key, handoff.key)

        // The owning tab closes and the host goes away: ownership and the worker both survive.
        coordinator.tabDidClose(sessionID: fixture.sessionID)
        coordinator.unregister(registrationID: registrationID)
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Tab close never releases duplicate-delivery protection")
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.hasAcceptedPayload, true)

        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("second persistence attempt failed and parked") {
            failures.callCount == 2 && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
        }
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID))
        failures.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("durable completion released ownership") {
            coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Durable completion releases ownership exactly")
        XCTAssertEqual(failures.callCount, 3)
        XCTAssertEqual(host.dispatches.count, 1, "The provider is never re-invoked by recovery")
        try await assertFinalized(fixture: fixture, payload: payload)
    }

    func testAcceptedRecoveryExhaustionRetainsPayloadAndProtectionUntilPersistenceOnlyRetry() async throws {
        let start = Date(timeIntervalSince1970: 34000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1])
        let fixture = try await makeRecoveryFixture(name: "Exhaustion", createdAt: start, notBefore: start.addingTimeInterval(10))
        let failures = RecoveryFailureSwitch()
        await fixture.service.test_setScheduledSendRecoveryFailureInjector { [failures] _ in failures.next() }
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("provider handoff completed") { handoff.payload != nil }
        let payload = try XCTUnwrap(handoff.payload)

        for expectedCalls in 1 ... 2 {
            try await waitUntil("attempt \(expectedCalls) failed and parked") {
                failures.callCount == expectedCalls && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
            }
            clock.advance(to: clock.now.addingTimeInterval(1))
        }
        try await waitUntil("bounded retries ended in attention") {
            if case .needsAttention(.persistenceExhausted)? = coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase { return true }
            return false
        }
        XCTAssertEqual(failures.callCount, 3)
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Attention retains duplicate-delivery protection")
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.hasAcceptedPayload, true, "Attention retains the immutable payload")

        // Neither the record on disk nor the host projection is normalized, and nothing re-dispatches.
        let parked = try await fixture.service.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
        XCTAssertEqual(parked?.scheduledSend?.persistedValue?.state, .dispatching)
        XCTAssertEqual(parked?.scheduledSend?.persistedValue?.attempt, payload.attempt)
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)
        XCTAssertEqual(host.record(scheduleID: fixture.record.id)?.state, .dispatching)
        XCTAssertEqual(host.persistCount, 0)

        // Persistence-only retry: exact session, single worker, never a provider action.
        XCTAssertFalse(coordinator.retryRecovery(sessionID: UUID()))
        failures.failing = false
        XCTAssertTrue(coordinator.retryRecovery(sessionID: fixture.sessionID))
        XCTAssertFalse(coordinator.retryRecovery(sessionID: fixture.sessionID), "A second retry while a worker is active is a no-op")
        try await waitUntil("manual retry committed") { coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil }
        XCTAssertNil(coordinator.activeAdmission(sessionID: fixture.sessionID))
        XCTAssertEqual(failures.callCount, 4)
        XCTAssertEqual(host.dispatches.count, 1, "The provider is never re-invoked by recovery")
        try await assertFinalized(fixture: fixture, payload: payload)
    }

    func testConflictingAcceptanceReportIsIgnoredFirstEvidenceWins() async throws {
        let start = Date(timeIntervalSince1970: 41000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1])
        let fixture = try await makeRecoveryFixture(name: "Conflict", createdAt: start, notBefore: start.addingTimeInterval(10))
        let failures = RecoveryFailureSwitch()
        await fixture.service.test_setScheduledSendRecoveryFailureInjector { [failures] _ in failures.next() }
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("canonical acceptance parked for retry") {
            failures.callCount == 1 && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
        }
        let canonical = try XCTUnwrap(handoff.payload)
        let key = try XCTUnwrap(handoff.key)
        let phaseBefore = try XCTUnwrap(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)

        // A conflicting report for the same key (different receipt) arrives while the worker is parked.
        var conflictingItem = AgentChatItem.user("conflicting", id: canonical.attempt.itemID)
        let conflictingReceipt = AgentScheduledSendProvenance(
            scheduleID: canonical.receipt.scheduleID,
            attemptID: canonical.attempt.attemptID,
            scheduledFor: canonical.receipt.scheduledFor,
            sentAt: canonical.receipt.sentAt.addingTimeInterval(5)
        )
        conflictingItem.scheduledSend = conflictingReceipt
        coordinator.reportAcceptance(
            key: key,
            payload: AgentScheduledSendAcceptedPayload(
                context: canonical.context,
                attempt: canonical.attempt,
                receipt: conflictingReceipt,
                acceptedItem: conflictingItem,
                expectedUpdatedAt: canonical.expectedUpdatedAt
            )
        )
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase, phaseBefore, "The live worker and its phase are untouched")
        XCTAssertEqual(coordinator.ignoredConflictingAcceptanceReportCount(sessionID: fixture.sessionID), 1)
        XCTAssertEqual(coordinator.acceptedPayload(sessionID: fixture.sessionID)?.receipt, canonical.receipt, "First evidence stays canonical")
        // An identical duplicate is a no-op, not a conflict.
        coordinator.reportAcceptance(key: key, payload: canonical)
        XCTAssertEqual(coordinator.ignoredConflictingAcceptanceReportCount(sessionID: fixture.sessionID), 1)

        failures.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("canonical attempt settled") { coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil }
        XCTAssertEqual(failures.callCount, 2)
        try await assertFinalized(fixture: fixture, payload: canonical)
        let loaded = try await fixture.service.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertNotEqual(reloaded.lastScheduledDispatch, conflictingReceipt)
    }

    func testDurableCompletionBeforeDispatchOutcomeLeavesNoRetainedProtection() async throws {
        let start = Date(timeIntervalSince1970: 35000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let fixture = try await makeRecoveryFixture(name: "EarlyCompletion", createdAt: start, notBefore: start.addingTimeInterval(10))
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.holdDispatches = true
        host.onDispatchEntered = { [weak self, fixture, coordinator, clock, handoff] lease in
            Task { @MainActor in
                _ = await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
            }
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("acceptance reported while the dispatch is still held") { handoff.payload != nil }
        let payload = try XCTUnwrap(handoff.payload)
        try await waitUntil("worker committed before the dispatch outcome returned") {
            coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil
        }
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "The admission is held until the dispatch returns")
        try await assertFinalized(fixture: fixture, payload: payload)

        host.completeNextDispatch(with: .unknownAfterHandoff)
        await drainTasks()
        XCTAssertNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Early completion is matched exactly; no protection lingers")
        XCTAssertNil(coordinator.recoveryStatus(sessionID: fixture.sessionID))
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)
    }

    func testExplicitSessionDeletionDuringRecoverySettlesWithoutReconstruction() async throws {
        let start = Date(timeIntervalSince1970: 36000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        // Stored through a symlinked directory: deletion is matched by the canonical file key.
        let fixture = try await makeRecoveryFixture(
            name: "Deleted",
            createdAt: start,
            notBefore: start.addingTimeInterval(10),
            storageThroughSymlink: true
        )
        let failures = RecoveryFailureSwitch()
        await fixture.service.test_setScheduledSendRecoveryFailureInjector { [failures] _ in failures.next() }
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("first persistence attempt failed and parked") {
            failures.callCount == 1 && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
        }
        let payload = try XCTUnwrap(handoff.payload)
        XCTAssertNotEqual(payload.context.fileURL.path, payload.context.fileKey.path, "The fixture path is not canonical")

        // Explicit deletion through the gated data service advances the deletion generation.
        try await fixture.service.deleteAgentSession(id: fixture.sessionID, for: fixture.workspace)
        try await waitUntil("recovery settled as explicitly deleted") {
            coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: fixture.sessionID))
        XCTAssertFalse(coordinator.retryRecovery(sessionID: fixture.sessionID))

        failures.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.context.fileURL.path), "An explicitly deleted session is never reconstructed")
        XCTAssertEqual(failures.callCount, 1)

        // Even a direct retry against the same evidence refuses to reconstruct.
        do {
            let outcome = try await fixture.service.finalizeScheduledSend(recovery: payload)
            guard case .explicitlyDeleted = outcome else {
                return XCTFail("Expected explicitlyDeleted, got \(outcome)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.context.fileURL.path))
    }

    func testAccidentalSessionFileLossDuringRecoveryIsReconstructedFromPinnedSnapshot() async throws {
        let start = Date(timeIntervalSince1970: 37000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1])
        let fixture = try await makeRecoveryFixture(name: "Lost", createdAt: start, notBefore: start.addingTimeInterval(10))
        let failures = RecoveryFailureSwitch()
        await fixture.service.test_setScheduledSendRecoveryFailureInjector { [failures] _ in failures.next() }
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("first persistence attempt failed and parked") {
            failures.callCount == 1 && Self.isWaitingToRetry(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase)
        }
        let payload = try XCTUnwrap(handoff.payload)

        // The file disappears without any gated deletion: no explicit-deletion evidence exists.
        try FileManager.default.removeItem(at: payload.context.fileURL)
        failures.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("reconstruction committed") { coordinator.recoveryStatus(sessionID: fixture.sessionID) == nil }
        XCTAssertNil(coordinator.activeAdmission(sessionID: fixture.sessionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.context.fileURL.path))
        try await assertFinalized(fixture: fixture, payload: payload)
        XCTAssertEqual(host.dispatches.count, 1)
    }

    func testReservedHandoffWithoutAcceptanceBecomesAttentionAndKeepsProtection() async throws {
        let start = Date(timeIntervalSince1970: 38000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let fixture = try await makeRecoveryFixture(name: "Unresolved", createdAt: start, notBefore: start.addingTimeInterval(10))
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .unknownAfterHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff, reportAcceptance: false)
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("dispatch returned without acceptance evidence") {
            host.dispatches.count == 1 && coordinator.recoveryStatus(sessionID: fixture.sessionID)?.phase == .needsAttention(.unresolvedProviderOutcome)
        }
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: fixture.sessionID), "Reserved ownership never lapses silently")
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: fixture.sessionID)?.hasAcceptedPayload, false)
        XCTAssertEqual(
            coordinator.dashboardRecoveryStatuses(in: fixture.workspace.id).map(\.key.sessionID),
            [fixture.sessionID]
        )
        XCTAssertTrue(coordinator.dashboardRecoveryStatuses(in: UUID()).isEmpty)
        XCTAssertFalse(coordinator.retryRecovery(sessionID: fixture.sessionID), "No payload: nothing to persist, nothing to re-send")
        coordinator.recordDidChange()
        await drainTasks()
        XCTAssertEqual(host.dispatches.count, 1)
        XCTAssertEqual(host.record(scheduleID: fixture.record.id)?.state, .dispatching, "A retained attempt is never normalized")
    }

    func testProviderOutcomeNotAcceptedReleasesReservationExactly() async throws {
        let start = Date(timeIntervalSince1970: 39000)
        let clock = FakeScheduledSendClock(now: start)
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        let fixture = try await makeRecoveryFixture(name: "NotAccepted", createdAt: start, notBefore: start.addingTimeInterval(10))
        let handoff = RecoveryHandoffRecorder()
        let host = FakeScheduledSendHost()
        host.automaticOutcome = .failedBeforeHandoff
        host.onProviderHandoff = { [weak self, fixture, coordinator, clock, handoff] lease in
            let projected = await self?.performAcceptedHandoff(lease: lease, fixture: fixture, coordinator: coordinator, clock: clock, recorder: handoff, reportAcceptance: false)
            if let key = handoff.key {
                XCTAssertNotNil(coordinator.recoveryStatus(sessionID: lease.sessionID), "Reserved at the gate")
                coordinator.reportProviderOutcomeNotAccepted(key: key)
                XCTAssertNil(coordinator.recoveryStatus(sessionID: lease.sessionID), "Released with no acceptance evidence")
            }
            return projected
        }
        host.addScheduledSession(sessionID: fixture.sessionID, workspaceID: fixture.workspace.id, record: fixture.record)
        coordinator.register(host)
        clock.advance(to: fixture.record.notBefore)
        try await waitUntil("dispatch finished") { host.dispatches.count == 1 && coordinator.activeAdmission(sessionID: fixture.sessionID) == nil }
        XCTAssertNotNil(handoff.key)
        XCTAssertNil(coordinator.recoveryStatus(sessionID: fixture.sessionID))
        XCTAssertFalse(coordinator.retryRecovery(sessionID: fixture.sessionID))
    }

    // MARK: Recovery helpers

    private struct RecoveryFixture {
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let sessionID: UUID
        let record: AgentScheduledSendPersist
    }

    private func makeRecoveryFixture(
        name: String,
        createdAt: Date,
        notBefore: Date,
        storageThroughSymlink: Bool = false
    ) async throws -> RecoveryFixture {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentScheduledSendCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        var storage = directory
        if storageThroughSymlink {
            let target = directory.appendingPathComponent("storage", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            storage = directory.appendingPathComponent("storage-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: target)
        }
        let workspace = WorkspaceModel(name: name, repoPaths: ["/tmp/repo"], customStoragePath: storage)
        let record = makeRecord(createdAt: createdAt, notBefore: notBefore, isNewSessionStart: false)
        let sessionID = UUID()
        _ = try await service.saveAgentSession(
            AgentSession(id: sessionID, workspaceID: workspace.id, name: name, scheduledSend: .v1(record)),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        return RecoveryFixture(service: service, workspace: workspace, sessionID: sessionID, record: record)
    }

    /// Mirrors the production host's guarded handoff: persist the `.dispatching` attempt, capture
    /// the DataService-issued recovery context, reserve process ownership inside the final gate,
    /// and (when the provider accepts) transfer the immutable payload synchronously.
    private func performAcceptedHandoff(
        lease: AgentScheduledSendAdmissionLease,
        fixture: RecoveryFixture,
        coordinator: AgentScheduledSendCoordinator,
        clock: FakeScheduledSendClock,
        recorder: RecoveryHandoffRecorder,
        reportAcceptance: Bool = true
    ) async -> AgentScheduledSendPersist? {
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: clock.now)
        var dispatching = fixture.record
        dispatching.state = .dispatching
        dispatching.attempt = attempt
        dispatching.updatedAt = clock.now
        do {
            _ = try await fixture.service.mutateScheduledSend(
                sessionID: fixture.sessionID,
                for: fixture.workspace,
                mutation: .upsert(expectedUpdatedAt: fixture.record.updatedAt, value: dispatching)
            )
            let context = try await fixture.service.prepareScheduledSendRecovery(
                sessionID: fixture.sessionID,
                for: fixture.workspace,
                expectedUpdatedAt: dispatching.updatedAt,
                expectedAttempt: attempt
            )
            guard let validator = coordinator.finalHandoffValidator(for: lease) else {
                XCTFail("Final handoff validator unavailable")
                return nil
            }
            guard coordinator.authorizeProviderHandoff(validator, context: context, attempt: attempt) else {
                XCTFail("Provider handoff revoked")
                return nil
            }
            let key = AgentScheduledSendRecoveryKey(sessionID: lease.sessionID, leaseID: lease.id, attemptID: attempt.attemptID)
            recorder.key = key
            XCTAssertEqual(coordinator.recoveryStatus(sessionID: lease.sessionID)?.phase, .awaitingProviderOutcome)
            guard reportAcceptance else { return dispatching }
            let receipt = AgentScheduledSendProvenance(
                scheduleID: lease.scheduleID,
                attemptID: attempt.attemptID,
                scheduledFor: dispatching.notBefore,
                sentAt: clock.now
            )
            var acceptedItem = AgentChatItem.user(dispatching.rawText, id: attempt.itemID)
            acceptedItem.scheduledSend = receipt
            let payload = AgentScheduledSendAcceptedPayload(
                context: context,
                attempt: attempt,
                receipt: receipt,
                acceptedItem: acceptedItem,
                expectedUpdatedAt: dispatching.updatedAt
            )
            recorder.payload = payload
            coordinator.reportAcceptance(key: key, payload: payload)
            XCTAssertEqual(coordinator.recoveryStatus(sessionID: lease.sessionID)?.hasAcceptedPayload, true, "Transfer is synchronous")
            return dispatching
        } catch {
            XCTFail("Handoff preparation failed: \(error)")
            return nil
        }
    }

    private func assertFinalized(
        fixture: RecoveryFixture,
        payload: AgentScheduledSendAcceptedPayload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let loaded = try await fixture.service.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
        let persisted = try XCTUnwrap(loaded, file: file, line: line)
        XCTAssertNil(persisted.scheduledSend, file: file, line: line)
        XCTAssertEqual(persisted.lastScheduledDispatch, payload.receipt, file: file, line: line)
        let items = persisted.toLiveItems().filter { $0.id == payload.attempt.itemID }
        XCTAssertEqual(items.count, 1, "Exactly one durable copy of the accepted item", file: file, line: line)
        XCTAssertEqual(items.first?.scheduledSend, payload.receipt, file: file, line: line)
        XCTAssertEqual(items.first?.text, fixture.record.rawText, file: file, line: line)
    }

    private static func isWaitingToRetry(_ phase: AgentScheduledSendRecoveryPhase?) -> Bool {
        if case .waitingToRetry? = phase { return true }
        return false
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw CoordinatorWaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct CoordinatorWaitTimeout: Error {}

private struct InjectedRecoveryFailure: Error {}

/// Thread-safe failure injector state: the data-service actor invokes the injector off the main actor.
private final class RecoveryFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _failing = true
    private var _callCount = 0

    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func next() -> Error? {
        lock.withLock {
            _callCount += 1
            return _failing ? InjectedRecoveryFailure() : nil
        }
    }
}

@MainActor
private final class DrainProbe {
    var completed = false
}

@MainActor
private final class RecoveryHandoffRecorder {
    var key: AgentScheduledSendRecoveryKey?
    var payload: AgentScheduledSendAcceptedPayload?
}

@MainActor
private final class FakeScheduledSendClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []
    private var nextProbe: SchedulerClockProbe = .none

    init(now: Date) {
        self.now = now
    }

    var clock: SchedulerClock {
        SchedulerClock(
            now: { [weak self] in
                self?.now ?? .distantPast
            },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await sleep(until: deadline)
            },
            probe: { [weak self] in
                guard let self else { return .none }
                let probe = nextProbe
                nextProbe = .none
                return probe
            }
        )
    }

    func advance(
        to date: Date,
        probe: SchedulerClockProbe = .none
    ) {
        setNow(max(now, date), probe: probe)
    }

    /// Moves the wall clock in either direction (a backward move models a system clock rollback).
    func setNow(_ date: Date, probe: SchedulerClockProbe = .none) {
        now = date
        nextProbe = probe
        let ready = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    private func sleep(until deadline: Date) async throws {
        if deadline <= now { return }
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }
}

@MainActor
private final class FakeScheduledSendHost: AgentScheduledSendCoordinatorHost {
    struct Dispatch: Equatable {
        let tabID: UUID
        let scheduleID: UUID
        let lease: AgentScheduledSendAdmissionLease
    }

    struct ProjectionRefresh: Equatable {
        let tabID: UUID
        let sessionID: UUID
    }

    private struct Session {
        let sessionID: UUID
        let tabID: UUID
        let workspaceID: UUID
        var record: AgentScheduledSendPersist?
        var isHydrated: Bool
        var busyState: AgentScheduledSendBusyState
    }

    private struct PendingDispatch {
        let tabID: UUID
        let scheduleID: UUID
        let continuation: CheckedContinuation<ScheduledDispatchOutcome, Never>
    }

    private var sessions: [UUID: Session] = [:]
    private var pendingDispatches: [PendingDispatch] = []
    private var activeDispatchTabIDs: Set<UUID> = []
    private var suppressedCandidateTabIDs: Set<UUID> = []
    private var heldHydrations: [CheckedContinuation<Void, Never>] = []

    var holdDispatches = false
    var suppressCandidatesWhileDispatching = false
    /// Workspaces in which this host reports unresolved lossless-restart recovery.
    var unresolvedRecoveryWorkspaceIDs: Set<UUID> = []
    /// Itemized lossless-restart recovery this host reports per workspace (F2).
    var recoveryBlockers: [UUID: AgentScheduledSendRecoveryBlocker] = [:]
    var automaticOutcome: ScheduledDispatchOutcome = .accepted
    var hydrationSucceeds = true
    /// When set, `ensureHydrated` suspends until `releaseHeldHydrations()`.
    var holdHydration = false
    var onCandidatesRead: (() -> Void)?
    var onDispatchStarted: (() -> Void)?
    /// Runs the guarded provider handoff for a non-held dispatch (persist attempt, reserve
    /// ownership, report acceptance). A returned record replaces this host's projection.
    var onProviderHandoff: ((AgentScheduledSendAdmissionLease) async -> AgentScheduledSendPersist?)?
    /// Called whenever `dispatchScheduledSend` is entered, with the lease. Useful for late
    /// blockers and rollback simulations while a dispatch is held.
    var onDispatchEntered: ((AgentScheduledSendAdmissionLease) -> Void)?

    var heldHydrationCount: Int {
        heldHydrations.count
    }

    func releaseHeldHydrations() {
        let held = heldHydrations
        heldHydrations.removeAll()
        for continuation in held {
            continuation.resume()
        }
    }

    private(set) var dispatches: [Dispatch] = []
    private(set) var projectionRefreshes: [ProjectionRefresh] = []
    private(set) var persistCount = 0
    private(set) var hydrationCount = 0
    private(set) var candidateReadCount = 0
    private(set) var unhydratedMutationAttemptCount = 0

    var pendingDispatchCount: Int {
        pendingDispatches.count
    }

    @discardableResult
    func addScheduledSession(
        sessionID: UUID = UUID(),
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        record: AgentScheduledSendPersist,
        isHydrated: Bool = true,
        busyState: AgentScheduledSendBusyState = AgentScheduledSendBusyState()
    ) -> UUID {
        addSession(
            sessionID: sessionID,
            tabID: tabID,
            workspaceID: workspaceID,
            record: record,
            isHydrated: isHydrated,
            busyState: busyState
        )
    }

    @discardableResult
    func addSession(
        sessionID: UUID = UUID(),
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        record: AgentScheduledSendPersist?,
        isHydrated: Bool = true,
        busyState: AgentScheduledSendBusyState
    ) -> UUID {
        sessions[tabID] = Session(
            sessionID: sessionID,
            tabID: tabID,
            workspaceID: workspaceID,
            record: record,
            isHydrated: isHydrated,
            busyState: busyState
        )
        return tabID
    }

    func scheduledSendCandidates() -> [AgentScheduledSendCandidate] {
        candidateReadCount += 1
        let result = sessions.values.compactMap { session -> AgentScheduledSendCandidate? in
            guard !suppressedCandidateTabIDs.contains(session.tabID),
                  !(suppressCandidatesWhileDispatching && activeDispatchTabIDs.contains(session.tabID)),
                  let record = session.record
            else {
                return nil
            }
            return AgentScheduledSendCandidate(
                sessionID: session.sessionID,
                tabID: session.tabID,
                workspaceID: session.workspaceID,
                scheduledSend: record,
                isHydrated: session.isHydrated
            )
        }
        if let callback = onCandidatesRead {
            onCandidatesRead = nil
            callback()
        }
        return result
    }

    func scheduledSendBusyState(tabID: UUID) -> AgentScheduledSendBusyState {
        sessions[tabID]?.busyState ?? AgentScheduledSendBusyState()
    }

    func hasBusySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        sessions.values.contains {
            $0.workspaceID == workspaceID
                && $0.sessionID != sessionID
                && $0.busyState.isBusy
        }
    }

    func scheduledSendRecoveryBlocker(
        inWorkspace workspaceID: UUID,
        excluding _: UUID
    ) -> AgentScheduledSendRecoveryBlocker? {
        if let blocker = recoveryBlockers[workspaceID] { return blocker }
        return unresolvedRecoveryWorkspaceIDs.contains(workspaceID)
            ? AgentScheduledSendRecoveryBlocker(unattributed: true)
            : nil
    }

    func scheduledSendBusyStateExcludingDispatchReservation(
        tabID: UUID
    ) -> AgentScheduledSendBusyState {
        var busyState = scheduledSendBusyState(tabID: tabID)
        busyState.hasStartOrDispatchReservation = false
        return busyState
    }

    func hasBusySessionForScheduledSendHandoff(
        inWorkspace workspaceID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        sessions.values.contains { session in
            guard session.workspaceID == workspaceID else { return false }
            var busyState = session.busyState
            if session.tabID == tabID {
                busyState.hasStartOrDispatchReservation = false
            }
            return busyState.isBusy
        }
    }

    func scheduledSendProjectionNeedsRefresh(tabID: UUID, sessionID: UUID) {
        projectionRefreshes.append(
            ProjectionRefresh(tabID: tabID, sessionID: sessionID)
        )
    }

    func ownsScheduledSendDestination(tabID: UUID, sessionID: UUID) -> Bool {
        sessions[tabID]?.sessionID == sessionID
    }

    func scheduledSendDestinationIsBusy(
        sessionID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        sessions.values.contains { session in
            guard session.sessionID == sessionID else { return false }
            var busyState = session.busyState
            if session.tabID == tabID {
                busyState.hasStartOrDispatchReservation = false
            }
            return busyState.isBusy
        }
    }

    func ensureHydrated(tabID: UUID) async -> Bool {
        hydrationCount += 1
        if holdHydration {
            await withCheckedContinuation { continuation in
                heldHydrations.append(continuation)
            }
        }
        guard hydrationSucceeds, var session = sessions[tabID] else { return false }
        session.isHydrated = true
        sessions[tabID] = session
        return true
    }

    /// Coordinator-issued mutation requests received, in order.
    private(set) var mutationRequests: [AgentScheduledSendHostMutationRequest] = []
    /// Injected outcomes for upcoming mutation attempts (consumed in order); `nil` = commit.
    var mutationOutcomeQueue: [AgentScheduledSendHostMutationOutcome?] = []
    /// When set, mutations suspend until `releaseHeldMutation(with:)`.
    var holdMutations = false
    private var heldMutations: [(request: AgentScheduledSendHostMutationRequest, continuation: CheckedContinuation<AgentScheduledSendHostMutationOutcome?, Never>)] = []

    var heldMutationCount: Int {
        heldMutations.count
    }

    /// Releases the oldest held mutation. `nil` commits the requested replacement.
    func releaseHeldMutation(with outcome: AgentScheduledSendHostMutationOutcome?) {
        guard !heldMutations.isEmpty else { return }
        let held = heldMutations.removeFirst()
        held.continuation.resume(returning: outcome)
    }

    func persistScheduledSendMutation(
        tabID: UUID,
        request: AgentScheduledSendHostMutationRequest
    ) async -> AgentScheduledSendHostMutationOutcome {
        guard var session = sessions[tabID], session.sessionID == request.sessionID else { return .unavailable }
        guard session.isHydrated else {
            unhydratedMutationAttemptCount += 1
            return .unavailable
        }
        guard let record = session.record, record.id == request.scheduleID else { return .conflict }
        guard record == request.expected else { return .conflict }
        mutationRequests.append(request)
        persistCount += 1
        let injected: AgentScheduledSendHostMutationOutcome? = if holdMutations {
            await withCheckedContinuation { continuation in
                heldMutations.append((request, continuation))
            }
        } else if !mutationOutcomeQueue.isEmpty {
            mutationOutcomeQueue.removeFirst()
        } else {
            nil
        }
        if let injected {
            return injected
        }
        // Durable commit: adopt the exact replacement into this host's projection.
        guard var current = sessions[tabID], current.record == request.expected else { return .conflict }
        current.record = request.replacement
        sessions[tabID] = current
        _ = session
        return .committed(committedUpdatedAt: request.replacement.updatedAt)
    }

    func dispatchScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        dispatches.append(Dispatch(tabID: tabID, scheduleID: scheduleID, lease: lease))
        activeDispatchTabIDs.insert(tabID)
        onDispatchStarted?()
        onDispatchEntered?(lease)
        defer {
            activeDispatchTabIDs.remove(tabID)
        }
        let outcome: ScheduledDispatchOutcome = if holdDispatches {
            await withCheckedContinuation { continuation in
                pendingDispatches.append(
                    PendingDispatch(
                        tabID: tabID,
                        scheduleID: scheduleID,
                        continuation: continuation
                    )
                )
            }
        } else {
            automaticOutcome
        }
        var projectedRecord: AgentScheduledSendPersist?
        if !holdDispatches, let onProviderHandoff {
            projectedRecord = await onProviderHandoff(lease)
        }
        apply(outcome, tabID: tabID, scheduleID: scheduleID, lease: lease, projectedRecord: projectedRecord)
        return outcome
    }

    func completeNextDispatch(with outcome: ScheduledDispatchOutcome) {
        guard !pendingDispatches.isEmpty else { return }
        let pending = pendingDispatches.removeFirst()
        pending.continuation.resume(returning: outcome)
    }

    func setBusyState(_ busyState: AgentScheduledSendBusyState, tabID: UUID) {
        guard var session = sessions[tabID] else { return }
        session.busyState = busyState
        sessions[tabID] = session
    }

    func setCandidateSuppressed(_ isSuppressed: Bool, tabID: UUID) {
        if isSuppressed {
            suppressedCandidateTabIDs.insert(tabID)
        } else {
            suppressedCandidateTabIDs.remove(tabID)
        }
    }

    func sessionID(tabID: UUID) -> UUID? {
        sessions[tabID]?.sessionID
    }

    var busyTabIDs: [UUID] {
        sessions.values.filter(\.busyState.isBusy).map(\.tabID)
    }

    func record(scheduleID: UUID) -> AgentScheduledSendPersist? {
        sessions.values.compactMap(\.record).first { $0.id == scheduleID }
    }

    func updateRecord(
        scheduleID: UUID,
        mutation: (inout AgentScheduledSendPersist) -> Void
    ) {
        guard let tabID = sessions.values.first(where: { $0.record?.id == scheduleID })?.tabID,
              var session = sessions[tabID],
              var record = session.record
        else {
            return
        }
        mutation(&record)
        session.record = record
        sessions[tabID] = session
    }

    private func apply(
        _ outcome: ScheduledDispatchOutcome,
        tabID: UUID,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease,
        projectedRecord: AgentScheduledSendPersist? = nil
    ) {
        guard var session = sessions[tabID],
              var record = session.record,
              record.id == scheduleID
        else {
            return
        }
        if let projectedRecord, projectedRecord.id == scheduleID {
            record = projectedRecord
        }

        switch outcome {
        case .accepted:
            session.record = nil
        case .deferredBusy:
            break
        case .failedBeforeHandoff:
            record.state = .failed
            session.record = record
        case .unknownAfterHandoff, .heldForRecovery:
            // A held transfer keeps the attempt projected as-is (`.dispatching`), like the real host.
            record.state = .dispatching
            if projectedRecord == nil {
                record.updatedAt = lease.admittedUpdatedAt.addingTimeInterval(0.001)
            }
            if record.attempt == nil {
                record.attempt = AgentScheduledSendPersist.Attempt(
                    attemptID: UUID(),
                    itemID: UUID(),
                    startedAt: lease.effectiveDueAt
                )
            }
            session.record = record
        }
        sessions[tabID] = session
    }
}

private final class DashboardChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
