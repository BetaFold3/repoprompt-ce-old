import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless-restart Phase 1b production composition and basic recovery list: one store and one
/// gated DataService per composition, scheduler admission closed until reconciliation is ready,
/// fail-closed dependency and index failures with Retry, and recovery-list actions that revalidate
/// the durable record and never replace newer typing. Every store, DataService, workspace, and
/// workspace index is an injected temporary directory (production composition is inactive here).
@MainActor
final class AgentRecoveryStartupCompositionTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private struct Fixture {
        let root: URL
        let recoveryRoot: URL
        let storageURL: URL
        let workspace: WorkspaceModel

        var destination: AgentRecoveryWorkspaceDestination {
            AgentRecoveryWorkspaceDestination(
                id: workspace.id,
                name: workspace.name,
                customStoragePath: workspace.customStoragePath
            )
        }
    }

    private struct Launch {
        let store: AgentRecoveryStore
        let service: AgentSessionDataService
    }

    // MARK: - Recovery list (UI / CAS)

    func testRecoveryListEditKeepsNewerTypingAndAFailedRemovalKeepsTheRowVisible() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        // Earlier launch: held input in a closed session, and a session whose record is unreadable.
        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let submission = Support.submission("held input")
        try await commitQueued(earlier, load, submission)
        let unreadable = try await makeSession(earlier, fixture: fixture)
        try await commitQueued(earlier, unreadable, Support.submission("unreadable input"))
        let unreadableURL = earlier.store.recordFileURL(sessionID: unreadable.session.id)
        try Data("{ not a recovery record".utf8).write(to: unreadableURL, options: .atomic)
        let unreadableBytes = try Data(contentsOf: unreadableURL)
        // A run whose transcript turn was never saved: listed from its recovery evidence alone.
        let unsaved = try await makeSession(earlier, fixture: fixture)
        let unsavedOwnership = Support.ownership(sessionID: unsaved.session.id)
        let unsavedGate = try earlier.service.recoveryLifecycleGate(for: unsaved.persistenceState)
        let earlierStore = earlier.store
        let unsavedBinding = unsavedGate.binding
        try await unsavedGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: unsavedBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: unsavedBinding.sessionID),
                ownership: unsavedOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }

        // This launch: production-shaped composition installed before anything hydrates.
        let failures = RecoveryStoreWriteFailureSwitch()
        let now = makeLaunch(fixture, failures: failures)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4801, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        XCTAssertEqual(session.activeAgentSessionID, load.session.id)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed, "Hydration claims the session's lane")

        let rowID = "intent-\(load.session.id.uuidString)-\(submission.intentID.uuidString)"
        func row() -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == rowID }
        }
        XCTAssertEqual(row()?.text, "held input")
        XCTAssertEqual(row()?.actions, [.edit, .remove, .dismiss])

        // Phase 2: the banner is the active session's exact catalog filter; other sessions'
        // needs-action items are counted there (O34-1: informational run notes are not) and every
        // item is listed in the app-wide Needs Attention sheet.
        let statusRowID = "status-\(unreadable.session.id.uuidString)"
        let runRowID = "run-\(unsaved.session.id.uuidString)-\(unsavedOwnership.attemptID.uuidString)"
        let banner = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        XCTAssertFalse(banner.rows.contains { $0.id == statusRowID || $0.id == runRowID })
        let listCoordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        XCTAssertEqual(listCoordinator.catalog.item(id: statusRowID)?.attention, .needsAction)
        XCTAssertEqual(listCoordinator.catalog.item(id: runRowID)?.attention, .informational)
        XCTAssertGreaterThanOrEqual(banner.otherItemCount, 1)
        XCTAssertEqual(
            banner.otherItemCount,
            listCoordinator.catalog.items.count { $0.isOpenNeedsAction && $0.sessionID != load.session.id },
            "\(listCoordinator.catalog.items.map { "\($0.id) \($0.attention)" })"
        )
        func sheetRow(_ id: String, includeDismissed: Bool = false) -> AgentRecoveryNeedsAttentionRow? {
            viewModel.recoveryNeedsAttentionRows(includeDismissed: includeDismissed, activeSession: session).first { $0.id == id }
        }

        // Unreadable recovered data is listed view-only (not dismissible) and left unchanged.
        let statusRow = sheetRow(statusRowID)?.row
        XCTAssertEqual(statusRow?.title, "Recovery status unknown")
        XCTAssertEqual(statusRow?.actions, [])
        XCTAssertEqual(try Data(contentsOf: unreadableURL), unreadableBytes)
        let runRow = sheetRow(runRowID)?.row
        XCTAssertEqual(runRow?.title, "Run interrupted before it was saved")
        XCTAssertEqual(runRow?.actions.first, .dismiss)

        // Dismiss of a closed session's card is durable (under its persistence gate) and changes
        // nothing else: the run evidence stays open and the item is still listed as dismissed.
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .dismiss)
        let dismissed = await Support.eventually { sheetRow(runRowID) == nil }
        XCTAssertTrue(dismissed, String(describing: viewModel.recoveryCoordinator?.catalogActionStates[runRowID]))
        XCTAssertEqual(sheetRow(runRowID, includeDismissed: true)?.isDismissed, true)
        let unsavedRecord = await now.store.read(sessionID: unsaved.session.id).record
        XCTAssertEqual(unsavedRecord?.cardAcknowledgements.map(\.key.entityID), [unsavedOwnership.attemptID.uuidString])
        XCTAssertNil(unsavedRecord?.runAttempts.first?.terminal, "Dismiss resolves nothing")

        // Edit never replaces newer typing; the source stays saved.
        viewModel.storeDraftText(for: tabID, "newer typing")
        await viewModel.performRecoveryListAction(rowID: rowID, action: .edit)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "newer typing")
        XCTAssertNotNil(row()?.error)
        let afterEdit = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterEdit, .queued)

        // A failed withdrawal leaves the row and its source in place.
        failures.shouldFailWrites = true
        await viewModel.performRecoveryListAction(rowID: rowID, action: .remove)
        failures.shouldFailWrites = false
        let failedRow = try XCTUnwrap(row(), "The row stays until the withdrawal commits")
        XCTAssertTrue(failedRow.error?.contains("couldn't be removed") == true, String(describing: failedRow.error))
        XCTAssertFalse(failedRow.isWorking)
        let afterFailure = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterFailure, .queued)

        // Repeating the action commits the withdrawal, then the row disappears.
        await viewModel.performRecoveryListAction(rowID: rowID, action: .remove)
        XCTAssertNil(row())
        let afterRemoval = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterRemoval, .withdrawn)
        XCTAssertEqual(try Data(contentsOf: unreadableURL), unreadableBytes)
    }

    /// Review B F5, F10 and cross-workspace Open: rows resolve their session from the catalog (the
    /// paused indicator's "It stopped" confirms the dismissed crash hold; a schedule row opens its
    /// session); an item in another workspace opens through the agent-session route with its exact
    /// workspace, tab, and session; and items only elsewhere keep the banner reachable.
    func testRecoveryListRowsResolveSessionsFromTheCatalogAndOpenAcrossWorkspaces() async throws {
        let fixture = try makeFixture()
        let otherStorage = fixture.root.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let other = WorkspaceModel(name: "Other Workspace", repoPaths: [otherStorage.path], customStoragePath: otherStorage)
        let otherDestination = AgentRecoveryWorkspaceDestination(id: other.id, name: other.name, customStoragePath: otherStorage)
        let tabID = UUID()

        // Earlier launch (no clean exit): a run in flight in this workspace's session (a crash
        // hold), and in another workspace an interrupted run and a schedule awaiting confirmation.
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store
        let held = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let heldOwnership = Support.ownership(sessionID: held.session.id)
        let heldGate = try earlier.service.recoveryLifecycleGate(for: held.persistenceState)
        let heldBinding = heldGate.binding
        try await heldGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                ownership: heldOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await earlierStore.commitDispatchingIntent(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                submission: Support.submission("in flight at crash"),
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: heldOwnership.attemptID),
                consumption: nil
            )
        }
        let elsewhereTabID = UUID()
        let elsewhere = try await makeSession(earlier, fixture: fixture, workspace: other, composeTabID: elsewhereTabID)
        let elsewhereOwnership = Support.ownership(sessionID: elsewhere.session.id)
        let elsewhereGate = try earlier.service.recoveryLifecycleGate(for: elsewhere.persistenceState)
        let elsewhereBinding = elsewhereGate.binding
        let question = AgentRecoveryQuestionSnapshot(
            interactionID: UUID(),
            kind: .askUser,
            runAttemptID: elsewhereOwnership.attemptID,
            transcriptResetGeneration: elsewhereBinding.transcriptResetGeneration,
            appInstanceID: UUID(),
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            title: "Question",
            message: nil,
            items: [AgentRecoveryQuestionItem(
                questionID: "target", header: nil, text: "Which environment?", options: [], isSecret: false, answer: "staging"
            )],
            extras: [:]
        )
        try await elsewhereGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: elsewhereBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: elsewhereBinding.sessionID),
                ownership: elsewhereOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await earlierStore.updateQuestionSnapshots(
                binding: elsewhereBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: elsewhereBinding.sessionID),
                update: AgentRecoveryStore.QuestionSnapshotUpdate(upserting: [question], removing: [])
            )
        }
        let scheduledTabID = UUID()
        let scheduled = try await makeSession(earlier, fixture: fixture, workspace: other, composeTabID: scheduledTabID)
        let notBefore = Date(timeIntervalSince1970: 1000)
        let schedule = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: notBefore.addingTimeInterval(-60),
            updatedAt: notBefore,
            notBefore: notBefore,
            state: .needsConfirmation,
            confirmationReason: .missedWhileClosed,
            rawText: "scheduled elsewhere",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false
        )
        let sessionsFolder = otherStorage.appendingPathComponent("AgentSessions", isDirectory: true)
        let scheduledURL = sessionsFolder.appendingPathComponent("AgentSession-\(scheduled.session.id.uuidString).json")
        var saved = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: scheduledURL))
        saved.scheduledSend = .v1(schedule)
        try AgentSessionDataCodec.encodeSession(saved).write(to: scheduledURL, options: .atomic)
        try? FileManager.default.removeItem(at: sessionsFolder.appendingPathComponent("AgentSessionIndex.json"))
        _ = try await makeLaunch(fixture).service.indexedAgentSessionMetadataRecords(for: otherDestination)

        // This launch: both workspaces are inventoried; this window shows the first one.
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destinations = [fixture.destination, otherDestination]
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: destinations) }
        )
        let viewModel = makeViewModel(windowID: 4811, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)

        let runRowID = "run-\(elsewhere.session.id.uuidString)-\(elsewhereOwnership.attemptID.uuidString)"
        let scheduleRowID = "schedule-\(scheduled.session.id.uuidString)-\(schedule.id.uuidString)"
        let listed = await Support.eventually {
            coordinator.catalog.item(id: runRowID) != nil && coordinator.catalog.item(id: scheduleRowID) != nil
        }
        XCTAssertTrue(listed, "\(coordinator.catalog.items.map(\.id))")

        // B F2: a saved question never claims it went unanswered (its answer may have been sent).
        let questionRowID = AgentModeViewModel.recoveryListQuestionRowID(
            sessionID: elsewhere.session.id, interactionID: question.interactionID
        )
        let questionRow = try XCTUnwrap(
            viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil).first { $0.id == questionRowID },
            "\(coordinator.catalog.items.map(\.id))"
        )
        XCTAssertTrue(questionRow.isOtherWorkspace)
        XCTAssertEqual(questionRow.row.title, "Expired question")
        XCTAssertTrue(questionRow.row.detail.contains("Whether an answer reached the agent is uncertain"), questionRow.row.detail)
        XCTAssertFalse(questionRow.row.title.localizedCaseInsensitiveContains("unanswered"))
        XCTAssertFalse(questionRow.row.detail.localizedCaseInsensitiveContains("before it was answered"))
        XCTAssertEqual(questionRow.row.actions, [.open, .dismiss])

        // O34-1 (replaces F10): with nothing for the active (here no) session, items elsewhere never
        // keep the banner; they stay reachable from the sidebar badge and the View menu, which count
        // needs-action items only.
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: nil), "Items elsewhere never keep the banner")
        let undismissed = coordinator.catalog.items.filter { !$0.isDismissed }
        let summary = undismissed.map { "\($0.id) \($0.attention)" }
        XCTAssertEqual(undismissed.count, 7, "The fixture's undismissed items, none in this (no) session: \(summary)")
        XCTAssertEqual(coordinator.catalog.item(id: runRowID)?.attention, .informational)
        XCTAssertEqual(coordinator.catalog.item(id: scheduleRowID)?.attention, .needsAction)
        XCTAssertEqual(coordinator.catalog.item(id: questionRowID)?.attention, .needsAction)
        XCTAssertEqual(viewModel.recoveryNeedsAttentionCount, undismissed.count { $0.attention == .needsAction }, "\(summary)")
        XCTAssertLessThan(viewModel.recoveryNeedsAttentionCount, undismissed.count, "Informational notes are not counted")

        // Cross-workspace Open (run and schedule rows) uses the exact agent-session route.
        final class Routes {
            var routes: [AgentSessionDeepLinkRoute] = []
            var result: AgentSessionRouteResult = .routed
        }
        let routes = Routes()
        viewModel.recoveryListRouteToSession = { route in
            routes.routes.append(route)
            return routes.result
        }
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .open)
        XCTAssertNil(coordinator.catalogActionStates[runRowID])
        await viewModel.performRecoveryListAction(rowID: scheduleRowID, action: .open)
        XCTAssertNil(coordinator.catalogActionStates[scheduleRowID], "A schedule row resolves its session from the catalog")
        XCTAssertEqual(routes.routes, [
            AgentSessionDeepLinkRoute(workspaceID: other.id, tabID: elsewhereTabID, sessionID: elsewhere.session.id),
            AgentSessionDeepLinkRoute(workspaceID: other.id, tabID: scheduledTabID, sessionID: scheduled.session.id)
        ])
        routes.result = .workspaceUnavailable
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .open)
        guard case .failed = coordinator.catalogActionStates[runRowID] else {
            return XCTFail("A failed route is reported on the row: \(String(describing: coordinator.catalogActionStates[runRowID]))")
        }
        XCTAssertTrue(viewModel.sessions.isEmpty, "Opening elsewhere hydrates nothing in this window")

        // F5: the paused indicator of a dismissed crash hold confirms exactly that hold.
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != held.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: held.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        XCTAssertNotNil(coordinator.crashHold(for: held.session.id))
        let crash = try XCTUnwrap(coordinator.catalog.items.first { $0.sessionID == held.session.id && $0.kind == .crashHold })
        await viewModel.performRecoveryListAction(rowID: crash.id, action: .dismiss)
        let dismissed = await Support.eventually { coordinator.catalog.item(id: crash.id)?.isDismissed == true }
        XCTAssertTrue(dismissed, String(describing: coordinator.catalogActionStates[crash.id]))
        XCTAssertEqual(coordinator.catalog.blockers[held.session.id], .crashHold, "Dismiss lifts nothing")
        // F2: the new-session gate and its itemized reason still name the dismissed crash hold.
        let heldWorkspaceID = fixture.workspace.id
        XCTAssertTrue(viewModel.hasUnresolvedRecoverySession(inWorkspace: heldWorkspaceID, excluding: UUID()))
        XCTAssertEqual(
            coordinator.unresolvedSessionSummary(inWorkspace: heldWorkspaceID, excluding: UUID()).crashHeldSessionIDs,
            [held.session.id]
        )
        XCTAssertTrue(
            viewModel.scheduledSendRecoveryBlocker(inWorkspace: heldWorkspaceID, excluding: UUID())?
                .interruptedSessionIDs.contains(held.session.id) == true,
            "Dismiss does not clear the new-session gate"
        )
        let pausedRowID = "\(AgentModeViewModel.recoveryListPausedRowPrefix)\(held.session.id.uuidString)"
        let pausedProps = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        let paused = try XCTUnwrap(pausedProps.rows.first { $0.id == pausedRowID })
        // F3: the dismissed crash hold's indicator is this session's item; items elsewhere stay distinct.
        // O34-1: the banner keeps the paused indicator and the uncertain input; the session's run
        // note (informational) moved to the sheet's Information section, and the elsewhere count
        // excludes the other workspace's informational run note.
        XCTAssertEqual(pausedProps.rows.count, 2, pausedProps.rows.map(\.id).description)
        XCTAssertFalse(pausedProps.rows.contains { $0.id.hasPrefix("turn-") || $0.id.hasPrefix("run-") }, pausedProps.rows.map(\.id).description)
        XCTAssertTrue(coordinator.catalog.items.contains { $0.sessionID == held.session.id && $0.attention == .informational })
        XCTAssertEqual(pausedProps.otherItemCount, 3)
        XCTAssertEqual(
            pausedProps.headerText,
            "2 saved or interrupted items in this session need your attention. 3 items elsewhere need attention."
        )
        XCTAssertTrue(paused.actions.contains(.confirmStopped))
        XCTAssertFalse(paused.actions.contains(.dismiss), "The paused indicator is not dismissible")
        await viewModel.performRecoveryListAction(rowID: pausedRowID, action: .confirmStopped)
        XCTAssertNil(coordinator.catalogActionStates[pausedRowID], "It stopped resolves the hold's session from the catalog")
        let lifted = await Support.eventually { coordinator.catalog.blockers[held.session.id] == nil }
        XCTAssertTrue(lifted)
        XCTAssertTrue(
            coordinator.unresolvedSessionSummary(inWorkspace: heldWorkspaceID, excluding: UUID()).crashHeldSessionIDs.isEmpty,
            "It stopped clears the crash hold behind the new-session gate"
        )
        XCTAssertFalse(
            viewModel.scheduledSendRecoveryBlocker(inWorkspace: heldWorkspaceID, excluding: UUID())?
                .interruptedSessionIDs.contains(held.session.id) ?? false
        )
        let acknowledgement = await now.store.read(sessionID: held.session.id).record?.crashHoldAcknowledgement
        XCTAssertNotNil(acknowledgement)
    }

    /// Lossless restart F2 / review B F2-R7, real host end to end: a real startup crash hold blocks
    /// an overdue-style new-session Send now (Run alongside included), the banner names the fix,
    /// Dismiss changes nothing, and It stopped on that exact hold sends the consented message once.
    func testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce() async throws {
        let fixture = try makeFixture()
        let heldTabID = UUID()

        // Earlier launch (no clean exit): a run was in flight in this workspace's session.
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store
        let held = try await makeSession(earlier, fixture: fixture, composeTabID: heldTabID)
        let heldOwnership = Support.ownership(sessionID: held.session.id)
        let heldGate = try earlier.service.recoveryLifecycleGate(for: held.persistenceState)
        let heldBinding = heldGate.binding
        try await heldGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                ownership: heldOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await earlierStore.commitDispatchingIntent(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                submission: Support.submission("in flight at crash"),
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: heldOwnership.attemptID),
                consumption: nil
            )
        }

        // This launch: the real composition, store, coordinator, and scheduler.
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destinations = [fixture.destination]
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: destinations) }
        )
        let viewModel = makeViewModel(windowID: 4812, fixture: fixture)
        viewModel.test_initializeRunService()
        composition.install(into: viewModel)
        viewModel.attachScheduledSendCoordinator(scheduler)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)

        viewModel.test_setCurrentTabIDOverride(heldTabID)
        let heldTab = try await viewModel.ensureSessionReady(tabID: heldTabID)
        if heldTab.activeAgentSessionID != held.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: held.session.id, on: heldTab))
            _ = await viewModel.test_hydrateBoundSession(tabID: heldTabID)
        }
        let heldLaneClaimed = await Support.eventually { heldTab.recoveryLane != nil }
        XCTAssertTrue(heldLaneClaimed)
        XCTAssertNotNil(coordinator.crashHold(for: held.session.id))

        // Another tab in the same workspace schedules a new-session start.
        let scheduledTabID = UUID()
        let scheduledTab = try await viewModel.ensureSessionReady(tabID: scheduledTabID)
        scheduledTab.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: scheduledTabID)
        XCTAssertTrue(saved)
        XCTAssertNotNil(scheduledTab.recoveryLane, "The first save claims the scheduled session's lane")
        final class Starts {
            var count = 0
        }
        let starts = Starts()
        viewModel.scheduledDispatchRunStarter = { [starts] _, _, _, _ in
            starts.count += 1
            return .stale(reason: "test starter")
        }
        let scheduleID = try await viewModel.installScheduledSend(
            text: "Start after the interrupted session",
            on: scheduledTab,
            notBefore: Date().addingTimeInterval(3600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: true
        ).get()

        let message = await viewModel.sendScheduledSendNow(
            tabID: scheduledTabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: true
        )
        XCTAssertNil(message, "Consent is recorded; the blocker is shown in the banner")
        let blocked = await Support.eventually {
            scheduler.recoveryBlocker(scheduleID: scheduleID)?.interruptedSessionIDs == [held.session.id]
        }
        XCTAssertTrue(blocked, "\(scheduler.disposition(scheduleID: scheduleID))")
        let expectedBanner =
            "Will send after 1 interrupted session in this workspace is resolved: choose It stopped (not Dismiss) in Needs Attention…"
        XCTAssertEqual(viewModel.makeComposerProps(tabID: scheduledTabID).scheduledSend?.recoveryBlockedMessage, expectedBanner)
        XCTAssertEqual(starts.count, 0, "Run alongside never bypasses the recovery gate")

        // Dismiss lifts nothing.
        let crash = try XCTUnwrap(coordinator.catalog.items.first { $0.sessionID == held.session.id && $0.kind == .crashHold })
        await viewModel.performRecoveryListAction(rowID: crash.id, action: .dismiss)
        let dismissed = await Support.eventually { coordinator.catalog.item(id: crash.id)?.isDismissed == true }
        XCTAssertTrue(dismissed)
        scheduler.recordDidChange()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(starts.count, 0, "Dismiss does not release the schedule")
        XCTAssertEqual(viewModel.makeComposerProps(tabID: scheduledTabID).scheduledSend?.recoveryBlockedMessage, expectedBanner)

        // It stopped on that exact hold: the consented message is sent once.
        let pausedRowID = "\(AgentModeViewModel.recoveryListPausedRowPrefix)\(held.session.id.uuidString)"
        await viewModel.performRecoveryListAction(rowID: pausedRowID, action: .confirmStopped)
        XCTAssertNil(coordinator.catalogActionStates[pausedRowID])
        let sent = await Support.eventually { starts.count == 1 }
        XCTAssertTrue(sent, "\(scheduler.disposition(scheduleID: scheduleID))")
        XCTAssertNil(scheduler.recoveryBlocker(scheduleID: scheduleID))
        scheduler.recordDidChange()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(starts.count, 1, "Exactly one dispatch")
    }

    /// Step 9-activation-b (review A P2-02, B A7): the same already-authorized new-session Send now
    /// stays undispatched while Check confirms the crash hold from process records (the hold's run
    /// was registered at run start and its only earlier-launch record exited), and dispatches
    /// exactly once after the acknowledgement commits. The held session is never opened.
    func testCrashHoldBlocksNewSessionSendNowUntilCheckConfirmsItThenDispatchesOnce() async throws {
        let fixture = try makeFixture()
        let processes = ScriptedProcessSystem()

        // Earlier launch (no clean exit): a registered run was in flight in this workspace's session.
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store
        let held = try await makeSession(earlier, fixture: fixture)
        let heldOwnership = Support.ownership(sessionID: held.session.id)
        let heldGate = try earlier.service.recoveryLifecycleGate(for: held.persistenceState)
        let heldBinding = heldGate.binding
        try await heldGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                ownership: heldOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: AgentProviderKind.claudeCode.rawValue,
                runtimeRegistrationRaw: AgentRecoveryRunAttempt.registeredRuntimeRegistration
            )
        }
        try AgentProcessRegistryFixtures.seed(
            rootURL: fixture.recoveryRoot,
            state: .exited,
            root: processes.identity(pid: 7100),
            rootGroup: 7100,
            associations: [AgentRuntimeAssociation(
                session: AgentRuntimeSessionAssociation(lifecycle: heldBinding, runAttemptID: heldOwnership.attemptID, processRunID: nil),
                conversationID: "conv-held",
                worktreePath: fixture.storageURL.path,
                permission: .unavailable
            )],
            conversationIDs: ["conv-held"],
            worktreePaths: [fixture.storageURL.path]
        )

        // This launch: the real composition with a registry over its store (scripted processes).
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destinations = [fixture.destination]
        let registry = AgentProcessRegistry(
            store: now.store,
            qualification: AgentRecoveryActivation.claudeAndCodex.runtime,
            system: processes.system
        )
        addTeardownBlock { await registry.disposeWatches() }
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            processRegistry: registry,
            activation: .claudeAndCodex,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: destinations) }
        )
        let viewModel = makeViewModel(windowID: 4813, fixture: fixture)
        viewModel.test_initializeRunService()
        composition.install(into: viewModel)
        viewModel.attachScheduledSendCoordinator(scheduler)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        XCTAssertNotNil(coordinator.blockingCrashHold(for: heldBinding))

        // Another tab in the same workspace schedules a new-session start and sends it now.
        let scheduledTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(scheduledTabID)
        let scheduledTab = try await viewModel.ensureSessionReady(tabID: scheduledTabID)
        scheduledTab.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: scheduledTabID)
        XCTAssertTrue(saved)
        final class Starts {
            var count = 0
        }
        let starts = Starts()
        viewModel.scheduledDispatchRunStarter = { [starts] _, _, _, _ in
            starts.count += 1
            return .stale(reason: "test starter")
        }
        let scheduleID = try await viewModel.installScheduledSend(
            text: "Start after the interrupted session",
            on: scheduledTab,
            notBefore: Date().addingTimeInterval(3600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: true
        ).get()
        let message = await viewModel.sendScheduledSendNow(
            tabID: scheduledTabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: true
        )
        XCTAssertNil(message, "Consent is recorded; the blocker is shown in the banner")
        let blocked = await Support.eventually {
            scheduler.recoveryBlocker(scheduleID: scheduleID)?.interruptedSessionIDs == [held.session.id]
        }
        XCTAssertTrue(blocked, "\(scheduler.disposition(scheduleID: scheduleID))")
        XCTAssertEqual(starts.count, 0)

        // Check confirms the hold; just before its acknowledgement write, nothing has been sent.
        final class Paused {
            var startsBeforeCommit: Int?
        }
        let paused = Paused()
        coordinator.test_crashHoldProofAtCommit = { [scheduler, starts, paused] in
            scheduler.recordDidChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            paused.startsBeforeCommit = starts.count
        }
        let crash = try XCTUnwrap(coordinator.catalog.items.first { $0.sessionID == held.session.id && $0.kind == .crashHold })
        let status = await coordinator.checkCatalogItems([crash], checksActive: true) { _ in
            XCTFail("a crash hold is never reconciled")
            return .notAttempted("no reconcile")
        }
        XCTAssertEqual(paused.startsBeforeCommit, 0, "the authorized send waits for the acknowledgement commit")
        XCTAssertEqual(status?.entries.first?.outcome, .resolved(AgentRecoveryCrashHoldCheckText.confirmed))
        let acknowledgement = await now.store.read(sessionID: held.session.id).record?.crashHoldAcknowledgement
        XCTAssertNotNil(acknowledgement)
        XCTAssertNil(coordinator.lane(for: held.session.id), "the held session was never opened")

        // After the commit: the consented message is sent exactly once.
        let sent = await Support.eventually { starts.count == 1 }
        XCTAssertTrue(sent, "\(scheduler.disposition(scheduleID: scheduleID))")
        XCTAssertNil(scheduler.recoveryBlocker(scheduleID: scheduleID))
        scheduler.recordDidChange()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(starts.count, 1, "Exactly one dispatch")
    }

    /// Review A F09: recorded outcomes are worded without unsupported timing claims, and a failed or
    /// cancelled run is never presented as completed.
    func testRecoveredRunWordingStatesOnlyWhatTheEvidenceEstablishes() {
        func attempt(_ state: AgentSessionRunState, _ cause: AgentRunTerminalCause?) -> AgentRecoveryRunAttempt {
            AgentRecoveryRunAttempt(
                runAttemptID: UUID(),
                transcriptResetGeneration: 0,
                processRunID: nil,
                transcriptTurnID: UUID(),
                startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
                terminal: AgentRecoveryRunTerminalEvidence(
                    commitID: UUID(), terminalState: state, expectedRunID: nil,
                    recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000), cause: cause
                )
            )
        }
        let completed = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.completed, .ordinary))
        )
        XCTAssertEqual(completed.title, "Completed; transcript tail may be missing")
        XCTAssertFalse(completed.title.contains("while RepoPrompt was closed"))
        XCTAssertFalse(completed.detail.contains("while RepoPrompt was closed"))
        let failed = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.failed, .ordinary))
        )
        XCTAssertEqual(failed.title, "Run failed")
        XCTAssertFalse(failed.title.localizedCaseInsensitiveContains("completed"))
        let cancelled = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.cancelled, .userCancel))
        )
        XCTAssertEqual(cancelled.title, "Run cancelled")
        let unsavedCompleted = AgentModeViewModel.recoveryOnlyRunRowText(attempt(.completed, .ordinary))
        XCTAssertEqual(unsavedCompleted.title, "Run finished, but its turn wasn't saved")
        XCTAssertTrue(unsavedCompleted.detail.hasPrefix("The run completed"))
        let unsavedFailed = AgentModeViewModel.recoveryOnlyRunRowText(attempt(.failed, .ordinary))
        XCTAssertTrue(unsavedFailed.detail.hasPrefix("The run failed"), unsavedFailed.detail)
    }

    /// 9-live S4: a crash-interrupted turn's row outlives later normal quits, so its text names the
    /// earlier launch; a normal quit keeps its own wording.
    func testInterruptedTurnTextNamesTheEarlierLaunchOnlyForAnUnexpectedQuit() {
        func text(_ reason: AgentTranscriptTurnInterruption.Reason) -> (title: String, detail: String) {
            let id = UUID()
            return AgentModeViewModel.recoveryListTurnText(AgentRecoveryInterruptedTurn(
                turnID: id,
                interruption: AgentTranscriptTurnInterruption(reason: reason, observedAt: Date(timeIntervalSince1970: 1), runAttemptID: id),
                status: .interrupted,
                isLastTurn: true
            ))
        }
        let crashed = text(.appCrash)
        XCTAssertEqual(crashed.title, "Turn interrupted")
        XCTAssertEqual(
            crashed.detail,
            "In an earlier launch, RepoPrompt quit unexpectedly during this turn. The saved conversation stops where it was interrupted."
        )
        let quit = text(.appQuit)
        XCTAssertEqual(quit.detail, "RepoPrompt was quit during this turn. The saved conversation stops where it was interrupted.")
        XCTAssertFalse(quit.detail.contains("earlier launch"))
    }

    /// 9-live S5 / review P3-8: a survivor started through a launcher shim names the launcher's and
    /// the agent's PIDs without contradicting the process count; without a distinct writer only the
    /// root is named. Let finish is stated in the text.
    func testSurvivingRuntimeTextNamesTheAgentPIDAndLetFinish() {
        func restriction(rootPID: Int32?, writerPID: Int32?, letFinish: Bool) -> AgentRuntimeRestriction {
            AgentRuntimeRestriction(
                runtimeID: UUID(), kind: .possibleWriter, family: .claudeNative, provider: nil, state: .live,
                isPreviousInstance: true, isUnreadable: false, providerHome: nil,
                conversationIDs: ["conv-S5"], worktreePaths: ["/tmp/wt-s5"], sessionIDs: [], associations: [],
                rootPID: rootPID, writerPID: writerPID, memberCount: 1, letFinish: letFinish, revision: .make(), createdAt: nil
            )
        }
        let shim = AgentModeViewModel.recoveryListRuntimeText(restriction(rootPID: 56334, writerPID: 56474, letFinish: false)).1
        XCTAssertTrue(
            shim.hasPrefix("Claude from an earlier launch of RepoPrompt (1 process found; launcher PID 56334, agent PID 56474)."),
            shim
        )
        XCTAssertFalse(shim.contains("You chose to let it finish"))
        let direct = AgentModeViewModel.recoveryListRuntimeText(restriction(rootPID: 7048, writerPID: 7048, letFinish: true)).1
        XCTAssertTrue(direct.hasPrefix("Claude from an earlier launch of RepoPrompt (1 process found, started as PID 7048)."), direct)
        XCTAssertFalse(direct.contains("agent PID"))
        XCTAssertTrue(direct.contains("You chose to let it finish; RepoPrompt keeps watching it."), direct)
    }

    /// R04: Edit keeps a carrier's exact pending-handoff association. An absent session payload is
    /// restored and saved before the withdrawal, the join then releases it for the next explicit send
    /// (never pasted into the composer text); a conflicting snapshot refuses with nothing changed.
    func testRecoveryListEditRestoresTheCarriedPendingHandoffAndRefusesAConflictingOne() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        func snapshot(_ payload: String) -> AgentRecoveryPendingHandoffSnapshot {
            AgentRecoveryPendingHandoffSnapshot(
                payloadID: UUID(),
                payload: payload,
                createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 1234),
                sourceItemID: nil,
                prependedText: "\(payload)\n\n---\n\n"
            )
        }
        func carrier(_ text: String, _ handoff: AgentRecoveryPendingHandoffSnapshot) -> AgentRecoveryIntentSubmission {
            AgentRecoveryIntentSubmission(
                intentID: UUID(),
                userItemID: UUID(),
                origin: .composer,
                target: .session,
                payload: Support.content(text),
                pendingHandoff: handoff
            )
        }
        let carried = snapshot("earlier conversation")
        let first = carrier("carried input", carried)
        try await commitQueued(earlier, load, first)
        let conflicting = carrier("conflicting input", snapshot("other conversation"))
        try await commitQueued(earlier, load, conflicting)

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4802, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        XCTAssertFalse(session.pendingHandoff.hasPayload, "No payload is pending in the session before Edit")

        func rowID(_ submission: AgentRecoveryIntentSubmission) -> String {
            "intent-\(load.session.id.uuidString)-\(submission.intentID.uuidString)"
        }
        func row(_ submission: AgentRecoveryIntentSubmission) -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == rowID(submission) }
        }

        await viewModel.performRecoveryListAction(rowID: rowID(first), action: .edit)
        XCTAssertNil(row(first)?.error)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "carried input", "The prefix is never pasted into the composer")
        XCTAssertEqual(session.pendingHandoff.payloadID, carried.payloadID)
        XCTAssertEqual(session.pendingHandoff.payload, carried.payload)
        XCTAssertNil(session.pendingHandoff.deliveryHold, "The withdrawn carrier releases the payload for the next explicit send")
        XCTAssertTrue(session.pendingHandoff.hasStageablePayload)
        let firstState = await deliveryState(now.store, load, first.intentID)
        XCTAssertEqual(firstState, .withdrawn)

        // A different carried payload never replaces the session's.
        viewModel.storeDraftText(for: tabID, "")
        await viewModel.performRecoveryListAction(rowID: rowID(conflicting), action: .edit)
        XCTAssertTrue(row(conflicting)?.error?.contains("Nothing was changed") == true, String(describing: row(conflicting)?.error))
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID) ?? "", "")
        XCTAssertEqual(session.pendingHandoff.payloadID, carried.payloadID)
        let conflictingState = await deliveryState(now.store, load, conflicting.intentID)
        XCTAssertEqual(conflictingState, .queued)
    }

    // MARK: - Composition

    func testCompositionSharesOneStoreAndDataServiceAndOpensSchedulingOnlyAfterReady() async throws {
        let fixture = try makeFixture()
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { .empty }
        )
        XCTAssertTrue(composition.isActive)
        XCTAssertNil(composition.failure)
        XCTAssertEqual(scheduler.startupAdmission, .awaitingRecovery)
        XCTAssertTrue(scheduler.dispatchingRecordsRequireTransferResolution)
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(coordinator.store === now.store)
        XCTAssertTrue(coordinator.dataService === now.service)

        let first = makeViewModel(windowID: 4811, fixture: fixture)
        let second = makeViewModel(windowID: 4812, fixture: fixture)
        composition.install(into: first)
        composition.install(into: second)
        XCTAssertFalse(scheduler.isStartupAdmissionOpen, "Scheduling stays closed until reconciliation is ready")
        for viewModel in [first, second] {
            XCTAssertTrue(viewModel.recoveryCoordinator === coordinator, "Every window shares one coordinator")
            XCTAssertTrue(viewModel.test_dataService === now.service, "Every window writes through the gated DataService")
            XCTAssertNil(viewModel.recoveryCompositionFailure)
        }

        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        first.test_establishPersistenceWorkspace(fixture.workspace)
        let tabID = UUID()
        first.test_setCurrentTabIDOverride(tabID)
        let session = try await first.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
    }

    func testCompositionAndViewModelDefaultReadTheOneProductionActivation() throws {
        let fixture = try makeFixture()
        let now = makeLaunch(fixture)
        // A view model nobody installed into still reads the composition's runner, not an all-off copy.
        let uninstalled = makeViewModel(windowID: 4815, fixture: fixture)
        XCTAssertEqual(uninstalled.recoveryActionRunner.activation, AgentRecoveryActivation.production)
        XCTAssertEqual(AgentRecoveryAppComposition.makeActionRunner().activation, AgentRecoveryActivation.production)
        XCTAssertEqual(AgentRecoveryActivation.production, .off, "Production stays off until the reviewed flip")

        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { .empty }
        )
        XCTAssertEqual(composition.activation, AgentRecoveryActivation.production)
        let installed = makeViewModel(windowID: 4816, fixture: fixture)
        composition.install(into: installed)
        XCTAssertEqual(installed.recoveryActionRunner.activation, AgentRecoveryActivation.production)

        // An explicit activation reaches every installed window's runner.
        let qualifiedComposition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery),
            activation: .claudeAndCodex,
            loadInventory: { .empty }
        )
        let qualified = makeViewModel(windowID: 4817, fixture: fixture)
        qualifiedComposition.install(into: qualified)
        XCTAssertEqual(qualified.recoveryActionRunner.activation, .claudeAndCodex)
    }

    func testCompositionDependencyFailureStaysFailClosedWithoutPermissiveFallback() async throws {
        let fixture = try makeFixture()
        let store = AgentRecoveryStore(rootURL: fixture.recoveryRoot)
        // A DataService not gated by `store`: the coordinator cannot be composed.
        let ungated = AgentSessionDataService(
            tombstoneRoot: fixture.recoveryRoot.appendingPathComponent("tombstones", isDirectory: true)
        )
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: store,
            dataService: ungated,
            scheduler: scheduler,
            loadInventory: { .empty }
        )
        XCTAssertTrue(composition.isActive)
        XCTAssertNil(composition.coordinator)
        XCTAssertNotNil(composition.failure)
        guard case .recoveryFailed = scheduler.startupAdmission else {
            return XCTFail("Scheduling stays closed with a reason, got \(scheduler.startupAdmission)")
        }

        let viewModel = makeViewModel(windowID: 4821, fixture: fixture)
        composition.install(into: viewModel)
        XCTAssertNil(viewModel.recoveryCoordinator)
        XCTAssertNotNil(viewModel.recoveryCompositionFailure)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory, "No legacy (untracked) fallback")

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "not admitted",
            tabID: tabID,
            origin: .composer
        )
        guard case .blocked = result else {
            return XCTFail("Input is refused without a coordinator, got \(result)")
        }
        XCTAssertFalse(session.items.contains { $0.kind == .user && $0.text == "not admitted" })
        let props = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        guard case .failed = props.status else {
            return XCTFail("The failure is shown, got \(props.status)")
        }
        XCTAssertFalse(props.canRetry)
        XCTAssertFalse(scheduler.isStartupAdmissionOpen)
    }

    func testUnreadableWorkspaceIndexKeepsStartupClosedUntilRetrySucceeds() async throws {
        let fixture = try makeFixture()
        let baseRoot = fixture.root.appendingPathComponent("WorkspacesRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        try Data("not a workspace index".utf8).write(to: indexURL, options: .atomic)
        XCTAssertThrowsError(try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot)) { error in
            XCTAssertTrue(error is AgentRecoveryInventoryIndexFailure, "\(error)")
        }

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot) }
        )
        let viewModel = makeViewModel(windowID: 4831, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        guard case .failed = coordinator.startupState else {
            return XCTFail("The global scope could not be established, got \(coordinator.startupState)")
        }
        guard case .recoveryFailed = scheduler.startupAdmission else {
            return XCTFail("Scheduling stays closed, got \(scheduler.startupAdmission)")
        }
        let failedProps = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: nil))
        guard case .failed = failedProps.status else {
            return XCTFail("The failure is shown, got \(failedProps.status)")
        }
        XCTAssertTrue(failedProps.canRetry)

        // The index is repaired; Retry reconciles and then opens scheduling.
        let entry = WorkspaceIndexEntry(
            id: fixture.workspace.id,
            name: fixture.workspace.name,
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        try JSONEncoder().encode([entry]).write(to: indexURL, options: .atomic)
        viewModel.retryRecoveryStartup()
        XCTAssertFalse(scheduler.isStartupAdmissionOpen, "Retry closes admission until it is ready")
        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: nil), "Nothing is left to show")
    }

    /// F-10: an owner that hydrated a `.dispatching` schedule while startup had failed holds it
    /// (`.awaitingRecovery`) and gives up its repair; once Retry opens admission, the transfer is
    /// resolved and the hydrated owner's projection and hold are released without user action.
    func testHydratedScheduleTransferIsRepairedWhenStartupRetryOpensAdmission() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        // Earlier launch: the schedule attempt was transferred to a queued recovery intent, but the
        // pending `.dispatching` schedule was never cleared from the session file.
        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let start = Date(timeIntervalSince1970: 100)
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        let schedule = AgentScheduledSendPersist(
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
            attempt: attempt
        )
        let submission = Support.submission(
            schedule.rawText,
            userItemID: attempt.itemID,
            origin: .scheduled,
            scheduleReference: AgentScheduledSendTransfer.recoveryScheduleReference(scheduleID: schedule.id, attempt: attempt)
        )
        try await commitQueued(earlier, load, submission)
        let sessionURL = fixture.storageURL
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(load.session.id.uuidString).json")
        var saved = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        saved.scheduledSend = .v1(schedule)
        try AgentSessionDataCodec.encodeSession(saved).write(to: sessionURL, options: .atomic)

        // This launch: the workspace index is unreadable, so startup fails and admission stays closed.
        let baseRoot = fixture.root.appendingPathComponent("WorkspacesRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        try Data("not a workspace index".utf8).write(to: indexURL, options: .atomic)
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot) }
        )
        let viewModel = makeViewModel(windowID: 4832, fixture: fixture)
        composition.install(into: viewModel)
        viewModel.attachScheduledSendCoordinator(scheduler)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        guard case .failed = coordinator.startupState else {
            return XCTFail("Startup failed before hydration, got \(coordinator.startupState)")
        }

        // Hydrated while startup is failed: projected as saved and held, never confirmed or dispatched.
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        XCTAssertEqual(session.activeAgentSessionID, load.session.id)
        XCTAssertEqual(session.pendingScheduledSendRecord?.id, schedule.id)
        XCTAssertEqual(session.pendingScheduledSendRecord?.state, .dispatching)
        let heldWhileFailed = await Support.eventually {
            scheduler.transferHold(scheduleID: schedule.id)?.reason == .awaitingRecovery
        }
        XCTAssertTrue(heldWhileFailed, "The hydrated attempt is held while startup is failed")
        XCTAssertFalse(scheduler.isStartupAdmissionOpen)
        let diskBeforeRetry = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        XCTAssertEqual(diskBeforeRetry.scheduledSend?.persistedValue?.id, schedule.id, "Nothing is repaired while startup is failed")

        // The index is repaired; Retry reconciles and opens admission.
        let entry = WorkspaceIndexEntry(
            id: fixture.workspace.id,
            name: fixture.workspace.name,
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        try JSONEncoder().encode([entry]).write(to: indexURL, options: .atomic)
        viewModel.retryRecoveryStartup()
        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        let released = await Support.eventually {
            session.pendingScheduledSendRecord == nil && scheduler.transferHold(scheduleID: schedule.id) == nil
        }
        XCTAssertTrue(released, "The hydrated owner's projection and hold are released after Retry")
        XCTAssertNil(scheduler.transferHold(sessionID: load.session.id))
        let disk = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        XCTAssertNil(disk.scheduledSend, "The pending schedule is cleared")
        XCTAssertEqual(disk.lastScheduledDispatch?.scheduleID, schedule.id)
        XCTAssertEqual(disk.lastScheduledDispatch?.attemptID, attempt.attemptID)
        XCTAssertEqual(
            disk.lastScheduledDispatch?.kind,
            .savedInQueue(AgentScheduledSendQueueLink(intentID: submission.intentID, userItemID: attempt.itemID))
        )
        let intentState = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(intentState, .queued, "The transfer never records acceptance")
    }

    // MARK: - Tab switch (R13)

    /// R13: switching tabs writes the outgoing tab's composer at the switch boundary. The debounce
    /// sleep is injected and never fired, so only the switch can have written the draft.
    func testTabSwitchFlushesTheOutgoingComposerWithoutTheDebounce() async throws {
        let fixture = try makeFixture()
        let sleeper = RecoveryManualSleeper()
        let now = makeLaunch(fixture)
        let coordinator = try AgentRecoveryCoordinator(
            store: now.store,
            dataService: now.service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { try await sleeper.sleep(until: $0) }
                )
            }
        )
        coordinator.startIfNeeded()
        let startup = await coordinator.awaitStartup()
        XCTAssertEqual(startup, .ready)

        // A real window, so the compose-tab change reaches the view model's tab-switch handler.
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        do {
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            let created = window.workspaceManager.createWorkspace(
                name: "Recovery Tab Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [fixture.storageURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "agentRecoveryTabSwitchFlushTest")
            let tabAID = UUID()
            let tabBID = UUID()
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex(where: { $0.id == created.id }))
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabAID, name: "A"),
                ComposeTabState(id: tabBID, name: "B")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true)

            let viewModel = window.agentModeViewModel
            viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
            XCTAssertTrue(viewModel.test_dataService === now.service, "The window writes through the coordinator's gated DataService")
            // Session files live in the temporary fixture storage, never in app data.
            var persistence = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            persistence.customStoragePath = fixture.storageURL
            viewModel.test_establishPersistenceWorkspace(persistence)

            // Tab A's first save claims its lane; the lane's eager composer restore completes.
            let sessionA = try XCTUnwrap(viewModel.session(for: tabAID, createIfNeeded: true))
            let sessionB = try XCTUnwrap(viewModel.session(for: tabBID, createIfNeeded: true))
            sessionA.appendItem(.user("Before switching"))
            let savedA = await viewModel.flushSave(for: tabAID)
            XCTAssertTrue(savedA)
            let laneA = try XCTUnwrap(sessionA.recoveryLane, "The first save claims tab A's lane")
            let restored = await Support.eventually {
                if case .ready = laneA.composerState { return true }
                return false
            }
            XCTAssertTrue(restored)
            viewModel.setAgentModeActive(true)

            // Typing arms the debounce, which never fires: nothing is written before the switch.
            viewModel.storeDraftText(for: tabAID, "typed in tab A")
            let armed = await Support.eventually { await !sleeper.pendingDeadlines.isEmpty }
            XCTAssertTrue(armed, "The debounce sleep is pending")
            let beforeSwitch = await now.store.read(sessionID: laneA.sessionID).record?.composer?.content.text
            XCTAssertNotEqual(beforeSwitch, "typed in tab A", "No write happens without the switch")

            await window.promptManager.switchComposeTab(tabBID)
            let flushed = await Support.eventually {
                await now.store.read(sessionID: laneA.sessionID).record?.composer?.content.text == "typed in tab A"
            }
            XCTAssertTrue(flushed, "The outgoing composer is written at the switch boundary")
            XCTAssertNotEqual(sessionB.draftText, "typed in tab A", "Nothing crosses tabs")
            if let laneB = sessionB.recoveryLane {
                XCTAssertNotEqual(laneB.sessionID, laneA.sessionID)
            }
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testRecoveryWorkspaceInventoryReportsMissingAndDuplicateEntriesWithoutWriting() throws {
        let fixture = try makeFixture()
        let baseRoot = fixture.root.appendingPathComponent("InventoryRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        XCTAssertEqual(try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot), .empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: baseRoot.path), [], "Nothing is created")

        let unique = WorkspaceIndexEntry(
            id: UUID(),
            name: "Unique",
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        let repeatedID = UUID()
        let repeated = [
            WorkspaceIndexEntry(id: repeatedID, name: "Twice A", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: false),
            WorkspaceIndexEntry(id: repeatedID, name: "Twice B", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: true)
        ]
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        let indexData = try JSONEncoder().encode([unique] + repeated)
        try indexData.write(to: indexURL, options: .atomic)

        let inventory = try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot)
        XCTAssertEqual(inventory.workspaces, [AgentRecoveryWorkspaceDestination(
            id: unique.id,
            name: "Unique",
            customStoragePath: fixture.storageURL
        )])
        XCTAssertEqual(inventory.failures.map(\.workspaceID), [repeatedID], "A repeated workspace is a scoped failure")
        XCTAssertEqual(try Data(contentsOf: indexURL), indexData, "The index is read only")
    }

    // MARK: - App-wide Needs Attention (non-visible routing and publication)

    /// Records the objects of one notification name (posted synchronously on the main thread).
    @MainActor
    private final class PostedObjects {
        var ids: [ObjectIdentifier] = []
        private var token: (any NSObjectProtocol)?

        init(_ name: Notification.Name) {
            token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    if let id { self?.ids.append(id) }
                }
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }

        func count(of object: AnyObject) -> Int {
            ids.count { $0 == ObjectIdentifier(object) }
        }
    }

    private struct RouteOpenFailure: Error {}

    /// The app-level route reaches the focused window's view model, or a window it opens when none
    /// exists, and presents the shared catalog only: nothing hydrates, and the route stays
    /// reachable when every item is dismissed. A Dismiss in one window is published to every window.
    func testNeedsAttentionRouteReachesAnyWindowWithoutHydratingAndStaysReachableWhenAllDismissed() async throws {
        let fixture = try makeFixture()

        // Earlier launch: a closed session's run whose transcript turn was never saved.
        let earlier = makeLaunch(fixture)
        let unsaved = try await makeSession(earlier, fixture: fixture)
        let ownership = Support.ownership(sessionID: unsaved.session.id)
        let gate = try earlier.service.recoveryLifecycleGate(for: unsaved.persistenceState)
        let earlierStore = earlier.store
        let binding = gate.binding
        try await gate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: binding,
                expectedRevision: earlierStore.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }

        // This launch: two windows share one composition; neither opens a tab.
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let windowA = makeViewModel(windowID: 4851, fixture: fixture)
        let windowB = makeViewModel(windowID: 4852, fixture: fixture)
        composition.install(into: windowA)
        composition.install(into: windowB)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(windowA.recoveryCoordinator === coordinator)
        XCTAssertTrue(windowB.recoveryCoordinator === coordinator)

        let runRowID = "run-\(unsaved.session.id.uuidString)-\(ownership.attemptID.uuidString)"
        let initialRows = windowA.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil)
        let initialSummary = initialRows.map { "\($0.id): \($0.row.title) \($0.row.actions)" }
        XCTAssertTrue(initialRows.contains { $0.id == runRowID }, "\(initialSummary)")
        // O34-1: the badge counts needs-action rows only (the run note is informational).
        XCTAssertEqual(initialRows.first { $0.id == runRowID }?.attention, .informational, "\(initialSummary)")
        let needsActionCount = initialRows.count { $0.attention == .needsAction }
        XCTAssertEqual(windowA.recoveryNeedsAttentionCount, needsActionCount)
        XCTAssertEqual(windowB.recoveryNeedsAttentionCount, needsActionCount)
        XCTAssertEqual(
            initialRows.map(\.id),
            windowB.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil).map(\.id),
            "Every window renders the same catalog"
        )

        // Every item dismissed in window B; window A observes the same published catalog.
        let catalogPosts = PostedObjects(.agentRecoveryCatalogDidChange)
        defer { catalogPosts.stop() }
        for row in initialRows {
            XCTAssertTrue(row.row.actions.contains(.dismiss), "\(initialSummary)")
            await windowB.performRecoveryListAction(rowID: row.id, action: .dismiss)
        }
        let dismissedEverywhere = await Support.eventually {
            windowA.recoveryNeedsAttentionCount == 0 && windowB.recoveryNeedsAttentionCount == 0
        }
        XCTAssertTrue(dismissedEverywhere, "\(initialSummary) \(coordinator.catalogActionStates)")
        let publishedPost = await Support.eventually { catalogPosts.count(of: coordinator) > 0 }
        XCTAssertTrue(publishedPost)
        let dismissedRowInA = windowA.recoveryNeedsAttentionRows(includeDismissed: true, activeSession: nil).first { $0.id == runRowID }
        XCTAssertEqual(dismissedRowInA?.isDismissed, true, "Show dismissed still lists it with nothing undismissed")
        XCTAssertNil(dismissedRowInA?.row.error)

        // Route to an existing window: it never opens another.
        let requests = PostedObjects(.agentRecoveryNeedsAttentionRequested)
        defer { requests.stop() }
        let existingTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: windowA) {
            XCTFail("An existing window is used")
            throw RouteOpenFailure()
        }
        XCTAssertTrue(existingTarget === windowA)
        XCTAssertEqual(requests.ids, [ObjectIdentifier(windowA)])
        XCTAssertTrue(windowA.consumeRecoveryNeedsAttentionRequest())
        XCTAssertFalse(windowA.consumeRecoveryNeedsAttentionRequest(), "A request presents once")
        XCTAssertFalse(windowB.consumeRecoveryNeedsAttentionRequest())

        // No window: one is opened through the existing route and presents once registered.
        var opened = 0
        let openedTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: nil) {
            opened += 1
            return windowB
        }
        XCTAssertTrue(openedTarget === windowB)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(requests.ids, [ObjectIdentifier(windowA), ObjectIdentifier(windowB)])
        XCTAssertTrue(windowB.consumeRecoveryNeedsAttentionRequest())

        let failedTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: nil) {
            throw RouteOpenFailure()
        }
        XCTAssertNil(failedTarget)
        XCTAssertEqual(requests.count(of: windowA) + requests.count(of: windowB), 2)

        XCTAssertTrue(windowA.sessions.isEmpty, "Presenting hydrates nothing")
        XCTAssertTrue(windowB.sessions.isEmpty, "Presenting hydrates nothing")
        XCTAssertTrue(scheduler.confirmationSummaries().isEmpty)
    }

    /// O34-1: a session whose only item is an informational run note shows no banner and adds
    /// nothing to the Needs Attention count; the note is listed in the sheet's Information section.
    /// An unfinished recovery action on it makes it a needs-action row of the banner again.
    func testBannerHidesInformationalRunNotesAndShowsARunWithAnUnfinishedAction() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()
        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4871, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        let lane = try XCTUnwrap(session.recoveryLane)
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: session), "Nothing to show")

        // This launch's run ends by provider process loss: an informational note only.
        let ownership = Support.ownership(sessionID: load.session.id)
        let turnID = UUID()
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: nil).get()
        await lane.recordTerminalEvidence(
            Support.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(load.session.id.uuidString)-\(turnID.uuidString)"
        let listed = await Support.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed, "\(coordinator.catalog.items.map(\.id))")
        let summary = coordinator.catalog.items.map { "\($0.id) \($0.attention)" }
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: session), "An informational note never shows the banner: \(summary)")
        XCTAssertEqual(viewModel.recoveryNeedsAttentionCount, 0, "\(summary)")
        let sheetRow = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: session).first { $0.id == itemID }
        XCTAssertEqual(sheetRow?.attention, .informational, "Listed in the Information section")

        // A reserved recovery action without an outcome: the banner shows the run as needing action.
        let key = try XCTUnwrap(coordinator.catalog.item(id: itemID)?.acknowledgement?.key)
        let revision = try await now.store.currentRevision(sessionID: load.session.id)
        let request = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: .reconcileOnly,
            expectedRevision: revision,
            sourceRunAttemptID: ownership.attemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")
        )
        _ = try await lane.reserveRecoveryAction(request).get()
        let shown = await Support.eventually {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.contains { $0.id == itemID } == true
        }
        XCTAssertTrue(shown, "\(coordinator.catalog.items.map { "\($0.id) \($0.attention)" })")
        XCTAssertEqual(viewModel.recoveryNeedsAttentionCount, 1)
        XCTAssertEqual(
            viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: session).first { $0.id == itemID }?.attention,
            .needsAction
        )
        XCTAssertFalse(
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == itemID }?.detail
                .contains(AgentModeViewModel.recoveryListUnsentContinuationNote) ?? true
        )

        // ATT1-R2-3: typed continuation text that was not sent keeps the row, and its detail says why.
        _ = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: .importedUnconfirmed, reason: nil).get()
        let continuation = try await AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: .continueWithText,
            expectedRevision: now.store.currentRevision(sessionID: load.session.id),
            sourceRunAttemptID: ownership.attemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1"),
            text: "please continue",
            plannedUserItemID: UUID()
        )
        _ = try await lane.reserveRecoveryAction(continuation).get()
        _ = try await lane.completeRecoveryAction(actionID: continuation.actionID, outcome: .notDispatched, reason: nil).get()
        let explained = await Support.eventually {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == itemID }?.detail
                .hasSuffix(" \(AgentModeViewModel.recoveryListUnsentContinuationNote)") == true
        }
        XCTAssertTrue(explained, "\(viewModel.recoveryListProps(forActiveSession: session)?.rows.map(\.detail) ?? [])")
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.actionFacts.unsentContinuationText, "please continue")

        // 9-live R4a: a refusal on that row shows the note first, then the reason.
        let reason = "No history position was saved for this run, so it can't be continued safely."
        coordinator.setCatalogActionState(.failed(reason), for: itemID)
        let refusedRow = viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == itemID }
        XCTAssertEqual(refusedRow?.error, "\(AgentModeViewModel.recoveryListUnsentContinuationNote) \(reason)")
        let sheetError = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: session)
            .first { $0.id == itemID }?.row.error
        XCTAssertEqual(sheetError, refusedRow?.error, "the sheet shows the same row error")
        coordinator.setCatalogActionState(nil, for: itemID)
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == itemID }?.error)
    }

    /// 9-live R4a: the note leads only a run card's refusal while its typed text is unsent; other
    /// refusals keep their reason alone.
    func testRecoveryRowErrorPutsTheUnsentNoteBeforeTheReason() {
        let note = AgentModeViewModel.recoveryListUnsentContinuationNote
        XCTAssertEqual(
            AgentModeViewModel.recoveryListRowError(.failed("Reason."), hasUnsentContinuation: true),
            "\(note) Reason."
        )
        XCTAssertEqual(AgentModeViewModel.recoveryListRowError(.failed("Reason."), hasUnsentContinuation: false), "Reason.")
        XCTAssertNil(AgentModeViewModel.recoveryListRowError(.working, hasUnsentContinuation: true))
        XCTAssertNil(AgentModeViewModel.recoveryListRowError(nil, hasUnsentContinuation: true))
    }

    /// 9-live R4b/R5: the Continue editor opens with the row's draft, then the card's unsent
    /// typed text, then the default; a draft is kept as typed, even when empty.
    func testContinuationEditorOpeningTextPrecedence() {
        let defaultText = AgentModeViewModel.recoveryContinueDefaultText
        XCTAssertEqual(AgentModeViewModel.recoveryContinuationOpeningText(draft: "draft", unsentText: "unsent"), "draft")
        XCTAssertEqual(AgentModeViewModel.recoveryContinuationOpeningText(draft: "", unsentText: "unsent"), "")
        XCTAssertEqual(AgentModeViewModel.recoveryContinuationOpeningText(draft: nil, unsentText: "unsent"), "unsent")
        XCTAssertEqual(AgentModeViewModel.recoveryContinuationOpeningText(draft: nil, unsentText: nil), defaultText)
    }

    /// 9-live R4b/R5, review B L1/L3: a choice that recorded nothing keeps the draft; a recorded
    /// outcome whose record holds the text (sent, or the card's unsent text again) clears it; a
    /// recorded choice whose text the record neither sent nor shows moves it to the message box.
    func testContinuationDraftDispositionFollowsWhatTheRecordHolds() {
        let expectations: [(AgentRecoveryActionResult?, AgentModeViewModel.RecoveryContinuationDraftDisposition)] = [
            (nil, .keep),
            (.disabled("off"), .keep),
            (.refused("stale"), .keep),
            (.joined(.unknown), .keep),
            (.priorAction(actionID: UUID(), join: .unknown), .keep),
            (.completed(.dispatched, reason: nil), .clear),
            (.outcomeUnrecorded(.dispatched, reason: nil), .clear),
            (.completed(.notDispatched, reason: "No history position was saved."), .clear),
            (.completed(.importedUnconfirmed, reason: nil), .clear),
            (.completed(.importedCompleted, reason: nil), .moveToComposer),
            (.outcomeUnrecorded(.importedCompleted, reason: nil), .moveToComposer),
            (.outcomeUnrecorded(.notDispatched, reason: nil), .moveToComposer),
            (.outcomeUnrecorded(.importedUnconfirmed, reason: nil), .moveToComposer)
        ]
        for (result, expected) in expectations {
            XCTAssertEqual(
                AgentModeViewModel.recoveryContinuationDraftDisposition(result), expected, "\(String(describing: result))"
            )
        }
        XCTAssertEqual(
            AgentModeViewModel.recoveryContinuationMovedToComposerText(.completed(.importedCompleted, reason: nil)),
            AgentModeViewModel.recoveryContinuationFinishedMovedText
        )
        XCTAssertEqual(
            AgentModeViewModel.recoveryContinuationMovedToComposerText(.outcomeUnrecorded(.notDispatched, reason: nil)),
            AgentModeViewModel.recoveryContinuationUnrecordedMovedText
        )
    }

    /// Review B N2, A R2-01 / B P1-B: the view model stores the appended result and the input bar
    /// shows exactly that result: a repeat changes nothing, and when two events coalesce, the last
    /// one alone still shows both texts.
    func testComposerAppendIsAppliedOnce() {
        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppending("moved", to: ""), "moved", "an empty box gets the text alone")
        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppending("moved", to: "  \n"), "moved", "whitespace counts as empty")
        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppending("moved", to: "mine"), "mine\n\nmoved")

        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppendUpdate(live: "mine", result: "mine\n\nmoved"), "mine\n\nmoved")
        XCTAssertNil(
            AgentModeViewModel.recoveryComposerAppendUpdate(live: "mine\n\nmoved", result: "mine\n\nmoved"),
            "already showing the stored result: unchanged"
        )
        // Restore of R then a held-back T in one turn: the bar sees only the second event.
        let restored = "R"
        let second = AgentModeViewModel.recoveryComposerAppending("T", to: restored)
        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppendUpdate(live: "", result: second), "R\n\nT", "nothing is lost")

        /// Review A R1-01: an unsent submitted text and a differing newer edit move together.
        func unsent(_ submitted: String, _ newer: String?) -> String? {
            AgentModeViewModel.recoveryUnsentContinuationText(submitted: submitted, newer: newer)
        }
        let defaultText = AgentModeViewModel.recoveryContinueDefaultText
        XCTAssertEqual(unsent("X", "Y"), "X\n\nY", "the submitted text first")
        XCTAssertEqual(unsent("X", "X"), "X", "deduplicated")
        XCTAssertEqual(unsent("X", nil), "X")
        XCTAssertEqual(unsent(defaultText, "Y"), "Y", "the default text is left out")
        XCTAssertEqual(unsent("X", " \n"), "X", "a blank edit is left out")
        XCTAssertNil(unsent(defaultText, nil))
    }

    /// Review B ATT1-5: after a crash, an active session whose only other items are informational
    /// run notes still shows the banner with its undismissed crash hold; and a run card on the
    /// startup path (keyed by the startup binding's incarnation) with an earlier launch's unfinished
    /// recovery action needs action.
    func testStartupCrashHoldKeepsTheBannerAndAnEarlierLaunchUnfinishedActionNeedsAction() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store

        // Earlier launch (no clean exit): S1's run is open at the crash (a crash hold and a run
        // note); S2's run too, with a recovery action reserved on its run card and no outcome.
        let active = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let activeOwnership = Support.ownership(sessionID: active.session.id)
        let activeGate = try earlier.service.recoveryLifecycleGate(for: active.persistenceState)
        let activeBinding = activeGate.binding
        try await activeGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: activeBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: activeBinding.sessionID),
                ownership: activeOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }
        let acted = try await makeSession(earlier, fixture: fixture)
        let actedOwnership = Support.ownership(sessionID: acted.session.id)
        let actedGate = try earlier.service.recoveryLifecycleGate(for: acted.persistenceState)
        let actedBinding = actedGate.binding
        let actedKey = AgentRecoveryCardKey(
            kind: .run,
            incarnationID: actedBinding.incarnationID,
            transcriptResetGeneration: nil,
            entityID: actedOwnership.attemptID.uuidString
        )
        try await actedGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: actedBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: actedBinding.sessionID),
                ownership: actedOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await earlierStore.reserveRecoveryAction(
                binding: actedBinding,
                request: AgentRecoveryActionRequest(
                    actionID: UUID(),
                    itemKey: actedKey,
                    kind: .reconcileOnly,
                    expectedRevision: earlierStore.currentRevision(sessionID: actedBinding.sessionID),
                    sourceRunAttemptID: actedOwnership.attemptID,
                    target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")
                )
            )
        }

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4872, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)

        let crashID = "crash-\(active.session.id.uuidString)"
        let activeRunID = "run-\(active.session.id.uuidString)-\(activeOwnership.attemptID.uuidString)"
        let actedRunID = "run-\(acted.session.id.uuidString)-\(actedOwnership.attemptID.uuidString)"
        let listed = await Support.eventually {
            [crashID, activeRunID, actedRunID].allSatisfy { coordinator.catalog.item(id: $0) != nil }
        }
        let summary = coordinator.catalog.items.map { "\($0.id) \($0.attention)" }
        XCTAssertTrue(listed, "\(summary)")
        XCTAssertEqual(coordinator.catalog.item(id: activeRunID)?.attention, .informational, "\(summary)")
        let actedRun = try XCTUnwrap(coordinator.catalog.item(id: actedRunID))
        XCTAssertEqual(actedRun.acknowledgement?.key, actedKey, "The startup run card is keyed by the startup binding")
        XCTAssertTrue(actedRun.actionFacts.hasUnfinishedAction, "\(summary)")
        XCTAssertEqual(actedRun.attention, .needsAction)

        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != active.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: active.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        XCTAssertEqual(session.activeAgentSessionID, active.session.id)
        let banner = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session), "\(summary)")
        XCTAssertEqual(banner.rows.map(\.id), [crashID], "The crash hold explains the pause; the run note is information")
        XCTAssertEqual(
            viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: session).first { $0.id == actedRunID }?.attention,
            .needsAction
        )
    }

    /// A tab's failed composer preparation is a coordinator catalog item (runtime only): every
    /// window lists it, only the window owning the tab offers Retry, it has no durable Dismiss, and
    /// an action's failure is the same shared state in every window.
    func testFailedComposerPreparationAndActionResultArePublishedToEveryWindow() async throws {
        let fixture = try makeFixture()
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let windowA = makeViewModel(windowID: 4861, fixture: fixture)
        let windowB = makeViewModel(windowID: 4862, fixture: fixture)
        composition.install(into: windowA)
        composition.install(into: windowB)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        windowA.test_establishPersistenceWorkspace(fixture.workspace)
        windowB.test_establishPersistenceWorkspace(fixture.workspace)

        let tabID = UUID()
        let owner = try XCTUnwrap(windowA.session(for: tabID, createIfNeeded: true))
        let catalogPosts = PostedObjects(.agentRecoveryCatalogDidChange)
        defer { catalogPosts.stop() }
        coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: AgentRecoveryInputContent(text: "typed"))
        XCTAssertTrue(coordinator.startComposerPreparation(owner: owner) { _ in .authorityUnavailable("no workspace authority") })

        let itemID = AgentRecoveryCatalogProjection.preparationItemID(tabID: tabID)
        let published = await Support.eventually {
            coordinator.catalog.item(id: itemID) != nil && catalogPosts.count(of: coordinator) > 0
        }
        XCTAssertTrue(published, "The failure is published as a catalog change")
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(item.kind, .saveFailure)
        XCTAssertEqual(item.composeTabID, tabID)
        XCTAssertNil(item.acknowledgement, "No durable Dismiss for an unpersistable failure")
        XCTAssertEqual(item.payload, .composerPreparationFailed(.authorityUnavailable("no workspace authority")))
        XCTAssertEqual(item.attention, .needsAction, "Review B ATT1-5: a sessionless tab's failure needs action")

        func sheetRow(_ window: AgentModeViewModel) -> AgentRecoveryListRowProps? {
            window.recoveryNeedsAttentionRows(includeDismissed: true, activeSession: nil).first { $0.id == itemID }?.row
        }
        XCTAssertEqual(sheetRow(windowA)?.title, "Message box not saved yet")
        XCTAssertEqual(sheetRow(windowA)?.actions, [.retrySave], "The window owning the tab retries")
        XCTAssertEqual(sheetRow(windowB)?.title, "Message box not saved yet")
        XCTAssertEqual(sheetRow(windowB)?.actions, [], "Another window lists it without acting on a tab it does not own")
        XCTAssertNil(owner.activeAgentSessionID, "The tab has no session")
        let banner = try XCTUnwrap(windowA.recoveryListProps(forActiveSession: owner))
        XCTAssertTrue(banner.rows.contains { $0.id == itemID }, "The owning tab's banner shows the same item")

        // An action failure is shared state: both windows show it, and the item stays listed.
        await windowA.performRecoveryListAction(rowID: itemID, action: .dismiss)
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed("This item can't be dismissed."))
        XCTAssertEqual(sheetRow(windowA)?.error, "This item can't be dismissed.")
        XCTAssertEqual(sheetRow(windowB)?.error, "This item can't be dismissed.")
        XCTAssertNotNil(coordinator.catalog.item(id: itemID))
        XCTAssertTrue(windowB.sessions.isEmpty, "Listing it in another window hydrates nothing there")
    }

    /// Step 8-attention-2: a needs-action bulk Dismiss from the sheet dismisses the crash hold and the
    /// held input, skips the unreadable status item (no Dismiss), and lifts nothing: the dismissed
    /// crash hold still blocks the session and the new-session gate, its paused indicator still
    /// shows, and the saved input is neither sent nor withdrawn.
    func testNeedsActionBulkDismissKeepsTheCrashHoldBlockingAndItsPausedIndicator() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        // Earlier launch (no clean exit): a run in flight with its input (a crash hold), and a
        // session whose record is unreadable.
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store
        let held = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let heldOwnership = Support.ownership(sessionID: held.session.id)
        let heldGate = try earlier.service.recoveryLifecycleGate(for: held.persistenceState)
        let heldBinding = heldGate.binding
        let submission = Support.submission("in flight at crash")
        try await heldGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                ownership: heldOwnership,
                processRunID: nil,
                transcriptTurnID: nil,
                providerKindRaw: nil
            )
            _ = try await earlierStore.commitDispatchingIntent(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                submission: submission,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: heldOwnership.attemptID),
                consumption: nil
            )
        }
        let unreadable = try await makeSession(earlier, fixture: fixture)
        try await commitQueued(earlier, unreadable, Support.submission("unreadable input"))
        try Data("{ not a recovery record".utf8).write(to: earlier.store.recordFileURL(sessionID: unreadable.session.id), options: .atomic)

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4881, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != held.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: held.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        let lane = try XCTUnwrap(session.recoveryLane)

        let crashID = "crash-\(held.session.id.uuidString)"
        let statusID = "status-\(unreadable.session.id.uuidString)"
        let intentRowID = "intent-\(held.session.id.uuidString)-\(submission.intentID.uuidString)"
        let listed = await Support.eventually {
            [crashID, statusID, intentRowID].allSatisfy { coordinator.catalog.item(id: $0) != nil }
        }
        XCTAssertTrue(listed, "\(coordinator.catalog.items.map(\.id))")
        let needsActionRows = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: session)
            .filter { $0.attention == .needsAction }
        XCTAssertTrue(Set([crashID, statusID, intentRowID]).isSubset(of: Set(needsActionRows.map(\.id))), "\(needsActionRows.map(\.id))")
        let eligible = viewModel.recoveryBulkDismissEligibleCount(needsActionRows)
        XCTAssertEqual(eligible, needsActionRows.count { $0.item?.acknowledgement != nil })
        let deliveryBefore = await deliveryState(now.store, held, submission.intentID)

        let task = try XCTUnwrap(viewModel.startRecoveryBulkDismiss(section: .needsAction, rows: needsActionRows))
        let result = await task.value
        let status = try XCTUnwrap(result)
        XCTAssertEqual(status.section, .needsAction)
        XCTAssertEqual(status.dismissed, eligible, status.summaryText)
        XCTAssertEqual(status.failed, 0, status.summaryText)
        XCTAssertTrue(status.skipped.contains(AgentRecoveryBulkDismissSkip(itemID: statusID, reason: .noDismiss)))
        XCTAssertEqual(viewModel.recoveryBulkDismissStatus, status)
        XCTAssertFalse(viewModel.isRecoveryBulkDismissRunning)
        XCTAssertEqual(coordinator.catalog.item(id: crashID)?.isDismissed, true)
        XCTAssertEqual(coordinator.catalog.item(id: intentRowID)?.isDismissed, true)
        XCTAssertEqual(coordinator.catalog.item(id: statusID)?.isDismissed, false)

        // Dismiss lifts nothing.
        XCTAssertEqual(coordinator.catalog.blockers[held.session.id], .crashHold)
        XCTAssertNotNil(coordinator.blockingCrashHold(for: lane.binding), "sending stays paused")
        XCTAssertTrue(
            viewModel.scheduledSendRecoveryBlocker(inWorkspace: fixture.workspace.id, excluding: UUID())?
                .interruptedSessionIDs.contains(held.session.id) == true,
            "the new-session gate still names the session"
        )
        let pausedRowID = "\(AgentModeViewModel.recoveryListPausedRowPrefix)\(held.session.id.uuidString)"
        let banner = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        let paused = try XCTUnwrap(banner.rows.first { $0.id == pausedRowID }, "\(banner.rows.map(\.id))")
        XCTAssertTrue(paused.actions.contains(.confirmStopped))
        let deliveryAfter = await deliveryState(now.store, held, submission.intentID)
        XCTAssertEqual(deliveryAfter, deliveryBefore, "the saved input is neither sent nor withdrawn")
        let acknowledgement = await now.store.read(sessionID: held.session.id).record?.crashHoldAcknowledgement
        XCTAssertNil(acknowledgement, "Dismiss is not It stopped")

        // Review B F2: with "Show dismissed and cleared" on, the dismissed rows are listed but never
        // captured or counted: a bulk acts on exactly what the section header counts.
        let toggledOn = viewModel.recoveryNeedsAttentionRows(includeDismissed: true, activeSession: session)
            .filter { $0.attention == .needsAction }
        XCTAssertTrue(Set([crashID, intentRowID]).isSubset(of: Set(toggledOn.map(\.id))), "\(toggledOn.map(\.id))")
        let request = try XCTUnwrap(viewModel.recoveryBulkDismissRequest(section: .needsAction, rows: toggledOn))
        XCTAssertEqual(request.capture.total, AgentRecoveryNeedsAttentionSheet.headerCount(toggledOn))
        XCTAssertEqual(request.eligibleCount, 0)
        XCTAssertEqual(viewModel.recoveryBulkDismissEligibleCount(toggledOn), 0)
        XCTAssertFalse(request.capture.skipped.contains { [crashID, intentRowID].contains($0.itemID) })
        // Closing the sheet clears the finished summary.
        viewModel.clearRecoveryBulkDismissSummary()
        XCTAssertNil(viewModel.recoveryBulkDismissStatus)
    }

    // MARK: - Fixtures

    private func makeFixture() throws -> Fixture {
        let root = try Support.makeTemporaryRoot("AgentRecoveryStartupComposition")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            recoveryRoot: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            storageURL: storageURL,
            workspace: WorkspaceModel(
                name: "Recovery Startup Composition",
                repoPaths: [storageURL.path],
                customStoragePath: storageURL
            )
        )
    }

    private func makeLaunch(_ fixture: Fixture, failures: RecoveryStoreWriteFailureSwitch = RecoveryStoreWriteFailureSwitch()) -> Launch {
        let store = AgentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            appInstanceID: UUID(),
            fileOperations: failures.fileOperations()
        )
        let service = AgentSessionDataService(
            tombstoneRoot: fixture.recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        return Launch(store: store, service: service)
    }

    private func makeViewModel(windowID: Int, fixture: Fixture) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: fixture.storageURL.path,
            testWorkspaceDirectory: fixture.storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    private func makeSession(
        _ launch: Launch,
        fixture: Fixture,
        workspace: WorkspaceModel? = nil,
        composeTabID: UUID = UUID()
    ) async throws -> AgentSessionEditableLoad {
        let workspace = workspace ?? fixture.workspace
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: composeTabID,
            name: "Recovered Session"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await launch.service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
    }

    private func commitQueued(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        _ submission: AgentRecoveryIntentSubmission
    ) async throws {
        let gate = try launch.service.recoveryLifecycleGate(for: load.persistenceState)
        let store = launch.store
        let binding = gate.binding
        try await gate.performRecoveryTransaction {
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
        }
    }

    private func deliveryState(
        _ store: AgentRecoveryStore,
        _ load: AgentSessionEditableLoad,
        _ intentID: UUID
    ) async -> AgentRecoveryDeliveryState? {
        await store.read(sessionID: load.session.id).record?.intent(id: intentID)?.deliveryState
    }
}
