import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Lossless-restart Step 5b: a routed `agent_run.start` admitted under a recovery-tracked parent
/// links its child by the exact server-side MCP invocation UUID and the parent run attempt frozen at
/// admission, only after a covering `.written` save of the child and before any child dispatch.
/// Real temporary recovery store, real DataService gate, mandatory admission.
@MainActor
final class AgentRecoveryDelegatedChildLinkTests: XCTestCase {
    // MARK: - Ingress identity

    func testToolInvocationIDIsScopedToEachConcurrentCall() async {
        let ids = (0 ..< 8).map { _ in UUID() }
        let observed = await withTaskGroup(of: (UUID, UUID?, UUID?).self) { group in
            for id in ids {
                group.addTask {
                    await ServerNetworkManager.withConnectionID(UUID(), toolInvocationID: id) {
                        await Task.yield()
                        let inherited = await Task { ServerNetworkManager.currentToolInvocationID }.value
                        let nested = await ServerNetworkManager.withConnectionID(UUID()) {
                            ServerNetworkManager.currentToolInvocationID
                        }
                        XCTAssertEqual(inherited, id, "Unstructured work inside the call keeps its identity")
                        return (id, ServerNetworkManager.currentToolInvocationID, nested)
                    }
                }
            }
            var results: [(UUID, UUID?, UUID?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        XCTAssertEqual(observed.count, ids.count)
        for (expected, actual, nested) in observed {
            XCTAssertEqual(actual, expected, "Each call reads its own dispatcher invocation UUID")
            XCTAssertEqual(nested, expected, "A nested scope without an ID keeps the inherited one")
        }
        XCTAssertNil(ServerNetworkManager.currentToolInvocationID, "Nothing outside a dispatched call")
        let metadata = MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil, actorRoutedRunTab: nil)
        XCTAssertNil(metadata.toolInvocationID, "Existing metadata construction is unchanged")
    }

    // MARK: - Admission

    func testIndependentCallerIsUnchangedAndTrackedParentFailsClosedWithoutIdentityOrAttempt() async throws {
        let harness = try await makeHarness(windowID: 95201)
        _ = try await persistAndClaimLane(harness)
        let parentSessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let viewModel = harness.viewModel

        XCTAssertNil(try viewModel.mcpAdmitDelegatedChildLink(
            sourceTabID: nil,
            admittedCallerSessionID: nil,
            invocationID: UUID(),
            operation: "agent_run.start",
            revalidateDelegation: {}
        ), "An independent MCP caller has no parent to link")

        XCTAssertThrowsError(try admit(harness, invocationID: UUID()), "No current parent run attempt") { error in
            XCTAssertTrue("\(error)".contains("no current run attempt"), "\(error)")
        }
        beginParentAttempt(harness)
        XCTAssertThrowsError(try admit(harness, invocationID: nil), "No MCP invocation identity") { error in
            XCTAssertTrue("\(error)".contains("MCP invocation identity"), "\(error)")
        }
        XCTAssertThrowsError(try viewModel.mcpAdmitDelegatedChildLink(
            sourceTabID: harness.tabID,
            admittedCallerSessionID: UUID(),
            invocationID: UUID(),
            operation: "agent_run.start",
            revalidateDelegation: {}
        ), "Another admitted caller identity")
        let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
        XCTAssertEqual(admission.parentSessionID, parentSessionID)
    }

    // MARK: - Commit

    func testLinkCommitsExactInvocationAfterCoveringChildSaveAndFencesDispatch() async throws {
        let harness = try await makeHarness(windowID: 95202)
        let lane = try await persistAndClaimLane(harness)
        let ownership = beginParentAttempt(harness)
        let invocationID = UUID()
        let admission = try XCTUnwrap(admit(harness, invocationID: invocationID))
        XCTAssertEqual(admission.invocationID, invocationID, "The exact ingress UUID, never a replacement")
        XCTAssertEqual(admission.ownership, ownership, "The attempt frozen at admission")
        let child = try await makeChild(harness)

        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)

        let links = await recordedLinks(lane)
        XCTAssertEqual(links.map(\.invocationID), [invocationID])
        XCTAssertEqual(links.map(\.parentRunAttemptID), [ownership.attemptID])
        XCTAssertEqual(links.map(\.childSessionID), [child.sessionID])
        let persistedChild = try await harness.viewModel.test_dataService.loadAgentSession(id: child.sessionID, for: harness.workspace)
        XCTAssertEqual(persistedChild?.parentSessionID, admission.parentSessionID, "The child's identity and parent were durable before the link")
        XCTAssertEqual(admission.linkedChildSessionID, child.sessionID)

        // An exact repeat of the same invocation and child changes nothing.
        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
        let repeatedLinks = await recordedLinks(lane)
        XCTAssertEqual(repeatedLinks.count, 1)

        // The final dispatch predicate holds only while the parent admission does, and only for
        // the linked child.
        let fence = MCPDelegatedChildDispatchFence.$current.withValue(admission) {
            harness.viewModel.mcpDelegatedChildDispatchFence(for: child.sessionID)
        }
        XCTAssertTrue(fence === admission)
        XCTAssertNil(MCPDelegatedChildDispatchFence.$current.withValue(admission) {
            harness.viewModel.mcpDelegatedChildDispatchFence(for: UUID())
        }, "An unrelated dispatch is unchanged")
        XCTAssertNoThrow(try harness.viewModel.mcpRequireDelegatedChildDispatchFence(fence))
        XCTAssertTrue(harness.session.endRunAttempt(ifCurrent: ownership, source: "test.delegatedChildLink"))
        beginParentAttempt(harness)
        XCTAssertThrowsError(try harness.viewModel.mcpRequireDelegatedChildDispatchFence(fence), "A replaced parent attempt never dispatches the child")
        XCTAssertFalse(harness.viewModel.mcpDelegatedChildLinkAdmissionIsCurrent(admission))
    }

    /// The link's write creates the parent's run attempt with the parent run's run-start provider:
    /// never the child's provider, and never the parent's provider after a mid-run change.
    func testLinkCreatingTheParentAttemptRecordsTheParentRunStartProvider() async throws {
        let harness = try await makeHarness(windowID: 95211)
        let lane = try await persistAndClaimLane(harness)
        harness.session.selectedAgent = .codexExec
        let ownership = beginParentAttempt(harness)
        harness.session.selectedAgent = .claudeCode
        let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
        let child = try await makeChild(harness)
        child.session.selectedAgent = .openCode
        func parentAttempt() async -> AgentRecoveryRunAttempt? {
            guard case let .success(.supported(record)) = await lane.readRecord() else { return nil }
            return record.runAttempt(id: ownership.attemptID)
        }
        let before = await parentAttempt()
        XCTAssertNil(before, "the link's write creates the parent's attempt")

        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)

        let after = await parentAttempt()
        XCTAssertEqual(after?.recordedProviderKindRaw, AgentProviderKind.codexExec.rawValue)
    }

