import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// F7: the shared composer store only ever holds the current tab's props. Another tab's sync or a
/// recovery refresh never overwrites them, and other tabs' scheduler busy state is still reported.
@MainActor
final class AgentComposerTabOwnershipTests: XCTestCase {
    func testRecoveryListRefreshKeepsCurrentTabPropsForEveryTabOrder() async throws {
        let viewModel = makeViewModel()
        let tabIDs = try await openTabs(4, in: viewModel)

        // Every tab takes a turn as the current tab, so it sits first, in the middle and last in
        // the sessions dictionary's (per-launch seeded) iteration order.
        for currentTabID in tabIDs {
            makeCurrent(currentTabID, among: tabIDs, in: viewModel)
            viewModel.refreshRecoveryListUI()
            assertComposerOwned(by: currentTabID, in: viewModel)
        }
    }

    func testExplicitNonCurrentSyncLeavesPropsAndStillReportsBusyState() async throws {
        let viewModel = makeViewModel()
        let tabIDs = try await openTabs(2, in: viewModel)
        let (tabA, tabB) = (tabIDs[0], tabIDs[1])
        let scheduler = AgentScheduledSendCoordinator()
        viewModel.attachScheduledSendCoordinator(scheduler)
        addTeardownBlock { @MainActor in viewModel.detachScheduledSendCoordinator() }
        makeCurrent(tabA, among: tabIDs, in: viewModel)
        let sessionB = try XCTUnwrap(viewModel.session(for: tabB, createIfNeeded: false))
        let propsBefore = viewModel.ui.composer.props
        let revisionBefore = viewModel.ui.composer.revision

        sessionB.lastReportedScheduledSendBusyState = nil
        viewModel.syncComposerUIState(tabID: tabB)

        XCTAssertEqual(viewModel.ui.composer.props, propsBefore)
        XCTAssertEqual(viewModel.ui.composer.revision, revisionBefore)
        XCTAssertNotNil(sessionB.lastReportedScheduledSendBusyState, "B's busy state is still reported")

        sessionB.lastReportedScheduledSendBusyState = nil
        viewModel.refreshRecoveryListUI()

        assertComposerOwned(by: tabA, in: viewModel)
        XCTAssertNotNil(sessionB.lastReportedScheduledSendBusyState, "The refresh reports every other tab")
    }

    func testCatalogChangeNotificationKeepsCurrentTabPropsAndFollowsATabSwitchWhileQueued() async throws {
        let coordinator = try await makeRecoveryCoordinator()
        let viewModel = makeViewModel()
        viewModel.installRecoveryCoordinator(coordinator)
        let tabIDs = try await openTabs(3, in: viewModel)
        makeCurrent(tabIDs[0], among: tabIDs, in: viewModel)

        try await postAndAwaitRefresh(.agentRecoveryCatalogDidChange, from: coordinator, in: viewModel)
        assertComposerOwned(by: tabIDs[0], in: viewModel)

        try await postAndAwaitRefresh(.agentRecoveryComposerStateDidChange, from: coordinator, in: viewModel)
        assertComposerOwned(by: tabIDs[0], in: viewModel)

        // The tab switches after the notification is posted but before it is delivered: the
        // refresh publishes the tab that is current at delivery. Only the middle tab stays
        // MCP-controlled, so the switched-to tab's own props are unlocked.
        viewModel.test_setMCPControlledTabIDs([tabIDs[1]])
        assertComposerOwned(by: tabIDs[0], in: viewModel)
        try await postAndAwaitRefresh(.agentRecoveryCatalogDidChange, from: coordinator, in: viewModel) {
            viewModel.test_setCurrentTabIDOverride(tabIDs[2])
        }
        assertComposerOwned(by: tabIDs[2], in: viewModel)
    }

    func testNoCurrentTabPublishesNoTabPropsInsteadOfAnotherTabs() async throws {
        let viewModel = makeViewModel()
        let tabIDs = try await openTabs(2, in: viewModel)
        makeCurrent(tabIDs[0], among: tabIDs, in: viewModel)
        viewModel.test_setCurrentTabIDOverride(nil)

        viewModel.syncComposerUIState(tabID: tabIDs[1])
        XCTAssertNil(viewModel.ui.composer.props.currentTabID)
        XCTAssertNil(viewModel.ui.composer.props.submitTarget)

        viewModel.refreshRecoveryListUI()
        XCTAssertNil(viewModel.ui.composer.props.currentTabID)
        XCTAssertNil(viewModel.ui.composer.props.submitTarget)
        XCTAssertFalse(viewModel.ui.composer.props.isCurrentTabMCPControlled)
    }

