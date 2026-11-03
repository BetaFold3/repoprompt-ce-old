import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Lossless-restart Step 5a: an ordinary pending `apply_edits` review of a recovery-tracked
/// session commits its exact proposal before the live review is published, commits
/// `applicationStarted` before the live write, preserves the proposal on timeout and lifecycle
/// cancellation, withdraws it only on explicit reject or Discard, and never applies it from
/// history. Real temporary recovery store, real DataService gate, mandatory admission, and a
/// private approval store; the provider's call order is pinned by source.
@MainActor
final class AgentRecoveryEditProposalTests: XCTestCase {
    // MARK: - Ordering

    func testProposalIsDurableBeforeLiveReviewAndApplicationStartedBeforeWrite() async throws {
        let harness = try await makeHarness(windowID: 95301)
        let lane = try await persistAndClaimLane(harness)
        let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
        let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: ticket.reviewID,
            input: Self.input()
        ))
        XCTAssertTrue(lane.liveEditProposalIDs.contains(ticket.reviewID), "Live while its review is pending")
        let stored = try await XCTUnwrapAsync(proposals(lane).first)
        XCTAssertEqual(stored.reviewID, ticket.reviewID)
        XCTAssertEqual(stored.state, .pending)
        XCTAssertEqual(stored.proposedText, Self.proposedText)
        XCTAssertEqual(stored.unifiedDiff, Self.diff)
        XCTAssertEqual(stored.physicalPath, Self.physicalPath)
        XCTAssertEqual(stored.displayPath, Self.displayPath)
        XCTAssertEqual(stored.base, .preview(originalText: Self.originalText))
        XCTAssertEqual(stored.appInstanceID, lane.store.appInstanceID)
        XCTAssertEqual(stored.transcriptResetGeneration, lane.binding.transcriptResetGeneration)
        XCTAssertFalse(
            harness.viewModel.recoveryCoordinator?.catalog.items.contains { $0.kind == .pendingEditReview } ?? true,
            "A live review is not listed as history"
        )

        // Live publication happens only after the acknowledged commit, under the same review ID.
        let decision = Task { await harness.approvalStore.awaitReview(ticket, path: Self.displayPath, unifiedDiff: Self.diff, timeoutSeconds: 60) }
        try await waitUntil { harness.session.pendingApplyEditsReview?.id == ticket.reviewID }
        let atPublication = await proposals(lane)
        XCTAssertEqual(atPublication.map(\.reviewID), [ticket.reviewID], "Durable before the card was shown")

        await harness.approvalStore.resolveReview(scope: harness.scope, reviewID: ticket.reviewID, decision: .accept)
        let accepted = await decision.value
        XCTAssertEqual(accepted, .accept)
        let afterAccept = await proposals(lane)
        XCTAssertEqual(afterAccept.first?.state, .pending, "Accepting alone records nothing")

        // The provider's accepted path, executed: the write observes `applicationStarted` durable.
        let writes = WriteLog()
        let recorded = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
            admission,
            ticketIsCurrent: { await harness.approvalStore.isReviewTicketCurrent(ticket) },
            write: {
                let stored = await self.proposals(lane)
                writes.observed.append(contentsOf: stored)
                writes.count += 1
                XCTAssertTrue(admission.isApplicationStarted)
            }
        )
        XCTAssertEqual(writes.count, 1, "Written exactly once")
        let started = try XCTUnwrap(writes.observed.first)
        XCTAssertEqual(started.state, .applicationStarted, "Acknowledged before the write begins")
        XCTAssertNotNil(started.applicationStartedAt)
        XCTAssertTrue(recorded)
        let afterApplied = await proposals(lane)
        XCTAssertEqual(afterApplied, [], "An applied proposal is removed")
        XCTAssertFalse(lane.liveEditProposalIDs.contains(ticket.reviewID))
    }

    /// The provider's order: ticket → pending commit → live review; accept → `applicationStarted`
    /// → the existing host write → applied commit; the final commit's failure is partial success.
    func testProviderCommitsBeforePublicationAndBeforeWrite() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift"),
            encoding: .utf8
        )
        try Self.assertOrdered([
            "mcpCaptureApplyEditsReviewOwner(tabID: approvalScope.tabID)",
            "host.canonicalExistingFilePath(path: effectivePath)",
            "path: existingTarget ?? effectivePath",
            "let preview = try await service.preview(previewRequest)",
            "Self.canonicalReviewTarget(",
            "applyEditsApprovalStore.beginReview(scope: approvalScope)",
            "mcpAdmitApplyEditsReviewProposal(",
            "owner: recoveryOwner,",
            "physicalPath: reviewTargetPath,",
            "applyEditsApprovalStore.awaitReview(",
            "case .accept:",
            "mcpPerformAcceptedApplyEditsReview(",
            "ticketIsCurrent: { await approvalStore.isReviewTicketCurrent(ticket) }",
            "try await host.writeText(",
            "path: reviewTargetPath,",
            "guard recorded else {",
            "errorCode: \"recovery_record_failed\"",
            "retryable: false",
            "case let .reject(reason):",
            "mcpFinishApplyEditsReview(recovery, .withdrawn)",
            "guard withdrawn else {",
            "rejectionNotRecordedNote(reason: reason)",
            "case .timeout:",
            "mcpFinishApplyEditsReview(recovery, .preserved)",
            "case let .cancelled(reason):",
            "mcpFinishApplyEditsReview(recovery, .preserved)"
        ], in: source)
        XCTAssertFalse(source.contains("requestReview("), "The provider never shows a review before its proposal is saved")
    }

    // MARK: - Failures write nothing

    func testFailedPendingCommitShowsNothingAndWritesNothing() async throws {
        let failWrites = FailSwitch()
        let harness = try await makeHarness(windowID: 95302, failWrites: failWrites)
        let lane = try await persistAndClaimLane(harness)
        failWrites.isOn = true
        let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
        do {
            _ = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID), reviewID: ticket.reviewID, input: Self.input())
            XCTFail("A proposal that can't be saved is never shown")
        } catch {
            XCTAssertTrue("\(error)".contains("could not be saved for crash recovery"), "\(error)")
            XCTAssertTrue("\(error)".contains("Nothing was changed"), "\(error)")
        }
        failWrites.isOn = false
        let stored = await proposals(lane)
        XCTAssertEqual(stored, [])
        XCTAssertTrue(lane.liveEditProposalIDs.isEmpty)
        XCTAssertNil(harness.session.pendingApplyEditsReview, "No live card")
    }

    func testFailedApplicationStartedCommitRefusesTheWrite() async throws {
        let failWrites = FailSwitch()
        let harness = try await makeHarness(windowID: 95303, failWrites: failWrites)
        let lane = try await persistAndClaimLane(harness)
        let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: UUID(),
            input: Self.input()
        ))
        failWrites.isOn = true
        let writes = WriteLog()
        do {
            _ = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
                admission,
                ticketIsCurrent: { true },
                write: { writes.count += 1 }
            )
            XCTFail("The write never begins without an acknowledged applicationStarted")
        } catch {
            XCTAssertTrue("\(error)".contains("Nothing was changed"), "\(error)")
        }
        failWrites.isOn = false
        XCTAssertEqual(writes.count, 0)
        XCTAssertFalse(admission.isApplicationStarted)
        let states = await proposals(lane).map(\.state)
        XCTAssertEqual(states, [.pending], "Kept as an unapplied historical proposal")
        XCTAssertTrue(lane.liveEditProposalIDs.isEmpty)
    }

    func testFailedAppliedCommitReportsFailureAndKeepsPossiblyApplied() async throws {
        let failWrites = FailSwitch()
        let harness = try await makeHarness(windowID: 95304, failWrites: failWrites)
        let lane = try await persistAndClaimLane(harness)
        let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: UUID(),
            input: Self.input()
        ))
        let writes = WriteLog()
        let recorded = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
            admission,
            ticketIsCurrent: { true },
            write: {
                writes.count += 1
                failWrites.isOn = true
            }
        )
        failWrites.isOn = false
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(recorded, "The caller must report partial success, never \"nothing changed\"")
        let states = await proposals(lane).map(\.state)
        XCTAssertEqual(states, [.applicationStarted], "Stays possibly applied")
        let row = try await waitForRow(harness)
        XCTAssertEqual(row.title, "Edit may have been applied")
        XCTAssertTrue(row.detail.contains("uncertain"), row.detail)
        XCTAssertTrue(MCPApplyEditsToolProvider.recoveryRecordFailedNote.contains("Do not retry"))
    }

    // MARK: - Lifecycle versus withdrawal

    func testTimeoutAndCleanupPreserveButExplicitRejectWithdraws() async throws {
        enum Ending: CaseIterable { case timeout, scopeCleanup, replacement, reject }
        for ending in Ending.allCases {
            let harness = try await makeHarness(windowID: 95305)
            let lane = try await persistAndClaimLane(harness)
            let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
            let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
                owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
                reviewID: ticket.reviewID,
                input: Self.input()
            ))
            let timeout: TimeInterval = ending == .timeout ? 0.01 : 60
            let review = Task { await harness.approvalStore.awaitReview(ticket, path: Self.displayPath, unifiedDiff: Self.diff, timeoutSeconds: timeout) }
            if ending != .timeout {
                try await waitUntil { harness.session.pendingApplyEditsReview?.id == ticket.reviewID }
            }
            switch ending {
            case .timeout:
                break
            case .scopeCleanup:
                await harness.approvalStore.cleanupScope(harness.scope)
            case .replacement:
                _ = await harness.approvalStore.beginReview(scope: harness.scope)
            case .reject:
                await harness.approvalStore.resolveReview(scope: harness.scope, reviewID: ticket.reviewID, decision: .reject(reason: "No"))
            }
            let decision = await review.value
            // The provider's typed mapping: only an explicit reject withdraws.
            switch decision {
            case .accept:
                XCTFail("\(ending): never an accept")
            case .reject:
                XCTAssertEqual(ending, .reject)
                await harness.viewModel.mcpFinishApplyEditsReview(admission, .withdrawn)
            case .timeout:
                XCTAssertEqual(ending, .timeout)
                await harness.viewModel.mcpFinishApplyEditsReview(admission, .preserved)
            case .cancelled:
                XCTAssertTrue(ending == .scopeCleanup || ending == .replacement, "\(ending)")
                await harness.viewModel.mcpFinishApplyEditsReview(admission, .preserved)
            }
            XCTAssertTrue(lane.liveEditProposalIDs.isEmpty, "\(ending)")
            let stored = await proposals(lane)
            if ending == .reject {
                XCTAssertEqual(stored, [], "Explicit reject withdraws durably")
                let listed = harness.viewModel.recoveryCoordinator?.catalog.items.contains { $0.kind == .pendingEditReview }
                XCTAssertEqual(listed, false)
            } else {
                XCTAssertEqual(stored.map(\.reviewID), [ticket.reviewID], "\(ending) preserves the proposal")
                let row = try await waitForRow(harness)
                XCTAssertEqual(row.title, "Edit proposal not applied")
                XCTAssertEqual(row.actions, [.copyProposal, .discardProposal], "\(ending): View/Copy/Discard only")
                XCTAssertTrue(row.inspectsOnView)
                XCTAssertTrue(row.detail.contains("nothing was applied automatically"), row.detail)
            }
        }
    }

    func testHistoricalCopyAndDiscardNeverTouchTheFileAndViewCompares() async throws {
        let harness = try await makeHarness(windowID: 95306)
        let lane = try await persistAndClaimLane(harness)
        let fileURL = harness.workspaceURL.appendingPathComponent("A.swift")
        try Self.originalText.write(to: fileURL, atomically: true, encoding: .utf8)
        let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: UUID(),
            input: Self.input(physicalPath: fileURL.path)
        ))
        await harness.viewModel.mcpFinishApplyEditsReview(admission, .preserved)
        let row = try await waitForRow(harness)

        let copied = CopiedTexts()
        harness.viewModel.test_recoveryListPasteboardWriter = { copied.values.append($0) }
        await harness.viewModel.performRecoveryListAction(rowID: row.id, action: .copyProposal)
        XCTAssertEqual(copied.values, [Self.proposedText], "Copy is the exact full proposal")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), Self.originalText)

        // View's comparison is transient, read-only, and decoded by the same host as the preview.
        let comparison = await harness.viewModel.inspectRecoveryEditProposal(rowID: row.id)
        XCTAssertNotNil(comparison)
        let stored = try await XCTUnwrapAsync(proposals(lane).first)
        XCTAssertEqual(
            AgentModeViewModel.recoveryListEditProposalComparison(stored, currentText: Self.originalText),
            "The file still matches the version this edit was proposed against."
        )
        XCTAssertEqual(stored.base.matches(decodedText: Self.originalText), true)
        var started = stored
        started = AgentRecoveryEditProposal(
            reviewID: started.reviewID,
            runAttemptID: started.runAttemptID,
            transcriptResetGeneration: started.transcriptResetGeneration,
            appInstanceID: started.appInstanceID,
            proposedAt: started.proposedAt,
            physicalPath: started.physicalPath,
            displayPath: started.displayPath,
            unifiedDiff: started.unifiedDiff,
            proposedText: started.proposedText,
            base: started.base,
            state: .applicationStarted,
            applicationStartedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1)
        )
        let matching = AgentModeViewModel.recoveryListEditProposalComparison(started, currentText: Self.proposedText)
        XCTAssertTrue(matching.contains("doesn't prove"), matching)
        XCTAssertTrue(matching.contains("stays uncertain"), "A matching file never upgrades possibly applied: \(matching)")
        XCTAssertTrue(AgentModeViewModel.recoveryListEditProposalComparison(started, currentText: nil).contains("wasn't found"))

        await harness.viewModel.performRecoveryListAction(rowID: row.id, action: .discardProposal)
        let afterDiscard = await proposals(lane)
        XCTAssertEqual(afterDiscard, [], "Discard withdraws durably")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), Self.originalText, "Discard never touches the file")
        XCTAssertNil(harness.viewModel.recoveryCoordinator?.catalogActionStates[row.id])
    }

    // MARK: - Stale owner and cancellation at the new awaits

    func testResetOrCancellationAtEachNewAwaitWritesNothing() async throws {
        enum Change: CaseIterable { case reset, laneReplaced, bindingTransitionInProgress, bindingRebound, cancelled }
        let points: [EditProposalRecoveryAwaitPoint] = [.pendingCommit, .applicationStartedCommit, .reviewTicketCheck]
        for point in points {
            for change in Change.allCases {
                let harness = try await makeHarness(windowID: 95307)
                let lane = try await persistAndClaimLane(harness)
                let reviewID = UUID()
                let admission: ApplyEditsReviewRecoveryAdmission?
                if point != .pendingCommit {
                    admission = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID), reviewID: reviewID, input: Self.input())
                    XCTAssertNotNil(admission, "The healthy same-owner path is admitted")
                } else {
                    admission = nil
                }
                harness.viewModel.test_editProposalRecoveryAwaitHook = { session, reached in
                    guard reached == point else { return }
                    switch change {
                    case .reset:
                        let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: session.tabID)
                        XCTAssertEqual(outcome, .committed, "The fixture really reset the session")
                    case .laneReplaced:
                        session.recoveryLane = nil
                    case .bindingTransitionInProgress:
                        session.beginPersistentBindingTransition()
                    case .bindingRebound:
                        // Same session ID and lane; only the existing binding generation moved.
                        let generation = session.beginPersistentBindingTransition()
                        session.finishPersistentBindingTransition(generation: generation)
                    case .cancelled:
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                let writes = WriteLog()
                let task = Task { @MainActor in
                    if point == .pendingCommit {
                        _ = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID), reviewID: reviewID, input: Self.input())
                    } else {
                        _ = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
                            admission,
                            ticketIsCurrent: { true },
                            write: { writes.count += 1 }
                        )
                    }
                }
                do {
                    try await task.value
                    XCTFail("\(point)/\(change): a stale or cancelled request never proceeds")
                } catch {
                    XCTAssertTrue("\(error)".contains("Nothing was changed"), "\(point)/\(change): \(error)")
                }
                harness.viewModel.test_editProposalRecoveryAwaitHook = nil
                XCTAssertEqual(writes.count, 0, "\(point)/\(change): nothing is written")
                XCTAssertTrue(lane.liveEditProposalIDs.isEmpty, "\(point)/\(change)")
                XCTAssertFalse(admission?.isApplicationStarted ?? false, "\(point)/\(change): the write never begins")
                // Read against the session's CURRENT lane (a reset's successor binding), not the old lane.
                let currentLane = try XCTUnwrap(harness.session.recoveryLane ?? (change == .laneReplaced ? lane : nil), "\(point)/\(change)")
                let stored = await currentLane.store.read(sessionID: currentLane.sessionID).record?.editProposals ?? []
                switch (point, change) {
                case (.pendingCommit, .reset):
                    // The reset retired the admitted lane before its commit: nothing was saved.
                    XCTAssertEqual(stored.map(\.reviewID), [], "\(point)/\(change)")
                case (.reviewTicketCheck, .reset):
                    // Committed `applicationStarted` survives the reset; the retired lane can't revert
                    // it, so it honestly stays possibly applied (never applied, nothing written).
                    XCTAssertEqual(stored.map(\.reviewID), [reviewID], "\(point)/\(change): survives clearChatPreservingRecovery")
                    XCTAssertEqual(stored.map(\.state), [.applicationStarted], "\(point)/\(change)")
                default:
                    // Known not written: it is kept, back to pending.
                    XCTAssertEqual(stored.map(\.reviewID), [reviewID], "\(point)/\(change)")
                    XCTAssertEqual(stored.map(\.state), [.pending], "\(point)/\(change)")
                }
                if change == .reset {
                    XCTAssertFalse(currentLane === lane, "\(point)/\(change): the reset installed a successor binding")
                    XCTAssertGreaterThan(currentLane.binding.transcriptResetGeneration, lane.binding.transcriptResetGeneration)
                    XCTAssertTrue(
                        stored.allSatisfy { $0.transcriptResetGeneration == lane.binding.transcriptResetGeneration },
                        "\(point)/\(change): kept from the earlier generation"
                    )
                }
                XCTAssertNil(harness.session.pendingApplyEditsReview, "\(point)/\(change): no live card")
            }
        }
    }

    /// Scope cleanup, window cleanup, an explicit lifecycle cancel (turn end: the public
    /// `cancelPendingReview`, without cleanup), or a newer review while an accepted review's
    /// `applicationStarted` is held: the exact ticket is stale, so nothing is written.
    func testStaleTicketAtHeldApplicationStartedWritesNothing() async throws {
        enum Ending: CaseIterable { case scopeCleanup, windowCleanup, lifecycleCancel, newerReview }
        let points: [EditProposalRecoveryAwaitPoint] = [.applicationStartedCommit, .reviewTicketCheck]
        for point in points {
            for ending in Ending.allCases {
                let harness = try await makeHarness(windowID: 95310)
                let lane = try await persistAndClaimLane(harness)
                let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
                let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
                    owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
                    reviewID: ticket.reviewID,
                    input: Self.input()
                ))
                let review = Task { await harness.approvalStore.awaitReview(ticket, path: Self.displayPath, unifiedDiff: Self.diff, timeoutSeconds: 60) }
                try await waitUntil { harness.session.pendingApplyEditsReview?.id == ticket.reviewID }
                await harness.approvalStore.resolveReview(scope: harness.scope, reviewID: ticket.reviewID, decision: .accept)
                let decision = await review.value
                XCTAssertEqual(decision, .accept)
                let currentAfterAccept = await harness.approvalStore.isReviewTicketCurrent(ticket)
                XCTAssertTrue(currentAfterAccept, "Accepting keeps the exact ticket current")

                harness.viewModel.test_editProposalRecoveryAwaitHook = { _, reached in
                    guard reached == point else { return }
                    switch ending {
                    case .scopeCleanup:
                        await harness.approvalStore.cleanupScope(harness.scope)
                    case .windowCleanup:
                        await harness.approvalStore.cleanupWindowScopes(windowID: harness.scope.windowID, reason: "Window closed")
                    case .lifecycleCancel:
                        // Nothing is pending any more (accepted); the scope's ticket still expires.
                        await harness.approvalStore.cancelPendingReview(scope: harness.scope, reason: "Turn ended")
                    case .newerReview:
                        _ = await harness.approvalStore.beginReview(scope: harness.scope)
                    }
                }
                let writes = WriteLog()
                do {
                    _ = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
                        admission,
                        ticketIsCurrent: { await harness.approvalStore.isReviewTicketCurrent(ticket) },
                        write: { writes.count += 1 }
                    )
                    XCTFail("\(point)/\(ending): a stale ticket never writes")
                } catch {
                    XCTAssertTrue("\(error)".contains("replaced or closed"), "\(point)/\(ending): \(error)")
                    XCTAssertTrue("\(error)".contains("Nothing was changed"), "\(point)/\(ending): \(error)")
                }
                harness.viewModel.test_editProposalRecoveryAwaitHook = nil
                XCTAssertEqual(writes.count, 0, "\(point)/\(ending): nothing is written")
                XCTAssertFalse(admission.isApplicationStarted)
                XCTAssertTrue(lane.liveEditProposalIDs.isEmpty, "\(point)/\(ending): no false live row")
                let states = await proposals(lane).map(\.state)
                XCTAssertEqual(states, [.pending], "\(point)/\(ending): known not written, so back to pending")
                let row = try await waitForRow(harness)
                XCTAssertEqual(row.title, "Edit proposal not applied", "\(point)/\(ending)")
            }
        }
    }

    /// An explicit reject whose withdrawal can't be saved is reported, and the proposal stays history.
    func testFailedWithdrawalOnRejectIsReportedAndKeepsTheProposal() async throws {
        let failWrites = FailSwitch()
        let harness = try await makeHarness(windowID: 95309, failWrites: failWrites)
        let lane = try await persistAndClaimLane(harness)
        let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
        let admission = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: ticket.reviewID,
            input: Self.input()
        ))
        let review = Task { await harness.approvalStore.awaitReview(ticket, path: Self.displayPath, unifiedDiff: Self.diff, timeoutSeconds: 60) }
        try await waitUntil { harness.session.pendingApplyEditsReview?.id == ticket.reviewID }
        await harness.approvalStore.resolveReview(scope: harness.scope, reviewID: ticket.reviewID, decision: .reject(reason: "No"))
        let decision = await review.value
        XCTAssertEqual(decision, .reject(reason: "No"))

        failWrites.isOn = true
        let withdrawn = await harness.viewModel.mcpFinishApplyEditsReview(admission, .withdrawn)
        failWrites.isOn = false
        XCTAssertFalse(withdrawn, "The provider must not claim a durable rejection")
        XCTAssertTrue(lane.liveEditProposalIDs.isEmpty)
        let stored = await proposals(lane)
        XCTAssertEqual(stored.map(\.reviewID), [ticket.reviewID], "The proposal remains historical")
        XCTAssertEqual(stored.map(\.state), [.pending])
        let row = try await waitForRow(harness)
        XCTAssertEqual(row.title, "Edit proposal not applied")
        let note = MCPApplyEditsToolProvider.rejectionNotRecordedNote(reason: "No")
        XCTAssertTrue(note.contains("The file was not changed"), note)
        XCTAssertTrue(note.contains("could not save the rejection"), note)
        XCTAssertTrue(note.contains("remains listed in Needs Attention"), note)
    }

    // MARK: - Owner frozen before the first new await

    /// The owner is captured before the provider's first new await (target resolution, preview,
    /// ticket). A reset, rebind, replaced, or removed owner during those awaits refuses admission:
    /// nothing is saved, published, or written, and no replacement or untracked path is adopted.
    func testOwnerChangeDuringTheInitialAwaitsPublishesAndWritesNothing() async throws {
        enum Change: CaseIterable { case reset, rebound, replaced, removed }
        for change in Change.allCases {
            let harness = try await makeHarness(windowID: 95311)
            let lane = try await persistAndClaimLane(harness)
            let owner = try XCTUnwrap(harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID), "\(change): tracked")
            // ... the provider's held initial awaits (target resolution, preview, ticket) ...
            let ticket = await harness.approvalStore.beginReview(scope: harness.scope)
            switch change {
            case .reset:
                let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID)
                XCTAssertEqual(outcome, .committed)
            case .rebound:
                let generation = harness.session.beginPersistentBindingTransition()
                harness.session.finishPersistentBindingTransition(generation: generation)
            case .replaced:
                harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
                let replacement = try await harness.viewModel.ensureSessionReady(tabID: harness.tabID)
                XCTAssertFalse(replacement === harness.session, "\(change): a different session now owns the tab")
            case .removed:
                harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
            }
            let writes = WriteLog()
            do {
                let admission = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(
                    owner: owner,
                    reviewID: ticket.reviewID,
                    input: Self.input()
                )
                _ = try await harness.viewModel.mcpPerformAcceptedApplyEditsReview(
                    admission,
                    ticketIsCurrent: { true },
                    write: { writes.count += 1 }
                )
                XCTFail("\(change): a changed owner is never adopted")
            } catch {
                XCTAssertTrue("\(error)".contains("session changed"), "\(change): \(error)")
                XCTAssertTrue("\(error)".contains("Nothing was changed"), "\(change): \(error)")
            }
            XCTAssertEqual(writes.count, 0, "\(change): nothing is written")
            XCTAssertTrue(lane.liveEditProposalIDs.isEmpty, "\(change)")
            let stored = await lane.store.read(sessionID: lane.sessionID).record?.editProposals ?? []
            XCTAssertEqual(stored, [], "\(change): nothing is saved")
            XCTAssertNil(harness.session.pendingApplyEditsReview, "\(change): nothing is published")
            XCTAssertNil(harness.viewModel.sessions[harness.tabID]?.pendingApplyEditsReview, "\(change): nothing is published")
        }

        // A missing session under mandatory admission fails closed at capture.
        let harness = try await makeHarness(windowID: 95312)
        harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
        XCTAssertThrowsError(try harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID))
    }

    // MARK: - Store reset generation

    /// An earlier reset's started proposal is never joined as `unchanged` by the successor binding.
    func testApplicationStartedFromAnEarlierResetIsRefusedNotJoined() async throws {
        let harness = try await makeHarness(windowID: 95313)
        let lane = try await persistAndClaimLane(harness)
        let reviewID = UUID()
        _ = try await XCTUnwrapAsync(harness.viewModel.mcpAdmitApplyEditsReviewProposal(
            owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID),
            reviewID: reviewID,
            input: Self.input()
        ))
        if case let .failure(failure) = await lane.transitionEditProposal(reviewID: reviewID, .applicationStarted) {
            XCTFail("\(failure)")
        }
        let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID)
        XCTAssertEqual(outcome, .committed)
        let successor = try XCTUnwrap(harness.session.recoveryLane)
        XCTAssertFalse(successor === lane)
        let repeated = await successor.transitionEditProposal(reviewID: reviewID, .applicationStarted)
        if case .success = repeated {
            XCTFail("An earlier reset's started proposal is never joined")
        }
        let stored = await successor.store.read(sessionID: successor.sessionID).record?.editProposals ?? []
        XCTAssertEqual(stored.map(\.reviewID), [reviewID], "Survives clearChatPreservingRecovery")
        XCTAssertEqual(stored.map(\.state), [.applicationStarted])
        XCTAssertEqual(stored.first?.transcriptResetGeneration, lane.binding.transcriptResetGeneration)
    }

    // MARK: - Canonical target

    /// The review's target is the canonical absolute file the preview read; History compares that
    /// file even after another root makes the original relative string ambiguous, a new file's
    /// destination is frozen in its original root, and a target outside every visible root is
    /// reported neutrally.
    func testReviewTargetIsCanonicalAndHistoryComparesTheSameFileAfterRootsChange() async throws {
        let rootA = try RecoveryTestSupport.makeTemporaryRoot("EditProposalRootA")
        let rootB = try RecoveryTestSupport.makeTemporaryRoot("EditProposalRootB")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let fileA = rootA.appendingPathComponent("Sources/A.swift")
        let fileB = rootB.appendingPathComponent("Sources/A.swift")
        for (url, text) in [(fileA, Self.originalText), (fileB, "let b = 0\n")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace, createPathResolutionPolicy: .canonicalAliasFirst, selectCreatedFiles: false)

        // At preview time the relative path names root A's file, resolved once to its absolute path.
        let existing = try await XCTUnwrapAsync(host.canonicalExistingFilePath(path: "Sources/A.swift"))
        XCTAssertEqual(existing, StandardizedPath.absolute(fileA.path))
        let target = try await MCPApplyEditsToolProvider.canonicalReviewTarget(existingTarget: existing, previewExists: true, effectivePath: "Sources/A.swift", host: host)
        XCTAssertEqual(target, existing)
        let newTarget = try await MCPApplyEditsToolProvider.canonicalReviewTarget(existingTarget: nil, previewExists: false, effectivePath: "Sources/New.swift", host: host)
        XCTAssertEqual(newTarget, StandardizedPath.absolute(rootA.appendingPathComponent("Sources/New.swift").path))
        // The preview and the resolution must agree, or the review fails closed.
        do {
            _ = try await MCPApplyEditsToolProvider.canonicalReviewTarget(existingTarget: nil, previewExists: true, effectivePath: "Sources/A.swift", host: host)
            XCTFail("An unestablished target is refused")
        } catch {
            XCTAssertTrue("\(error)".contains("couldn't be established"), "\(error)")
        }
        let proposal = AgentRecoveryEditProposal(
            reviewID: UUID(),
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: UUID(),
            proposedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1),
            physicalPath: target,
            displayPath: "Sources/A.swift",
            unifiedDiff: Self.diff,
            proposedText: Self.proposedText,
            base: .preview(originalText: Self.originalText)
        )

        // Another root is loaded: the original relative string no longer names root A's file.
        _ = try await store.loadRoot(path: rootB.path)
        let relativeNow = await host.canonicalExistingFilePath(path: "Sources/A.swift")
        XCTAssertNotEqual(relativeNow, existing, "Re-resolving the relative string would not reach the reviewed file")
        let matching = await AgentModeViewModel.recoveryListEditProposalInspection(proposal, store: store)
        XCTAssertEqual(matching, "The file still matches the version this edit was proposed against.")
        try "let a = 9\n".write(to: fileA, atomically: true, encoding: .utf8)
        let changed = await AgentModeViewModel.recoveryListEditProposalInspection(proposal, store: store)
        XCTAssertEqual(changed, "The file has changed since this edit was proposed, and doesn't match the proposal.")
        XCTAssertEqual(try String(contentsOf: fileB, encoding: .utf8), "let b = 0\n", "Root B is never compared or written")

        // The frozen create destination still writes root A, not wherever the string resolves now.
        try await host.writeText(path: newTarget, content: Self.proposedText, overwrite: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("Sources/New.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("Sources/New.swift").path))

        // Outside every visible root (for example a session worktree): neutral, never "deleted".
        let elsewhere = AgentRecoveryEditProposal(
            reviewID: UUID(),
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: UUID(),
            proposedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1),
            physicalPath: "/tmp/rpce-step5a-worktree-elsewhere/Sources/A.swift",
            displayPath: "Sources/A.swift",
            unifiedDiff: Self.diff,
            proposedText: Self.proposedText,
            base: .preview(originalText: Self.originalText)
        )
        let neutral = await AgentModeViewModel.recoveryListEditProposalInspection(elsewhere, store: store)
        XCTAssertTrue(neutral.contains("isn't inside this window's loaded workspace roots"), neutral)
        XCTAssertFalse(neutral.contains("wasn't found") || neutral.contains("doesn't exist"), neutral)
    }

    // MARK: - Unchanged legacy

    func testSessionWithoutDurableAdmissionIsUnchanged() async throws {
        let harness = try await makeHarness(windowID: 95308, admissionMode: nil)
        let admission = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: harness.tabID), reviewID: UUID(), input: Self.input())
        XCTAssertNil(admission, "No recovery record is written for an untracked session")
        let other = try await harness.viewModel.mcpAdmitApplyEditsReviewProposal(owner: harness.viewModel.mcpCaptureApplyEditsReviewOwner(tabID: UUID()), reviewID: UUID(), input: Self.input())
        XCTAssertNil(other, "An unknown tab is the unchanged legacy path")
        // The legacy wrapper still issues and shows a review.
        let review = Task { await harness.approvalStore.requestReview(scope: harness.scope, path: "A", unifiedDiff: "d", timeoutSeconds: 0.01) }
        let decision = await review.value
        XCTAssertEqual(decision, .timeout)
    }

    // MARK: - Fixtures

    private nonisolated static let originalText = "let a = 1\n"
    private nonisolated static let proposedText = "let a = 2\n"
    private nonisolated static let diff = "@@ -1 +1 @@\n-let a = 1\n+let a = 2\n"
    private nonisolated static let physicalPath = "/tmp/rpce-step5a/Sources/A.swift"
    private nonisolated static let displayPath = "Sources/A.swift"

    private static func input(physicalPath: String = physicalPath) -> ApplyEditsReviewProposalInput {
        ApplyEditsReviewProposalInput(
            physicalPath: physicalPath,
            displayPath: displayPath,
            unifiedDiff: diff,
            proposedText: proposedText,
            baseText: originalText
        )
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let approvalStore: ApplyEditsApprovalStore
        let tabID: UUID
        let session: AgentTabSession
        let scope: ApplyEditsApprovalScope
        let workspaceURL: URL
    }

    private func proposals(_ lane: AgentRecoverySessionLane) async -> [AgentRecoveryEditProposal] {
        await lane.store.read(sessionID: lane.sessionID).record?.editProposals ?? []
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 2000 where !condition() {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Condition not reached", file: file, line: line)
    }

    /// The session's historical proposal row, once the catalog lists it.
    private func waitForRow(_ harness: Harness) async throws -> AgentRecoveryListRowProps {
        var row: AgentRecoveryListRowProps?
        for _ in 0 ..< 2000 {
            if let coordinator = harness.viewModel.recoveryCoordinator,
               let item = coordinator.catalog.items.first(where: { $0.kind == .pendingEditReview })
            {
                row = harness.viewModel.recoveryListRow(for: item, coordinator: coordinator, activeSession: harness.viewModel.activeSession)
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return try XCTUnwrap(row, "The proposal is listed as history")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private static func assertOrdered(_ needles: [String], in source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(
                source.range(of: needle, range: lowerBound ..< source.endIndex),
                "Missing ordered source fragment: \(needle)",
                file: file,
                line: line
            )
            lowerBound = range.upperBound
        }
    }

    /// Persists the first transcript through the VM save path, which claims the session's lane.
    private func persistAndClaimLane(_ harness: Harness) async throws -> AgentRecoverySessionLane {
        harness.session.appendItem(.user("Earlier turn"))
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        return try XCTUnwrap(harness.session.recoveryLane, "The first save claims the session's lane")
    }

    private func makeHarness(
        windowID: Int,
        failWrites: FailSwitch = FailSwitch(),
        admissionMode: AgentRecoveryAdmissionMode? = .mandatory
    ) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryEditProposalWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryEditProposalStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let sessionsDirectory = recoveryRoot.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path
        let store = AgentRecoveryStore(
            rootURL: recoveryRoot,
            fileOperations: AgentRecoveryStore.FileOperations(
                writeAtomically: { data, url in
                    if failWrites.isOn, url.standardizedFileURL.path.hasPrefix(sessionsDirectory) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                },
                removeItem: { url in try FileManager.default.removeItem(at: url) }
            )
        )
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
            name: "Agent Recovery Edit Proposals",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let approvalStore = ApplyEditsApprovalStore()
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            applyEditsApprovalStore: approvalStore,
            codexControllerFactory: { _, _, _, _, _, _ in EditProposalNoopCodexController() }
        )
        viewModel.test_initializeRunService()
        if let admissionMode {
            viewModel.installRecoveryCoordinator(coordinator, admissionMode: admissionMode)
        }
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        for _ in 0 ..< 200 where session.applyEditsApprovalSubscriptionID == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(session.applyEditsApprovalSubscriptionID)
        return Harness(
            viewModel: viewModel,
            approvalStore: approvalStore,
            tabID: tabID,
            session: session,
            scope: viewModel.applyEditsScope(for: tabID),
            workspaceURL: storageURL
        )
    }
}

@MainActor
private final class CopiedTexts {
    var values: [String] = []
}

/// Counts executed host writes and what recovery stored when each began.
@MainActor
private final class WriteLog {
    var count = 0
    var observed: [AgentRecoveryEditProposal] = []
}

private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class EditProposalNoopCodexController: CodexSessionControlling {
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