    func testAttemptReplacedBeforeAdmissionBelongsToNewAttemptAndAfterAdmissionFails() async throws {
        let harness = try await makeHarness(windowID: 95203)
        let lane = try await persistAndClaimLane(harness)
        let attemptA = beginParentAttempt(harness)
        XCTAssertTrue(harness.session.endRunAttempt(ifCurrent: attemptA, source: "test.delegatedChildLink"))
        let attemptB = beginParentAttempt(harness)

        let admittedUnderB = try XCTUnwrap(admit(harness, invocationID: UUID()))
        XCTAssertEqual(admittedUnderB.ownership.attemptID, attemptB.attemptID, "A→B before admission belongs to B")
        let first = try await makeChild(harness)
        try await harness.viewModel.mcpCommitDelegatedChildLink(admittedUnderB, childTabID: first.session.tabID, childSessionID: first.sessionID)
        let committedLinks = await recordedLinks(lane)
        XCTAssertEqual(committedLinks.map(\.parentRunAttemptID), [attemptB.attemptID])

        let staleInvocationID = UUID()
        let admittedBeforeChange = try XCTUnwrap(admit(harness, invocationID: staleInvocationID))
        XCTAssertTrue(harness.session.endRunAttempt(ifCurrent: attemptB, source: "test.delegatedChildLink"))
        beginParentAttempt(harness)
        let second = try await makeChild(harness)
        do {
            try await harness.viewModel.mcpCommitDelegatedChildLink(admittedBeforeChange, childTabID: second.session.tabID, childSessionID: second.sessionID)
            XCTFail("After admission, an attempt change fails the link")
        } catch {}
        let links = await recordedLinks(lane)
        XCTAssertFalse(links.contains { $0.invocationID == staleInvocationID }, "Nothing is linked under the new attempt")
        XCTAssertNil(admittedBeforeChange.linkedChildSessionID)
    }

