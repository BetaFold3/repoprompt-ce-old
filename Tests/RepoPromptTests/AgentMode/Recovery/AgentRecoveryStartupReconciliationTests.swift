@testable import RepoPromptAgentCore
import XCTest

/// Lossless-restart Phase 1b startup reconciliation fixtures: closed sessions are unioned from
/// session files and recovery records, cold restore stamps open turns before normalization, R9
/// receipt transfer is repaired (or held) under the DataService gate before readiness, and crash
/// holds come only from the authoritative per-session results. Each "launch" is a fresh store
/// instance and DataService over the same temporary roots, as after an app restart.
@MainActor
final class AgentRecoveryStartupReconciliationTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    /// One app launch: its own store instance (app instance ID) and DataService.
    private struct Launch {
        let store: AgentRecoveryStore
        let service: AgentSessionDataService
    }

    private var root: URL!
    private var recoveryRoot: URL!
    /// Session folder of each fixture workspace, by workspace ID.
    private var sessionFolders: [UUID: URL] = [:]

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryStartupReconciliationTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Closed-session union and scoped restrictions

    func testStartupSweepUnionsClosedSessionsAndScopesEachRestriction() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let other = try makeWorkspace("other")
        let unrelated = try makeWorkspace("unrelated")
        let unreadable = AgentRecoveryWorkspaceDestination(
            id: UUID(),
            name: "unreachable",
            customStoragePath: root.appendingPathComponent("missing-volume", isDirectory: true)
        )

        // A closed session with input the earlier launch saved but never sent.
        let queued = try await makeSession(earlier, in: home)
        try await commitQueued(earlier, queued, Support.submission("held input"))
        // A durable stub: an empty session whose only content is its recovery record.
        let stub = try await makeSession(earlier, in: home, items: [])
        try await commitQueued(earlier, stub, Support.submission("stub input"))
        // An unowned `.dispatching` schedule that nothing links to.
        let scheduled = try await makeSession(earlier, in: home)
        let schedule = dispatchingSchedule()
        try rewriteSessionFile(scheduled) { $0.scheduledSend = .v1(schedule) }
        // The same session UUID stored in two workspaces.
        let duplicated = try await makeSession(earlier, in: home)
        try copySessionFile(duplicated, into: other)
        // A deleted session whose recovery cleanup left residue behind its tombstone.
        let deleted = try await makeSession(earlier, in: home)
        try await commitQueued(earlier, deleted, Support.submission("deleted input"))
        let recordURL = earlier.store.recordFileURL(sessionID: deleted.session.id)
        let residue = try Data(contentsOf: recordURL)
        let deletion = try await earlier.service.deleteAgentSession(ifCurrent: candidate(deleted), for: home)
        XCTAssertEqual(deletion, .deleted)
        try residue.write(to: recordURL, options: .atomic)
        // A recovery record whose session file no readable workspace holds.
        let orphan = try await makeSession(earlier, in: home)
        try await commitQueued(earlier, orphan, Support.submission("orphan input"))
        try FileManager.default.removeItem(at: sessionFileURL(orphan))
        // An idle session in an unrelated workspace.
        let idle = try await makeSession(earlier, in: unrelated)

        let now = launch()
        let results = try await sweep(now, [home, other, unrelated, unreadable])
        let restrictions = AgentRecoveryRestrictions.from(results)

        let queuedResolution = try XCTUnwrap(results.resolution(for: queued.session.id))
        XCTAssertEqual(queuedResolution.classification, .actionable)
        XCTAssertEqual(queuedResolution.workspaceID, home.id)
        XCTAssertEqual(queuedResolution.composeTabID, queued.session.composeTabID)
        XCTAssertEqual(queuedResolution.record?.record.intents.map(\.payload.text), ["held input"])
        XCTAssertEqual(queuedResolution.record?.record.intents.map(\.deliveryState), [.queued])
        XCTAssertTrue(queuedResolution.hasRecoveryItems)
        XCTAssertNil(restrictions.sessionRestriction(queued.session.id), "Held input is listed, not a restriction")

        let stubResolution = try XCTUnwrap(results.resolution(for: stub.session.id), "A durable stub is inventoried")
        XCTAssertEqual(stubResolution.classification, .actionable)
        XCTAssertEqual(stubResolution.record?.record.intents.map(\.payload.text), ["stub input"])

        // Normalized to the delivery-unknown confirmation the scheduler owns: nothing for recovery.
        XCTAssertNil(results.resolution(for: scheduled.session.id))
        let normalized = try XCTUnwrap(readSessionFile(scheduled).scheduledSend?.persistedValue)
        XCTAssertEqual(normalized.state, .needsConfirmation)
        XCTAssertEqual(normalized.confirmationReason, .deliveryUnknown)
        XCTAssertEqual(normalized.id, schedule.id)
        XCTAssertNil(restrictions.sessionRestriction(scheduled.session.id))

        let duplicateResolution = try XCTUnwrap(results.resolution(for: duplicated.session.id))
        XCTAssertEqual(duplicateResolution.classification, .duplicateDestination(workspaceIDs: [home.id, other.id]))
        XCTAssertNil(duplicateResolution.binding, "No destination is chosen")
        XCTAssertNotNil(restrictions.sessionRestriction(duplicated.session.id))

        let discoveredIDs = try await now.store.discoverRecords().compactMap { entry -> UUID? in
            if case let .supported(discovered) = entry { return discovered.record.sessionID }
            return nil
        }
        if discoveredIDs.contains(deleted.session.id) {
            XCTAssertEqual(results.resolution(for: deleted.session.id)?.classification, .tombstoned)
        } else {
            XCTAssertNil(results.resolution(for: deleted.session.id))
        }
        XCTAssertNil(restrictions.sessionRestriction(deleted.session.id), "Deletion residue never restricts")
        XCTAssertEqual(try Data(contentsOf: recordURL), residue, "Residue is left unchanged")

        XCTAssertEqual(results.resolution(for: orphan.session.id)?.classification, .noDestination)
        XCTAssertNotNil(restrictions.sessionRestriction(orphan.session.id))

        XCTAssertNil(results.resolution(for: idle.session.id), "Idle sessions need no recovery")
        XCTAssertEqual(results.workspaceFailures.map(\.workspaceID), [unreadable.id])
        XCTAssertNotNil(restrictions.workspaceRestriction(unreadable.id))
        XCTAssertTrue(restrictions.blocks(sessionID: UUID(), workspaceID: unreadable.id))
        XCTAssertFalse(restrictions.blocks(sessionID: idle.session.id, workspaceID: unrelated.id), "An unrelated workspace stays eligible")
        XCTAssertFalse(restrictions.hasUnresolvedSession(inWorkspace: unrelated.id, excluding: UUID()))
        XCTAssertTrue(restrictions.hasUnresolvedSession(inWorkspace: unreadable.id, excluding: UUID()), "A workspace restriction blocks its workspace")
        XCTAssertTrue(restrictions.restrictedSessionIDs(inWorkspace: unrelated.id, excluding: UUID()).isEmpty)
    }

    // MARK: - Pre-normalization stamp and accepted bubbles

    func testColdRestoreStampsOpenTurnsBeforeNormalizationAndRestoresAcceptedBubblesOnce() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")

        // A legacy open turn: no recovery record, so no run identity exists.
        let legacy = try await makeSession(earlier, in: home)
        var openedLegacyTurnID: UUID?
        try rewriteSessionFile(legacy) { openedLegacyTurnID = try self.openLastTurn(&$0) }
        let legacyTurnID = try XCTUnwrap(openedLegacyTurnID)

        // An open turn whose run attempt recorded terminal evidence before the crash.
        let completed = try await makeSession(earlier, in: home)
        let completedTurnID = try XCTUnwrap(readSessionFile(completed).transcript?.turns.last?.id)
        let ownership = Support.ownership(sessionID: completed.session.id)
        let terminal = Support.terminalCommit(ownership: ownership)
        try await transact(earlier, completed) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: nil,
                transcriptTurnID: completedTurnID,
                providerKindRaw: nil
            )
            _ = try await store.recordRunTerminal(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                commit: terminal
            )
        }
        try rewriteSessionFile(completed) { _ = try self.openLastTurn(&$0) }

        // Provider-accepted input whose bubble the earlier launch never saved.
        let accepted = try await makeSession(earlier, in: home)
        let acceptedItemID = UUID()
        let acceptedSubmission = Support.submission("accepted before the crash", userItemID: acceptedItemID)
        try await transact(earlier, accepted) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: acceptedSubmission,
                consumption: nil
            )
            let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
            _ = try await store.beginDispatch(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: acceptedSubmission.intentID,
                attempt: attempt,
                authorization: .liveQueue
            )
            _ = try await store.recordDeliveryOutcome(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: acceptedSubmission.intentID,
                attemptID: attempt.attemptID,
                outcome: .providerAccepted
            )
        }
        XCTAssertFalse(try readSessionFile(accepted).toLiveItems().contains { $0.id == acceptedItemID })

        let now = launch()
        let results = try await sweep(now, [home])

        let legacyResolution = try XCTUnwrap(results.resolution(for: legacy.session.id))
        XCTAssertEqual(legacyResolution.classification, .actionable)
        XCTAssertEqual(legacyResolution.interruptedTurns.count, 1)
        let legacyTurn = try XCTUnwrap(legacyResolution.interruptedTurns.first)
        XCTAssertEqual(legacyTurn.turnID, legacyTurnID)
        XCTAssertEqual(legacyTurn.interruption.reason, .unknown, "A missing clean mark proves no cause")
        XCTAssertNil(legacyTurn.interruption.runAttemptID, "No run identity is invented for a legacy turn")
        XCTAssertNil(legacyTurn.interruption.resolution)
        XCTAssertEqual(legacyTurn.status, .interrupted)
        XCTAssertTrue(legacyTurn.isLastTurn)
        XCTAssertEqual(legacyResolution.unresolvedLegacyInterruptedTurnIDs, [legacyTurnID])
        let persistedLegacy = try XCTUnwrap(readSessionFile(legacy).transcript?.turns.first { $0.id == legacyTurnID })
        XCTAssertEqual(persistedLegacy.interruption, legacyTurn.interruption, "The stamp is durable in the normalizing rewrite")
        XCTAssertEqual(persistedLegacy.terminalState, .cancelled)

        let completedResolution = try XCTUnwrap(results.resolution(for: completed.session.id))
        // Review A F03 (deliberate contract change from R4): authoritative completion closes the open
        // turn as completed with no interruption stamp and lists it as an outcome turn (its transcript
        // tail may be missing; durable across launches until dismissed, review A F03-R1).
        XCTAssertTrue(completedResolution.interruptedTurns.isEmpty, "An ordinary outcome is never an interruption")
        let completedTurn = try XCTUnwrap(completedResolution.outcomeTurns.first)
        XCTAssertEqual(completedTurn.turnID, completedTurnID)
        XCTAssertEqual(completedTurn.runAttempt.runAttemptID, ownership.attemptID, "Joined to its existing run attempt")
        XCTAssertEqual(completedTurn.status, .completedTailMayBeMissing)
        let persistedCompleted = try XCTUnwrap(readSessionFile(completed).transcript?.turns.first { $0.id == completedTurnID })
        XCTAssertNil(persistedCompleted.interruption)
        XCTAssertEqual(persistedCompleted.terminalState, .completed)

        let currentInstanceID = await now.store.appInstanceID
        let holds = AgentRecoveryCoordinator.deriveCrashHolds(
            from: results,
            currentInstanceID: currentInstanceID,
            previousExitProvenClean: false
        )
        let legacyHold = try XCTUnwrap(holds[legacy.session.id], "An interrupted legacy last turn is held by its turn")
        XCTAssertEqual(legacyHold.uncertainTranscriptTurnIDs, legacyResolution.unresolvedLegacyInterruptedTurnIDs)
        XCTAssertTrue(legacyHold.uncertainRunAttemptIDs.isEmpty)
        XCTAssertNil(holds[completed.session.id], "Terminal evidence closed the run")
        XCTAssertNil(holds[accepted.session.id], "Accepted input is not uncertain")

        XCTAssertEqual(results.resolution(for: accepted.session.id)?.classification, .actionable)
        let restored = try readSessionFile(accepted).toLiveItems().filter { $0.id == acceptedItemID }
        XCTAssertEqual(restored.map(\.text), ["accepted before the crash"], "The accepted bubble is restored once")

        // A later launch neither re-stamps the turn nor duplicates the bubble, and still lists the
        // unresolved turn an earlier launch stamped.
        let later = launch()
        let reread = await later.service.reconcileRecoverySession(sessionID: legacy.session.id, workspace: home)
        XCTAssertEqual(reread.interruptedTurns.map(\.interruption), [legacyTurn.interruption], "The original stamp is kept")
        let relisted = try await sweep(launch(), [home])
        XCTAssertEqual(relisted.resolution(for: legacy.session.id)?.interruptedTurns.map(\.interruption), [legacyTurn.interruption])
        XCTAssertEqual(try readSessionFile(accepted).toLiveItems().count { $0.id == acceptedItemID }, 1)
    }

    // MARK: - Repeated restarts, R5 reasons, not-sent bubbles, recovery-only runs

    func testRepeatedRestartsKeepAnUnresolvedLegacyRowAndItsExactCrashHold() async throws {
        let crashed = launch()
        let home = try makeWorkspace("home")
        let legacy = try await makeSession(crashed, in: home)
        var openedTurnID: UUID?
        try rewriteSessionFile(legacy) { openedTurnID = try self.openLastTurn(&$0) }
        let turnID = try XCTUnwrap(openedTurnID)

        // First relaunch stamps the legacy last turn, then crashes as well (its mark stays running).
        let first = launch()
        let firstCoordinator = try await startedCoordinator(first, workspaces: [home])
        let stamped = try XCTUnwrap(firstCoordinator.reconciliation.resolution(for: legacy.session.id)?.interruptedTurns.first)
        XCTAssertEqual(stamped.turnID, turnID)
        XCTAssertEqual(stamped.interruption.reason, .unknown, "No launch mark proves a cause")
        XCTAssertNil(stamped.interruption.runAttemptID)
        XCTAssertEqual(firstCoordinator.crashHold(for: legacy.session.id)?.uncertainTranscriptTurnIDs, [turnID])

        // The saved session now looks idle; its index entry says it still needs inspection.
        let files = try await first.service.recoverySessionFiles(for: home)
        let hint = try XCTUnwrap(files.first { $0.sessionID == legacy.session.id }?.hint, "The index entry describes the file")
        XCTAssertNotEqual(hint.lastRunStateRaw, AgentSessionRunState.running.rawValue)
        XCTAssertTrue(hint.mayHaveUnresolvedInterruption)
        XCTAssertTrue(hint.needsInspection)

        // Second relaunch: no recovery record, the earlier launch's stamp, still listed and held.
        let second = launch()
        let secondCoordinator = try await startedCoordinator(second, workspaces: [home])
        let relisted = try XCTUnwrap(
            secondCoordinator.reconciliation.resolution(for: legacy.session.id),
            "The unresolved turn is listed after another restart"
        )
        XCTAssertNil(relisted.record)
        XCTAssertTrue(relisted.hasRecoveryItems)
        XCTAssertEqual(
            relisted.interruptedTurns.map(\.interruption),
            [stamped.interruption],
            "The earlier stamp is neither erased, re-stamped, nor re-attributed"
        )
        let hold = try XCTUnwrap(secondCoordinator.crashHold(for: legacy.session.id))
        XCTAssertEqual(hold.uncertainTranscriptTurnIDs, [turnID], "The exact legacy turn stays held")
        XCTAssertTrue(hold.uncertainRunAttemptIDs.isEmpty, "No run identity is invented")
        XCTAssertEqual(try readSessionFile(legacy).transcript?.turns.last?.interruption, stamped.interruption)
    }

    func testColdRestoreReasonUsesPerAttemptEvidenceThenTheCapturedLaunchState() async throws {
        let earlier = launch()
        let otherInstance = UUID()
        func mark(_ state: AgentRecoveryLaunchMark.State) -> AgentRecoveryPreviousLaunch {
            .mark(AgentRecoveryLaunchMark(
                appInstanceID: otherInstance,
                state: state,
                recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000)
            ))
        }

        // Clean previous exit: an attempt's own shutdown reason wins; a legacy turn reads as a quit.
        let quitHome = try makeWorkspace("quit")
        let windowClosed = try await makeSession(earlier, in: quitHome)
        let windowTurnID = try XCTUnwrap(readSessionFile(windowClosed).transcript?.turns.last?.id)
        let windowOwnership = Support.ownership(sessionID: windowClosed.session.id)
        try await transact(earlier, windowClosed) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: windowOwnership,
                processRunID: nil,
                transcriptTurnID: windowTurnID,
                providerKindRaw: nil
            )
            _ = try await store.recordRunShutdown(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                runAttemptID: windowOwnership.attemptID,
                reason: .windowClose,
                lastConfirmedActivityAt: nil
            )
        }
        try rewriteSessionFile(windowClosed) { _ = try self.openLastTurn(&$0) }
        let quitLegacy = try await makeOpenLegacySession(earlier, in: quitHome)
        // Unclean previous exit and unreadable launch state.
        let crashHome = try makeWorkspace("crash")
        let crashLegacy = try await makeOpenLegacySession(earlier, in: crashHome)
        let unreadableHome = try makeWorkspace("unreadable")
        let unreadableLegacy = try await makeOpenLegacySession(earlier, in: unreadableHome)

        func stampedReason(
            _ previous: AgentRecoveryPreviousLaunch,
            _ workspace: AgentRecoveryWorkspaceDestination,
            _ load: AgentSessionEditableLoad
        ) async throws -> AgentTranscriptTurnInterruption {
            let now = launch()
            await now.service.adoptColdRestoreLaunchEvidence(previous)
            let results = try await sweep(now, [workspace])
            let turn = try XCTUnwrap(results.resolution(for: load.session.id)?.interruptedTurns.first)
            XCTAssertEqual(try readSessionFile(load).transcript?.turns.last?.interruption, turn.interruption, "Durable")
            return turn.interruption
        }
        let windowInterruption = try await stampedReason(mark(.cleanExit), quitHome, windowClosed)
        XCTAssertEqual(windowInterruption.reason, .windowClose, "Per-attempt evidence comes first")
        XCTAssertEqual(windowInterruption.runAttemptID, windowOwnership.attemptID)
        let quitInterruption = try await stampedReason(mark(.cleanExit), quitHome, quitLegacy)
        XCTAssertEqual(quitInterruption.reason, .appQuit, "A proven clean exit closed it by quitting")
        XCTAssertNil(quitInterruption.runAttemptID, "No run identity is invented")
        let crashInterruption = try await stampedReason(mark(.running), crashHome, crashLegacy)
        XCTAssertEqual(crashInterruption.reason, .appCrash, "Another instance's running mark is a crash")
        XCTAssertNil(crashInterruption.runAttemptID)
        let unreadableInterruption = try await stampedReason(.unreadable("bad bytes"), unreadableHome, unreadableLegacy)
        XCTAssertEqual(unreadableInterruption.reason, .unknown, "Unreadable launch state proves nothing")

        let currentInstance = UUID()
        XCTAssertNil(AgentColdRestoreInterruptionContext.launchReason(previousLaunch: .none, currentInstanceID: currentInstance))
        XCTAssertNil(AgentColdRestoreInterruptionContext.launchReason(
            previousLaunch: .mark(AgentRecoveryLaunchMark(
                appInstanceID: currentInstance,
                state: .running,
                recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000)
            )),
            currentInstanceID: currentInstance
        ), "This launch's own mark proves nothing about the previous one")
    }

    /// Review A F04 / B F1: teardown → save → reload → reconcile. A window close stamps the turn the
    /// terminal closed (live barrier stamp), the session is saved, and the next launch reconciles
    /// that stamp by its run attempt exactly once: never as a recovery-only run, never as an outcome.
    /// The steering variant closes a later steer turn while the run keeps its opening turn. Review
    /// B R1-F1: the live transcript always opens a turn per user item (`importLegacyItems`), but a
    /// saved transcript may carry the steer as a mid-turn user activity; the terminal user item is
    /// then that activity, and the turn containing it is stamped and reconciled.
    func testLiveTeardownStampSurvivesSaveAndReloadAndReconcilesByRunAttempt() async throws {
        enum Steering: CaseIterable { case none, ownTurn, midTurnActivity }
        let earlier = launch()
        let home = try makeWorkspace("teardown")
        for steering in Steering.allCases {
            let steered = steering != .none
            let startID = UUID()
            let steerID = UUID()
            var items = [AgentChatItem.user("start", id: startID, sequenceIndex: 0)]
            if steering == .ownTurn { items.append(AgentChatItem.user("steer", id: steerID, sequenceIndex: 1)) }
            if steering == .midTurnActivity { items.append(AgentChatItem.assistant("working", sequenceIndex: 1)) }
            let load = try await makeSession(earlier, in: home, items: items)
            if steering == .midTurnActivity {
                try rewriteSessionFile(load) { session in
                    var transcript = try XCTUnwrap(session.transcript)
                    let spanIndex = try XCTUnwrap(transcript.turns.last?.responseSpans.indices.last)
                    let steer = AgentChatItem.user("steer", id: steerID, sequenceIndex: 2)
                    transcript.turns[transcript.turns.count - 1].responseSpans[spanIndex].activities.append(AgentTranscriptActivity(from: steer))
                    session.transcript = transcript
                }
            }
            // The run's terminal closes the turn of its last user item.
            let terminalUserItemID = steered ? steerID : startID
            let terminalTurnID = steering == .ownTurn ? steerID : startID
            let ownership = Support.ownership(sessionID: load.session.id)
            let commit = Support.terminalCommit(ownership: ownership, state: .cancelled, cause: .windowClose)
            try await transact(earlier, load) { store, binding in
                _ = try await store.ensureRunAttempt(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    ownership: ownership,
                    processRunID: nil,
                    transcriptTurnID: startID,
                    providerKindRaw: nil
                )
                if steered {
                    _ = try await store.commitDispatchingIntent(
                        binding: binding,
                        expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                        submission: Support.submission("steer", userItemID: steerID),
                        attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: ownership.attemptID),
                        consumption: nil
                    )
                }
                _ = try await store.recordRunTerminal(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    commit: commit
                )
            }

            // Teardown: the barrier's live stamp on the turn the terminal closed; then the save.
            let tab = AgentTabSession(tabID: UUID())
            tab.transcript = try XCTUnwrap(readSessionFile(load).transcript)
            XCTAssertEqual(tab.transcript.turns.last?.id, terminalTurnID)
            XCTAssertEqual(tab.transcript.turns.count, steering == .ownTurn ? 2 : 1, "\(steering)")
            AgentRunTerminalCommitBarrier.stampLiveInterruption(
                cause: commit.cause,
                terminalState: .cancelled,
                turnID: terminalUserItemID,
                runAttemptID: ownership.attemptID,
                session: tab,
                now: Date(timeIntervalSince1970: 2000)
            )
            let stamped = try XCTUnwrap(tab.transcript.turns.first { $0.id == terminalTurnID }?.interruption)
            try rewriteSessionFile(load) { $0.transcript = tab.transcript }

            // Reload and reconcile in the next launch.
            let now = launch()
            await now.service.adoptColdRestoreLaunchEvidence(.mark(AgentRecoveryLaunchMark(
                appInstanceID: earlier.store.appInstanceID,
                state: .cleanExit,
                recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 3000)
            )))
            let results = try await sweep(now, [home])
            let resolution = try XCTUnwrap(results.resolution(for: load.session.id), "\(steering)")
            XCTAssertEqual(resolution.interruptedTurns.map(\.turnID), [terminalTurnID], "\(steering)")
            let turn = try XCTUnwrap(resolution.interruptedTurns.first)
            XCTAssertEqual(turn.interruption, stamped, "the saved stamp, unchanged")
            XCTAssertEqual(turn.interruption.reason, .windowClose)
            XCTAssertEqual(turn.interruption.runAttemptID, ownership.attemptID)
            XCTAssertTrue(turn.status.isInterruption)
            XCTAssertTrue(resolution.recoveryOnlyRunAttempts.isEmpty, "the saved turn represents the run")
            XCTAssertTrue(resolution.outcomeTurns.isEmpty)
            XCTAssertEqual(
                try readSessionFile(load).transcript?.turns.compactMap(\.interruption),
                [stamped],
                "\(steering): no other turn is stamped"
            )
        }
    }

    /// R4: a recorded shutdown reason is intent, never proof of a stop. Neither this launch's
    /// uncertain-input hold nor the next launch's crash hold treats it as terminal evidence, and a
    /// `shutdownInProgress` launch mark proves no clean exit.
    func testShutdownReasonWithoutAStopKeepsTheRunAndItsUncertainInputHeld() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let ownership = Support.ownership(sessionID: load.session.id)
        let submission = Support.submission("sent while quitting")
        try await transact(earlier, load) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
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
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: ownership.attemptID),
                authorization: .liveQueue
            )
            _ = try await store.recordRunShutdown(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                runAttemptID: ownership.attemptID,
                reason: .appQuit,
                lastConfirmedActivityAt: nil
            )
        }
        let stored = await earlier.store.read(sessionID: load.session.id)
        let record = try XCTUnwrap(stored.record)
        let intent = try XCTUnwrap(record.intent(id: submission.intentID))
        XCTAssertEqual(record.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .appQuit)
        XCTAssertNil(
            AgentRecoveryCoordinator.uncertainInputHoldReason(intent, in: record),
            "A shutdown reason without terminal evidence leaves the input owned by its run"
        )

        let previous = AgentRecoveryPreviousLaunch.mark(AgentRecoveryLaunchMark(
            appInstanceID: earlier.store.appInstanceID,
            state: .shutdownInProgress,
            recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        ))
        let now = launch()
        XCTAssertFalse(previous.provesCleanExit(currentInstanceID: now.store.appInstanceID))
        XCTAssertNil(
            AgentColdRestoreInterruptionContext.launchReason(previousLaunch: previous, currentInstanceID: now.store.appInstanceID),
            "An unfinished shutdown proves no cause for legacy turns"
        )
        let results = try await sweep(now, [home])
        let hold = try XCTUnwrap(AgentRecoveryCoordinator.deriveCrashHolds(
            from: results,
            currentInstanceID: now.store.appInstanceID,
            previousExitProvenClean: false
        )[load.session.id], "A shutdown reason is never a stop")
        XCTAssertEqual(hold.uncertainRunAttemptIDs, [ownership.attemptID])
        XCTAssertEqual(hold.uncertainIntentIDs, [submission.intentID])
    }

    func testOrdinaryLoadBeforeStartupStampsProvisionallyAndReconcileRefinesWithoutErasing() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let legacy = try await makeOpenLegacySession(earlier, in: home)

        // An ordinary load before the coordinator captured launch state stamps `unknown`.
        let now = launch()
        _ = try await now.service.loadAgentSessionForEditing(id: legacy.session.id, for: home)
        let provisional = try XCTUnwrap(readSessionFile(legacy).transcript?.turns.last?.interruption)
        XCTAssertEqual(provisional.reason, .unknown)

        await now.service.adoptColdRestoreLaunchEvidence(.mark(AgentRecoveryLaunchMark(
            appInstanceID: UUID(),
            state: .running,
            recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        )))
        let results = try await sweep(now, [home])
        let refined = try XCTUnwrap(results.resolution(for: legacy.session.id)?.interruptedTurns.first?.interruption)
        XCTAssertEqual(refined.reason, .appCrash, "Refined with the captured launch evidence")
        XCTAssertEqual(refined.observedAt, provisional.observedAt, "The stamp is refined, not erased or replaced")
        XCTAssertEqual(refined.lastConfirmedActivityAt, provisional.lastConfirmedActivityAt)
        XCTAssertNil(refined.runAttemptID, "No run identity is invented")
        XCTAssertNil(refined.resolution)
        XCTAssertEqual(try readSessionFile(legacy).transcript?.turns.last?.interruption, refined)

        // Another launch's provisional stamp is never re-attributed.
        let later = launch()
        await later.service.adoptColdRestoreLaunchEvidence(.mark(AgentRecoveryLaunchMark(
            appInstanceID: UUID(),
            state: .cleanExit,
            recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000)
        )))
        let reread = await later.service.reconcileRecoverySession(sessionID: legacy.session.id, workspace: home)
        XCTAssertEqual(reread.interruptedTurns.map(\.interruption), [refined])
    }

    func testUnacceptedEarlierLaunchBubblesAreSavedAsNotSentAndAcceptedOnesStaySent() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        func bubbleSession(
            _ text: String,
            reply: String? = nil
        ) async throws -> (AgentSessionEditableLoad, AgentRecoveryIntentSubmission) {
            let itemID = UUID()
            var items = [AgentChatItem.user(text, id: itemID, sequenceIndex: 0)]
            if let reply {
                items.append(AgentChatItem.assistant(reply, sequenceIndex: 1))
            }
            let load = try await makeSession(earlier, in: home, items: items)
            return (load, Support.submission(text, userItemID: itemID))
        }
        let (queued, queuedSubmission) = try await bubbleSession("queued, never sent")
        try await commitQueued(earlier, queued, queuedSubmission)
        let (unknown, unknownSubmission) = try await bubbleSession("delivery unknown")
        try await dispatch(earlier, unknown, unknownSubmission, outcome: .deliveryUnknown)
        let (accepted, acceptedSubmission) = try await bubbleSession("accepted")
        try await dispatch(earlier, accepted, acceptedSubmission, outcome: .providerAccepted)
        // A saved provider reply in the bubble's turn is acceptance evidence of its own.
        let (answered, answeredSubmission) = try await bubbleSession("answered", reply: "The provider replied.")
        try await dispatch(earlier, answered, answeredSubmission, outcome: .deliveryUnknown)
        // R11: a mid-turn steering item saved as a user activity of an answered turn; turn-wide
        // output does not prove it was received.
        let (steered, _) = try await bubbleSession("request", reply: "Working on it.")
        let steeringItemID = UUID()
        let steeringSubmission = Support.submission("mid-turn steering", userItemID: steeringItemID)
        try rewriteSessionFile(steered) { session in
            var transcript = try XCTUnwrap(session.transcript)
            let turn = try XCTUnwrap(transcript.turns.indices.last)
            let span = try XCTUnwrap(transcript.turns[turn].responseSpans.indices.last)
            transcript.turns[turn].responseSpans[span].activities.append(AgentTranscriptActivity(
                id: steeringItemID,
                timestamp: Date(),
                sequenceIndex: 2,
                role: .note,
                itemKind: .user,
                text: "mid-turn steering"
            ))
            session.transcript = transcript
        }
        try await commitQueued(earlier, steered, steeringSubmission)
        // R11: schedule receipts are kind-aware: saved-in-queue proves no delivery; a provider-
        // accepted receipt does.
        func scheduledBubble(_ text: String, kind: (UUID) -> AgentScheduledSendReceiptKind) async throws
            -> (AgentSessionEditableLoad, AgentRecoveryIntentSubmission)
        {
            let itemID = UUID()
            let receipt = AgentScheduledSendProvenance(
                scheduleID: UUID(),
                attemptID: UUID(),
                scheduledFor: Date(timeIntervalSince1970: 1000),
                sentAt: Date(timeIntervalSince1970: 2000),
                kind: kind(itemID)
            )
            let load = try await makeSession(earlier, in: home, items: [
                AgentChatItem.user(text, id: itemID, sequenceIndex: 0, scheduledSend: receipt)
            ])
            let submission = Support.submission(text, userItemID: itemID)
            try await commitQueued(earlier, load, submission)
            return (load, submission)
        }
        let (savedInQueue, savedInQueueSubmission) = try await scheduledBubble("scheduled, saved") {
            .savedInQueue(AgentScheduledSendQueueLink(intentID: UUID(), userItemID: $0))
        }
        let (acceptedReceipt, acceptedReceiptSubmission) = try await scheduledBubble("scheduled, accepted") { _ in
            .providerAccepted
        }

        let now = launch()
        _ = try await sweep(now, [home])

        func savedRequest(
            _ load: AgentSessionEditableLoad,
            _ submission: AgentRecoveryIntentSubmission
        ) throws -> AgentTranscriptRequestAnchor {
            try XCTUnwrap(readSessionFile(load).transcript?.turns.compactMap(\.request).first { $0.id == submission.userItemID })
        }
        XCTAssertEqual(try savedRequest(queued, queuedSubmission).recoveryDelivery, .notSent, "Queued input was never sent")
        XCTAssertEqual(
            try savedRequest(unknown, unknownSubmission).recoveryDelivery,
            .unconfirmed,
            "Unknown delivery is shown distinctly from verified not-sent"
        )
        XCTAssertNil(try savedRequest(accepted, acceptedSubmission).recoveryDelivery, "Affirmative acceptance stays sent")
        XCTAssertNil(try savedRequest(answered, answeredSubmission).recoveryDelivery, "A saved reply stays sent")
        for (load, submission) in [(queued, queuedSubmission), (unknown, unknownSubmission)] {
            XCTAssertNil(try savedRequest(load, submission).isUndeliveredRemoteSend, "The remote-resend flag is never reused")
        }
        let steeredSpans = try readSessionFile(steered).transcript?.turns.last?.responseSpans ?? []
        let steeringActivity = try XCTUnwrap(steeredSpans.flatMap(\.activities).first { $0.id == steeringItemID })
        XCTAssertEqual(steeringActivity.recoveryDelivery, .notSent, "A mid-turn user item is joined by its own item ID")
        XCTAssertEqual(try savedRequest(savedInQueue, savedInQueueSubmission).recoveryDelivery, .notSent)
        XCTAssertNil(
            try savedRequest(acceptedReceipt, acceptedReceiptSubmission).recoveryDelivery,
            "A provider-accepted schedule receipt is acceptance"
        )
        XCTAssertEqual(try readSessionFile(queued).serializationVersion, AgentSession.currentSerializationVersion)
        let queuedState = await now.store.read(sessionID: queued.session.id).record?.intent(id: queuedSubmission.intentID)?.deliveryState
        XCTAssertEqual(queuedState, .queued, "Presentation never changes delivery evidence")

        // A later launch presents the same deterministic bubble as not sent.
        let reloadedLoad = try await launch().service.loadAgentSessionForEditing(id: queued.session.id, for: home)
        let reloaded = try XCTUnwrap(reloadedLoad)
        let bubble = try XCTUnwrap(reloaded.session.toLiveItems().first { $0.id == queuedSubmission.userItemID })
        XCTAssertEqual(bubble.recoveryDelivery, .notSent)
        XCTAssertFalse(bubble.isUndeliveredRemoteSend, "No remote resend affordance for a local bubble")
        XCTAssertEqual(reloaded.session.toLiveItems().count { $0.id == queuedSubmission.userItemID }, 1)
    }

    func testRecoveryOnlyRunAttemptIsDiscoverableWithoutATranscriptTurn() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let ownership = Support.ownership(sessionID: load.session.id)
        try await transact(earlier, load) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: UUID(),
                transcriptTurnID: UUID(),
                providerKindRaw: nil
            )
        }

        let results = try await sweep(launch(), [home])
        let resolution = try XCTUnwrap(results.resolution(for: load.session.id))
        XCTAssertEqual(resolution.recoveryOnlyRunAttempts.map(\.runAttemptID), [ownership.attemptID])
        XCTAssertTrue(resolution.interruptedTurns.isEmpty, "No saved turn to stamp")
        XCTAssertTrue(resolution.hasRecoveryItems, "Unresolved run evidence counts without a transcript turn")
    }

    /// R08/R09: Claude reuses one process run across turns, so an older saved turn on that process
    /// run never represents a newer attempt; a finished run whose own turn is missing is listed with
    /// its outcome and holds nothing.
    func testRepeatedProcessRunIDsJoinOnlyUnambiguouslyAndTerminalOnlyRunsAreListed() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let savedTurnID = UUID()
        let processRunID = UUID()
        let load = try await makeSession(earlier, in: home, items: [
            AgentChatItem.user("first turn", id: savedTurnID, sequenceIndex: 0),
            AgentChatItem.assistant("first reply", sequenceIndex: 1)
        ])
        try rewriteSessionFile(load) { session in
            var transcript = try XCTUnwrap(session.transcript)
            let index = try XCTUnwrap(transcript.turns.firstIndex { $0.id == savedTurnID })
            let span = try XCTUnwrap(transcript.turns[index].responseSpans.indices.last)
            transcript.turns[index].responseSpans[span].runID = processRunID
            session.transcript = transcript
        }
        typealias Run = (ownership: AgentRunOwnership, commit: AgentRunTerminalCommitRevision?, turnID: UUID?, processRunID: UUID?)
        func run(turn: UUID?, process: UUID?, terminal: AgentSessionRunState?) -> Run {
            let ownership = Support.ownership(sessionID: load.session.id)
            let commit = terminal.map { Support.terminalCommit(ownership: ownership, state: $0, expectedRunID: process) }
            return (ownership, commit, turn, process)
        }
        let finishedSaved = run(turn: savedTurnID, process: processRunID, terminal: .completed)
        let openNewerTurn = run(turn: UUID(), process: processRunID, terminal: nil)
        let openUnkeyedTurn = run(turn: nil, process: processRunID, terminal: nil)
        let finishedUnsaved = run(turn: UUID(), process: UUID(), terminal: .cancelled)
        let finishedWithoutKeys = run(turn: nil, process: nil, terminal: .completed)
        let specs = [finishedSaved, openNewerTurn, openUnkeyedTurn, finishedUnsaved, finishedWithoutKeys]
        try await transact(earlier, load) { store, binding in
            for spec in specs {
                _ = try await store.ensureRunAttempt(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    ownership: spec.ownership,
                    processRunID: spec.processRunID,
                    transcriptTurnID: spec.turnID,
                    providerKindRaw: nil
                )
                if let commit = spec.commit {
                    _ = try await store.recordRunTerminal(
                        binding: binding,
                        expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                        commit: commit
                    )
                }
            }
        }

        let now = launch()
        let results = try await sweep(now, [home])
        let resolution = try XCTUnwrap(results.resolution(for: load.session.id))
        XCTAssertEqual(
            Set(resolution.recoveryOnlyRunAttempts.map(\.runAttemptID)),
            [openNewerTurn.ownership.attemptID, openUnkeyedTurn.ownership.attemptID, finishedUnsaved.ownership.attemptID],
            "Represented: only the attempt whose own turn is saved; a keyless finished run proves nothing"
        )
        XCTAssertTrue(resolution.hasRecoveryItems)
        let finishedRow = try XCTUnwrap(resolution.recoveryOnlyRunAttempts.first {
            $0.runAttemptID == finishedUnsaved.ownership.attemptID
        })
        XCTAssertEqual(finishedRow.terminal?.terminalState, .cancelled, "The recorded outcome is presented")

        let currentInstanceID = now.store.appInstanceID
        let hold = try XCTUnwrap(AgentRecoveryCoordinator.deriveCrashHolds(
            from: results,
            currentInstanceID: currentInstanceID,
            previousExitProvenClean: false
        )[load.session.id])
        XCTAssertEqual(
            hold.uncertainRunAttemptIDs,
            [openNewerTurn.ownership.attemptID, openUnkeyedTurn.ownership.attemptID],
            "Only open runs hold; finished ones never do"
        )

        // The join itself: the saved turn resolves to its own attempt, never to a newer one on the
        // same process run; two attempts without their own turn on one process run are ambiguous.
        let attempts = try XCTUnwrap(resolution.record?.record.runAttempts)
        let savedTurn = try XCTUnwrap(readSessionFile(load).transcript?.turns.first { $0.id == savedTurnID })
        let join = AgentRecoveryRunTurnJoin(runAttempts: attempts)
        XCTAssertEqual(join.attempt(for: savedTurn)?.runAttemptID, finishedSaved.ownership.attemptID)
        let unkeyed = try XCTUnwrap(attempts.first { $0.runAttemptID == openUnkeyedTurn.ownership.attemptID })
        XCTAssertEqual(join.hasSavedTurn(unkeyed, in: [savedTurn]), false, "A turn claimed by another attempt never stands in")
        // Without the attempt that claims it, the same saved turn is unclaimed.
        let unique = AgentRecoveryRunTurnJoin(runAttempts: [unkeyed])
        XCTAssertEqual(unique.hasSavedTurn(unkeyed, in: [savedTurn]), true, "A unique unkeyed attempt joins by its process run")
        XCTAssertEqual(unique.attempt(for: savedTurn)?.runAttemptID, unkeyed.runAttemptID)
        let ambiguous = AgentRecoveryRunTurnJoin(runAttempts: [unkeyed, AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: unkeyed.transcriptResetGeneration,
            processRunID: processRunID,
            transcriptTurnID: nil,
            startedAt: unkeyed.startedAt
        )])
        XCTAssertNil(ambiguous.attempt(for: savedTurn), "Two attempts on one process run: no guess")
        XCTAssertEqual(ambiguous.hasSavedTurn(unkeyed, in: [savedTurn]), false)
        let keyless = try XCTUnwrap(attempts.first { $0.runAttemptID == finishedWithoutKeys.ownership.attemptID })
        XCTAssertNil(join.hasSavedTurn(keyless, in: [savedTurn]))
    }

    // MARK: - R9 receipt transfer at the startup boundary

    func testStartupCompletesLinkedScheduleTransferOfClosedSessionBeforeReady() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let schedule = dispatchingSchedule()
        let attempt = try XCTUnwrap(schedule.attempt)
        let submission = scheduledSubmission(schedule, attempt: attempt)
        try await commitQueued(earlier, load, submission)
        try rewriteSessionFile(load) { $0.scheduledSend = .v1(schedule) }

        let now = launch()
        // Startup reaching `.ready` proves reconciliation never awaited its own barrier.
        let coordinator = try await startedCoordinator(now, workspaces: [home])

        let resolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: load.session.id))
        guard case let .completed(receipt) = resolution.scheduleTransfer else {
            return XCTFail("A durably queued linked intent completes the transfer, got \(resolution.scheduleTransfer)")
        }
        XCTAssertEqual(receipt.queueLink, AgentScheduledSendQueueLink(intentID: submission.intentID, userItemID: attempt.itemID))
        let disk = try readSessionFile(load)
        XCTAssertNil(disk.scheduledSend, "The pending schedule is cleared in the same CAS")
        XCTAssertEqual(disk.lastScheduledDispatch, receipt)
        XCTAssertNil(coordinator.restrictions.sessionRestriction(load.session.id))
        let intent = await now.store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertEqual(intent?.deliveryState, .queued, "The transfer never records acceptance")
    }

    // MARK: - R10 Cancel pending schedule

    /// A held transfer (linked intent's delivery unknown) is cancelled explicitly: the decision is
    /// committed on the linked intent, then that exact schedule is cleared with no receipt. The
    /// intent keeps its uncertain delivery; a mismatched attempt is never cancelled.
    func testCancelPendingScheduleCommitsDecisionThenClearsTheExactScheduleWithoutReceipt() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let schedule = dispatchingSchedule()
        let attempt = try XCTUnwrap(schedule.attempt)
        let submission = scheduledSubmission(schedule, attempt: attempt)
        try await dispatch(earlier, load, submission, outcome: .deliveryUnknown)
        try rewriteSessionFile(load) { $0.scheduledSend = .v1(schedule) }

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let resolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: load.session.id))
        guard case .held = resolution.scheduleTransfer else {
            return XCTFail("Unknown delivery holds the transfer, got \(resolution.scheduleTransfer)")
        }
        let reloaded = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let stamp = try XCTUnwrap(reloaded?.persistenceState).stamp
        let pending = try XCTUnwrap(readSessionFile(load).scheduledSend?.persistedValue)
        XCTAssertEqual(pending, schedule)
        let receiptBefore = try readSessionFile(load).lastScheduledDispatch

        var otherAttempt = pending
        otherAttempt.attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: attempt.itemID, startedAt: attempt.startedAt)
        let mismatch = await now.service.cancelScheduledSendTransfer(
            sessionID: load.session.id,
            for: home,
            persistenceStamp: stamp,
            expectedRecord: otherAttempt
        )
        XCTAssertEqual(mismatch, .notApplicable, "Only the exact pending attempt is cancelled")
        let untouched = await now.store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertNil(untouched?.scheduledTransferCancellation)

        let outcome = await now.service.cancelScheduledSendTransfer(
            sessionID: load.session.id,
            for: home,
            persistenceStamp: stamp,
            expectedRecord: pending
        )
        XCTAssertEqual(outcome, .cancelled)
        let disk = try readSessionFile(load)
        XCTAssertNil(disk.scheduledSend, "The exact pending schedule is cleared")
        XCTAssertEqual(disk.lastScheduledDispatch, receiptBefore, "No provider-accepted or saved-in-queue receipt")
        let intent = await now.store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertEqual(intent?.deliveryState, .deliveryUnknown, "Delivery evidence is unchanged")
        XCTAssertEqual(
            intent?.scheduledTransferCancellation?.matches(scheduleID: schedule.id, scheduleAttemptID: attempt.attemptID),
            true
        )
        coordinator.noteScheduleTransferResolved(sessionID: load.session.id)
        XCTAssertNil(coordinator.restrictions.sessionRestriction(load.session.id), "The transfer restriction lifts after the clear")
    }

    /// A crash after the decision was written but before the schedule was cleared: the next
    /// startup's repair finishes the cancellation (no resend, no new confirmation).
    func testStartupFinishesACommittedScheduleCancellation() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let schedule = dispatchingSchedule()
        let attempt = try XCTUnwrap(schedule.attempt)
        let submission = scheduledSubmission(schedule, attempt: attempt)
        try await dispatch(earlier, load, submission, outcome: .deliveryUnknown)
        try await transact(earlier, load) { store, binding in
            _ = try await store.recordScheduledTransferCancellation(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: submission.intentID,
                scheduleID: schedule.id,
                scheduleAttemptID: attempt.attemptID
            )
        }
        try rewriteSessionFile(load) { $0.scheduledSend = .v1(schedule) }

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let resolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: load.session.id))
        XCTAssertEqual(resolution.scheduleTransfer, .cancelled)
        XCTAssertNil(try readSessionFile(load).scheduledSend)
        XCTAssertNil(coordinator.restrictions.sessionRestriction(load.session.id))
        let intent = await now.store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertEqual(intent?.deliveryState, .deliveryUnknown)

        // A replacement attempt of the same schedule is not cancelled by the earlier decision.
        var replacement = schedule
        replacement.attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: attempt.startedAt)
        let read = await now.store.read(sessionID: load.session.id)
        let decision = AgentScheduledSendTransfer.resolve(record: replacement, recoveryRecord: read, sentAt: Date())
        XCTAssertNotEqual(decision, .cancelTransfer)
    }

    func testFailedScheduleTransferCommitStaysHeldAndRestrictsItsSession() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let load = try await makeSession(earlier, in: home)
        let schedule = dispatchingSchedule()
        let attempt = try XCTUnwrap(schedule.attempt)
        try await commitQueued(earlier, load, scheduledSubmission(schedule, attempt: attempt))
        try rewriteSessionFile(load) { $0.scheduledSend = .v1(schedule) }

        let now = launch()
        // One cold load normalizes the file; every later session write then fails.
        _ = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let fileURL = try sessionFileURL(load)
        let before = try Data(contentsOf: fileURL)
        await now.service.test_setSessionWriteFailureInjector { _ in CocoaError(.fileWriteNoPermission) }

        let coordinator = try await startedCoordinator(now, workspaces: [home])
        await now.service.test_setSessionWriteFailureInjector(nil)

        let resolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: load.session.id))
        guard case let .held(message) = resolution.scheduleTransfer else {
            return XCTFail("A failed commit is held, got \(resolution.scheduleTransfer)")
        }
        XCTAssertTrue(message.contains("could not be saved"), message)
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "Nothing was written")
        XCTAssertEqual(try readSessionFile(load).scheduledSend?.persistedValue, schedule, "The schedule and payload are unchanged")
        XCTAssertEqual(coordinator.restrictions.sessionRestriction(load.session.id), message)
        let binding = try XCTUnwrap(resolution.binding)
        let refusal = await coordinator.admissionRefusal(for: binding, workspaceID: home.id)
        XCTAssertEqual(refusal, .restricted(message))
        XCTAssertTrue(
            coordinator.hasUnresolvedSession(inWorkspace: home.id, excluding: UUID()),
            "The closed session keeps its workspace busy for scheduling"
        )
        XCTAssertFalse(coordinator.hasUnresolvedSession(inWorkspace: home.id, excluding: load.session.id))
        // F2: the itemized summary names the same restricted session.
        XCTAssertEqual(
            coordinator.unresolvedSessionSummary(inWorkspace: home.id, excluding: UUID()),
            AgentRecoveryWorkspaceUnresolvedSummary(restrictedSessionIDs: [load.session.id])
        )
        XCTAssertTrue(coordinator.unresolvedSessionSummary(inWorkspace: home.id, excluding: load.session.id).isEmpty)
    }

    // MARK: - Crash-hold matrix

    func testCrashHoldsCoverOpenRunsAndUncertainDeliveryAndConfirmOnlyTheExactHold() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")

        // A run attempt with a recorded shutdown reason but no terminal evidence.
        let quit = try await makeSession(earlier, in: home)
        let quitOwnership = Support.ownership(sessionID: quit.session.id)
        try await transact(earlier, quit) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: quitOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await store.recordRunShutdown(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                runAttemptID: quitOwnership.attemptID,
                reason: .appQuit,
                lastConfirmedActivityAt: nil
            )
        }

        // Remote input whose delivery is unknown, without any run attempt.
        let remote = try await makeSession(earlier, in: home)
        let remoteSubmission = Support.submission("remote send", origin: .mcp)
        try await transact(earlier, remote) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: remoteSubmission,
                consumption: nil
            )
            let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
            _ = try await store.beginDispatch(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: remoteSubmission.intentID,
                attempt: attempt,
                authorization: .liveQueue
            )
            _ = try await store.recordDeliveryOutcome(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: remoteSubmission.intentID,
                attemptID: attempt.attemptID,
                outcome: .deliveryUnknown
            )
        }

        // An open run recorded before a transcript reset.
        let reset = try await makeSession(earlier, in: home)
        let resetOwnership = Support.ownership(sessionID: reset.session.id)
        try await transact(earlier, reset) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: resetOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }
        _ = try await resetTranscript(earlier, reset, in: home)

        // F-3: a session executing on an authoritative remote host (persisted execution binding),
        // with an open run and unknown delivery.
        let remoteHosted = try await makeSession(earlier, in: home)
        let remoteHostedOwnership = Support.ownership(sessionID: remoteHosted.session.id)
        let remoteHostedSubmission = Support.submission("host command", origin: .mcp)
        try await transact(earlier, remoteHosted) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: remoteHostedOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: remoteHostedSubmission,
                consumption: nil
            )
            let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
            _ = try await store.beginDispatch(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: remoteHostedSubmission.intentID,
                attempt: attempt,
                authorization: .liveQueue
            )
            _ = try await store.recordDeliveryOutcome(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: remoteHostedSubmission.intentID,
                attemptID: attempt.attemptID,
                outcome: .deliveryUnknown
            )
        }
        try rewriteSessionFile(remoteHosted) {
            $0.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "host-1",
                hostDisplayName: "Host",
                remoteSessionID: "remote-session"
            )
        }

        // A record written for another incarnation of the session.
        let mismatched = try await makeSession(earlier, in: home)
        let mismatchedBinding = try earlier.service.recoveryLifecycleGate(for: mismatched.persistenceState).binding
        _ = try await earlier.store.commitQueuedIntent(
            binding: AgentRecoveryLifecycleBinding(
                sessionID: mismatched.session.id,
                incarnationID: UUID(),
                transcriptResetGeneration: 0
            ),
            expectedRevision: nil,
            submission: Support.submission("foreign incarnation"),
            consumption: nil
        )

        let now = launch()
        let coordinator = try await startedCoordinator(now, workspaces: [home])

        let quitHold = try XCTUnwrap(coordinator.crashHold(for: quit.session.id))
        XCTAssertEqual(quitHold.uncertainRunAttemptIDs, [quitOwnership.attemptID], "A shutdown reason does not close the run")
        XCTAssertTrue(quitHold.uncertainIntentIDs.isEmpty)
        XCTAssertFalse(quitHold.previousExitProvenClean)

        let remoteHold = try XCTUnwrap(coordinator.crashHold(for: remote.session.id))
        XCTAssertEqual(remoteHold.uncertainIntentIDs, [remoteSubmission.intentID])
        XCTAssertTrue(remoteHold.uncertainRunAttemptIDs.isEmpty, "No run identity is required to hold uncertain delivery")

        let resetResolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: reset.session.id))
        let resetBinding = try XCTUnwrap(resetResolution.binding)
        XCTAssertEqual(resetBinding.transcriptResetGeneration, 1)
        let resetHold = try XCTUnwrap(coordinator.crashHold(for: reset.session.id))
        XCTAssertEqual(resetHold.transcriptResetGeneration, 1, "The hold binds the validated current generation")
        XCTAssertEqual(resetHold.uncertainRunAttemptIDs, [resetOwnership.attemptID])

        let mismatchedResolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: mismatched.session.id))
        XCTAssertEqual(mismatchedResolution.classification, .nonactionable(.authorityMismatch))
        XCTAssertNil(coordinator.crashHold(for: mismatched.session.id), "A mismatched record holds nothing for this incarnation")
        let mismatchedRefusal = await coordinator.admissionRefusal(for: mismatchedBinding, workspaceID: home.id)
        guard case .restricted = mismatchedRefusal else {
            return XCTFail("A mismatched record restricts its session, got \(String(describing: mismatchedRefusal))")
        }

        // Exact confirmation only, per session.
        let quitBinding = try XCTUnwrap(coordinator.reconciliation.resolution(for: quit.session.id)?.binding)
        let heldRefusal = await coordinator.admissionRefusal(for: quitBinding, workspaceID: home.id)
        XCTAssertEqual(heldRefusal, .crashHeld(quitHold))
        let stale = AgentRecoveryCrashHold(
            sessionID: quitHold.sessionID,
            incarnationID: quitHold.incarnationID,
            transcriptResetGeneration: quitHold.transcriptResetGeneration + 1,
            uncertainRunAttemptIDs: quitHold.uncertainRunAttemptIDs,
            uncertainIntentIDs: quitHold.uncertainIntentIDs,
            previousExitProvenClean: quitHold.previousExitProvenClean
        )
        let quitLoad = try await now.service.loadAgentSessionForEditing(id: quit.session.id, for: home)
        let quitState = try XCTUnwrap(quitLoad?.persistenceState)
        let owner = NSObject()
        let quitLane = try coordinator.claimLane(owner: owner, persistenceState: quitState)
        let staleConfirmed = await coordinator.confirmCrashHold(stale, lane: quitLane)
        XCTAssertFalse(staleConfirmed, "A hold for another generation is not this hold")
        XCTAssertNotNil(coordinator.blockingCrashHold(for: quitBinding))
        let quitConfirmed = await coordinator.confirmCrashHold(quitHold, lane: quitLane)
        XCTAssertTrue(quitConfirmed)
        XCTAssertNil(coordinator.blockingCrashHold(for: quitBinding))
        let quitRecord = await now.store.read(sessionID: quit.session.id).record
        XCTAssertTrue(quitHold.isCovered(by: quitRecord?.crashHoldAcknowledgement), "The decision is durable")
        XCTAssertNil(quitRecord?.runAttempt(id: quitOwnership.attemptID)?.terminal, "It does not close the run")
        let otherGeneration = AgentRecoveryLifecycleBinding(
            sessionID: quitBinding.sessionID,
            incarnationID: quitBinding.incarnationID,
            transcriptResetGeneration: quitBinding.transcriptResetGeneration + 1
        )
        XCTAssertNil(coordinator.blockingCrashHold(for: otherGeneration), "A hold binds its own reset generation")

        // F-3: the remote-hosted session holds nothing locally; its evidence is kept.
        let remoteHostedResolution = try XCTUnwrap(coordinator.reconciliation.resolution(for: remoteHosted.session.id))
        XCTAssertEqual(remoteHostedResolution.remoteHostID, "host-1")
        XCTAssertNil(coordinator.crashHold(for: remoteHosted.session.id), "No local crash hold for a remote session")
        XCTAssertEqual(
            remoteHostedResolution.record?.record.intent(id: remoteHostedSubmission.intentID)?.deliveryState,
            .deliveryUnknown,
            "Remote uncertainty stays recorded, never upgraded"
        )
        XCTAssertTrue(remoteHostedResolution.hasRecoveryItems, "Remote uncertainty stays visible")
        let confirmedRefusal = await coordinator.admissionRefusal(for: quitBinding, workspaceID: home.id)
        XCTAssertNil(confirmedRefusal)
        let remoteBinding = try XCTUnwrap(coordinator.reconciliation.resolution(for: remote.session.id)?.binding)
        XCTAssertNotNil(coordinator.blockingCrashHold(for: remoteBinding), "Confirmation never lifts another session's hold")
        XCTAssertNotNil(coordinator.blockingCrashHold(for: resetBinding))
    }

    // MARK: - Load purpose (F-7)

    /// Same-launch resync, rename, and read-only loads are storage mutations: an open turn a live
    /// owner may still be running is neither stamped, cancelled, nor rewritten as interrupted. Only
    /// the cold restoration (startup reconciliation, hydration) applies prior-execution evidence.
    func testStorageMutationLoadsNeverStampOrCancelAnOpenTurnOnlyColdRestorationDoes() async throws {
        let earlier = launch()
        let home = try makeWorkspace("purpose")
        let load = try await makeSession(earlier, in: home)
        var openedTurnID: UUID?
        try rewriteSessionFile(load) { openedTurnID = try self.openLastTurn(&$0) }
        let turnID = try XCTUnwrap(openedTurnID)
        let running = AgentSessionRunState.running.rawValue

        let now = launch()
        let resynced = try await now.service.loadAgentSession(id: load.session.id, for: home)
        let resyncedTurn = try XCTUnwrap(resynced?.transcript?.turns.last)
        XCTAssertEqual(resyncedTurn.id, turnID)
        XCTAssertEqual(resyncedTurn.terminalState, .running, "A storage-mutation load never cancels the open turn")
        XCTAssertNil(resyncedTurn.interruption, "A storage-mutation load never stamps an interruption")
        XCTAssertEqual(resynced?.lastRunState, running)

        try await now.service.renameAgentSession(id: load.session.id, to: "Renamed", for: home)
        let afterRename = try readSessionFile(load)
        XCTAssertEqual(afterRename.name, "Renamed")
        XCTAssertEqual(afterRename.transcript?.turns.last?.terminalState, .running)
        XCTAssertNil(afterRename.transcript?.turns.last?.interruption)
        XCTAssertEqual(afterRename.lastRunState, running)

        let coordinator = try await startedCoordinator(now, workspaces: [home])
        let stamped = try XCTUnwrap(
            coordinator.reconciliation.resolution(for: load.session.id)?.interruptedTurns.first,
            "The cold restoration still stamps the open turn"
        )
        XCTAssertEqual(stamped.turnID, turnID)
        XCTAssertEqual(try readSessionFile(load).transcript?.turns.last?.interruption, stamped.interruption)
    }

    /// F-7 residual: cold restoration excludes exactly the runs the current launch still owns. A second
    /// owner cold-hydrating a session while this launch's run is live leaves that run's turn and the
    /// saved active run state as saved, yet still closes and stamps, in the same record, an earlier
    /// launch's open turn and a legacy attempt's turn (no instance: unknown owner, never current).
    /// Hydration rewrites no run evidence or ownership and fabricates no terminal evidence. Once the
    /// same launch records the run's shutdown, it is no longer live, and a later cold hydration closes
    /// its turn with that reason.
    func testSecondOwnerColdHydrationExcludesOnlyTheCurrentLaunchLiveRunTurn() async throws {
        let earlier = launch()
        let home = try makeWorkspace("live-owner")
        let crashedTurnID = UUID()
        let legacyTurnID = UUID()
        let liveTurnID = UUID()
        let load = try await makeSession(earlier, in: home, items: [
            AgentChatItem.user("crashed", id: crashedTurnID, sequenceIndex: 0),
            AgentChatItem.assistant("partial", sequenceIndex: 1),
            AgentChatItem.user("legacy", id: legacyTurnID, sequenceIndex: 2),
            AgentChatItem.assistant("partial", sequenceIndex: 3),
            AgentChatItem.user("live", id: liveTurnID, sequenceIndex: 4),
            AgentChatItem.assistant("streaming", sequenceIndex: 5)
        ])
        let running = AgentSessionRunState.running.rawValue

        // An earlier launch's open run, and one whose run-start evidence predates the instance field.
        let crashed = Support.ownership(sessionID: load.session.id)
        let legacy = Support.ownership(sessionID: load.session.id)
        let earlierRuns = [(crashed, crashedTurnID), (legacy, legacyTurnID)]
        try await transact(earlier, load) { store, binding in
            for (ownership, turnID) in earlierRuns {
                _ = try await store.ensureRunAttempt(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    ownership: ownership,
                    processRunID: nil,
                    transcriptTurnID: turnID,
                    providerKindRaw: nil
                )
            }
        }
        let recordURL = earlier.store.recordFileURL(sessionID: load.session.id)
        guard case var .object(recordJSON) = try Support.readJSON(recordURL),
              case var .array(runsJSON) = recordJSON["runAttempts"]
        else { return XCTFail("Expected run attempts in the recovery record") }
        var strippedLegacyInstance = false
        for index in runsJSON.indices {
            guard case var .object(run) = runsJSON[index],
                  run["runAttemptID"] == .string(legacy.attemptID.uuidString)
            else { continue }
            XCTAssertEqual(run["appInstanceID"], .string(earlier.store.appInstanceID.uuidString), "Run-start evidence records its launch")
            run["appInstanceID"] = nil
            runsJSON[index] = .object(run)
            strippedLegacyInstance = true
        }
        XCTAssertTrue(strippedLegacyInstance)
        recordJSON["runAttempts"] = .array(runsJSON)
        try Support.writeJSON(.object(recordJSON), to: recordURL)

        // The current launch's first owner hydrates the session (its own gate) and starts the live run.
        let now = launch()
        let firstOwnerLoad = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let firstOwner = try XCTUnwrap(firstOwnerLoad)
        let live = Support.ownership(sessionID: load.session.id)
        try await transact(now, firstOwner) { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: live,
                processRunID: UUID(),
                transcriptTurnID: liveTurnID,
                providerKindRaw: nil
            )
        }
        // The saved file holds all three turns open at once (the live owner saved mid-run beside the
        // earlier launch's open turns), so one cold hydration must decide per turn.
        try rewriteSessionFile(load) { session in
            var transcript = try XCTUnwrap(session.transcript)
            XCTAssertEqual(transcript.turns.map(\.id), [crashedTurnID, legacyTurnID, liveTurnID])
            for index in transcript.turns.indices {
                transcript.turns[index].terminalState = .running
                transcript.turns[index].completedAt = nil
                transcript.turns[index].interruption = nil
            }
            session.transcript = transcript
            session.lastRunState = running
        }
        let recordBefore = await now.store.read(sessionID: load.session.id).record
        let runsBefore = try XCTUnwrap(recordBefore?.runAttempts)
        XCTAssertEqual(runsBefore.first { $0.runAttemptID == live.attemptID }?.appInstanceID, now.store.appInstanceID)
        XCTAssertEqual(runsBefore.first { $0.runAttemptID == crashed.attemptID }?.appInstanceID, earlier.store.appInstanceID)
        let legacyRun = try XCTUnwrap(runsBefore.first { $0.runAttemptID == legacy.attemptID })
        XCTAssertNil(legacyRun.appInstanceID, "A legacy attempt's absent instance survives a later write and is never backfilled")

        // A second owner of the same launch cold-hydrates the session.
        let hydratedLoad = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let hydrated = try XCTUnwrap(hydratedLoad)
        let turns = try XCTUnwrap(hydrated.session.transcript?.turns)
        let liveTurn = try XCTUnwrap(turns.first { $0.id == liveTurnID })
        XCTAssertEqual(liveTurn.terminalState, .running, "The current launch's live turn is never cancelled")
        XCTAssertNil(liveTurn.interruption, "The current launch's live turn is never stamped")
        XCTAssertNil(liveTurn.completedAt)
        XCTAssertEqual(hydrated.session.lastRunState, running, "The live run's saved state is not a previous execution's")
        let crashedTurn = try XCTUnwrap(turns.first { $0.id == crashedTurnID })
        XCTAssertEqual(crashedTurn.terminalState, .cancelled, "The rest of the record is still cold-restored")
        XCTAssertEqual(crashedTurn.interruption?.runAttemptID, crashed.attemptID)
        let legacyTurn = try XCTUnwrap(turns.first { $0.id == legacyTurnID })
        XCTAssertEqual(legacyTurn.terminalState, .cancelled, "No instance means an unknown owner, never the current launch")
        XCTAssertEqual(legacyTurn.interruption?.runAttemptID, legacy.attemptID)

        let saved = try readSessionFile(load)
        XCTAssertEqual(saved.transcript?.turns.first { $0.id == liveTurnID }?.terminalState, .running)
        XCTAssertNil(saved.transcript?.turns.first { $0.id == liveTurnID }?.interruption)
        XCTAssertEqual(saved.transcript?.turns.first { $0.id == crashedTurnID }?.interruption?.runAttemptID, crashed.attemptID)
        XCTAssertEqual(saved.transcript?.turns.first { $0.id == legacyTurnID }?.interruption?.runAttemptID, legacy.attemptID)
        XCTAssertEqual(saved.lastRunState, running)
        let recordAfter = await now.store.read(sessionID: load.session.id).record
        XCTAssertEqual(recordAfter?.runAttempts, runsBefore, "Hydration rewrites no run evidence and fabricates no terminal")

        // The same launch records the live run's window-close shutdown: it is no longer live.
        try await transact(now, hydrated) { store, binding in
            _ = try await store.recordRunShutdown(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                runAttemptID: live.attemptID,
                reason: .windowClose,
                lastConfirmedActivityAt: nil
            )
        }
        let rehydratedLoad = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let rehydrated = try XCTUnwrap(rehydratedLoad)
        let closedTurn = try XCTUnwrap(rehydrated.session.transcript?.turns.first { $0.id == liveTurnID })
        XCTAssertEqual(closedTurn.terminalState, .cancelled, "A stopped run of this launch is cold-restored")
        XCTAssertEqual(closedTurn.interruption?.reason, .windowClose)
        XCTAssertEqual(closedTurn.interruption?.runAttemptID, live.attemptID)
        XCTAssertNotEqual(rehydrated.session.lastRunState, running)
        let finalRun = await now.store.read(sessionID: load.session.id).record?.runAttempts.first { $0.runAttemptID == live.attemptID }
        XCTAssertNil(finalRun?.terminal, "Cold restoration never fabricates terminal evidence")
    }

    /// Review A F03 / B F7: an earlier launch's open turn whose run attempt committed authoritative
    /// ordinary terminal evidence (completed, even after a provisional Stage A `appQuit` shutdown
    /// reason; an ordinary failure; an ordinary cancel) is closed on cold hydration with that outcome
    /// and no interruption. The closed envelope is saved, and a later reload keeps it unchanged. A
    /// recorded interruption cause on a sibling turn is still stamped.
    func testColdHydrationClosesOrdinaryTerminalOutcomesWithoutInterruptionThroughSaveAndReload() async throws {
        let earlier = launch()
        let home = try makeWorkspace("ordinary-terminal")
        let completedTurnID = UUID()
        let failedTurnID = UUID()
        let cancelledTurnID = UUID()
        let interruptedTurnID = UUID()
        let load = try await makeSession(earlier, in: home, items: [
            AgentChatItem.user("completed", id: completedTurnID, sequenceIndex: 0),
            AgentChatItem.assistant("done", sequenceIndex: 1),
            AgentChatItem.user("failed", id: failedTurnID, sequenceIndex: 2),
            AgentChatItem.assistant("partial", sequenceIndex: 3),
            AgentChatItem.user("cancelled", id: cancelledTurnID, sequenceIndex: 4),
            AgentChatItem.assistant("partial", sequenceIndex: 5),
            AgentChatItem.user("interrupted", id: interruptedTurnID, sequenceIndex: 6),
            AgentChatItem.assistant("partial", sequenceIndex: 7)
        ])
        let completed = Support.ownership(sessionID: load.session.id)
        let failed = Support.ownership(sessionID: load.session.id)
        let cancelled = Support.ownership(sessionID: load.session.id)
        let interrupted = Support.ownership(sessionID: load.session.id)
        let runs = [
            (completed, completedTurnID, AgentSessionRunState.completed, AgentRunTerminalCause.ordinary),
            (failed, failedTurnID, .failed, .ordinary),
            (cancelled, cancelledTurnID, .cancelled, .ordinary),
            (interrupted, interruptedTurnID, .cancelled, .windowClose)
        ]
        try await transact(earlier, load) { store, binding in
            for (ownership, turnID, state, cause) in runs {
                _ = try await store.ensureRunAttempt(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    ownership: ownership,
                    processRunID: nil,
                    transcriptTurnID: turnID,
                    providerKindRaw: nil
                )
                if ownership == completed {
                    // Stage A recorded a provisional quit reason before the run completed.
                    _ = try await store.recordRunShutdown(
                        binding: binding,
                        expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                        runAttemptID: ownership.attemptID,
                        reason: .appQuit,
                        lastConfirmedActivityAt: nil
                    )
                }
                _ = try await store.recordRunTerminal(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    commit: Support.terminalCommit(ownership: ownership, state: state, cause: cause)
                )
            }
        }
        // The app crashed after the terminal commits but before the transcript save: every turn is
        // saved open.
        try rewriteSessionFile(load) { session in
            var transcript = try XCTUnwrap(session.transcript)
            XCTAssertEqual(transcript.turns.map(\.id), [completedTurnID, failedTurnID, cancelledTurnID, interruptedTurnID])
            for index in transcript.turns.indices {
                transcript.turns[index].terminalState = .running
                transcript.turns[index].completedAt = nil
                transcript.turns[index].interruption = nil
                XCTAssertFalse(transcript.turns[index].responseSpans.isEmpty)
                for spanIndex in transcript.turns[index].responseSpans.indices {
                    transcript.turns[index].responseSpans[spanIndex].lifecycle = .open
                    transcript.turns[index].responseSpans[spanIndex].completedAt = nil
                }
            }
            session.transcript = transcript
            session.lastRunState = AgentSessionRunState.running.rawValue
        }

        let now = launch()
        let hydratedLoad = try await now.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let hydrated = try XCTUnwrap(hydratedLoad)
        let expected: [UUID: AgentSessionRunState] = [
            completedTurnID: .completed,
            failedTurnID: .failed,
            cancelledTurnID: .cancelled
        ]
        func assertClosed(_ turns: [AgentTranscriptTurn], _ label: String) throws {
            for (turnID, outcome) in expected {
                let turn = try XCTUnwrap(turns.first { $0.id == turnID }, label)
                XCTAssertEqual(turn.terminalState, outcome, "\(label): closed with its authoritative outcome")
                XCTAssertNil(turn.interruption, "\(label): an ordinary outcome is never an interruption")
                XCTAssertNotNil(turn.completedAt, label)
                XCTAssertFalse(turn.responseSpans.contains { $0.lifecycle == .open }, label)
            }
            let control = try XCTUnwrap(turns.first { $0.id == interruptedTurnID }, label)
            XCTAssertEqual(control.terminalState, .cancelled, label)
            XCTAssertEqual(control.interruption?.reason, .windowClose, "\(label): a recorded interruption cause is still stamped")
            XCTAssertEqual(control.interruption?.runAttemptID, interrupted.attemptID, label)
        }
        try assertClosed(XCTUnwrap(hydrated.session.transcript?.turns), "hydrated")
        let saved = try readSessionFile(load)
        try assertClosed(XCTUnwrap(saved.transcript?.turns), "saved")
        XCTAssertEqual(
            Set(saved.transcript?.turns.first { $0.id == completedTurnID }?.responseSpans.map(\.lifecycle) ?? []),
            [.completed],
            "The completed turn's spans close completed, not cancelled"
        )
        XCTAssertEqual(
            Set(saved.transcript?.turns.first { $0.id == failedTurnID }?.responseSpans.map(\.lifecycle) ?? []),
            [.failed]
        )

        // A later launch reloads the saved envelope unchanged.
        let later = launch()
        let reloadedLoad = try await later.service.loadAgentSessionForEditing(id: load.session.id, for: home)
        let reloaded = try XCTUnwrap(reloadedLoad)
        try assertClosed(XCTUnwrap(reloaded.session.transcript?.turns), "reloaded")
        XCTAssertEqual(reloaded.session.transcript?.turns, hydrated.session.transcript?.turns, "Reload changes nothing")
    }

    /// Review A F03-R1: the "transcript tail may be missing" item of a turn saved open and closed as
    /// its ordinary outcome is durable on the turn itself, so a second fresh launch (which finds the
    /// turn already closed) still lists it. A turn that was saved closed is never marked. Dismiss is
    /// a durable card acknowledgement that an unrelated record write and a further launch keep.
    func testOrdinaryOutcomeTailWarningSurvivesFreshLaunchesUntilDismissed() async throws {
        let earlier = launch()
        let home = try makeWorkspace("tail-warning")
        let closedTurnID = UUID()
        let openTurnID = UUID()
        let load = try await makeSession(earlier, in: home, items: [
            AgentChatItem.user("saved closed", id: closedTurnID, sequenceIndex: 0),
            AgentChatItem.assistant("done", sequenceIndex: 1),
            AgentChatItem.user("saved open", id: openTurnID, sequenceIndex: 2),
            AgentChatItem.assistant("partial", sequenceIndex: 3)
        ])
        let closedRun = Support.ownership(sessionID: load.session.id)
        let openRun = Support.ownership(sessionID: load.session.id)
        try await transact(earlier, load) { store, binding in
            for (ownership, turnID) in [(closedRun, closedTurnID), (openRun, openTurnID)] {
                _ = try await store.ensureRunAttempt(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    ownership: ownership,
                    processRunID: nil,
                    transcriptTurnID: turnID,
                    providerKindRaw: nil
                )
                _ = try await store.recordRunTerminal(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    commit: Support.terminalCommit(ownership: ownership, state: .completed, cause: .ordinary)
                )
            }
        }
        // Crash after the last terminal commit, before the transcript save: only the last turn is open.
        try rewriteSessionFile(load) { _ = try self.openLastTurn(&$0) }

        // First fresh launch closes the open turn as completed and marks it durably.
        let first = launch()
        let firstResults = try await sweep(first, [home])
        let firstResolution = try XCTUnwrap(firstResults.resolution(for: load.session.id))
        XCTAssertEqual(firstResolution.outcomeTurns.map(\.turnID), [openTurnID], "Only the turn saved open is listed")
        XCTAssertTrue(firstResolution.interruptedTurns.isEmpty)
        let saved = try XCTUnwrap(readSessionFile(load).transcript?.turns)
        let savedOpen = try XCTUnwrap(saved.first { $0.id == openTurnID })
        XCTAssertEqual(savedOpen.terminalState, .completed)
        XCTAssertNil(savedOpen.interruption, "Never a fake interruption")
        XCTAssertEqual(savedOpen.recoveredOutcome?.runAttemptID, openRun.attemptID, "The obligation is durable on the turn")
        XCTAssertNil(saved.first { $0.id == closedTurnID }?.recoveredOutcome, "A turn saved closed is never marked uncertain")

        // Second fresh launch: the turn is already closed, and the item is still listed.
        let second = launch()
        let secondCoordinator = try await startedCoordinator(second, workspaces: [home])
        let secondResolution = try XCTUnwrap(secondCoordinator.reconciliation.resolution(for: load.session.id))
        XCTAssertEqual(secondResolution.outcomeTurns.map(\.turnID), [openTurnID], "Listed after another restart")
        XCTAssertEqual(secondResolution.outcomeTurns.first?.status, .completedTailMayBeMissing)
        func outcomeItem(_ coordinator: AgentRecoveryCoordinator) -> AgentRecoveryCatalogItem? {
            coordinator.catalog.items.first { item in
                if case let .outcomeTurn(outcome) = item.payload { return outcome.turnID == openTurnID }
                return false
            }
        }
        let item = try XCTUnwrap(outcomeItem(secondCoordinator))
        XCTAssertFalse(item.isDismissed)
        XCTAssertFalse(secondCoordinator.catalog.items.contains { item in
            if case let .outcomeTurn(outcome) = item.payload { return outcome.turnID == closedTurnID }
            return false
        })
        let dismissFailure = await secondCoordinator.dismissCatalogItem(item)
        XCTAssertNil(dismissFailure)
        XCTAssertEqual(outcomeItem(secondCoordinator)?.isDismissed, true)

        // An unrelated record write (a saved question) after the Dismiss.
        let binding = try XCTUnwrap(secondResolution.binding)
        _ = try await second.store.updateQuestionSnapshots(
            binding: binding,
            expectedRevision: second.store.currentRevision(sessionID: load.session.id),
            update: .init(upserting: [AgentRecoveryQuestionSnapshot(
                interactionID: UUID(),
                kind: .askUser,
                runAttemptID: nil,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                appInstanceID: second.store.appInstanceID,
                askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 5000),
                title: "Unrelated",
                message: nil,
                items: [],
                extras: [:]
            )])
        )

        // Third fresh launch: still the same obligation on disk, still dismissed.
        let third = launch()
        let thirdCoordinator = try await startedCoordinator(third, workspaces: [home])
        XCTAssertEqual(thirdCoordinator.reconciliation.resolution(for: load.session.id)?.outcomeTurns.map(\.turnID), [openTurnID])
        let kept = try XCTUnwrap(outcomeItem(thirdCoordinator))
        XCTAssertTrue(kept.isDismissed, "The Dismiss survives an unrelated write and another launch")
        XCTAssertEqual(try readSessionFile(load).transcript?.turns.first { $0.id == openTurnID }?.recoveredOutcome, savedOpen.recoveredOutcome)
    }

    // MARK: - Delegated child links (Step 5b)

    /// A parent's link committed before the child's dispatch (then a crash): the store joins only an
    /// exact repeat, refuses a conflicting child or a missing attempt, and after a restart the link
    /// is discovered under the admitted attempt's run card without resolving or recreating the
    /// child. Unknown link members survive later writes; a duplicate invocation is unreadable.
    func testDelegatedChildLinkCommittedBeforeDispatchIsDiscoveredAfterRestart() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let parent = try await makeSession(earlier, in: home)
        let ownership = Support.ownership(sessionID: parent.session.id)
        let invocationID = UUID()
        let childSessionID = UUID()
        let link = AgentRecoveryDelegatedChildLink(
            invocationID: invocationID,
            parentRunAttemptID: ownership.attemptID,
            childSessionID: childSessionID,
            linkedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        )

        try await transact(earlier, parent) { store, binding in
            do {
                _ = try await store.commitDelegatedChildLink(binding: binding, link: link)
                XCTFail("A link needs its recorded, open parent attempt")
            } catch AgentRecoveryStoreError.delegatedChildLinkIneligible(_) {}
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: UUID(),
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            let first = try await store.commitDelegatedChildLink(binding: binding, link: link)
            XCTAssertEqual(first.disposition, .committed)
            let repeated = try await store.commitDelegatedChildLink(binding: binding, link: link)
            XCTAssertEqual(repeated.disposition, .unchanged, "The same invocation and child is joined")
            let conflicting = AgentRecoveryDelegatedChildLink(
                invocationID: invocationID,
                parentRunAttemptID: ownership.attemptID,
                childSessionID: UUID(),
                linkedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000)
            )
            do {
                _ = try await store.commitDelegatedChildLink(binding: binding, link: conflicting)
                XCTFail("Another child for the same invocation conflicts")
            } catch let AgentRecoveryStoreError.delegatedChildLinkConflict(conflictID) {
                XCTAssertEqual(conflictID, invocationID)
            }
        }
        let committed = await earlier.store.read(sessionID: parent.session.id).record?.delegatedChildLinks
        XCTAssertEqual(committed, [link])

        // Crash before the child dispatch; the next launch discovers the link under its attempt.
        let next = launch()
        let coordinator = try await startedCoordinator(next, workspaces: [home])
        let item = try XCTUnwrap(coordinator.catalog.items.first { item in
            if case let .recoveryOnlyRun(attempt) = item.payload { return attempt.runAttemptID == ownership.attemptID }
            return false
        })
        XCTAssertEqual(item.sessionID, parent.session.id)
        XCTAssertEqual(item.actionFacts.delegatedChildLinks, [link])
        XCTAssertNil(coordinator.reconciliation.resolution(for: childSessionID), "A link never resolves or creates its child")

        // Unknown members of a link survive an unrelated write by a later launch.
        let fileURL = next.store.recordFileURL(sessionID: parent.session.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var links = try XCTUnwrap(object["delegatedChildLinks"] as? [[String: Any]])
        links[0]["futureLinkMember"] = "kept"
        object["delegatedChildLinks"] = links
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        let later = launch()
        let laterCoordinator = try await startedCoordinator(later, workspaces: [home])
        let binding = try XCTUnwrap(laterCoordinator.reconciliation.resolution(for: parent.session.id)?.binding)
        _ = try await later.store.updateQuestionSnapshots(
            binding: binding,
            expectedRevision: later.store.currentRevision(sessionID: parent.session.id),
            update: .init(upserting: [AgentRecoveryQuestionSnapshot(
                interactionID: UUID(),
                kind: .askUser,
                runAttemptID: nil,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                appInstanceID: later.store.appInstanceID,
                askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 5000),
                title: "Unrelated",
                message: nil,
                items: [],
                extras: [:]
            )])
        )
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let keptLinks = try XCTUnwrap(rewritten["delegatedChildLinks"] as? [[String: Any]])
        XCTAssertEqual(keptLinks.count, 1)
        XCTAssertEqual(keptLinks.first?["futureLinkMember"] as? String, "kept")
        XCTAssertEqual((keptLinks.first?["childSessionID"] as? String)?.uppercased(), childSessionID.uuidString)

        // A duplicate invocation link is never adopted.
        var duplicated = rewritten
        duplicated["delegatedChildLinks"] = keptLinks + keptLinks
        let duplicatedData = try JSONSerialization.data(withJSONObject: duplicated)
        guard case .failure = AgentRecoveryRecordCodec.decode(duplicatedData, expectedSessionID: parent.session.id) else {
            return XCTFail("A duplicate delegated child link is unreadable")
        }
    }

    // MARK: - Edit proposals (Step 5a)

    /// A reviewed `apply_edits` proposal committed before its review was shown (then a crash) is
    /// discovered exactly after a restart, with the session closed: historical only, never applied.
    /// The store joins only an exact repeat; unknown proposal members survive later writes; an
    /// unknown state and a duplicate review ID are unreadable.
    func testEditProposalCommittedBeforeReviewIsDiscoveredExactlyAfterRestart() async throws {
        let earlier = launch()
        let home = try makeWorkspace("home")
        let session = try await makeSession(earlier, in: home)
        let generation = try earlier.service.recoveryLifecycleGate(for: session.persistenceState).binding.transcriptResetGeneration
        let reviewID = UUID()
        let original = "let a = 1\n"
        let proposal = AgentRecoveryEditProposal(
            reviewID: reviewID,
            runAttemptID: nil,
            transcriptResetGeneration: generation,
            appInstanceID: earlier.store.appInstanceID,
            proposedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            physicalPath: "/tmp/project/Sources/A.swift",
            displayPath: "Sources/A.swift",
            unifiedDiff: "@@ -1 +1 @@\n-let a = 1\n+let a = 2\n",
            proposedText: "let a = 2\n",
            base: .preview(originalText: original)
        )
        XCTAssertEqual(proposal.base.domain, AgentRecoveryEditProposalBase.decodedTextDomain)
        XCTAssertEqual(proposal.base.matches(decodedText: original), true)
        XCTAssertEqual(proposal.base.matches(decodedText: "let a = 2\n"), false)

        try await transact(earlier, session) { store, binding in
            let first = try await store.commitEditProposal(binding: binding, proposal: proposal)
            XCTAssertEqual(first.disposition, .committed)
            let repeated = try await store.commitEditProposal(binding: binding, proposal: proposal)
            XCTAssertEqual(repeated.disposition, .unchanged, "The same review's own proposal is joined")
            let conflicting = AgentRecoveryEditProposal(
                reviewID: reviewID,
                runAttemptID: nil,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                appInstanceID: proposal.appInstanceID,
                proposedAt: proposal.proposedAt,
                physicalPath: proposal.physicalPath,
                displayPath: proposal.displayPath,
                unifiedDiff: proposal.unifiedDiff,
                proposedText: "let a = 3\n",
                base: proposal.base
            )
            do {
                _ = try await store.commitEditProposal(binding: binding, proposal: conflicting)
                XCTFail("Another proposal for the same review conflicts")
            } catch let AgentRecoveryStoreError.editProposalConflict(conflictID) {
                XCTAssertEqual(conflictID, reviewID)
            }
        }
        let committed = await earlier.store.read(sessionID: session.session.id).record?.editProposals
        XCTAssertEqual(committed, [proposal])

        // Crash before the review was answered; the next launch discovers the exact proposal.
        let next = launch()
        let coordinator = try await startedCoordinator(next, workspaces: [home])
        let item = try XCTUnwrap(coordinator.catalog.items.first { $0.kind == .pendingEditReview })
        XCTAssertEqual(item.id, AgentRecoveryCatalogProjection.editProposalItemID(sessionID: session.session.id, reviewID: reviewID))
        XCTAssertEqual(item.sessionID, session.session.id)
        XCTAssertNil(item.acknowledgement, "A proposal is never merely dismissed")
        guard case let .editProposal(discovered, isCurrentLaunch) = item.payload else {
            return XCTFail("The item carries the stored proposal")
        }
        XCTAssertEqual(discovered, proposal, "Exact proposed text, diff, paths, owner, and base evidence")
        XCTAssertFalse(isCurrentLaunch)
        XCTAssertEqual(discovered.state, .pending)

        // Unknown proposal and base members survive an unrelated write by a later launch.
        let fileURL = next.store.recordFileURL(sessionID: session.session.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var proposals = try XCTUnwrap(object["editProposals"] as? [[String: Any]])
        proposals[0]["futureProposalMember"] = "kept"
        var base = try XCTUnwrap(proposals[0]["base"] as? [String: Any])
        base["futureBaseMember"] = 7
        proposals[0]["base"] = base
        object["editProposals"] = proposals
        object["futureRecordMember"] = ["nested": true]
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        let later = launch()
        let laterCoordinator = try await startedCoordinator(later, workspaces: [home])
        let binding = try XCTUnwrap(laterCoordinator.reconciliation.resolution(for: session.session.id)?.binding)
        _ = try await later.store.updateQuestionSnapshots(
            binding: binding,
            expectedRevision: later.store.currentRevision(sessionID: session.session.id),
            update: .init(upserting: [AgentRecoveryQuestionSnapshot(
                interactionID: UUID(),
                kind: .askUser,
                runAttemptID: nil,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                appInstanceID: later.store.appInstanceID,
                askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 5000),
                title: "Unrelated",
                message: nil,
                items: [],
                extras: [:]
            )])
        )
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let kept = try XCTUnwrap(rewritten["editProposals"] as? [[String: Any]])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["futureProposalMember"] as? String, "kept")
        XCTAssertEqual((kept.first?["base"] as? [String: Any])?["futureBaseMember"] as? Int, 7)
        XCTAssertEqual(kept.first?["proposedText"] as? String, "let a = 2\n")
        XCTAssertNotNil(rewritten["futureRecordMember"], "Unrelated record fields survive")

        // An unknown state and a duplicate review ID are never adopted.
        var unknownState = rewritten
        var unknownProposals = kept
        unknownProposals[0]["state"] = "appliedByFutureBuild"
        unknownState["editProposals"] = unknownProposals
        let unknownStateData = try JSONSerialization.data(withJSONObject: unknownState)
        guard case .failure = AgentRecoveryRecordCodec.decode(unknownStateData, expectedSessionID: session.session.id) else {
            return XCTFail("An unknown proposal state is unreadable")
        }
        var duplicated = rewritten
        duplicated["editProposals"] = kept + kept
        let duplicatedData = try JSONSerialization.data(withJSONObject: duplicated)
        guard case .failure = AgentRecoveryRecordCodec.decode(duplicatedData, expectedSessionID: session.session.id) else {
            return XCTFail("A duplicate edit proposal is unreadable")
        }
    }

    // MARK: - Fixtures

    private func launch() -> Launch {
        let store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        return Launch(store: store, service: service)
    }

    private func makeWorkspace(_ name: String) throws -> AgentRecoveryWorkspaceDestination {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let workspace = AgentRecoveryWorkspaceDestination(id: UUID(), name: name, customStoragePath: url)
        sessionFolders[workspace.id] = url.appendingPathComponent("AgentSessions", isDirectory: true)
        return workspace
    }

    private func makeSession(
        _ launch: Launch,
        in workspace: AgentRecoveryWorkspaceDestination,
        items: [AgentChatItem] = [AgentChatItem.user("hello", sequenceIndex: 0)]
    ) async throws -> AgentSessionEditableLoad {
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Recovery"
        ).withItems(items)
        return try await launch.service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: items.count
        )
    }

    private func resetTranscript(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        in workspace: AgentRecoveryWorkspaceDestination
    ) async throws -> AgentSessionSaveCommit {
        try await launch.service.saveAgentSession(
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

    private func candidate(_ load: AgentSessionEditableLoad) throws -> AgentSessionDeletionCandidate {
        try AgentSessionDeletionCandidate(
            composeTabID: XCTUnwrap(load.session.composeTabID),
            persistenceState: load.persistenceState
        )
    }

    /// Runs `body` as a recovery transaction under the session's DataService gate.
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

    private func commitQueued(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        _ submission: AgentRecoveryIntentSubmission
    ) async throws {
        try await transact(launch, load) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
        }
    }

    /// A session whose last saved turn is open, with no recovery record (legacy).
    private func makeOpenLegacySession(
        _ launch: Launch,
        in workspace: AgentRecoveryWorkspaceDestination
    ) async throws -> AgentSessionEditableLoad {
        let load = try await makeSession(launch, in: workspace)
        try rewriteSessionFile(load) { _ = try self.openLastTurn(&$0) }
        return load
    }

    private func dispatch(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        _ submission: AgentRecoveryIntentSubmission,
        outcome: AgentRecoveryDeliveryOutcome
    ) async throws {
        try await transact(launch, load) { store, binding in
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
            let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
            _ = try await store.beginDispatch(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: submission.intentID,
                attempt: attempt,
                authorization: .liveQueue
            )
            _ = try await store.recordDeliveryOutcome(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: submission.intentID,
                attemptID: attempt.attemptID,
                outcome: outcome
            )
        }
    }

    private func sweep(
        _ launch: Launch,
        _ workspaces: [AgentRecoveryWorkspaceDestination]
    ) async throws -> AgentRecoveryStartupReconciliation {
        let entries = try await launch.store.discoverRecords()
        return await AgentRecoveryStartupSweep.run(
            inventory: AgentRecoveryWorkspaceInventory(workspaces: workspaces),
            entries: entries,
            dataService: launch.service
        )
    }

    /// A coordinator composed as in production (real sweep), started and awaited to `.ready`.
    private func startedCoordinator(
        _ launch: Launch,
        workspaces: [AgentRecoveryWorkspaceDestination]
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
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    private func dispatchingSchedule() -> AgentScheduledSendPersist {
        let start = Date(timeIntervalSince1970: 100)
        return AgentScheduledSendPersist(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            notBefore: start.addingTimeInterval(60),
            state: .dispatching,
            rawText: "scheduled",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            attempt: AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        )
    }

    private func scheduledSubmission(
        _ schedule: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt
    ) -> AgentRecoveryIntentSubmission {
        Support.submission(
            schedule.rawText,
            userItemID: attempt.itemID,
            origin: .scheduled,
            scheduleReference: AgentScheduledSendTransfer.recoveryScheduleReference(scheduleID: schedule.id, attempt: attempt)
        )
    }

    // MARK: Session files

    /// The session's file in the fixture workspace it was created in.
    private func sessionFileURL(_ load: AgentSessionEditableLoad) throws -> URL {
        let workspaceID = try XCTUnwrap(load.session.workspaceID)
        let folder = try XCTUnwrap(sessionFolders[workspaceID])
        return folder.appendingPathComponent("AgentSession-\(load.session.id.uuidString).json")
    }

    private func readSessionFile(_ load: AgentSessionEditableLoad) throws -> AgentSession {
        try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionFileURL(load)))
    }

    /// Rewrites the saved session as a crashed launch left it (bypassing the DataService).
    private func rewriteSessionFile(
        _ load: AgentSessionEditableLoad,
        _ mutate: (inout AgentSession) throws -> Void
    ) throws {
        var session = try readSessionFile(load)
        try mutate(&session)
        try AgentSessionDataCodec.encodeSession(session).write(to: sessionFileURL(load), options: .atomic)
    }

    /// Re-opens the last saved turn, as a session saved mid-run looks after a crash.
    private func openLastTurn(_ session: inout AgentSession) throws -> UUID {
        var transcript = try XCTUnwrap(session.transcript)
        let index = try XCTUnwrap(transcript.turns.indices.last)
        transcript.turns[index].terminalState = .running
        transcript.turns[index].completedAt = nil
        transcript.turns[index].interruption = nil
        session.transcript = transcript
        session.lastRunState = AgentSessionRunState.running.rawValue
        return transcript.turns[index].id
    }

    private func copySessionFile(_ load: AgentSessionEditableLoad, into workspace: AgentRecoveryWorkspaceDestination) throws {
        let source = try sessionFileURL(load)
        let folder = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
    }
}
