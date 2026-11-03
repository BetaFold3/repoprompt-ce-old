@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class WorktreeMergeReviewStateTests: XCTestCase {
    func testSourceBindingResolutionRequiresRepoRootWhenMultipleBindingsExist() throws {
        let first = makeBinding(logicalRootName: "App", logicalRootPath: "/repo/app", worktreeID: "wt_app")
        let second = makeBinding(logicalRootName: "Lib", logicalRootPath: "/repo/lib", worktreeID: "wt_lib")

        XCTAssertThrowsError(try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("ambiguous") || (error as? LocalizedError)?.errorDescription?.contains("Multiple") == true)
        }

        let resolvedByName = try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: "Lib")
        XCTAssertEqual(resolvedByName.worktreeID, "wt_lib")

        let resolvedByPath = try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: "/repo/app")
        XCTAssertEqual(resolvedByPath.worktreeID, "wt_app")
    }

    func testSourceBindingResolutionBuildsEndpointFromSessionBinding() throws {
        let binding = makeBinding(
            logicalRootName: "App",
            logicalRootPath: "/repo/app",
            worktreeID: "wt_app",
            branch: "feature/merge",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )

        let endpoint = try WorktreeMergeSourceBindingResolver.endpoint(from: binding)

        XCTAssertEqual(endpoint.worktreeID, "wt_app")
        XCTAssertEqual(endpoint.repositoryID, binding.repositoryID)
        XCTAssertEqual(endpoint.repoKey, binding.repoKey)
        XCTAssertEqual(endpoint.path, binding.worktreeRootPath)
        XCTAssertEqual(endpoint.branch, "feature/merge")
        XCTAssertEqual(endpoint.head, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    func testPreviewOperationUpsertAndApprovalStateAreReflectedInRunSnapshot() {
        var operations: [AgentSessionWorktreeMergeOperation] = []
        let preview = makePreview(operationID: "merge_state")
        let operation = AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .awaitingApproval, now: stateNow)
        AgentWorktreeMergeCoordinator.upsert(operation, in: &operations)

        XCTAssertEqual(operations.map(\.id), ["merge_state"])
        XCTAssertEqual(operations[0].status, .awaitingApproval)
        XCTAssertEqual(operations.activeWorktreeMergeSummaries.first?.status, .awaitingApproval)

        let review = PendingWorktreeMergeReview(
            id: reviewID,
            scope: WorktreeMergeReviewScope(windowID: 7, tabID: tabID),
            preview: preview,
            createdAt: stateNow
        )
        let snapshot = AgentRunInteractionUISnapshot(
            currentTabID: tabID,
            runState: .waitingForApproval,
            runningStatusText: nil,
            activeAgentRunStartedAt: nil,
            waitingPrompt: nil,
            pendingAskUser: nil,
            pendingUserInputRequest: nil,
            pendingApproval: nil,
            pendingPermissionsRequest: nil,
            pendingMCPElicitationRequest: nil,
            pendingApplyEditsReview: nil,
            pendingWorktreeMergeReview: review,
            activeRunID: nil,
            activeAgentSessionID: sessionID,
            activeRunAttemptID: nil,
            latestUserSequenceIndex: nil,
            canForkCurrentSession: false,
            selectedAgent: .codexExec,
            selectedModelRaw: AgentModel.defaultModel.rawValue,
            selectedReasoningEffortRaw: nil
        )

        XCTAssertEqual(snapshot.pendingWorktreeMergeReview?.operationID, "merge_state")
        XCTAssertTrue(snapshot.isWaitingForInstruction == false)
    }

    func testRejectedReviewMarksOperationCancelledWithoutApplyResult() throws {
        var operations = [AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_reject"),
            status: .awaitingApproval,
            now: stateNow
        )]

        try AgentWorktreeMergeCoordinator.update(operationID: "merge_reject", in: &operations, now: stateNow) { operation in
            operation.status = .cancelled
            operation.completedAt = stateNow
            operation.lastError = "Rejected by user"
        }

        XCTAssertEqual(operations[0].status, .cancelled)
        XCTAssertEqual(operations[0].completedAt, stateNow)
        XCTAssertEqual(operations[0].lastError, "Rejected by user")
        XCTAssertNil(operations[0].resultCommit)
        XCTAssertTrue(operations.activeWorktreeMergeSummaries.isEmpty)
    }

    func testAcceptedApplyResultUpdatesCompletedAndConflictedStates() {
        var completed = AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_apply"),
            status: .applying,
            now: stateNow
        )
        AgentWorktreeMergeCoordinator.apply(
            result: GitWorktreeMergeApplyResult(
                status: .completed,
                source: completed.source,
                target: completed.target,
                sourceHead: completed.sourceHead,
                targetHeadBefore: completed.targetHeadBefore,
                targetHeadAfter: "dddddddddddddddddddddddddddddddddddddddd",
                mergeCommit: "dddddddddddddddddddddddddddddddddddddddd"
            ),
            to: &completed,
            now: stateNow
        )

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.resultCommit, "dddddddddddddddddddddddddddddddddddddddd")
        XCTAssertEqual(completed.completedAt, stateNow)

        var conflicted = AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_conflict"),
            status: .applying,
            now: stateNow
        )
        AgentWorktreeMergeCoordinator.apply(
            result: GitWorktreeMergeApplyResult(
                status: .conflicted,
                source: conflicted.source,
                target: conflicted.target,
                sourceHead: conflicted.sourceHead,
                targetHeadBefore: conflicted.targetHeadBefore,
                conflictFiles: ["b.txt", "a.txt"]
            ),
            to: &conflicted,
            now: stateNow
        )

        XCTAssertEqual(conflicted.status, .conflicted)
        XCTAssertEqual(conflicted.conflictFiles, ["a.txt", "b.txt"])
        XCTAssertNil(conflicted.completedAt)
        XCTAssertEqual(conflicted.activeSummary?.conflictFileCount, 2)
    }

    // MARK: - Step 5c preserved reviews (view-model flows)

    @MainActor
    func testPreservedReviewIsDurableBeforeItIsShownAndAppliesFromTheRetainedCopy() async throws {
        let harness = try await makeMergeHarness(windowID: 95501)
        let bundle = try makeBundle(operationID: "merge_preserve")
        let log = MergeCallLog()
        installRecorders(harness, log: log, operationID: bundle.preview.operationID)

        let task = Task { @MainActor in
            try await harness.viewModel.requestWorktreeMergeReviewAndApply(
                preview: bundle.preview,
                sessionID: harness.sessionID,
                timeoutSeconds: 60
            )
        }
        try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
        let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview)
        let reserved = try XCTUnwrap(operation(bundle.preview.operationID, in: harness))
        XCTAssertEqual(reserved.status, .awaitingApproval)
        XCTAssertEqual(reserved.reviewPreservation, .live)
        let retained = try XCTUnwrap(reserved.previewArtifacts)
        XCTAssertTrue(GitWorktreeMergeReviewArtifactRetention.isRetained(retained))
        XCTAssertEqual(retained.snapshotID, bundle.artifacts.snapshotID)
        XCTAssertEqual(shown.artifacts, retained, "The card shows the retained bundle, not the original")
        XCTAssertEqual(
            dedupe(log.events),
            ["save:awaiting_approval:live:hidden"],
            "A covering written save of the preserved review precedes publication"
        )
        let durable = try await durableOperation(bundle.preview.operationID, in: harness)
        XCTAssertEqual(durable?.reviewPreservation, .live, "Durable before it is shown")
        XCTAssertEqual(durable?.previewArtifacts, retained)

        // The original snapshot (temporary or tab-scoped) disappears; the review still works.
        try FileManager.default.removeItem(at: bundle.directory)
        harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .accept)
        let result = try await task.value

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(
            dedupe(log.events),
            ["save:awaiting_approval:live:hidden", "save:applying:-:hidden", "apply"],
            "The applying save precedes the one VCS handoff"
        )
        XCTAssertEqual(log.applies.map(\.preview.artifacts), [retained])
        let final = try XCTUnwrap(operation(bundle.preview.operationID, in: harness))
        XCTAssertEqual(final.status, .completed)
        XCTAssertNil(final.reviewPreservation)
        XCTAssertNil(harness.session.pendingWorktreeMergeReview)
    }

    @MainActor
    func testArtifactlessReviewIsRefusedBeforeAnythingIsReservedShownOrSaved() async throws {
        let harness = try await makeMergeHarness(windowID: 95502)
        let log = MergeCallLog()
        let preview = makePreview(operationID: "merge_artifactless", artifacts: nil)
        installRecorders(harness, log: log, operationID: preview.operationID)

        do {
            _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: preview, sessionID: harness.sessionID, timeoutSeconds: 60)
            XCTFail("An artifactless review is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("no published artifacts"), "\(error)")
        }
        XCTAssertNil(operation(preview.operationID, in: harness), "Nothing is reserved")

        // The stored-operation route refuses it too and leaves the previewed operation unchanged.
        harness.viewModel.test_worktreeMergeInspectOverride = { _ in preview.inspection }
        let previewed = AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .previewed, now: stateNow)
        AgentWorktreeMergeCoordinator.upsert(previewed, in: &harness.session.worktreeMergeOperations)
        do {
            _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(sessionID: harness.sessionID, operationID: preview.operationID, timeoutSeconds: 60)
            XCTFail("An artifactless review is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("no published artifacts"), "\(error)")
        }
        XCTAssertEqual(operation(preview.operationID, in: harness), previewed)
        XCTAssertNil(harness.session.pendingWorktreeMergeReview)
        XCTAssertEqual(log.events.filter { $0.hasPrefix("save") }, [], "Nothing was saved for it")
        XCTAssertEqual(log.applies.count, 0)
    }

    @MainActor
    func testNonCoveringPublicationSaveRefusesAndWithdrawsWithoutShowingOrGit() async throws {
        let outcomes: [AgentModeViewModel.SessionSaveOutcome] = [.notWritten, .suppressed, .resetAcknowledged]
        for (index, outcome) in outcomes.enumerated() {
            let harness = try await makeMergeHarness(windowID: 95510 + index)
            let bundle = try makeBundle(operationID: "merge_publication_\(index)")
            let log = MergeCallLog()
            installRecorders(harness, log: log, operationID: bundle.preview.operationID) { operation in
                operation?.reviewPreservation == .live ? outcome : nil
            }

            do {
                _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
                XCTFail("\(outcome): refused")
            } catch {
                XCTAssertTrue("\(error)".contains("wasn't shown"), "\(outcome): \(error)")
            }
            let withdrawn = try XCTUnwrap(operation(bundle.preview.operationID, in: harness))
            XCTAssertEqual(withdrawn.status, .cancelled, "\(outcome)")
            XCTAssertNil(withdrawn.reviewPreservation, "\(outcome)")
            XCTAssertEqual(withdrawn.lastError, AgentModeViewModel.worktreeMergeReviewNotSavedText, "\(outcome)")
            XCTAssertNil(harness.session.pendingWorktreeMergeReview, "\(outcome): never shown")
            XCTAssertFalse(log.events.contains { $0.hasSuffix(":shown") }, "\(outcome)")
            XCTAssertNil(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID), "\(outcome)")
            XCTAssertEqual(log.applies.count, 0, "\(outcome): 0 VCS calls")
        }
    }

    @MainActor
    func testFailedApplyingSaveNeverRunsGitAndKeepsTheKnownUnstartedState() async throws {
        // Review route: the accepted review returns to read-only history.
        let harness = try await makeMergeHarness(windowID: 95520)
        let bundle = try makeBundle(operationID: "merge_applying_review")
        let log = MergeCallLog()
        installRecorders(harness, log: log, operationID: bundle.preview.operationID) { operation in
            operation?.status == .applying ? .notWritten : nil
        }
        let task = Task { @MainActor in
            try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
        }
        try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
        let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview)
        let retained = try XCTUnwrap(operation(bundle.preview.operationID, in: harness)?.previewArtifacts)
        harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .accept)
        do {
            _ = try await task.value
            XCTFail("Not started without a covering applying save")
        } catch {
            XCTAssertTrue("\(error)".contains("Git was not changed"), "\(error)")
        }
        let history = try XCTUnwrap(operation(bundle.preview.operationID, in: harness))
        XCTAssertEqual(history.status, .awaitingApproval, "Never marked failed as if Git ran")
        XCTAssertTrue(history.isHistoricalReview)
        XCTAssertEqual(history.reviewPreservation?.endedReason, AgentModeViewModel.worktreeMergeNotStartedText)
        XCTAssertEqual(history.previewArtifacts, retained)
        XCTAssertEqual(log.applies.count, 0, "0 VCS calls")
        XCTAssertEqual(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id, bundle.preview.operationID)

        // Direct confirmed route: artifactless stays supported; a failed save returns it to previewed.
        let direct = makePreview(operationID: "merge_direct", artifacts: nil)
        let directLog = MergeCallLog()
        installRecorders(harness, log: directLog, operationID: direct.operationID) { operation in
            operation?.status == .applying ? .notWritten : nil
        }
        harness.viewModel.test_worktreeMergeInspectOverride = { _ in direct.inspection }
        let previewed = AgentWorktreeMergeCoordinator.makeOperation(preview: direct, status: .previewed, now: stateNow)
        AgentWorktreeMergeCoordinator.upsert(previewed, in: &harness.session.worktreeMergeOperations)
        do {
            _ = try await harness.viewModel.applyConfirmedWorktreeMerge(sessionID: harness.sessionID, operationID: direct.operationID)
            XCTFail("Not started without a covering applying save")
        } catch {
            XCTAssertTrue("\(error)".contains("Git was not changed"), "\(error)")
        }
        let unstarted = try XCTUnwrap(operation(direct.operationID, in: harness))
        XCTAssertEqual(unstarted.status, .previewed)
        XCTAssertEqual(unstarted.lastError, AgentModeViewModel.worktreeMergeNotStartedText)
        XCTAssertEqual(directLog.applies.count, 0, "0 VCS calls")

        installRecorders(harness, log: directLog, operationID: direct.operationID)
        let result = try await harness.viewModel.applyConfirmedWorktreeMerge(sessionID: harness.sessionID, operationID: direct.operationID)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(directLog.applies.count, 1)
        XCTAssertNil(directLog.applies.first?.preview.artifacts, "Artifactless direct apply keeps working")
        XCTAssertEqual(Array(dedupe(directLog.events).suffix(2)), ["save:applying:-:hidden", "apply"])
        XCTAssertEqual(operation(direct.operationID, in: harness)?.status, .completed)
    }

    @MainActor
    func testOwnerChangeOrCancellationAtEachNewAwaitPublishesAndAppliesNothing() async throws {
        enum Change: String, CaseIterable { case reset, bindingTransitionInProgress, bindingRebound, operationReplaced, cancelled }
        let points: [WorktreeMergeAwaitPoint] = [.retention, .publicationSave, .applyingSave]
        var windowID = 95530
        for point in points {
            for change in Change.allCases {
                let label = "\(point)/\(change)"
                windowID += 1
                let harness = try await makeMergeHarness(windowID: windowID)
                let bundle = try makeBundle(operationID: "merge_await_\(windowID)")
                let operationID = bundle.preview.operationID
                let log = MergeCallLog()
                installRecorders(harness, log: log, operationID: operationID)
                harness.viewModel.test_worktreeMergeAwaitHook = { session, reached in
                    guard reached == point else { return }
                    switch change {
                    case .reset:
                        _ = await harness.viewModel.clearChatPreservingRecovery(tabID: session.tabID)
                    case .bindingTransitionInProgress:
                        _ = session.beginPersistentBindingTransition()
                    case .bindingRebound:
                        let generation = session.beginPersistentBindingTransition()
                        session.finishPersistentBindingTransition(generation: generation)
                    case .operationReplaced:
                        if let index = session.worktreeMergeOperations.firstIndex(where: { $0.id == operationID }) {
                            session.worktreeMergeOperations[index].lastError = "replacement"
                        }
                    case .cancelled:
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                let task = Task { @MainActor in
                    try await harness.viewModel.requestWorktreeMergeReviewAndApply(
                        preview: bundle.preview,
                        sessionID: harness.sessionID,
                        timeoutSeconds: point == .applyingSave ? 60 : 5
                    )
                }
                if point == .applyingSave {
                    try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
                    let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview, label)
                    harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .accept)
                }
                do {
                    _ = try await task.value
                    XCTFail("\(label): a stale or cancelled request never proceeds")
                } catch {}
                harness.viewModel.test_worktreeMergeAwaitHook = nil

                XCTAssertEqual(log.applies.count, 0, "\(label): 0 VCS calls")
                XCTAssertNil(harness.session.pendingWorktreeMergeReview, "\(label): no live card")
                if point != .applyingSave {
                    XCTAssertFalse(log.events.contains { $0.hasSuffix(":shown") }, "\(label): never shown")
                }
                let stored = operation(operationID, in: harness)
                switch (point, change) {
                case (_, .operationReplaced):
                    // The replacement is never retargeted, withdrawn, or restored by the stale request.
                    XCTAssertEqual(stored?.lastError, "replacement", label)
                    XCTAssertEqual(stored?.status, point == .applyingSave ? .applying : .awaitingApproval, label)
                case (.applyingSave, _):
                    // Accepted but known unstarted: read-only history, never `failed`.
                    XCTAssertEqual(stored?.status, .awaitingApproval, label)
                    XCTAssertEqual(stored?.isHistoricalReview, true, label)
                default:
                    // Never shown: withdrawn.
                    XCTAssertEqual(stored?.status, .cancelled, label)
                    XCTAssertNil(stored?.reviewPreservation, label)
                }
            }
        }
    }

    @MainActor
    func testExplicitRejectWithdrawsButTimeoutLifecycleAndReplacementPreserveHistory() async throws {
        enum Ending: String, CaseIterable { case reject, timeout, lifecycle, replacement }
        for (index, ending) in Ending.allCases.enumerated() {
            let harness = try await makeMergeHarness(windowID: 95560 + index)
            let bundle = try makeBundle(operationID: "merge_ending_\(index)")
            let log = MergeCallLog()
            installRecorders(harness, log: log, operationID: bundle.preview.operationID)
            let task = Task { @MainActor in
                try await harness.viewModel.requestWorktreeMergeReviewAndApply(
                    preview: bundle.preview,
                    sessionID: harness.sessionID,
                    timeoutSeconds: ending == .timeout ? 0.05 : 60
                )
            }
            try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
            let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview)
            var newer: (bundle: MergeBundle, task: Task<GitWorktreeMergeApplyResult, Error>)?
            switch ending {
            case .reject:
                harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .reject(reason: "No thanks"))
            case .timeout:
                break
            case .lifecycle:
                harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
            case .replacement:
                let newerBundle = try makeBundle(operationID: "merge_newer_\(index)")
                let newerTask = Task { @MainActor in
                    try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: newerBundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
                }
                newer = (newerBundle, newerTask)
            }
            do {
                _ = try await task.value
                XCTFail("\(ending): never applied")
            } catch {}

            let ended = try XCTUnwrap(operation(bundle.preview.operationID, in: harness), "\(ending)")
            if ending == .reject {
                XCTAssertEqual(ended.status, .cancelled, "Explicit reject withdraws")
                XCTAssertNil(ended.reviewPreservation)
                XCTAssertEqual(ended.lastError, "No thanks")
            } else {
                XCTAssertEqual(ended.status, .awaitingApproval, "\(ending)")
                XCTAssertTrue(ended.isHistoricalReview, "\(ending) preserves read-only history")
                let expectedReason: String? = switch ending {
                case .timeout: WorktreeMergeReviewDecision.timeout.cancelledReason
                case .lifecycle: "Run ended"
                default: AgentModeViewModel.worktreeMergeReviewReplacedReason
                }
                XCTAssertEqual(ended.reviewPreservation?.endedReason, expectedReason, "\(ending)")
            }
            if let newer {
                try await waitUntil { harness.session.pendingWorktreeMergeReview?.operationID == newer.bundle.preview.operationID }
                XCTAssertEqual(
                    harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id,
                    bundle.preview.operationID,
                    "The older review is history while the newer one is live"
                )
                harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Test cleanup")
                _ = try? await newer.task.value
            }
            XCTAssertEqual(log.applies.count, 0, "\(ending): 0 VCS calls")
            XCTAssertNil(harness.session.pendingWorktreeMergeReview, "\(ending)")

            if ending != .reject {
                // Reject was already acknowledged by its own covering save (the session is clean);
                // the other endings are written by an explicit flush here.
                let saved = await harness.viewModel.flushSave(for: harness.tabID)
                XCTAssertTrue(saved, "\(ending)")
            }
            let durable = try await durableOperation(bundle.preview.operationID, in: harness)
            XCTAssertEqual(durable?.status, ended.status, "\(ending)")
            XCTAssertEqual(durable?.reviewPreservation, ended.reviewPreservation, "\(ending)")
        }
    }

    @MainActor
    func testHistoricalViewCopyAndDiscardNeverRunGitAndCannotBeApplied() async throws {
        let harness = try await makeMergeHarness(windowID: 95570)
        let prediction = GitWorktreeMergeConflictPrediction(status: .conflicts, files: ["Shared.swift"], message: "Recorded")
        let bundle = try makeBundle(operationID: "merge_history", conflictPrediction: prediction)
        let log = MergeCallLog()
        installRecorders(harness, log: log, operationID: bundle.preview.operationID)
        let task = Task { @MainActor in
            try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
        }
        try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
        harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
        _ = try? await task.value
        let operationID = bundle.preview.operationID
        let history = try XCTUnwrap(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID))
        XCTAssertEqual(history.id, operationID)
        try FileManager.default.removeItem(at: bundle.directory)

        // Status: history is never the implicit active operation; an explicit lookup still returns it.
        XCTAssertThrowsError(try harness.viewModel.statusWorktreeMerge(sessionID: harness.sessionID, operationID: nil)) { error in
            XCTAssertTrue("\(error)".contains("no active worktree merge operation"), "\(error)")
        }
        XCTAssertEqual(try harness.viewModel.statusWorktreeMerge(sessionID: harness.sessionID, operationID: operationID).id, operationID)
        let previewedSibling = AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_history_sibling", artifacts: nil),
            status: .previewed,
            now: stateNow
        )
        AgentWorktreeMergeCoordinator.upsert(previewedSibling, in: &harness.session.worktreeMergeOperations)
        XCTAssertEqual(
            try harness.viewModel.statusWorktreeMerge(sessionID: harness.sessionID, operationID: nil).id,
            previewedSibling.id,
            "The one non-historical operation is the implicit active one"
        )
        harness.session.worktreeMergeOperations.removeAll { $0.id == previewedSibling.id }

        // View: the saved patch and the recorded (past) prediction, from the retained copy.
        let saved = await harness.viewModel.historicalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID)
        XCTAssertEqual(saved, .patch(Self.bundlePatch))
        let truncated = await harness.viewModel.historicalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID, maximumBytes: 4)
        guard case .unavailable = truncated else { return XCTFail("Oversized patch is unavailable, never truncated: \(truncated)") }
        let past = await harness.viewModel.historicalWorktreeMergePastPrediction(tabID: harness.tabID, operationID: operationID)
        XCTAssertEqual(past, prediction)

        // View's current-state observation is transient, read-only, and fenced by the exact operation.
        let movedInspection = makePreview(operationID: operationID, targetStatusHash: "target-moved", artifacts: nil).inspection
        let inspections = InspectionLog()
        harness.viewModel.test_worktreeMergeInspectOverride = { request in
            inspections.count += 1
            return try inspections.next(request)
        }
        inspections.next = { _ in bundle.preview.inspection }
        let unchanged = await harness.viewModel.historicalWorktreeMergeCurrentState(tabID: harness.tabID, operationID: operationID)
        XCTAssertTrue(unchanged.contains("unchanged"), unchanged)
        inspections.next = { _ in movedInspection }
        let moved = await harness.viewModel.historicalWorktreeMergeCurrentState(tabID: harness.tabID, operationID: operationID)
        XCTAssertTrue(moved.contains("has changed"), moved)
        inspections.next = { _ in throw CocoaError(.fileReadUnknown) }
        let failed = await harness.viewModel.historicalWorktreeMergeCurrentState(tabID: harness.tabID, operationID: operationID)
        XCTAssertTrue(failed.contains("unavailable"), failed)
        inspections.next = { _ in
            if let index = harness.session.worktreeMergeOperations.firstIndex(where: { $0.id == operationID }) {
                harness.session.worktreeMergeOperations[index].updatedAt = Date()
            }
            return bundle.preview.inspection
        }
        let raced = await harness.viewModel.historicalWorktreeMergeCurrentState(tabID: harness.tabID, operationID: operationID)
        XCTAssertTrue(raced.contains("changed while it was checked"), raced)
        XCTAssertEqual(inspections.count, 4)
        let afterView = try XCTUnwrap(operation(operationID, in: harness))
        XCTAssertTrue(afterView.isHistoricalReview, "Viewing never mutates the review's state")
        XCTAssertEqual(afterView.previewArtifacts, history.previewArtifacts)

        // Copy: the full saved patch.
        let copied = CopiedMergeTexts()
        harness.viewModel.test_recoveryListPasteboardWriter = { copied.values.append($0) }
        let copyMessage = await harness.viewModel.copyHistoricalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID)
        XCTAssertNil(copyMessage)
        XCTAssertEqual(copied.values, [Self.bundlePatch])

        // Strict UTF-8: invalid bytes make View and Copy unavailable, never lossy text.
        let retainedPatchPath = try XCTUnwrap(history.previewArtifacts?.allPatchPath)
        let validPatch = try Data(contentsOf: URL(fileURLWithPath: retainedPatchPath))
        try Data([0x2B, 0xFF, 0xFE, 0x0A]).write(to: URL(fileURLWithPath: retainedPatchPath))
        let invalidView = await harness.viewModel.historicalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID)
        guard case let .unavailable(invalidMessage) = invalidView else { return XCTFail("Invalid UTF-8 is unavailable: \(invalidView)") }
        XCTAssertTrue(invalidMessage.contains("UTF-8"), invalidMessage)
        let invalidCopy = await harness.viewModel.copyHistoricalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID)
        XCTAssertEqual(invalidCopy, invalidMessage)
        XCTAssertEqual(copied.values, [Self.bundlePatch], "Nothing lossy is copied")
        try validPatch.write(to: URL(fileURLWithPath: retainedPatchPath))

        // No recovered Apply on any initial route.
        inspections.next = { _ in bundle.preview.inspection }
        do {
            _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(sessionID: harness.sessionID, operationID: operationID, timeoutSeconds: 60)
            XCTFail("History can't be re-reviewed")
        } catch {}
        do {
            _ = try await harness.viewModel.applyConfirmedWorktreeMerge(sessionID: harness.sessionID, operationID: operationID)
            XCTFail("History can't be applied")
        } catch {}
        do {
            _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
            XCTFail("History can't be replaced by re-submitting its preview")
        } catch {}
        XCTAssertTrue(try XCTUnwrap(operation(operationID, in: harness)).isHistoricalReview)

        // Discard: explicit withdrawal, acknowledged by a covering written save.
        let discardMessage = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
        XCTAssertNil(discardMessage)
        let durableDiscard = try await durableOperation(operationID, in: harness)
        XCTAssertEqual(durableDiscard?.status, .cancelled, "Discard is durable when acknowledged")
        XCTAssertNil(durableDiscard?.reviewPreservation)
        let discarded = try XCTUnwrap(operation(operationID, in: harness))
        XCTAssertEqual(discarded.status, .cancelled)
        XCTAssertNil(discarded.reviewPreservation)
        XCTAssertEqual(discarded.lastError, AgentModeViewModel.worktreeMergeReviewDiscardedText)
        XCTAssertNil(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID))
        let afterDiscard = await harness.viewModel.historicalWorktreeMergeSavedPatch(tabID: harness.tabID, operationID: operationID)
        guard case .unavailable = afterDiscard else { return XCTFail("Discarded history is gone: \(afterDiscard)") }
        XCTAssertEqual(log.applies.count, 0, "View/Copy/Discard never run Git")
    }

    @MainActor
    func testRejectOrDiscardWithoutCoveringSaveKeepsHistoryAndNeverClaimsWithdrawal() async throws {
        let cases: [(outcome: AgentModeViewModel.SessionSaveOutcome, decision: WorktreeMergeReviewDecision)] = [
            (.notWritten, .reject(reason: "No")),
            (.suppressed, .reject(reason: "No")),
            (.resetAcknowledged, .reject(reason: "No")),
            (.deferredBehindInFlightSave, .reject(reason: "No")),
            (.notWritten, .cancelled(reason: "Cancelled by reviewer"))
        ]
        for (index, item) in cases.enumerated() {
            let label = "\(item.outcome)/\(item.decision)"
            let harness = try await makeMergeHarness(windowID: 95580 + index)
            let bundle = try makeBundle(operationID: "merge_withdraw_\(index)")
            let operationID = bundle.preview.operationID
            let log = MergeCallLog()
            installRecorders(harness, log: log, operationID: operationID) { operation in
                operation?.status == .cancelled ? item.outcome : nil
            }
            let task = Task { @MainActor in
                try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
            }
            try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
            let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview, label)
            harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: item.decision)
            do {
                _ = try await task.value
                XCTFail("\(label): never applied")
            } catch {
                XCTAssertTrue("\(error)".contains("couldn't save the rejection"), "\(label): truthful failure, not a withdrawal claim: \(error)")
            }
            XCTAssertTrue(log.events.contains("save:cancelled:-:hidden"), "\(label): the withdrawal save was attempted")
            let kept = try XCTUnwrap(operation(operationID, in: harness), label)
            XCTAssertEqual(kept.status, .awaitingApproval, "\(label): kept, not withdrawn")
            XCTAssertTrue(kept.isHistoricalReview, label)
            XCTAssertEqual(kept.reviewPreservation?.endedReason, AgentModeViewModel.worktreeMergeRejectNotSavedText, label)
            XCTAssertNotNil(kept.previewArtifacts, label)
            XCTAssertEqual(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id, operationID, label)
            XCTAssertNil(harness.session.pendingWorktreeMergeReview, label)

            // Discard with the same non-covering receipt: refused with a message, history kept.
            let message = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
            XCTAssertEqual(message, AgentModeViewModel.worktreeMergeDiscardNotSavedText, label)
            let stillKept = try XCTUnwrap(operation(operationID, in: harness), label)
            XCTAssertTrue(stillKept.isHistoricalReview, label)
            XCTAssertEqual(stillKept.reviewPreservation, kept.reviewPreservation, label)
            XCTAssertEqual(stillKept.previewArtifacts, kept.previewArtifacts, label)
            XCTAssertNil(stillKept.lastError, label)
            // No extra flush: the compensating covering save already wrote the kept history.
            let durableKept = try await durableOperation(operationID, in: harness)
            XCTAssertEqual(durableKept?.status, .awaitingApproval, "\(label): the durable record is recoverable history")
            XCTAssertEqual(durableKept?.isHistoricalReview, true, label)

            // A covering save then acknowledges Discard.
            installRecorders(harness, log: log, operationID: operationID)
            let acknowledged = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
            XCTAssertNil(acknowledged, label)
            XCTAssertEqual(operation(operationID, in: harness)?.status, .cancelled, label)
            let durableWithdrawn = try await durableOperation(operationID, in: harness)
            XCTAssertEqual(durableWithdrawn?.status, .cancelled, label)
            XCTAssertEqual(log.applies.count, 0, "\(label): Git is never touched")
        }
    }

    @MainActor
    func testOwnerOrOperationChangeAtWithdrawalSaveNeverClaimsWithdrawal() async throws {
        enum Change: String, CaseIterable { case reset, bindingTransitionInProgress, bindingRebound, operationReplaced }
        enum Route: String, CaseIterable { case reject, discard }
        var windowID = 95590
        for route in Route.allCases {
            for change in Change.allCases {
                let label = "\(route)/\(change)"
                windowID += 1
                let harness = try await makeMergeHarness(windowID: windowID)
                let bundle = try makeBundle(operationID: "merge_withdraw_race_\(windowID)")
                let operationID = bundle.preview.operationID
                let log = MergeCallLog()
                installRecorders(harness, log: log, operationID: operationID)
                let task = Task { @MainActor in
                    try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
                }
                try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
                let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview, label)
                if route == .discard {
                    harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
                    _ = try? await task.value
                    XCTAssertEqual(operation(operationID, in: harness)?.isHistoricalReview, true, label)
                }
                harness.viewModel.test_worktreeMergeAwaitHook = { session, reached in
                    guard reached == .withdrawalSave else { return }
                    switch change {
                    case .reset:
                        _ = await harness.viewModel.clearChatPreservingRecovery(tabID: session.tabID)
                    case .bindingTransitionInProgress:
                        _ = session.beginPersistentBindingTransition()
                    case .bindingRebound:
                        let generation = session.beginPersistentBindingTransition()
                        session.finishPersistentBindingTransition(generation: generation)
                    case .operationReplaced:
                        if let index = session.worktreeMergeOperations.firstIndex(where: { $0.id == operationID }) {
                            session.worktreeMergeOperations[index].lastError = "replacement"
                        }
                    }
                }
                switch route {
                case .reject:
                    harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .reject(reason: "No"))
                    do {
                        _ = try await task.value
                        XCTFail("\(label): never applied")
                    } catch {
                        XCTAssertTrue("\(error)".contains("couldn't save the rejection"), "\(label): \(error)")
                        switch change {
                        case .bindingTransitionInProgress, .bindingRebound:
                            XCTAssertTrue("\(error)".contains(AgentModeViewModel.worktreeMergeRejectNotSavedText), "\(label): kept, never written: \(error)")
                        case .operationReplaced:
                            XCTAssertTrue("\(error)".contains(AgentModeViewModel.worktreeMergeRejectChangedText), "\(label): \(error)")
                        case .reset:
                            break
                        }
                    }
                case .discard:
                    let message = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
                    switch change {
                    case .operationReplaced:
                        XCTAssertEqual(message, AgentModeViewModel.worktreeMergeDiscardChangedText, label)
                    case .reset:
                        XCTAssertNotNil(message, "\(label): never claims withdrawal")
                    case .bindingTransitionInProgress, .bindingRebound:
                        XCTAssertEqual(message, AgentModeViewModel.worktreeMergeDiscardNotSavedText, label)
                    }
                }
                harness.viewModel.test_worktreeMergeAwaitHook = nil
                // Revalidated after the last await and before the write: the withdrawal is never written.
                XCTAssertFalse(log.events.contains("save:cancelled:-:hidden"), "\(label): no withdrawal save")

                let stored = operation(operationID, in: harness)
                switch change {
                case .operationReplaced:
                    // The replacement is never withdrawn, restored, or retargeted by the stale request.
                    XCTAssertEqual(stored?.lastError, "replacement", label)
                    XCTAssertEqual(stored?.status, .awaitingApproval, label)
                case .reset:
                    // Whatever the reset kept is never reported withdrawn; if present it is history.
                    if let stored {
                        XCTAssertEqual(stored.status, .awaitingApproval, label)
                        XCTAssertTrue(stored.isHistoricalReview, label)
                    }
                case .bindingTransitionInProgress, .bindingRebound:
                    XCTAssertEqual(stored?.status, .awaitingApproval, "\(label): kept, not withdrawn")
                    XCTAssertEqual(stored?.isHistoricalReview, true, label)
                    // Immediate cold read, no extra flush: the durable record is recoverable history.
                    let durable = try await durableOperation(operationID, in: harness)
                    XCTAssertEqual(durable?.status, .awaitingApproval, label)
                    XCTAssertNotNil(durable?.reviewPreservation, "\(label): live or historical both reload as history")
                }
                XCTAssertTrue(harness.session.resolvingWorktreeMergeReviewOperationIDs.isEmpty, label)
                XCTAssertNil(harness.session.pendingWorktreeMergeReview, label)
                XCTAssertEqual(log.applies.count, 0, "\(label): Git is never touched")
            }
        }
    }

    @MainActor
    func testSubmittedDecisionStaysShownForSameTurnLifecycleOrReplacement() async throws {
        enum Race: String, CaseIterable { case timeoutThenLifecycle, timeoutThenReplacement, acceptThenLifecycle }
        for (index, race) in Race.allCases.enumerated() {
            let label = race.rawValue
            let harness = try await makeMergeHarness(windowID: 95620 + index)
            let bundle = try makeBundle(operationID: "merge_resolving_\(index)")
            let operationID = bundle.preview.operationID
            let log = MergeCallLog()
            installRecorders(harness, log: log, operationID: operationID)
            let task = Task { @MainActor in
                try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
            }
            try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
            let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview, label)
            var newer: (bundle: MergeBundle, task: Task<GitWorktreeMergeApplyResult, Error>)?
            switch race {
            case .timeoutThenLifecycle, .acceptThenLifecycle:
                // One MainActor turn: the decision is submitted (card cleared) but not yet processed.
                let decision: WorktreeMergeReviewDecision = race == .acceptThenLifecycle ? .accept : .timeout
                harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: decision)
                XCTAssertNil(harness.session.pendingWorktreeMergeReview, "\(label): the card is already cleared")
                XCTAssertEqual(harness.session.resolvingWorktreeMergeReviewOperationIDs, [operationID], label)
                harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
            case .timeoutThenReplacement:
                let newerBundle = try makeBundle(operationID: "merge_resolving_newer_\(index)")
                // The timeout and the newer request's synchronous start (which ends older reviews)
                // run in one MainActor job, before the older request resumes.
                let newerTask = Task { @MainActor in
                    harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .timeout)
                    return try await harness.viewModel.requestWorktreeMergeReviewAndApply(
                        preview: newerBundle.preview,
                        sessionID: harness.sessionID,
                        timeoutSeconds: 60
                    )
                }
                newer = (newerBundle, newerTask)
            }
            do {
                _ = try await task.value
                XCTFail("\(label): never applied")
            } catch {}

            let ended = try XCTUnwrap(operation(operationID, in: harness), label)
            XCTAssertEqual(ended.status, .awaitingApproval, "\(label): the shown proposal is never withdrawn")
            XCTAssertTrue(ended.isHistoricalReview, "\(label): read-only history")
            XCTAssertEqual(
                ended.reviewPreservation?.endedReason,
                race == .timeoutThenReplacement ? AgentModeViewModel.worktreeMergeReviewReplacedReason : "Run ended",
                "\(label): the lifecycle end reached it first and kept it"
            )
            XCTAssertNotNil(ended.previewArtifacts, label)
            let endedText = AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: ended.reviewPreservation?.endedReason)
            XCTAssertFalse(endedText.contains("without a decision"), "\(label): a lifecycle end may overtake a submitted decision")
            XCTAssertTrue(endedText.contains("No merge was started from this review"), label)
            XCTAssertTrue(harness.session.resolvingWorktreeMergeReviewOperationIDs.isEmpty, "\(label): cleared once processed")
            if let newer {
                try await waitUntil { harness.session.pendingWorktreeMergeReview?.operationID == newer.bundle.preview.operationID }
                XCTAssertEqual(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id, operationID, label)
                harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Test cleanup")
                _ = try? await newer.task.value
            }
            XCTAssertEqual(log.applies.count, 0, "\(label): 0 VCS calls")
            _ = await harness.viewModel.flushSave(for: harness.tabID)
            let durable = try await durableOperation(operationID, in: harness)
            XCTAssertEqual(durable?.status, .awaitingApproval, label)
            XCTAssertEqual(durable?.reviewPreservation, ended.reviewPreservation, label)
        }
    }

    @MainActor
    func testRejectAfterOwnerAlreadyChangedKeepsTheShownProposalAsHistory() async throws {
        let harness = try await makeMergeHarness(windowID: 95630)
        let bundle = try makeBundle(operationID: "merge_reject_invalid_owner")
        let operationID = bundle.preview.operationID
        let log = MergeCallLog()
        installRecorders(harness, log: log, operationID: operationID)
        let task = Task { @MainActor in
            try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
        }
        try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
        let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview)
        // The binding transition starts before the decision: the owner is invalid at withdrawal entry.
        let generation = harness.session.beginPersistentBindingTransition()
        harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .reject(reason: "No"))
        do {
            _ = try await task.value
            XCTFail("Never applied")
        } catch {
            XCTAssertTrue("\(error)".contains(AgentModeViewModel.worktreeMergeRejectNotSavedText), "\(error)")
        }
        harness.session.finishPersistentBindingTransition(generation: generation)

        XCTAssertFalse(log.events.contains("save:cancelled:-:hidden"), "Nothing was withdrawn or written")
        let kept = try XCTUnwrap(operation(operationID, in: harness))
        XCTAssertEqual(kept.status, .awaitingApproval)
        XCTAssertTrue(kept.isHistoricalReview, "Visible history, not an invisible live orphan")
        XCTAssertEqual(kept.reviewPreservation?.endedReason, AgentModeViewModel.worktreeMergeRejectNotSavedText)
        XCTAssertNotNil(kept.previewArtifacts)
        XCTAssertEqual(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id, operationID)
        XCTAssertEqual(
            AgentWorktreeMergeBlockerSelector.sidebarAttention(in: harness.session.worktreeMergeOperations)?.kind,
            .historicalReview
        )
        XCTAssertTrue(harness.session.resolvingWorktreeMergeReviewOperationIDs.isEmpty)
        // Immediate cold read, no extra flush: the published `.live` record reloads as history.
        let durable = try await durableOperation(operationID, in: harness)
        XCTAssertEqual(durable?.status, .awaitingApproval)
        XCTAssertNotNil(durable?.reviewPreservation)
        XCTAssertEqual(log.applies.count, 0)

        // Card wording: rejected and approved-but-unstarted histories had a decision.
        let rejectedText = AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: kept.reviewPreservation?.endedReason)
        XCTAssertFalse(rejectedText.contains("without a decision"), rejectedText)
        XCTAssertTrue(rejectedText.contains("rejected"), rejectedText)
        let unstartedText = AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: AgentModeViewModel.worktreeMergeNotStartedText)
        XCTAssertFalse(unstartedText.contains("without a decision"), unstartedText)
        XCTAssertTrue(unstartedText.contains("approved"), unstartedText)
        let uncertainText = AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: AgentModeViewModel.worktreeMergeRejectUncertainText)
        XCTAssertFalse(uncertainText.contains("without a decision"), uncertainText)
        let lifecycleText = AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: "Run ended")
        XCTAssertTrue(lifecycleText.contains("review ended (Run ended)"), lifecycleText)
        XCTAssertFalse(lifecycleText.contains("without a decision"), lifecycleText)
        XCTAssertFalse(AgentModeViewModel.worktreeMergeReviewReplacedReason.contains("Replaced by newer"))
    }

    @MainActor
    func testWrittenWithdrawalIsRestoredUnderValidOwnerOrReportedUncertainOnImmediateColdReload() async throws {
        enum Route: String, CaseIterable { case reject, discard }
        enum After: String, CaseIterable { case nonCoveringReceipt, ownerChanged }
        var windowID = 95640
        for route in Route.allCases {
            for after in After.allCases {
                let label = "\(route)/\(after)"
                windowID += 1
                let harness = try await makeMergeHarness(windowID: windowID)
                let bundle = try makeBundle(operationID: "merge_written_withdrawal_\(windowID)")
                let operationID = bundle.preview.operationID
                let log = MergeCallLog()
                installRecorders(harness, log: log, operationID: operationID)
                let task = Task { @MainActor in
                    try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
                }
                try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
                let shown = try XCTUnwrap(harness.session.pendingWorktreeMergeReview, label)
                if route == .discard {
                    harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
                    _ = try? await task.value
                    XCTAssertEqual(operation(operationID, in: harness)?.isHistoricalReview, true, label)
                }

                // The withdrawal save really writes `.cancelled`; then its receipt isn't covering, or
                // the owner changes before it is acknowledged.
                let probe = WrittenWithdrawalProbe()
                harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
                    guard session.worktreeMergeOperations.first(where: { $0.id == operationID })?.status == .cancelled else {
                        return nil
                    }
                    let real = await harness.viewModel.flushSaveDetailed(for: session.tabID)
                    probe.didWrite = real.didWriteDurably
                    let reloaded = try? await self.durableOperation(operationID, in: harness)
                    probe.durableStatus = reloaded?.status
                    switch after {
                    case .nonCoveringReceipt:
                        return .notWritten
                    case .ownerChanged:
                        probe.generation = session.beginPersistentBindingTransition()
                        return real
                    }
                }

                let outcomeText: String?
                switch route {
                case .reject:
                    harness.viewModel.submitWorktreeMergeReviewDecision(tabID: harness.tabID, reviewID: shown.id, decision: .reject(reason: "No"))
                    do {
                        _ = try await task.value
                        XCTFail("\(label): never applied")
                        outcomeText = nil
                    } catch {
                        outcomeText = "\(error)"
                    }
                case .discard:
                    outcomeText = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
                }
                harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = nil
                XCTAssertTrue(probe.didWrite, "\(label): the withdrawal save really wrote")
                XCTAssertEqual(probe.durableStatus, .cancelled, "\(label): the withdrawal reached disk")

                // Immediate cold read, no extra flush.
                let durable = try await durableOperation(operationID, in: harness)
                let inMemory = try XCTUnwrap(operation(operationID, in: harness), label)
                XCTAssertEqual(inMemory.status, .awaitingApproval, "\(label): the proposal stays visible")
                XCTAssertTrue(inMemory.isHistoricalReview, label)
                switch after {
                case .nonCoveringReceipt:
                    // Owner still valid: a covering compensating save restored the kept history.
                    let expected = route == .reject
                        ? AgentModeViewModel.worktreeMergeRejectNotSavedText
                        : AgentModeViewModel.worktreeMergeDiscardNotSavedText
                    XCTAssertTrue(outcomeText?.contains(expected) == true, "\(label): \(outcomeText ?? "nil")")
                    XCTAssertEqual(durable?.status, .awaitingApproval, "\(label): durably kept")
                    XCTAssertEqual(durable?.isHistoricalReview, true, label)
                    XCTAssertEqual(durable?.reviewPreservation, inMemory.reviewPreservation, label)
                case .ownerChanged:
                    // Authority gone and restoration unproven: explicitly uncertain, never "kept".
                    let expected = route == .reject
                        ? AgentModeViewModel.worktreeMergeRejectUncertainText
                        : AgentModeViewModel.worktreeMergeDiscardUncertainText
                    XCTAssertTrue(outcomeText?.contains(expected) == true, "\(label): \(outcomeText ?? "nil")")
                    XCTAssertFalse(outcomeText?.contains(AgentModeViewModel.worktreeMergeRejectNotSavedText) == true, "\(label): no durable-kept claim")
                    XCTAssertFalse(outcomeText?.contains(AgentModeViewModel.worktreeMergeDiscardNotSavedText) == true, "\(label): no durable-kept claim")
                    XCTAssertTrue(
                        durable?.status == .cancelled || durable?.isHistoricalReview == true,
                        "\(label): disk holds the written withdrawal (or a later save of the history)"
                    )
                    if route == .reject {
                        XCTAssertEqual(inMemory.reviewPreservation?.endedReason, AgentModeViewModel.worktreeMergeRejectUncertainText, label)
                    }
                    if let generation = probe.generation {
                        harness.session.finishPersistentBindingTransition(generation: generation)
                    }
                }
                if route == .discard {
                    let snapshot = harness.viewModel.makeRunInteractionUISnapshot()
                    XCTAssertEqual(snapshot.historicalWorktreeMergeReviewDiscard?.message, outcomeText, "\(label): session-owned message")
                }
                XCTAssertEqual(log.applies.count, 0, "\(label): Git is never touched")
            }
        }
    }

    @MainActor
    func testDiscardProgressAndFailureAreSessionOwnedAcrossCardRemoval() async throws {
        let harness = try await makeMergeHarness(windowID: 95660)
        let bundle = try makeBundle(operationID: "merge_discard_presentation")
        let operationID = bundle.preview.operationID
        let log = MergeCallLog()
        installRecorders(harness, log: log, operationID: operationID)
        let task = Task { @MainActor in
            try await harness.viewModel.requestWorktreeMergeReviewAndApply(preview: bundle.preview, sessionID: harness.sessionID, timeoutSeconds: 60)
        }
        try await waitUntil { harness.session.pendingWorktreeMergeReview != nil }
        harness.viewModel.cancelPendingWorktreeMergeReview(for: harness.session, reason: "Run ended")
        _ = try? await task.value
        XCTAssertEqual(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID)?.id, operationID)

        // The withdrawal save is suspended, then fails to cover.
        let gate = SaveGate()
        harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
            guard session.worktreeMergeOperations.first(where: { $0.id == operationID })?.status == .cancelled else {
                return nil
            }
            await gate.wait()
            return .notWritten
        }
        let discard = Task { @MainActor in
            await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
        }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(operation(operationID, in: harness)?.status, .cancelled, "The operation alone would drop the card")
        let during = harness.viewModel.makeRunInteractionUISnapshot()
        XCTAssertEqual(during.currentTabID, harness.tabID)
        XCTAssertEqual(during.historicalWorktreeMergeReview?.id, operationID, "The review stays visible while Discard is unacknowledged")
        XCTAssertEqual(during.historicalWorktreeMergeReviewDiscard?.isDiscarding, true)
        XCTAssertNil(during.historicalWorktreeMergeReviewDiscard?.message)
        XCTAssertEqual(harness.viewModel.ui.runInteraction.snapshot.historicalWorktreeMergeReviewDiscard?.isDiscarding, true)
        let concurrent = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
        XCTAssertNotNil(concurrent, "A second Discard never claims withdrawal")

        gate.open()
        let message = await discard.value
        XCTAssertEqual(message, AgentModeViewModel.worktreeMergeDiscardNotSavedText)
        let after = harness.viewModel.makeRunInteractionUISnapshot()
        XCTAssertEqual(after.historicalWorktreeMergeReview?.id, operationID)
        XCTAssertEqual(after.historicalWorktreeMergeReview?.isHistoricalReview, true)
        XCTAssertEqual(after.historicalWorktreeMergeReviewDiscard?.isDiscarding, false)
        XCTAssertEqual(
            after.historicalWorktreeMergeReviewDiscard?.message,
            AgentModeViewModel.worktreeMergeDiscardNotSavedText,
            "A recreated card reads the failure from the session"
        )
        XCTAssertEqual(
            harness.viewModel.ui.runInteraction.snapshot.historicalWorktreeMergeReviewDiscard?.message,
            AgentModeViewModel.worktreeMergeDiscardNotSavedText
        )

        // A covering save then acknowledges Discard and clears the session-owned state.
        harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = nil
        installRecorders(harness, log: log, operationID: operationID)
        let acknowledged = await harness.viewModel.discardHistoricalWorktreeMergeReview(tabID: harness.tabID, operationID: operationID)
        XCTAssertNil(acknowledged)
        let cleared = harness.viewModel.makeRunInteractionUISnapshot()
        XCTAssertNil(cleared.historicalWorktreeMergeReview)
        XCTAssertNil(cleared.historicalWorktreeMergeReviewDiscard)
        XCTAssertNil(harness.session.worktreeMergeReviewDiscard)
        XCTAssertEqual(log.applies.count, 0)
    }

    @MainActor
    func testPreShowRefusalOnTheStoredOperationRouteRestoresThePreviewedOperation() async throws {
        enum Failure: String, CaseIterable { case publicationSave, retention }
        for (index, failure) in Failure.allCases.enumerated() {
            let label = failure.rawValue
            let harness = try await makeMergeHarness(windowID: 95670 + index)
            let bundle = try makeBundle(operationID: "merge_stored_refusal_\(index)")
            let operationID = bundle.preview.operationID
            let log = MergeCallLog()
            installRecorders(harness, log: log, operationID: operationID) { operation in
                failure == .publicationSave && operation?.reviewPreservation == .live ? .notWritten : nil
            }
            harness.viewModel.test_worktreeMergeInspectOverride = { _ in bundle.preview.inspection }
            let previewed = AgentWorktreeMergeCoordinator.makeOperation(preview: bundle.preview, status: .previewed, now: stateNow)
            AgentWorktreeMergeCoordinator.upsert(previewed, in: &harness.session.worktreeMergeOperations)
            if failure == .retention {
                try FileManager.default.removeItem(at: bundle.directory)
            }
            do {
                _ = try await harness.viewModel.requestWorktreeMergeReviewAndApply(sessionID: harness.sessionID, operationID: operationID, timeoutSeconds: 60)
                XCTFail("\(label): refused before it is shown")
            } catch {
                XCTAssertTrue("\(error)".contains("wasn't shown"), "\(label): \(error)")
            }
            let restored = try XCTUnwrap(operation(operationID, in: harness), label)
            XCTAssertEqual(restored.status, .previewed, "\(label): the prior previewed operation is restored, not cancelled")
            XCTAssertNil(restored.reviewPreservation, label)
            XCTAssertEqual(restored.previewArtifacts, previewed.previewArtifacts, label)
            XCTAssertEqual(restored.createdAt, previewed.createdAt, label)
            XCTAssertNotNil(restored.lastError, label)
            XCTAssertNil(harness.session.pendingWorktreeMergeReview, label)
            XCTAssertFalse(log.events.contains { $0.hasSuffix(":shown") }, label)
            XCTAssertNil(harness.viewModel.historicalWorktreeMergeReviewOperation(for: harness.tabID), label)
            XCTAssertEqual(log.applies.count, 0, label)

            // Explicitly confirmed direct apply is still available for it.
            installRecorders(harness, log: log, operationID: operationID)
            let result = try await harness.viewModel.applyConfirmedWorktreeMerge(sessionID: harness.sessionID, operationID: operationID)
            XCTAssertEqual(result.status, .completed, label)
            XCTAssertEqual(log.applies.count, 1, label)
        }
    }

    private let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    private let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    private let stateNow = Date(timeIntervalSinceReferenceDate: 303)

    private func makeBinding(
        logicalRootName: String,
        logicalRootPath: String,
        worktreeID: String,
        branch: String = "feature",
        head: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding_\(worktreeID)",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            logicalRootPath: logicalRootPath,
            logicalRootName: logicalRootName,
            worktreeID: worktreeID,
            worktreeRootPath: "/tmp/\(worktreeID)",
            worktreeName: worktreeID,
            branch: branch,
            head: head,
            visualLabel: logicalRootName,
            visualColorHex: "#6699CC",
            boundAt: stateNow,
            source: "test"
        )
    }

    private func makePreview(operationID: String) -> GitWorktreeMergePreview {
        makePreview(operationID: operationID, artifacts: GitWorktreeMergePreviewArtifacts(
            snapshotID: "snapshot_\(operationID)",
            snapshotDirectory: "/tmp/snapshot_\(operationID)",
            manifestPath: "/tmp/snapshot_\(operationID)/manifest.json",
            mapPath: "/tmp/snapshot_\(operationID)/MAP.txt",
            allPatchPath: "/tmp/snapshot_\(operationID)/diff/all.patch",
            sidecarPath: "/tmp/snapshot_\(operationID)/merge_preview.json"
        ))
    }

    private func makePreview(
        operationID: String,
        targetStatusHash: String = "target-clean",
        conflictPrediction: GitWorktreeMergeConflictPrediction = GitWorktreeMergeConflictPrediction(status: .clean),
        artifacts: GitWorktreeMergePreviewArtifacts?
    ) -> GitWorktreeMergePreview {
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "wt_source",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/source",
            name: "source",
            branch: "feature",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "wt_target",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/target",
            name: "target",
            branch: "main",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: true
        )
        let inspection = GitWorktreeMergeInspection(
            source: source,
            target: target,
            mergeBase: "cccccccccccccccccccccccccccccccccccccccc",
            sourceHead: source.head,
            targetHead: target.head,
            sourceFingerprint: GitDiffFingerprint(headSHA: source.head, baseRef: "HEAD", statusHash: "source-clean", generatedAt: stateNow),
            targetFingerprint: GitDiffFingerprint(headSHA: target.head, baseRef: "HEAD", statusHash: targetStatusHash, generatedAt: stateNow),
            blockers: [],
            conflictPrediction: conflictPrediction,
            summary: GitWorktreeMergeSummary(commits: 2, files: 4, insertions: 20, deletions: 5),
            visualization: "target main <- source feature"
        )
        return GitWorktreeMergePreview(operationID: operationID, inspection: inspection, artifacts: artifacts)
    }

    // MARK: - Step 5c fixtures

    private static let bundlePatch = "diff --git a/Source.txt b/Source.txt\n+source\n"

    private struct MergeBundle {
        let directory: URL
        let artifacts: GitWorktreeMergePreviewArtifacts
        let preview: GitWorktreeMergePreview
    }

    /// The publisher's subset of `merge_preview.json` that retention validates.
    private struct BundleSidecar: Encodable {
        let operationID: String
        let snapshotID: String
        let mergeBase: String
        let sourceHead: String
        let targetHead: String
        let sourceFingerprint: GitDiffFingerprint
        let targetFingerprint: GitDiffFingerprint
        let conflictPrediction: GitWorktreeMergeConflictPrediction
    }

    /// A small real preview bundle in its own temporary directory (outside session storage).
    private func makeBundle(
        operationID: String,
        conflictPrediction: GitWorktreeMergeConflictPrediction = GitWorktreeMergeConflictPrediction(status: .clean)
    ) throws -> MergeBundle {
        let directory = try RecoveryTestSupport.makeTemporaryRoot("WorktreeMergeReviewBundle")
            .appendingPathComponent("snapshot_\(operationID)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("diff", isDirectory: true), withIntermediateDirectories: true)
        let artifacts = GitWorktreeMergePreviewArtifacts(
            snapshotID: "snapshot_\(operationID)",
            snapshotDirectory: directory.path,
            manifestPath: directory.appendingPathComponent("manifest.json").path,
            mapPath: directory.appendingPathComponent("MAP.txt").path,
            allPatchPath: directory.appendingPathComponent("diff/all.patch").path,
            sidecarPath: directory.appendingPathComponent("merge_preview.json").path
        )
        let preview = makePreview(operationID: operationID, conflictPrediction: conflictPrediction, artifacts: artifacts)
        let inspection = preview.inspection
        try Data("{}".utf8).write(to: URL(fileURLWithPath: artifacts.manifestPath))
        try Data("MAP \(directory.path)\n".utf8).write(to: URL(fileURLWithPath: artifacts.mapPath))
        try Data(Self.bundlePatch.utf8).write(to: URL(fileURLWithPath: XCTUnwrap(artifacts.allPatchPath)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BundleSidecar(
            operationID: operationID,
            snapshotID: artifacts.snapshotID,
            mergeBase: inspection.mergeBase,
            sourceHead: inspection.sourceHead,
            targetHead: inspection.targetHead,
            sourceFingerprint: inspection.sourceFingerprint,
            targetFingerprint: inspection.targetFingerprint,
            conflictPrediction: conflictPrediction
        )).write(to: URL(fileURLWithPath: artifacts.sidecarPath))
        return MergeBundle(directory: directory, artifacts: artifacts, preview: preview)
    }

    private struct MergeHarness {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentTabSession
        let sessionID: UUID
        let storageURL: URL
    }

    /// The production composition used by the Step 5a recovery tests: a recovery coordinator whose
    /// DataService owns session saves, and a session made durable by one real save.
    @MainActor
    private func makeMergeHarness(windowID: Int) async throws -> MergeHarness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("WorktreeMergeReviewWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("WorktreeMergeReviewStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
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
        XCTAssertEqual(startup, .ready)

        let workspace = WorkspaceModel(
            name: "Worktree Merge Reviews",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            applyEditsApprovalStore: ApplyEditsApprovalStore(),
            codexControllerFactory: { _, _, _, _, _, _ in WorktreeMergeReviewNoopCodexController() }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved, "The fixture session is durable")
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertNotNil(session.persistenceState)
        return MergeHarness(viewModel: viewModel, tabID: tabID, session: session, sessionID: sessionID, storageURL: storageURL)
    }

    /// Records each covering save (operation status, marker, and whether a card is shown) and each
    /// VCS apply. `saveOutcome` may force a non-covering outcome for a matching save.
    @MainActor
    private func installRecorders(
        _ harness: MergeHarness,
        log: MergeCallLog,
        operationID: String,
        saveOutcome: @escaping @MainActor (AgentSessionWorktreeMergeOperation?) -> AgentModeViewModel.SessionSaveOutcome? = { _ in nil }
    ) {
        harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
            let operation = session.worktreeMergeOperations.first { $0.id == operationID }
            let status = operation?.status.rawValue ?? "none"
            let marker = operation?.reviewPreservation?.state.rawValue ?? "-"
            let shown = session.pendingWorktreeMergeReview == nil ? "hidden" : "shown"
            log.events.append("save:\(status):\(marker):\(shown)")
            return saveOutcome(operation)
        }
        harness.viewModel.test_worktreeMergeApplyOverride = { request in
            log.applies.append(request)
            log.events.append("apply")
            let inspection = request.preview.inspection
            let merged = String(repeating: "d", count: 40)
            return GitWorktreeMergeApplyResult(
                status: .completed,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                targetHeadAfter: merged,
                mergeCommit: merged
            )
        }
    }

    @MainActor
    private func operation(_ operationID: String, in harness: MergeHarness) -> AgentSessionWorktreeMergeOperation? {
        harness.session.worktreeMergeOperations.first { $0.id == operationID }
    }

    /// The operation as written in the session file (hidden retention folders are skipped).
    @MainActor
    private func durableOperation(_ operationID: String, in harness: MergeHarness) async throws -> AgentSessionWorktreeMergeOperation? {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: harness.storageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))
        let fileURL = try XCTUnwrap(
            enumerator.compactMap { $0 as? URL }.first {
                $0.lastPathComponent == "AgentSession-\(harness.sessionID.uuidString).json"
            },
            "The session file exists"
        )
        let stub = try await harness.viewModel.dataService.loadAgentSessionStub(from: fileURL)
        return stub.worktreeMergeOperations.first { $0.id == operationID }
    }

    private func dedupe(_ events: [String]) -> [String] {
        events.reduce(into: []) { result, event in
            if result.last != event { result.append(event) }
        }
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 4000 where !condition() {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Condition not reached", file: file, line: line)
    }
}

@MainActor
private final class MergeCallLog {
    var events: [String] = []
    var applies: [GitWorktreeMergeApplyRequest] = []
}

@MainActor
private final class CopiedMergeTexts {
    var values: [String] = []
}

@MainActor
private final class WrittenWithdrawalProbe {
    var didWrite = false
    var durableStatus: AgentSessionWorktreeMergeOperation.Status?
    var generation: UInt64?
}

/// Suspends one save until `open()`.
@MainActor
private final class SaveGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class InspectionLog {
    var count = 0
    var next: @MainActor (GitWorktreeMergeInspectRequest) throws -> GitWorktreeMergeInspection = { _ in
        throw CocoaError(.fileReadUnknown)
    }
}

private final class WorktreeMergeReviewNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil, runtimeStatus: .idle, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: nil)
    }

    func startUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(text _: String, images _: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
