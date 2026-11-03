@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class AgentModelSelectionHUDViewModelTests: XCTestCase {
    func testPresentationSnapshotsOnceTogglesAndReplacesMode() {
        let viewModel = AgentModelSelectionHUDViewModel()
        var switchSnapshots = 0
        var handoffSnapshots = 0

        XCTAssertEqual(viewModel.focusAssertionEpoch, 0)
        viewModel.present(mode: .switchModel) {
            switchSnapshots += 1
            return presentation(leaves: [leaf(0, current: true)])
        }
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1)
        XCTAssertEqual(switchSnapshots, 1)

        viewModel.present(mode: .switchModel) {
            switchSnapshots += 1
            return presentation(leaves: [])
        }
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "Toggling closed must not assert focus.")
        XCTAssertEqual(switchSnapshots, 1, "Toggling closed must not rebuild provider snapshots.")

        viewModel.dismiss()
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "Dismissal must not assert focus.")

        viewModel.present(mode: .switchModel) {
            switchSnapshots += 1
            return presentation(leaves: [leaf(0)])
        }
        XCTAssertEqual(viewModel.focusAssertionEpoch, 2)
        viewModel.query = "5.6"
        viewModel.present(mode: .handoffLastReply) {
            handoffSnapshots += 1
            return presentation(leaves: [leaf(1, title: "GPT 5.6")])
        }

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.mode, .handoffLastReply)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 3)
        XCTAssertEqual(viewModel.query, "5.6", "Replacing mode preserves the typeahead query.")
        XCTAssertEqual(switchSnapshots, 2)
        XCTAssertEqual(handoffSnapshots, 1)
    }

    func testFocusAssertionEpochIgnoresCommitAndSuspensionLifecycle() async {
        let viewModel = AgentModelSelectionHUDViewModel()
        let gate = CommitGate()
        var blockedPresentationSnapshots = 0

        viewModel.present(mode: .switchModel) {
            presentation(leaves: [leaf(0, current: true)]) { _ in
                await gate.wait()
            }
        }
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1)

        let commit = Task { await viewModel.commitSelected() }
        await Task.yield()
        XCTAssertEqual(viewModel.phase, .committing)

        viewModel.present(mode: .handoffLastReply) {
            blockedPresentationSnapshots += 1
            return presentation(leaves: [leaf(1, current: true)])
        }
        XCTAssertEqual(blockedPresentationSnapshots, 0)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "A press during commit must not assert focus.")

        viewModel.present(mode: .switchModel) {
            blockedPresentationSnapshots += 1
            return presentation(leaves: [leaf(1, current: true)])
        }
        XCTAssertEqual(blockedPresentationSnapshots, 0)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "A same-mode press during commit must not assert focus.")

        viewModel.suspendForBlockingOverlay()
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "Suspension must not assert focus.")
        gate.release()
        await commit.value
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1, "Commit reset must not assert focus.")

        viewModel.present(mode: .switchModel) {
            presentation(leaves: [leaf(2, current: true)])
        }
        XCTAssertEqual(viewModel.focusAssertionEpoch, 2, "A later fresh presentation must advance monotonically.")
        await viewModel.commitSelected()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 2, "Successful commit reset must not assert focus.")

        viewModel.present(mode: .switchModel) {
            presentation(leaves: [leaf(3, current: true)])
        }
        XCTAssertEqual(viewModel.focusAssertionEpoch, 3)
        viewModel.suspendForBlockingOverlay()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 3, "Non-committing suspension dismissal must not assert focus.")
    }

    func testRankingCapCurrentPreselectionSelectionPreservationWrapAndEscape() {
        let viewModel = AgentModelSelectionHUDViewModel()
        let leaves = (0 ..< 55).map {
            leaf(
                $0,
                title: $0 == 8 ? "GPT 5.6 Sol" : "Model \($0)",
                current: $0 == 54
            )
        }

        viewModel.present(mode: .switchModel) {
            presentation(leaves: leaves)
        }

        XCTAssertEqual(viewModel.filteredLeaves.count, AgentModelSelectionHUDViewModel.displayLimit)
        XCTAssertTrue(viewModel.isShowingLimitedResults)
        XCTAssertEqual(viewModel.totalMatchedLeafCount, leaves.count)
        XCTAssertEqual(viewModel.selectedLeafID, leaves[54].id)
        XCTAssertTrue(viewModel.filteredLeaves.contains(where: { $0.id == leaves[54].id }))

        viewModel.query = "model"
        XCTAssertEqual(viewModel.selectedLeafID, leaves[54].id)
        viewModel.moveSelection(to: leaves[10].id)
        viewModel.query = "model 1"
        XCTAssertEqual(viewModel.selectedLeafID, leaves[10].id)

        viewModel.query = "5.6"
        XCTAssertEqual(viewModel.query, "5.6", "Digits remain ordinary query input.")
        XCTAssertEqual(viewModel.filteredLeaves.map(\.id), [leaves[8].id])
        XCTAssertEqual(viewModel.totalMatchedLeafCount, 1)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedLeafID, leaves[8].id)
        viewModel.query = "model 1"
        let first = try? XCTUnwrap(viewModel.filteredLeaves.first)
        let last = try? XCTUnwrap(viewModel.filteredLeaves.last)
        viewModel.moveSelection(to: first?.id ?? leaves[0].id)
        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedLeafID, last?.id)

        XCTAssertFalse(viewModel.clearQueryOrDismiss())
        XCTAssertTrue(viewModel.queryIsEmpty)
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertTrue(viewModel.clearQueryOrDismiss())
        XCTAssertFalse(viewModel.isPresented)
    }

    func testAsyncFailureKeepsHUDOpenAndDoubleEnterIsGuarded() async {
        enum Failure: LocalizedError {
            case stale

            var errorDescription: String? {
                "Handoff outcome is uncertain (in doubt). Check remote sessions before retrying."
            }
        }

        let viewModel = AgentModelSelectionHUDViewModel()
        let gate = CommitGate()
        var commitCount = 0
        var shouldFail = true
        viewModel.present(mode: .handoffLastReply) {
            presentation(leaves: [leaf(0, current: true)]) { _ in
                commitCount += 1
                await gate.wait()
                if shouldFail {
                    throw Failure.stale
                }
            }
        }

        let firstCommit = Task { await viewModel.commitSelected() }
        await Task.yield()
        XCTAssertEqual(viewModel.phase, .committing)
        XCTAssertTrue(viewModel.isRouting)
        XCTAssertFalse(viewModel.canDismiss)

        await viewModel.commitSelected()
        XCTAssertEqual(commitCount, 1, "A second Enter must not start another handoff.")
        viewModel.dismiss()
        XCTAssertTrue(viewModel.isPresented, "An in-flight handoff cannot be cancelled.")

        gate.release()
        await firstCommit.value
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertFalse(viewModel.isRouting)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Handoff outcome is uncertain (in doubt). Check remote sessions before retrying."
        )

        shouldFail = false
        let successGate = CommitGate()
        viewModel.present(mode: .switchModel) {
            presentation(leaves: [leaf(0, current: true)])
        }
        viewModel.present(mode: .handoffLastReply) {
            presentation(leaves: [leaf(0, current: true)]) { _ in
                commitCount += 1
                await successGate.wait()
            }
        }
        let successCommit = Task { await viewModel.commitSelected() }
        await Task.yield()
        XCTAssertTrue(viewModel.isRouting)
        successGate.release()
        await successCommit.value
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertFalse(viewModel.isRouting)
    }

    func testEmptyQueryWithoutCurrentSelectionDoesNotCommitAndArrowsStartAtEdges() async {
        let viewModel = AgentModelSelectionHUDViewModel()
        let leaves = [leaf(0), leaf(1), leaf(2)]
        var commitCount = 0
        viewModel.present(mode: .switchModel) {
            presentation(leaves: leaves) { _ in
                commitCount += 1
            }
        }

        XCTAssertTrue(viewModel.queryIsEmpty)
        XCTAssertNil(viewModel.selectedLeafID)
        await viewModel.commitSelected()
        XCTAssertEqual(commitCount, 0, "Empty-query Enter must not choose an arbitrary first row.")

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedLeafID, leaves.first?.id)

        viewModel.query = "model"
        XCTAssertEqual(viewModel.selectedLeafID, leaves.first?.id)
        viewModel.query = ""
        XCTAssertNil(viewModel.selectedLeafID)

        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedLeafID, leaves.last?.id)

        viewModel.query = ""
        XCTAssertNil(viewModel.selectedLeafID)
        await viewModel.commitSelected()
        XCTAssertEqual(commitCount, 0)
    }

    func testBlockingOverlaySuspendsCommitWithoutCancellingOrRemounting() async {
        enum Failure: LocalizedError {
            case rejected

            var errorDescription: String? {
                "Rejected after suspension."
            }
        }

        let viewModel = AgentModelSelectionHUDViewModel()
        let failureGate = CommitGate()
        var failureTaskWasCancelled: Bool?
        viewModel.present(mode: .handoffLastReply) {
            presentation(leaves: [leaf(0, current: true)]) { _ in
                await failureGate.wait()
                failureTaskWasCancelled = Task.isCancelled
                throw Failure.rejected
            }
        }

        let failedCommit = Task { await viewModel.commitSelected() }
        await Task.yield()
        XCTAssertEqual(viewModel.phase, .committing)
        viewModel.suspendForBlockingOverlay()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .committing)
        XCTAssertTrue(viewModel.isRouting)

        failureGate.release()
        await failedCommit.value
        XCTAssertEqual(failureTaskWasCancelled, false)
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertFalse(viewModel.isRouting)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.filteredLeaves.isEmpty)
        XCTAssertNil(viewModel.selectedLeafID)

        let successGate = CommitGate()
        var successTaskWasCancelled: Bool?
        viewModel.present(mode: .handoffLastReply) {
            presentation(leaves: [leaf(1, current: true)]) { _ in
                await successGate.wait()
                successTaskWasCancelled = Task.isCancelled
            }
        }
        let successfulCommit = Task { await viewModel.commitSelected() }
        await Task.yield()
        viewModel.suspendForBlockingOverlay()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .committing)

        successGate.release()
        await successfulCommit.value
        XCTAssertEqual(successTaskWasCancelled, false)
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertFalse(viewModel.isRouting)
        XCTAssertTrue(viewModel.filteredLeaves.isEmpty)
    }

    func testUnavailablePresentationShowsMessageAndCannotCommit() async {
        let viewModel = AgentModelSelectionHUDViewModel()
        var presentationCount = 0
        var commitCount = 0
        let unavailablePresentation = {
            presentationCount += 1
            return AgentModelSelectionHUDPresentation(
                title: "Quick Handoff",
                subtitle: "No destination",
                index: AgentModelSelectionIndex(leaves: []),
                noticeText: "Target reply",
                unavailableMessage: "No completed assistant reply to hand off.",
                commit: { _ in commitCount += 1 }
            )
        }

        viewModel.present(mode: .handoffLastReply, presentationProvider: unavailablePresentation)

        XCTAssertEqual(
            viewModel.phase,
            .unavailable(message: "No completed assistant reply to hand off.")
        )
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1)
        XCTAssertTrue(viewModel.canDismiss)
        XCTAssertEqual(viewModel.noticeText, "Target reply")
        await viewModel.commitSelected()
        XCTAssertEqual(commitCount, 0)
        XCTAssertTrue(viewModel.isPresented)

        viewModel.query = "destination"
        XCTAssertFalse(viewModel.clearQueryOrDismiss())
        XCTAssertTrue(viewModel.queryIsEmpty)
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertTrue(viewModel.clearQueryOrDismiss())
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 1)

        viewModel.present(mode: .handoffLastReply, presentationProvider: unavailablePresentation)
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 2)
        viewModel.present(mode: .handoffLastReply, presentationProvider: unavailablePresentation)
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 2, "Same-mode toggle-dismiss must not assert focus.")
        XCTAssertEqual(presentationCount, 2, "Same-mode toggle-dismiss must not rebuild the presentation.")
    }

    func testSuccessfulModelSelectionRunsFocusCallbackOnceAfterLogicalReset() async {
        let viewModel = AgentModelSelectionHUDViewModel()
        var observations: [PostCommitObservation] = []
        var commitCount = 0
        viewModel.present(mode: .switchModel) {
            presentation(
                leaves: [leaf(0, current: true), leaf(1)],
                commit: { _ in commitCount += 1 },
                onSuccessfulModelSelection: {
                    observations.append(PostCommitObservation(viewModel))
                }
            )
        }
        XCTAssertTrue(observations.isEmpty, "Presenting the picker must not request composer focus.")

        await viewModel.commitSelected()

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(
            observations,
            [.dismissedReadyState],
            "The callback runs exactly once, after the HUD has logically dismissed."
        )
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .ready)

        await viewModel.commitSelected()
        XCTAssertEqual(commitCount, 1, "A repeated Enter after reset must not commit again.")
        XCTAssertEqual(observations.count, 1, "A repeated Enter after reset must not replay focus.")
    }

    func testFailedModelSelectionNeverRunsFocusCallbackAndRetryRunsItOnce() async {
        enum Failure: LocalizedError {
            case rejected

            var errorDescription: String? {
                "Model rejected."
            }
        }

        let viewModel = AgentModelSelectionHUDViewModel()
        var shouldFail = true
        var successCount = 0
        viewModel.present(mode: .switchModel) {
            presentation(
                leaves: [leaf(0, current: true)],
                commit: { _ in
                    if shouldFail {
                        throw Failure.rejected
                    }
                },
                onSuccessfulModelSelection: { successCount += 1 }
            )
        }

        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 0, "A failed commit must not move focus to the composer.")
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.errorMessage, "Model rejected.")

        shouldFail = false
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 1, "A successful retry in the same presentation restores focus once.")
        XCTAssertFalse(viewModel.isPresented)
    }

    func testFocusCallbackNeverRunsForHandoffDismissalToggleOrIdleTabChange() async {
        let viewModel = AgentModelSelectionHUDViewModel()
        var successCount = 0
        func focusingPresentation(_ index: Int) -> AgentModelSelectionHUDPresentation {
            presentation(
                leaves: [leaf(index, current: true)],
                onSuccessfulModelSelection: { successCount += 1 }
            )
        }

        viewModel.activeTabDidChange()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.focusAssertionEpoch, 0, "An idle tab change is a no-op.")

        viewModel.present(mode: .handoffLastReply) { focusingPresentation(0) }
        await viewModel.commitSelected()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(successCount, 0, "Handoff never restores the source composer focus.")

        viewModel.present(mode: .switchModel) { focusingPresentation(1) }
        viewModel.present(mode: .handoffLastReply) { focusingPresentation(2) }
        XCTAssertEqual(viewModel.mode, .handoffLastReply)
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 0, "Replacing switch mode with handoff drops the focus callback.")

        viewModel.present(mode: .switchModel) { focusingPresentation(3) }
        viewModel.dismiss()
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 0, "Dismissal must not request composer focus.")

        viewModel.present(mode: .switchModel) { focusingPresentation(4) }
        viewModel.present(mode: .switchModel) { focusingPresentation(5) }
        XCTAssertFalse(viewModel.isPresented)
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 0, "Toggle dismissal must not request composer focus.")

        viewModel.present(mode: .switchModel) { focusingPresentation(6) }
        viewModel.activeTabDidChange()
        XCTAssertFalse(viewModel.isPresented, "A tab change dismisses a ready HUD.")
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 0, "A tab-change dismissal must not request composer focus.")

        viewModel.present(mode: .switchModel) { focusingPresentation(7) }
        await viewModel.commitSelected()
        XCTAssertEqual(successCount, 1, "A later fresh switch-model success still restores focus.")
    }

    func testTabChangeOrSuspensionDuringCommitCompletesWithoutFocusCallback() async {
        enum Interruption {
            case activeTabChanged
            case blockingOverlay
        }

        let cases: [(mode: AgentModelSelectionHUDMode, interruption: Interruption)] = [
            (.switchModel, .activeTabChanged),
            (.switchModel, .blockingOverlay),
            // Every real handoff switches tabs while committing.
            (.handoffLastReply, .activeTabChanged)
        ]
        for (mode, interruption) in cases {
            let label = "\(mode) + \(interruption)"
            let viewModel = AgentModelSelectionHUDViewModel()
            let gate = EnteredCommitGate()
            var commitCount = 0
            var successCount = 0
            viewModel.present(mode: mode) {
                presentation(
                    leaves: [leaf(0, current: true)],
                    commit: { _ in
                        commitCount += 1
                        await gate.enterAndWaitForRelease()
                    },
                    onSuccessfulModelSelection: { successCount += 1 }
                )
            }

            let commit = Task { await viewModel.commitSelected() }
            await gate.waitUntilEntered()
            XCTAssertEqual(viewModel.phase, .committing, label)
            XCTAssertEqual(viewModel.isRouting, mode == .handoffLastReply, label)

            switch interruption {
            case .activeTabChanged:
                viewModel.activeTabDidChange()
                XCTAssertTrue(
                    viewModel.isPresented,
                    "\(label): a committing HUD is protected from tab-change dismissal."
                )
            case .blockingOverlay:
                viewModel.suspendForBlockingOverlay()
                XCTAssertFalse(viewModel.isPresented, label)
            }
            XCTAssertEqual(viewModel.phase, .committing, label)

            gate.release()
            await commit.value

            XCTAssertEqual(commitCount, 1, "\(label) must not cancel or repeat the commit.")
            XCTAssertEqual(successCount, 0, "\(label) leaves no post-commit focus.")
            XCTAssertFalse(viewModel.isPresented, label)
            XCTAssertEqual(viewModel.phase, .ready, label)
            XCTAssertFalse(viewModel.isRouting, label)
            XCTAssertNil(viewModel.errorMessage, label)

            var freshSuccessCount = 0
            viewModel.present(mode: .switchModel) {
                presentation(
                    leaves: [leaf(1, current: true)],
                    onSuccessfulModelSelection: { freshSuccessCount += 1 }
                )
            }
            await viewModel.commitSelected()
            XCTAssertEqual(
                freshSuccessCount,
                1,
                "After \(label), the next presentation requests focus normally."
            )
            XCTAssertEqual(successCount, 0, "The invalidated callback is never revived.")
        }
    }

    func testTabChangeDuringFailedCommitKeepsErrorAndRetryNeverRevivesFocusCallback() async {
        enum Failure: LocalizedError {
            case rejected

            var errorDescription: String? {
                "Rejected after tab change."
            }
        }

        for mode in AgentModelSelectionHUDMode.allCases {
            let viewModel = AgentModelSelectionHUDViewModel()
            let gate = EnteredCommitGate()
            var shouldFail = true
            var commitCount = 0
            var successCount = 0
            viewModel.present(mode: mode) {
                presentation(
                    leaves: [leaf(0, current: true)],
                    commit: { _ in
                        commitCount += 1
                        await gate.enterAndWaitForRelease()
                        if shouldFail {
                            throw Failure.rejected
                        }
                    },
                    onSuccessfulModelSelection: { successCount += 1 }
                )
            }

            let commit = Task { await viewModel.commitSelected() }
            await gate.waitUntilEntered()
            viewModel.activeTabDidChange()
            XCTAssertTrue(viewModel.isPresented, "\(mode)")
            XCTAssertEqual(viewModel.phase, .committing, "\(mode)")
            gate.release()
            await commit.value

            XCTAssertTrue(viewModel.isPresented, "\(mode): a failure after a tab change keeps the HUD open.")
            XCTAssertEqual(viewModel.phase, .ready, "\(mode)")
            XCTAssertFalse(viewModel.isRouting, "\(mode)")
            XCTAssertEqual(viewModel.errorMessage, "Rejected after tab change.", "\(mode)")
            XCTAssertEqual(successCount, 0, "\(mode): failure never requests focus.")

            // The gate is already released, so the retry completes without suspending.
            shouldFail = false
            await viewModel.commitSelected()
            XCTAssertEqual(commitCount, 2, "\(mode)")
            XCTAssertFalse(viewModel.isPresented, "\(mode)")
            XCTAssertNil(viewModel.errorMessage, "\(mode)")
            XCTAssertEqual(
                successCount,
                0,
                "\(mode): a retry after the tab change must not revive the invalidated callback."
            )
        }
    }

    private func presentation(
        leaves: [AgentModelSelectionLeaf],
        commit: @escaping @MainActor (AgentModelSelectionLeaf) async throws -> Void = { _ in },
        onSuccessfulModelSelection: (@MainActor () -> Void)? = nil
    ) -> AgentModelSelectionHUDPresentation {
        AgentModelSelectionHUDPresentation(
            title: "Models",
            subtitle: "Test",
            index: AgentModelSelectionIndex(leaves: leaves),
            noticeText: nil,
            unavailableMessage: nil,
            onSuccessfulModelSelection: onSuccessfulModelSelection,
            commit: commit
        )
    }

    private func leaf(
        _ index: Int,
        title: String? = nil,
        current: Bool = false
    ) -> AgentModelSelectionLeaf {
        let raw = "model-\(index)"
        return AgentModelSelectionLeaf(
            id: AgentModelSelectionLeafID(
                source: .local,
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: raw,
                effortRaw: "high"
            ),
            commitPayload: .local(
                agent: .codexExec,
                modelRaw: raw,
                reasoningEffortRaw: "high"
            ),
            title: title ?? "Model \(index)",
            providerSubtitle: "Codex",
            detail: nil,
            showsWarning: false,
            isCurrentSelection: current,
            catalogOrder: index,
            searchFields: AgentSessionSearchFields(
                title: nil,
                primary: ["Codex"],
                model: [title ?? "Model \(index)"],
                secondary: [],
                identifier: [raw, String(index)]
            )
        )
    }
}

