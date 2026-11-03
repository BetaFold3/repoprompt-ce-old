@testable import RepoPromptAgentCore
import XCTest

/// Queue identity and the shared dispatch-evidence contract (lossless restart Phase 1b, inactive
/// in production): untracked input exists only under inactive admission, durable identities come
/// from store-issued receipts, coalesced handoffs dispatch every constituent atomically, delivery
/// evidence is ordered and never downgraded, and run terminal evidence needs no MCP envelope.
@MainActor
final class AgentRecoveryQueuedInputTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private var fixture: RecoveryLaneFixture!

    override func setUp() async throws {
        fixture = try await RecoveryLaneFixture.make("AgentRecoveryQueuedInputTests")
    }

    override func tearDown() async throws {
        fixture?.tearDown()
        fixture = nil
    }

    private func dispatchState(_ identity: AgentQueuedInputIdentity) async -> AgentRecoveryDeliveryState? {
        await fixture.intent(identity)?.deliveryState
    }

    private func attempts(for identity: AgentQueuedInputIdentity) async -> [AgentRecoveryAttempt] {
        let record = await fixture.store.read(sessionID: fixture.sessionID).record
        return record?.attempts.filter { $0.intentID == identity.intentID } ?? []
    }

    // MARK: Identity

    func testUntrackedIdentityExistsOnlyWhileAdmissionIsInactive() async throws {
        let session = AgentTabSession(tabID: UUID())
        let userItemID = UUID()
        let untracked = try XCTUnwrap(AgentQueuedInputIdentity.untracked(userItemID: userItemID, in: session))
        XCTAssertEqual(untracked.userItemID, userItemID)
        XCTAssertNil(untracked.intentID)
        XCTAssertFalse(untracked.isDurable)

        session.recoveryAdmissionMode = .mandatory
        XCTAssertNil(
            AgentQueuedInputIdentity.untracked(userItemID: userItemID, in: session),
            "Mandatory admission never builds untracked queue input"
        )
        let pending = AgentPendingInstruction(text: "legacy", identity: untracked)
        let refused = await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: pending.constituents,
            runAttemptID: nil
        )
        guard case .failure(.refused(.untrackedInput)) = refused else {
            return XCTFail("untracked input under mandatory admission must be refused, got \(refused)")
        }

        session.recoveryAdmissionMode = .inactive
        let legacy = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: pending.constituents,
            runAttemptID: nil
        ).get()
        XCTAssertFalse(legacy.isDurable)
        XCTAssertTrue(legacy.receipts.isEmpty)
        legacy.noteAccepted()
        let failures = await legacy.settled()
        XCTAssertTrue(failures.isEmpty, "An untracked handoff writes no evidence")
        XCTAssertNil(AgentPendingInstruction(coalescedText: "none", constituents: []))
    }

    func testDurableIdentityCarriesTheStoreIssuedIntentAndUserItem() async throws {
        let userItemID = UUID()
        let identity = try await fixture.queuedIdentity("durable", userItemID: userItemID)
        let receipt = try XCTUnwrap(identity.queueReceipt)
        XCTAssertTrue(identity.isDurable)
        XCTAssertEqual(identity.userItemID, userItemID)
        XCTAssertEqual(identity.intentID, receipt.intent.intentID)
        let state = await dispatchState(identity)
        XCTAssertEqual(state, .queued)

        // A durable entry reaching the legacy dispatch alongside untracked input is refused.
        let session = fixture.boundTabSession()
        let untracked = AgentQueuedInputIdentity.inactiveForTesting(in: session)
        let mixed = await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [identity, untracked],
            runAttemptID: nil
        )
        guard case .failure(.refused(.untrackedInput)) = mixed else {
            return XCTFail("mixed durable and untracked constituents must be refused, got \(mixed)")
        }
        let unchanged = await dispatchState(identity)
        XCTAssertEqual(unchanged, .queued)
    }

    // MARK: Run-start provider

    /// P1-1: run start records the session's provider (when the run attempt is first written) as the
    /// run attempt's `providerKind` extras member; it survives the store codec unchanged, and a later
    /// write for the same run (here after a provider switch) never rewrites it.
    func testRunStartRecordsTheSessionsProviderOnTheRunAttempt() async throws {
        let session = fixture.boundTabSession()
        session.selectedAgent = .codexExec
        let identity = try await fixture.queuedIdentity("first input")
        let ownership = session.beginRunAttempt(source: "test.run-start.provider")

        _ = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: UUID()
        ).get()

        func runAttempt() async throws -> AgentRecoveryRunAttempt {
            let record = await fixture.store.read(sessionID: fixture.sessionID).record
            return try XCTUnwrap(record?.runAttempts.first { $0.runAttemptID == ownership.attemptID })
        }
        let recorded = try await runAttempt()
        XCTAssertEqual(recorded.recordedProviderKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(recorded.extras, [AgentRecoveryRunAttempt.providerKindExtrasKey: .string(AgentProviderKind.codexExec.rawValue)])

        // Store codec: the member is kept verbatim as extras and re-encodes to the same bytes.
        let stored = await fixture.store.read(sessionID: fixture.sessionID).record
        let record = try XCTUnwrap(stored)
        let data = try AgentRecoveryRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRecoveryRecordCodec.decode(data, expectedSessionID: record.sessionID) else {
            return XCTFail("the record must decode")
        }
        XCTAssertEqual(decoded.runAttempts, record.runAttempts)
        XCTAssertEqual(try AgentRecoveryRecordCodec.encode(decoded), data)

        // A later write for the same run never rewrites its run-start provider.
        session.selectedAgent = .claudeCode
        _ = try await fixture.lane.ensureRunAttempt(
            ownership: ownership,
            processRunID: nil,
            transcriptTurnID: nil,
            processRunAssociation: .keepExisting,
            providerKindRaw: session.selectedAgent.rawValue
        ).get()
        let kept = try await runAttempt()
        XCTAssertEqual(kept.recordedProviderKindRaw, AgentProviderKind.codexExec.rawValue)
    }

    // MARK: Coalesced dispatch

    func testCoalescedDispatchCommitsEveryConstituentInOneOrderedReplacement() async throws {
        let first = try await fixture.queuedIdentity("first")
        let second = try await fixture.queuedIdentity("second")
        let session = fixture.boundTabSession()
        let coalesced = try XCTUnwrap(AgentPendingInstruction(coalescedText: "first\nsecond", constituents: [first, second]))
        XCTAssertTrue(coalesced.isDurable)
        let revisionBefore = await fixture.store.read(sessionID: fixture.sessionID).record?.revision

        let runAttemptID = UUID()
        let evidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: coalesced.constituents,
            runAttemptID: runAttemptID
        ).get()

        XCTAssertEqual(evidence.receipts.map(\.intent.intentID), [first.intentID, second.intentID].compactMap(\.self))
        XCTAssertEqual(Set(evidence.receipts.map(\.intent.recordRevision)).count, 1, "One replacement for the whole handoff")
        XCTAssertNotEqual(evidence.receipts.first?.intent.recordRevision, revisionBefore)
        for identity in [first, second] {
            let state = await dispatchState(identity)
            XCTAssertEqual(state, .dispatching)
            let identityAttempts = await attempts(for: identity)
            XCTAssertEqual(identityAttempts.count, 1)
            XCTAssertEqual(identityAttempts.first?.runAttemptID, runAttemptID)
            XCTAssertEqual(identityAttempts.first?.userItemID, identity.userItemID)
        }
    }

    func testCoalescedDispatchWritesNothingWhenAnyConstituentIsIneligible() async throws {
        let eligible = try await fixture.queuedIdentity("eligible")
        let alreadyDispatching = try await fixture.queuedIdentity("already dispatching")
        let session = fixture.boundTabSession()
        _ = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [alreadyDispatching],
            runAttemptID: nil
        ).get()
        let revisionBefore = await fixture.store.read(sessionID: fixture.sessionID).record?.revision

        let refused = await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [eligible, alreadyDispatching],
            runAttemptID: nil
        )

        guard case .failure(.commitFailed) = refused else {
            return XCTFail("an ineligible constituent must fail the whole batch, got \(refused)")
        }
        let revisionAfter = await fixture.store.read(sessionID: fixture.sessionID).record?.revision
        XCTAssertEqual(revisionAfter, revisionBefore, "Nothing is written for a partially eligible batch")
        let eligibleState = await dispatchState(eligible)
        XCTAssertEqual(eligibleState, .queued)
        let eligibleAttempts = await attempts(for: eligible)
        XCTAssertTrue(eligibleAttempts.isEmpty)
    }

    func testRetiredLaneRefusesDispatchWithoutWriting() async throws {
        let identity = try await fixture.queuedIdentity("before replacement")
        let session = fixture.boundTabSession()
        let revisionBefore = await fixture.store.read(sessionID: fixture.sessionID).record?.revision
        _ = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.lane.persistenceState)
        XCTAssertTrue(fixture.lane.isRetired)

        let refused = await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [identity],
            runAttemptID: nil
        )

        guard case .failure(.refused(.laneRetired)) = refused else {
            return XCTFail("a retired lane must refuse dispatch, got \(refused)")
        }
        let revisionAfter = await fixture.store.read(sessionID: fixture.sessionID).record?.revision
        XCTAssertEqual(revisionAfter, revisionBefore)
    }

    private final class Owner {}

    // MARK: Delivery evidence

    func testAcceptanceIsNeverDowngradedAndNoHandoffSettlesTheSameIntent() async throws {
        let accepted = try await fixture.queuedIdentity("accepted")
        let notHandedOff = try await fixture.queuedIdentity("not handed off")
        let session = fixture.boundTabSession()

        let acceptedEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [accepted],
            runAttemptID: nil
        ).get()
        acceptedEvidence.noteAccepted()
        acceptedEvidence.noteDeliveryUnknown()
        acceptedEvidence.noteNoHandoff()
        XCTAssertEqual(acceptedEvidence.observation, .accepted)
        let acceptedFailures = await acceptedEvidence.settled()
        XCTAssertTrue(acceptedFailures.isEmpty)
        let acceptedState = await dispatchState(accepted)
        XCTAssertEqual(acceptedState, .providerAccepted)
        let acceptedAttempts = await attempts(for: accepted)
        XCTAssertEqual(acceptedAttempts.map(\.outcome?.outcome), [.providerAccepted])

        // Unknown first, then late acceptance: acceptance refines the uncertainty.
        let refined = try await fixture.queuedIdentity("refined")
        let refinedEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [refined],
            runAttemptID: nil
        ).get()
        refinedEvidence.noteDeliveryUnknown()
        refinedEvidence.noteAccepted()
        let refinedFailures = await refinedEvidence.settled()
        XCTAssertTrue(refinedFailures.isEmpty)
        let refinedState = await dispatchState(refined)
        XCTAssertEqual(refinedState, .providerAccepted)

        // A failed post-await freshness check reports no handoff: the same intent is queued again.
        let noHandoffEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [notHandedOff],
            runAttemptID: nil
        ).get()
        noHandoffEvidence.noteNoHandoff(message: "run changed during admission")
        XCTAssertEqual(noHandoffEvidence.observation, .notHandedOff)
        let settleFailures = await noHandoffEvidence.settled()
        XCTAssertTrue(settleFailures.isEmpty)
        let settledState = await dispatchState(notHandedOff)
        XCTAssertEqual(settledState, .queued)
        let intentID = try XCTUnwrap(notHandedOff.intentID)
        let reissued = try await fixture.lane.issueQueueReceipt(intentID: intentID).get()
        XCTAssertEqual(reissued.intent.intentID, notHandedOff.intentID)
        XCTAssertEqual(reissued.intent.userItemID, notHandedOff.userItemID)
    }

    // MARK: Run terminal evidence

    func testTerminalEvidenceIsRecordedWithoutAnMCPEnvelopeAndRepeatsAreUnchanged() async throws {
        let ownership = Support.ownership(sessionID: fixture.sessionID)
        let commit = Support.terminalCommit(ownership: ownership)
        XCTAssertNil(commit.mcpPublicationEnvelope)

        await fixture.lane.recordTerminalEvidence(commit, transcriptTurnID: nil).value
        await fixture.lane.recordTerminalEvidence(commit, transcriptTurnID: nil).value

        XCTAssertTrue(fixture.lane.terminalEvidenceFailures.isEmpty)
        let record = await fixture.store.read(sessionID: fixture.sessionID).record
        let run = try XCTUnwrap(record?.runAttempts.first { $0.runAttemptID == ownership.attemptID })
        XCTAssertEqual(run.terminal?.commitID, commit.commitID)
        XCTAssertEqual(run.terminal?.terminalState, .completed)

        // A conflicting commit for the same run attempt stays visible as a failure.
        await fixture.lane.recordTerminalEvidence(Support.terminalCommit(ownership: ownership), transcriptTurnID: nil).value
        XCTAssertNotNil(fixture.lane.terminalEvidenceFailures[ownership.attemptID])
    }

    /// R4-04: a terminal-evidence storage failure keeps its operation, and the finalization retry
    /// re-records it (storage only) once storage recovers; a later success clears the failure.
    func testFailedTerminalEvidenceIsRetainedAndRetriedStorageOnly() async throws {
        fixture.tearDown()
        let failures = RecoveryStoreWriteFailureSwitch()
        fixture = try await RecoveryLaneFixture.make(
            "AgentRecoveryQueuedInputTests-retry",
            fileOperations: failures.fileOperations()
        )
        let ownership = Support.ownership(sessionID: fixture.sessionID)
        let commit = Support.terminalCommit(ownership: ownership, state: .cancelled)

        failures.shouldFailWrites = true
        await fixture.lane.recordTerminalEvidence(commit, transcriptTurnID: nil).value
        XCTAssertNotNil(fixture.lane.terminalEvidenceFailures[ownership.attemptID])

        // Still failing: the retry keeps the failure visible.
        await fixture.lane.retryFailedTerminalEvidence()
        XCTAssertNotNil(fixture.lane.terminalEvidenceFailures[ownership.attemptID])
        let missing = await fixture.store.read(sessionID: fixture.sessionID).record
        XCTAssertNil(missing?.runAttempt(id: ownership.attemptID)?.terminal)

        failures.shouldFailWrites = false
        await fixture.lane.retryFailedTerminalEvidence()
        XCTAssertTrue(fixture.lane.terminalEvidenceFailures.isEmpty)
        let record = await fixture.store.read(sessionID: fixture.sessionID).record
        let run = try XCTUnwrap(record?.runAttempt(id: ownership.attemptID))
        XCTAssertEqual(run.terminal?.commitID, commit.commitID)
        XCTAssertEqual(run.terminal?.terminalState, .cancelled)

        // Nothing is left to retry.
        await fixture.lane.retryFailedTerminalEvidence()
        XCTAssertTrue(fixture.lane.terminalEvidenceFailures.isEmpty)
    }

    /// R08: a run's first recorded turn is kept (later steering never replaces it), and terminal
    /// evidence completes only missing join keys, never failing on a recorded one.
    func testTerminalEvidenceCompletesMissingRunJoinKeysAndKeepsRecordedOnes() async throws {
        let keyed = Support.ownership(sessionID: fixture.sessionID)
        let openingTurnID = UUID()
        let processRunID = UUID()
        _ = try await fixture.lane.ensureRunAttempt(ownership: keyed, processRunID: processRunID, transcriptTurnID: openingTurnID, providerKindRaw: nil).get()
        let steering = try await fixture.lane.ensureRunAttempt(ownership: keyed, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        XCTAssertEqual(steering.disposition, .unchanged, "A later turn never replaces the run's opening turn")
        await fixture.lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: keyed, state: .completed, expectedRunID: UUID()),
            transcriptTurnID: UUID()
        ).value
        XCTAssertNil(fixture.lane.terminalEvidenceFailures[keyed.attemptID], "A key mismatch never loses terminal evidence")

        let unkeyed = Support.ownership(sessionID: fixture.sessionID)
        let terminalTurnID = UUID()
        let terminalRunID = UUID()
        await fixture.lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: unkeyed, state: .cancelled, expectedRunID: terminalRunID),
            transcriptTurnID: terminalTurnID
        ).value
        XCTAssertNil(fixture.lane.terminalEvidenceFailures[unkeyed.attemptID])

        let read = await fixture.store.read(sessionID: fixture.sessionID)
        let record = try XCTUnwrap(read.record)
        let keyedRun = try XCTUnwrap(record.runAttempt(id: keyed.attemptID))
        XCTAssertEqual(keyedRun.transcriptTurnID, openingTurnID)
        XCTAssertEqual(keyedRun.processRunID, processRunID)
        XCTAssertEqual(keyedRun.terminal?.terminalState, .completed)
        let completedRun = try XCTUnwrap(record.runAttempt(id: unkeyed.attemptID))
        XCTAssertEqual(completedRun.transcriptTurnID, terminalTurnID, "Terminal evidence supplies the missing turn")
        XCTAssertEqual(completedRun.processRunID, terminalRunID, "and the missing process run")
        XCTAssertEqual(completedRun.terminal?.terminalState, .cancelled)

        // The store keeps the strict process-run check for start-time evidence.
        let conflict = await fixture.lane.ensureRunAttempt(ownership: keyed, processRunID: UUID(), transcriptTurnID: nil, providerKindRaw: nil)
        guard case .failure(.store(.runAttemptConflict(keyed.attemptID))) = conflict else {
            return XCTFail("A conflicting start-time process run must fail, got \(conflict)")
        }
    }

    // MARK: Uncertain input after its run ended (this launch)

    private func adopted(_ identity: AgentQueuedInputIdentity, _ state: AgentRecoveryDeliveryState) async -> Bool {
        await Support.eventually { [fixture] in
            guard let fixture, case let .supported(record)? = fixture.coordinator.liveRecordState(for: fixture.sessionID),
                  let intentID = identity.intentID
            else { return false }
            return record.intent(id: intentID)?.deliveryState == state
        }
    }

    private func heldReasons() -> [UUID: String] {
        fixture.coordinator.heldIntents(for: fixture.lane.binding)
    }

    func testUncertainInputIsHeldVisibleOnceItsLiveProjectionEndsWithoutARestart() async throws {
        let ownership = Support.ownership(sessionID: fixture.sessionID)
        let session = fixture.boundTabSession()
        let unknown = try await fixture.queuedIdentity("possibly delivered")
        let inFlight = try await fixture.queuedIdentity("handed off when the run stopped")
        let unknownEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [unknown],
            runAttemptID: ownership.attemptID
        ).get()
        unknownEvidence.noteDeliveryUnknown()
        let unknownFailures = await unknownEvidence.settled()
        XCTAssertTrue(unknownFailures.isEmpty)
        let inFlightEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [inFlight],
            runAttemptID: ownership.attemptID
        ).get()
        let unknownAdopted = await adopted(unknown, .deliveryUnknown)
        let inFlightAdopted = await adopted(inFlight, .dispatching)
        XCTAssertTrue(unknownAdopted && inFlightAdopted)
        XCTAssertTrue(heldReasons().isEmpty, "While its run is open, the live run projects the input (no duplicate row)")

        await fixture.lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .cancelled),
            transcriptTurnID: nil
        ).value
        let unknownID = try XCTUnwrap(unknown.intentID)
        let inFlightID = try XCTUnwrap(inFlight.intentID)
        let heldAfterStop = await Support.eventually { [self] in heldReasons().count == 2 }
        XCTAssertTrue(heldAfterStop, "Stopping the run must surface its uncertain input immediately")
        XCTAssertEqual(heldReasons()[unknownID], AgentRecoveryCoordinator.runEndedUnconfirmedHoldReason)
        XCTAssertEqual(heldReasons()[inFlightID], AgentRecoveryCoordinator.runEndedUnconfirmedHoldReason)
        XCTAssertEqual(fixture.coordinator.heldIntentSessions[fixture.sessionID]?.workspaceID, fixture.lane.persistenceState.stamp.workspaceID)

        // Unlinked handoffs: settled unknown is surfaced; an in-progress one is still owned by it.
        let unlinkedUnknown = try await fixture.queuedIdentity("unlinked unknown")
        let unlinkedInFlight = try await fixture.queuedIdentity("unlinked in flight")
        let unlinkedEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [unlinkedUnknown],
            runAttemptID: nil
        ).get()
        unlinkedEvidence.noteDeliveryUnknown()
        _ = await unlinkedEvidence.settled()
        _ = try await AgentRecoveryDispatchEvidence.begin(session: session, constituents: [unlinkedInFlight], runAttemptID: nil).get()
        let unlinkedUnknownID = try XCTUnwrap(unlinkedUnknown.intentID)
        let unlinkedHeld = await Support.eventually { [self] in heldReasons()[unlinkedUnknownID] != nil }
        XCTAssertTrue(unlinkedHeld)
        XCTAssertEqual(heldReasons()[unlinkedUnknownID], AgentRecoveryCoordinator.unlinkedUnconfirmedHoldReason)
        let unlinkedInFlightAdopted = await adopted(unlinkedInFlight, .dispatching)
        XCTAssertTrue(unlinkedInFlightAdopted)
        let unlinkedInFlightID = try XCTUnwrap(unlinkedInFlight.intentID)
        XCTAssertNil(heldReasons()[unlinkedInFlightID])

        // Input settled back to the live queue is owned by it again; removal needs no decision.
        let inFlightAttemptID = try XCTUnwrap(inFlightEvidence.receipts.first?.attemptID)
        _ = try await fixture.lane.settleToQueue(
            intentID: inFlightID,
            attemptID: inFlightAttemptID,
            evidence: .preHandoff,
            message: nil
        ).get()
        _ = try await fixture.lane.withdraw(intentID: unknownID).get()
        let pruned = await Support.eventually { [self] in
            heldReasons()[inFlightID] == nil && heldReasons()[unknownID] == nil
        }
        XCTAssertTrue(pruned)
        XCTAssertEqual(heldReasons().keys.sorted { $0.uuidString < $1.uuidString }, [unlinkedUnknownID])
    }
}