    func testTabRemovalNeverPublishesTheRemovedOrAnotherTab() async throws {
        let viewModel = makeViewModel()
        let tabIDs = try await openTabs(3, in: viewModel)
        let (tabA, tabB, tabC) = (tabIDs[0], tabIDs[1], tabIDs[2])
        makeCurrent(tabA, among: tabIDs, in: viewModel)

        // A removed non-current tab: its late sync publishes nothing, and the refresh keeps A.
        viewModel.test_removeLiveSession(tabID: tabB)
        viewModel.syncComposerUIState(tabID: tabB)
        viewModel.refreshRecoveryListUI()
        assertComposerOwned(by: tabA, in: viewModel)

        // The current tab's session removed: the refresh publishes a non-submittable snapshot of
        // A (never C) without re-creating A's session.
        viewModel.test_removeLiveSession(tabID: tabA)
        viewModel.refreshRecoveryListUI()
        XCTAssertNil(viewModel.session(for: tabA, createIfNeeded: false), "A refresh never materializes a session")
        XCTAssertEqual(viewModel.ui.composer.props.currentTabID, tabA)
        XCTAssertNotEqual(viewModel.ui.composer.props.currentTabID, tabC)
        XCTAssertNil(viewModel.ui.composer.props.submitTarget, "The removed session's target is not left submittable")
        XCTAssertFalse(viewModel.ui.composer.props.isCurrentTabMCPControlled)
    }

    // MARK: - Helpers

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 9701,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    private func openTabs(_ count: Int, in viewModel: AgentModeViewModel) async throws -> [UUID] {
        var tabIDs: [UUID] = []
        for _ in 0 ..< count {
            let tabID = UUID()
            _ = try await viewModel.ensureSessionReady(tabID: tabID)
            tabIDs.append(tabID)
        }
        addTeardownBlock { @MainActor in viewModel.test_setCurrentTabIDOverride(nil) }
        return tabIDs
    }

    /// Makes `tabID` current and every other tab MCP-controlled, so a leaked props snapshot of
    /// another tab shows up as an MCP lock and a foreign submit target.
    private func makeCurrent(_ tabID: UUID, among tabIDs: [UUID], in viewModel: AgentModeViewModel) {
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setMCPControlledTabIDs(Set(tabIDs.filter { $0 != tabID }))
        viewModel.syncComposerUIState()
        assertComposerOwned(by: tabID, in: viewModel)
    }

    private func assertComposerOwned(
        by tabID: UUID,
        in viewModel: AgentModeViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let props = viewModel.ui.composer.props
        XCTAssertEqual(props.currentTabID, tabID, file: file, line: line)
        XCTAssertEqual(props.submitTarget?.tabID, tabID, "Send stays enabled for the current tab", file: file, line: line)
        XCTAssertTrue(props.canSendWithCurrentProvider, "Send stays enabled for the current tab", file: file, line: line)
        XCTAssertFalse(props.isCurrentTabMCPControlled, file: file, line: line)
        XCTAssertFalse(props.areModelControlsDisabled, file: file, line: line)
    }

    private func postAndAwaitRefresh(
        _ name: Notification.Name,
        from coordinator: AgentRecoveryCoordinator,
        in viewModel: AgentModeViewModel,
        beforeDelivery: () -> Void = {}
    ) async throws {
        NotificationCenter.default.post(name: name, object: coordinator)
        beforeDelivery()
        // Sampled after `beforeDelivery`, so only the delivered refresh (never a setter's own
        // synchronous sync) can satisfy the wait; delivery needs the main run loop.
        let syncCountBefore = viewModel.test_syncComposerCallCount
        let refreshed = await RecoveryTestSupport.eventually {
            viewModel.test_syncComposerCallCount > syncCountBefore
        }
        XCTAssertTrue(refreshed, "The observer refreshes the composer")
    }

    private func makeRecoveryCoordinator() async throws -> AgentRecoveryCoordinator {
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentComposerTabOwnershipStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
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
        XCTAssertTrue(startup == .ready)
        return coordinator
    }
}