/// State observed by the post-commit focus callback at the moment it runs.
private struct PostCommitObservation: Equatable {
    let isPresented: Bool
    let phase: AgentModelSelectionHUDPhase
    let isRouting: Bool
    let hasLeaves: Bool
    let hasSelection: Bool
    let errorMessage: String?

    static var dismissedReadyState: PostCommitObservation {
        PostCommitObservation(
            isPresented: false,
            phase: .ready,
            isRouting: false,
            hasLeaves: false,
            hasSelection: false,
            errorMessage: nil
        )
    }

    @MainActor
    init(_ viewModel: AgentModelSelectionHUDViewModel) {
        isPresented = viewModel.isPresented
        phase = viewModel.phase
        isRouting = viewModel.isRouting
        hasLeaves = !viewModel.filteredLeaves.isEmpty
        hasSelection = viewModel.selectedLeafID != nil
        errorMessage = viewModel.errorMessage
    }

    private init(
        isPresented: Bool,
        phase: AgentModelSelectionHUDPhase,
        isRouting: Bool,
        hasLeaves: Bool,
        hasSelection: Bool,
        errorMessage: String?
    ) {
        self.isPresented = isPresented
        self.phase = phase
        self.isRouting = isRouting
        self.hasLeaves = hasLeaves
        self.hasSelection = hasSelection
        self.errorMessage = errorMessage
    }
}

/// Deterministic handshake: the test resumes only once the commit action is
/// suspended inside the gate, so interruptions land while `.committing`.
@MainActor
private final class EnteredCommitGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWaitForRelease() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class CommitGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