    func testStaleParentAtChildSaveAwaitWritesNoLink() async throws {
        enum Change: CaseIterable { case attempt, lane, delegation }
        for change in Change.allCases {
            let harness = try await makeHarness(windowID: 95204)
            let lane = try await persistAndClaimLane(harness)
            beginParentAttempt(harness)
            let delegationChanged = DelegationChangedFlag()
            let admission = try XCTUnwrap(harness.viewModel.mcpAdmitDelegatedChildLink(
                sourceTabID: harness.tabID,
                admittedCallerSessionID: harness.session.activeAgentSessionID,
                invocationID: UUID(),
                operation: "agent_run.start",
                revalidateDelegation: {
                    if delegationChanged.value { throw MCPDelegatedChildLinkTestError.delegationChanged }
                }
            ))
            let child = try await makeChild(harness)
            harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
                guard session === child.session else { return nil }
                switch change {
                case .attempt:
                    if let current = harness.session.activeRunOwnership {
                        _ = harness.session.endRunAttempt(ifCurrent: current, source: "test.delegatedChildLink")
                    }
                    harness.session.beginRunAttempt(source: "test.delegatedChildLink")
                case .lane:
                    harness.session.recoveryLane = nil
                case .delegation:
                    delegationChanged.value = true
                }
                return nil
            }
            do {
                try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
                XCTFail("A \(change) change at the child-save await fails the link")
            } catch {}
            let links = await recordedLinks(lane)
            XCTAssertTrue(links.isEmpty, "No link after a \(change) change")
            XCTAssertNil(admission.linkedChildSessionID)
            harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = nil
        }
    }

    func testFailedOrNonCoveringChildSaveWritesNoLink() async throws {
        for outcome in [AgentModeViewModel.SessionSaveOutcome.notWritten, .suppressed] {
            let harness = try await makeHarness(windowID: 95205)
            let lane = try await persistAndClaimLane(harness)
            beginParentAttempt(harness)
            let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
            let child = try await makeChild(harness)
            harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
                session === child.session ? outcome : nil
            }
            do {
                try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
                XCTFail("A \(outcome) child save never links")
            } catch {
                XCTAssertTrue("\(error)".contains("could not be saved"), "\(error)")
            }
            let links = await recordedLinks(lane)
            XCTAssertTrue(links.isEmpty)
            XCTAssertNil(admission.linkedChildSessionID, "No dispatch fence is ever armed")
            harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = nil
        }
    }

    func testFailedLinkCommitLeavesNoLinkForThisChild() async throws {
        let harness = try await makeHarness(windowID: 95206)
        let lane = try await persistAndClaimLane(harness)
        let ownership = beginParentAttempt(harness)
        let invocationID = UUID()
        let admission = try XCTUnwrap(admit(harness, invocationID: invocationID))
        let otherChildSessionID = UUID()
        let existing = AgentRecoveryDelegatedChildLink(
            invocationID: invocationID,
            parentRunAttemptID: ownership.attemptID,
            childSessionID: otherChildSessionID,
            linkedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1)
        )
        guard case .success = await lane.commitDelegatedChildLink(existing, parentOwnership: ownership, parentProcessRunID: harness.session.runID) else {
            return XCTFail("The conflicting fixture link commits")
        }
        let child = try await makeChild(harness)
        do {
            try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
            XCTFail("A conflicting child for the same invocation is an error")
        } catch {
            XCTAssertTrue("\(error)".contains("could not record"), "\(error)")
        }
        let links = await recordedLinks(lane)
        XCTAssertEqual(links.map(\.childSessionID), [otherChildSessionID])
        XCTAssertNil(admission.linkedChildSessionID, "No dispatch fence is ever armed")
        XCTAssertNil(MCPDelegatedChildDispatchFence.$current.withValue(admission) {
            harness.viewModel.mcpDelegatedChildDispatchFence(for: child.sessionID)
        })
    }

    // MARK: - Child identity fence

    /// A child reset during the parent's link await (after its covering save) or after the link
    /// keeps its object, session ID, and parent, but never dispatches under its new reset generation.
    func testChildResetDuringLinkAwaitOrBeforeStartDispatchesNothing() async throws {
        // During the link await: the link may commit unused, but no fence is ever armed.
        do {
            let harness = try await makeHarness(windowID: 95208)
            let lane = try await persistAndClaimLane(harness)
            beginParentAttempt(harness)
            let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
            let child = try await makeChild(harness)
            let resets = ResetOutcomes()
            harness.viewModel.test_delegatedChildLinkAwaitHook = { session in
                let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: session.tabID)
                resets.values.append(outcome)
            }
            do {
                try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
                XCTFail("A child reset during the link await fails the link")
            } catch {
                XCTAssertTrue("\(error)".contains("reset, rebound, or replaced"), "\(error)")
            }
            XCTAssertEqual(resets.values, [.committed], "The fixture really reset the saved child")
            XCTAssertTrue(child.session === harness.viewModel.sessions[child.session.tabID])
            XCTAssertEqual(child.session.activeAgentSessionID, child.sessionID, "Object and session ID are kept")
            XCTAssertEqual(child.session.parentSessionID, admission.parentSessionID, "Parent is kept")
            XCTAssertNil(admission.linkedChildSessionID, "No dispatch fence is ever armed")
            let links = await recordedLinks(lane)
            XCTAssertEqual(links.map(\.childSessionID), [child.sessionID], "The durable link stays, unused")
            // The service throws this commit failure before its scoped start, so nothing dispatches.
            XCTAssertNil(MCPDelegatedChildDispatchFence.$current.withValue(admission) {
                harness.viewModel.mcpDelegatedChildDispatchFence(for: child.sessionID)
            })
        }
        // After the link, before the start: the final pre-dispatch fence refuses the new generation.
        do {
            let harness = try await makeHarness(windowID: 95209)
            _ = try await persistAndClaimLane(harness)
            beginParentAttempt(harness)
            let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
            let child = try await makeChild(harness)
            try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
            XCTAssertTrue(harness.viewModel.mcpDelegatedChildLinkAdmissionIsCurrent(admission))
            let reset = await harness.viewModel.clearChatPreservingRecovery(tabID: child.session.tabID)
            XCTAssertEqual(reset, .committed)
            XCTAssertFalse(harness.viewModel.mcpDelegatedChildLinkAdmissionIsCurrent(admission), "The final predicate checks the child")
            let dispatches = DispatchRecorder()
            do {
                try await MCPDelegatedChildDispatchFence.$current.withValue(admission) {
                    _ = try await startChild(harness, child, recordingInto: dispatches)
                }
                XCTFail("A reset child is never started")
            } catch {
                XCTAssertTrue("\(error)".contains("reset, rebound, or replaced"), "\(error)")
            }
            XCTAssertEqual(dispatches.sessionIDs, [], "Zero dispatches")
        }
    }

    /// Control: the real starter under a linked fence dispatches exactly once (activation and
    /// configuration do not disturb the child's saved identity). Once the start's one-shot release
    /// runs, the inherited TaskLocal no longer arms the fence, while the explicitly captured fence
    /// keeps its checks.
    func testLinkedChildStartsOnceAndReleasedFenceIsNotArmedAgain() async throws {
        let harness = try await makeHarness(windowID: 95210)
        _ = try await persistAndClaimLane(harness)
        let ownership = beginParentAttempt(harness)
        let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
        let child = try await makeChild(harness)
        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
        let dispatches = DispatchRecorder()
        try await MCPDelegatedChildDispatchFence.$current.withValue(admission) {
            defer { admission.releaseDispatchFence() }
            _ = try await startChild(harness, child, recordingInto: dispatches)
        }
        XCTAssertEqual(dispatches.sessionIDs, [child.sessionID], "Exactly one dispatch")
        XCTAssertTrue(dispatches.fenceWasArmed, "The dispatch ran under the linked fence")
        XCTAssertTrue(admission.isDispatchFenceReleased)
        XCTAssertNil(MCPDelegatedChildDispatchFence.$current.withValue(admission) {
            harness.viewModel.mcpDelegatedChildDispatchFence(for: child.sessionID)
        }, "Unstructured work that inherited the scope no longer arms the fence")
        XCTAssertNoThrow(try harness.viewModel.mcpRequireDelegatedChildDispatchFence(admission), "An explicitly captured fence keeps its checks")
        XCTAssertTrue(harness.session.endRunAttempt(ifCurrent: ownership, source: "test.delegatedChildLink"))
        XCTAssertThrowsError(try harness.viewModel.mcpRequireDelegatedChildDispatchFence(admission))
    }

    /// Cancellation after each new persistence await and before dispatch starts nothing.
    func testCancellationAtEachNewAwaitDispatchesNothing() async throws {
        enum Point: CaseIterable { case childSave, linkAwait, starterBeforeDispatch }
        for point in Point.allCases {
            let harness = try await makeHarness(windowID: 95212)
            let lane = try await persistAndClaimLane(harness)
            beginParentAttempt(harness)
            let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
            let child = try await makeChild(harness)
            switch point {
            case .childSave:
                harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = { session in
                    guard session === child.session else { return nil }
                    let outcome = await harness.viewModel.flushSaveDetailed(for: session.tabID)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return outcome
                }
            case .linkAwait:
                harness.viewModel.test_delegatedChildLinkAwaitHook = { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            case .starterBeforeDispatch:
                break
            }
            let dispatches = DispatchRecorder()
            let task = Task { @MainActor in
                try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
                try await MCPDelegatedChildDispatchFence.$current.withValue(admission) {
                    _ = try await self.startChild(
                        harness,
                        child,
                        recordingInto: dispatches,
                        cancelAtBind: point == .starterBeforeDispatch
                    )
                }
            }
            do {
                try await task.value
                XCTFail("\(point): a cancelled start completes nothing")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(point): \(error)")
            }
            XCTAssertEqual(dispatches.sessionIDs, [], "\(point): zero dispatches")
            let links = await recordedLinks(lane)
            switch point {
            case .childSave:
                XCTAssertTrue(links.isEmpty, "Cancelled after the child save: nothing is linked")
                XCTAssertNil(admission.linkedChildSessionID)
            case .linkAwait:
                XCTAssertEqual(links.count, 1, "Cancelled during the link await: the link may commit, unused")
                XCTAssertNil(admission.linkedChildSessionID, "No dispatch fence is armed")
            case .starterBeforeDispatch:
                XCTAssertEqual(links.count, 1)
                XCTAssertEqual(admission.linkedChildSessionID, child.sessionID)
            }
            harness.viewModel.test_recoverySavedPlacementSaveOutcomeOverride = nil
            harness.viewModel.test_delegatedChildLinkAwaitHook = nil
        }
    }

    // MARK: - Parent terminal

    /// A first-turn parent attempt that began before its lane existed is first recorded by the link
    /// transaction; the normal terminal barrier still records its terminal.
    func testLinkEnsuredFirstTurnAttemptReceivesItsNormalTerminal() async throws {
        let harness = try await makeHarness(windowID: 95213)
        XCTAssertNotNil(harness.viewModel.ensureSessionBoundToTab(harness.session))
        let ownership = beginParentAttempt(harness)
        let lane = try await persistAndClaimLane(harness)
        let beforeLink = await lane.store.read(sessionID: lane.sessionID).record
        XCTAssertNil(
            beforeLink?.runAttempts.first { $0.runAttemptID == ownership.attemptID },
            "The attempt began before the lane: nothing recorded it yet"
        )
        let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
        let child = try await makeChild(harness)
        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
        let linked = await lane.store.read(sessionID: lane.sessionID).record
        let ensured = try XCTUnwrap(linked?.runAttempts.first { $0.runAttemptID == ownership.attemptID }, "The link transaction recorded the attempt")
        XCTAssertNil(ensured.terminal)

        let request = AgentRunTerminalCommitBarrier.Request(
            session: harness.session,
            ownership: ownership,
            expectedRunID: harness.session.runID,
            terminalState: .completed,
            source: "test.delegatedChildLink",
            cause: .ordinary,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false,
            supportsFollowUp: false,
            notifyTurnComplete: false
        )
        let committed = await harness.viewModel.test_terminalCommitBarrier().commit(request)
        let revision = try XCTUnwrap(committed, "The normal barrier commits the parent's terminal")
        var terminalCommitID: UUID?
        for _ in 0 ..< 500 {
            let record = await lane.store.read(sessionID: lane.sessionID).record
            terminalCommitID = record?.runAttempts.first { $0.runAttemptID == ownership.attemptID }?.terminal?.commitID
            if terminalCommitID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(terminalCommitID, revision.commitID, "The existing terminal owner records the link-ensured attempt")
        XCTAssertNil(lane.terminalEvidenceFailures[ownership.attemptID])
        let links = await recordedLinks(lane)
        XCTAssertEqual(links.map(\.childSessionID), [child.sessionID], "The link is kept")
    }

    // MARK: - Recovery presentation

    func testRecoveryOpensTheLinkedChildOrReportsMissingWithoutRecreatingIt() async throws {
        let harness = try await makeHarness(windowID: 95207)
        let lane = try await persistAndClaimLane(harness)
        beginParentAttempt(harness)
        let admission = try XCTUnwrap(admit(harness, invocationID: UUID()))
        let child = try await makeChild(harness)
        try await harness.viewModel.mcpCommitDelegatedChildLink(admission, childTabID: child.session.tabID, childSessionID: child.sessionID)
        let recorded = await recordedLinks(lane)
        let link = try XCTUnwrap(recorded.first)
        let viewModel = harness.viewModel
        let parentSessionID = admission.parentSessionID

        let present = viewModel.recoveryDelegatedChildPresentation([link], parentSessionID: parentSessionID)
        XCTAssertEqual(present.actions, [.openDelegatedSession(child.sessionID)])
        XCTAssertTrue(present.detail.contains(String(child.sessionID.uuidString.prefix(8))), present.detail)
        XCTAssertTrue(present.detail.contains("never restarted automatically"), present.detail)
        XCTAssertTrue(present.text?.contains(String(child.sessionID.uuidString.prefix(8))) == true, "The full status is viewable")

        // The same child linked under two invocations keeps both links but one status and one Open.
        let sameChildAgain = AgentRecoveryDelegatedChildLink(
            invocationID: UUID(),
            parentRunAttemptID: link.parentRunAttemptID,
            childSessionID: child.sessionID,
            linkedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2)
        )
        let deduped = viewModel.recoveryDelegatedChildPresentation([link, sameChildAgain], parentSessionID: parentSessionID)
        XCTAssertEqual(deduped.actions, [.openDelegatedSession(child.sessionID)], "No duplicate action IDs")
        let prefix = String(child.sessionID.uuidString.prefix(8))
        XCTAssertEqual(deduped.text?.components(separatedBy: prefix).count, 2, "One status line per child")

        // A parent row from another workspace is never resolved here.
        let elsewhere = viewModel.recoveryDelegatedChildPresentation([link], parentSessionID: parentSessionID, parentInOtherWorkspace: true)
        XCTAssertTrue(elsewhere.actions.isEmpty)
        XCTAssertTrue(elsewhere.detail.contains("open the parent to check"), elsewhere.detail)
        XCTAssertTrue(elsewhere.detail.contains("is linked to a delegated session"), elsewhere.detail)
        XCTAssertFalse(Self.claimsStarted(elsewhere.detail), elsewhere.detail)
        XCTAssertFalse(Self.claimsStarted(elsewhere.text ?? ""), elsewhere.text ?? "")

        let mismatched = viewModel.recoveryDelegatedChildPresentation([link], parentSessionID: UUID())
        XCTAssertTrue(mismatched.detail.contains("different parent"), mismatched.detail)

        let sessionCount = viewModel.sessions.count
        let missingID = UUID()
        let missing = AgentRecoveryDelegatedChildLink(
            invocationID: UUID(),
            parentRunAttemptID: link.parentRunAttemptID,
            childSessionID: missingID,
            linkedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1)
        )
        let absent = viewModel.recoveryDelegatedChildPresentation([missing], parentSessionID: parentSessionID)
        XCTAssertTrue(absent.actions.isEmpty, "No Open for a child that isn't here")
        XCTAssertTrue(absent.detail.contains("can't be found"), absent.detail)

        // Multiple distinct stubs: the summary says they are linked, never that they started.
        let multiple = viewModel.recoveryDelegatedChildPresentation([link, missing], parentSessionID: parentSessionID)
        XCTAssertTrue(multiple.detail.contains("is linked to 2 delegated sessions"), multiple.detail)
        XCTAssertFalse(Self.claimsStarted(multiple.detail), multiple.detail)

        let rowID = "delegated-child-test"
        await viewModel.performRecoveryListAction(rowID: rowID, action: .openDelegatedSession(missingID))
        guard case let .failed(message)? = viewModel.recoveryCoordinator?.catalogActionStates[rowID] else {
            return XCTFail("Opening a missing child reports it")
        }
        XCTAssertTrue(message.contains("not recreated"), message)
        XCTAssertEqual(viewModel.sessions.count, sessionCount, "Nothing was created or hydrated")
        XCTAssertNil(try viewModel.authoritativeLiveSession(for: missingID))
    }

    // MARK: - Fixtures

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let tabID: UUID
        let session: AgentTabSession
    }

    private struct Child {
        let session: AgentTabSession
        let sessionID: UUID
    }

    private func admit(_ harness: Harness, invocationID: UUID?) throws -> MCPDelegatedChildLinkAdmission? {
        try harness.viewModel.mcpAdmitDelegatedChildLink(
            sourceTabID: harness.tabID,
            admittedCallerSessionID: harness.session.activeAgentSessionID,
            invocationID: invocationID,
            operation: "agent_run.start",
            revalidateDelegation: {}
        )
    }

    @discardableResult
    private func beginParentAttempt(_ harness: Harness) -> AgentRunOwnership {
        harness.session.runID = UUID()
        harness.session.runState = .running
        return harness.session.beginRunAttempt(source: "test.delegatedChildLink")
    }

    /// A new child tab bound to its own identity and recorded under the parent, as production target
    /// creation (`mcpResolveOrCreateSessionTarget`'s new-tab branch: ready, bind, record parent)
    /// leaves it before the link: never saved, so no persistence state and no claimed lane. Only the
    /// link's covering save can make it durable.
    private func makeChild(_ harness: Harness) async throws -> Child {
        let session = try await harness.viewModel.ensureSessionReady(tabID: UUID())
        let sessionID = try XCTUnwrap(harness.viewModel.ensureSessionBoundToTab(session))
        session.parentSessionID = harness.session.activeAgentSessionID
        XCTAssertNil(session.persistenceState, "The child is not pre-saved")
        XCTAssertNil(session.recoveryLane, "The child's lane is not pre-claimed")
        return Child(session: session, sessionID: sessionID)
    }

    /// Whether a summary claims a child started ("restarted" in the never-restarted sentence is not a claim).
    private static func claimsStarted(_ text: String) -> Bool {
        text.range(of: #"\bstarted\b"#, options: .regularExpression) != nil
    }

    /// The production `AgentExternalMCPRunStarter` for the child, recording its dispatch instead of
    /// launching a provider. `cancelAtBind` cancels the calling task at the starter's last await.
    private func startChild(
        _ harness: Harness,
        _ child: Child,
        recordingInto dispatches: DispatchRecorder,
        cancelAtBind: Bool = false
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome {
        try await AgentExternalMCPRunStarter.start(
            target: AgentModeViewModel.MCPSessionTarget(tabID: child.session.tabID, sessionID: child.sessionID, origin: .createdNewTab),
            message: "Delegated work",
            metadata: MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil, actorRoutedRunTab: nil),
            bindCurrentRequestToTab: { _, _ in
                if cancelAtBind {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            agentModeVM: harness.viewModel,
            agentRaw: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            dispatchInstruction: { sessionID, _, _, _, host in
                dispatches.sessionIDs.append(sessionID)
                dispatches.fenceWasArmed = host.mcpDelegatedChildDispatchFence(for: sessionID) != nil
                return .startedRun
            }
        )
    }

    private func recordedLinks(_ lane: AgentRecoverySessionLane) async -> [AgentRecoveryDelegatedChildLink] {
        await lane.store.read(sessionID: lane.sessionID).record?.delegatedChildLinks ?? []
    }

    /// Persists the first transcript through the VM save path, which claims the session's lane.
    private func persistAndClaimLane(_ harness: Harness) async throws -> AgentRecoverySessionLane {
        harness.session.appendItem(.user("Earlier turn"))
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        return try XCTUnwrap(harness.session.recoveryLane, "The first save claims the session's lane")
    }

    private func makeHarness(windowID: Int) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryDelegatedChildLinkWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryDelegatedChildLinkStore")
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
            name: "Agent Recovery Delegated Child Links",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in DelegatedChildLinkNoopCodexController() }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        return Harness(viewModel: viewModel, workspace: workspace, tabID: tabID, session: session)
    }
}

private enum MCPDelegatedChildLinkTestError: Error {
    case delegationChanged
}

@MainActor
private final class DelegationChangedFlag {
    var value = false
}

@MainActor
private final class ResetOutcomes {
    var values: [AgentModeViewModel.RecoveryTranscriptResetOutcome] = []
}

@MainActor
private final class DispatchRecorder {
    var sessionIDs: [UUID] = []
    var fenceWasArmed = false
}

private final class DelegatedChildLinkNoopCodexController: CodexSessionControlling {
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
