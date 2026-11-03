import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Identity-scoped tri-state settlement of the pending-handoff payload (stage-delivery semantics, not
/// provider acceptance) and the hydration join against recovery-intent delivery evidence.
@MainActor
final class AgentPendingHandoffStageOutcomeTests: XCTestCase {
    // MARK: - Stage identity

    func testLateOutcomeOfAnEarlierStageNeverSettlesANewerStageOrPayload() throws {
        let (vm, session) = makeLiveSession()
        session.pendingHandoff = AgentPendingHandoffState(payload: "## First", payloadID: UUID())

        let first = vm.stagePendingHandoffIfNeeded("one", session: session)
        let firstStage = try XCTUnwrap(first.pendingHandoffStage)
        XCTAssertEqual(first.text, "## First\n\none")
        XCTAssertEqual(vm.stagePendingHandoffIfNeeded("again", session: session).text, "again", "A staged payload is never prepended twice")

        // Verified not sent: released, then staged into a later input under a new stage.
        vm.recordPendingHandoffStageOutcome(for: session, stage: firstStage, disposition: .notSent)
        XCTAssertFalse(session.pendingHandoff.isReservedForSend)
        let second = vm.stagePendingHandoffIfNeeded("two", session: session)
        let secondStage = try XCTUnwrap(second.pendingHandoffStage)
        XCTAssertNotEqual(secondStage, firstStage)

        // The first stage's late outcome settles nothing.
        vm.recordPendingHandoffStageOutcome(for: session, stage: firstStage, disposition: .sent)
        vm.recordPendingHandoffStageOutcome(for: session, stage: firstStage, disposition: .deliveryUnknown)
        XCTAssertEqual(session.pendingHandoff.payload, "## First")
        XCTAssertEqual(session.pendingHandoff.stage, secondStage)
        XCTAssertNil(session.pendingHandoff.deliveryHold)

        vm.recordPendingHandoffStageOutcome(for: session, stage: secondStage, disposition: .sent)
        XCTAssertNil(session.pendingHandoff.payload, "The stage-delivery boundary consumes exactly its payload")

        // A newer payload is never cleared by an outcome of an older payload's stage.
        let newerID = UUID()
        session.pendingHandoff = AgentPendingHandoffState(payload: "## Newer", payloadID: newerID)
        vm.recordPendingHandoffStageOutcome(for: session, stage: secondStage, disposition: .sent)
        vm.recordPendingHandoffStageOutcome(for: session, stage: AgentPendingHandoffStage(payloadID: newerID), disposition: .sent)
        XCTAssertEqual(session.pendingHandoff.payload, "## Newer")
        XCTAssertEqual(session.pendingHandoff.payloadID, newerID)
    }

    func testDeliveryUnknownHoldsThePayloadWithoutReprependUntilItsOwnLateOutcome() throws {
        let (vm, session) = makeLiveSession()
        session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: UUID())
        let stage = try XCTUnwrap(vm.stagePendingHandoffIfNeeded("one", session: session).pendingHandoffStage)

        vm.recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .deliveryUnknown)
        XCTAssertEqual(session.pendingHandoff.payload, "## Handoff", "Unknown never consumes")
        XCTAssertEqual(session.pendingHandoff.deliveryHold, .deliveryUnknown, "Unknown never releases")
        XCTAssertEqual(session.pendingHandoff.stage, stage)
        let next = vm.stagePendingHandoffIfNeeded("next", session: session)
        XCTAssertEqual(next.text, "next", "A possibly delivered payload is never prepended again")
        XCTAssertNil(next.pendingHandoffStage)

        // A late `sent` of the uncertain stage consumes it once; repeats are no-ops.
        vm.recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .sent)
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertNil(session.pendingHandoff.deliveryHold)
        vm.recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .sent)
        XCTAssertNil(session.pendingHandoff.payload)

        // A late verified `notSent` instead releases it for a later send.
        session.pendingHandoff = AgentPendingHandoffState(payload: "## Again", payloadID: UUID())
        let uncertain = try XCTUnwrap(vm.stagePendingHandoffIfNeeded("a", session: session).pendingHandoffStage)
        vm.recordPendingHandoffStageOutcome(for: session, stage: uncertain, disposition: .deliveryUnknown)
        vm.recordPendingHandoffStageOutcome(for: session, stage: uncertain, disposition: .notSent)
        XCTAssertFalse(session.pendingHandoff.isReservedForSend)
        XCTAssertEqual(vm.stagePendingHandoffIfNeeded("b", session: session).text, "## Again\n\nb")
    }

    func testStartTailMapsOnlyVerifiedOutcomesAndLeavesAdmittedRunnersToTheirOwnEvidence() {
        XCTAssertEqual(AgentModeViewModel.stagedInputStartDisposition(for: .stale(reason: "x")), .notSent)
        XCTAssertEqual(AgentModeViewModel.stagedInputStartDisposition(for: .failed(message: "x")), .notSent)
        XCTAssertEqual(AgentModeViewModel.stagedInputStartDisposition(for: .deliveryUnknown(message: "x")), .deliveryUnknown)
        XCTAssertNil(AgentModeViewModel.stagedInputStartDisposition(for: .sent))
        XCTAssertNil(AgentModeViewModel.stagedInputStartDisposition(for: nil), "An admitted runner owns the outcome")
    }

    // MARK: - Hydration join

    func testPayloadCarriedByADispatchingIntentIsHeldAndOnlyItsAcceptanceConsumesIt() async throws {
        let harness = try await makeRecoveryHarness(windowID: 4901)
        let payloadID = UUID()
        let intentID = try await harness.commitIntent(carryingPayloadID: payloadID)
        let attemptID = try await harness.beginDispatch(intentID: intentID)
        harness.session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: payloadID)

        harness.viewModel.resolvePendingHandoffRecoveryJoin(for: harness.session)
        XCTAssertEqual(harness.session.pendingHandoff.deliveryHold, .recoveryJoinPending)
        XCTAssertEqual(harness.viewModel.stagePendingHandoffIfNeeded("user", session: harness.session).text, "user")
        try await waitUntil("uncertain join") { harness.session.pendingHandoff.deliveryHold == .recoveryDeliveryUncertain }
        XCTAssertEqual(harness.session.pendingHandoff.payload, "## Handoff", "Uncertain evidence never consumes")
        XCTAssertEqual(
            harness.viewModel.stagePendingHandoffIfNeeded("user", session: harness.session).text,
            "user",
            "A matching uncertain snapshot prevents a duplicate prepend"
        )
        // No runtime stage outcome resolves a recovery hold.
        harness.viewModel.recordPendingHandoffStageOutcome(
            for: harness.session,
            stage: AgentPendingHandoffStage(payloadID: payloadID),
            disposition: .notSent
        )
        XCTAssertEqual(harness.session.pendingHandoff.deliveryHold, .recoveryDeliveryUncertain)

        _ = try await harness.lane.store.recordDeliveryOutcome(
            binding: harness.lane.binding,
            expectedRevision: harness.revision(),
            intentID: intentID,
            attemptID: attemptID,
            outcome: .providerAccepted
        )
        harness.viewModel.resolvePendingHandoffRecoveryJoin(for: harness.session)
        try await waitUntil("accepted join consumes") { harness.session.pendingHandoff.payload == nil }
        XCTAssertNil(harness.session.pendingHandoff.deliveryHold)
        XCTAssertTrue(harness.session.isDirty, "The consumed payload is saved")
    }

    func testStillOwningQueuedOrFailedCarrierKeepsThePayloadReservedUntilWithdrawn() async throws {
        // A queued carrier with no attempt still owns the durable snapshot and may later be sent.
        let queued = try await makeRecoveryHarness(windowID: 4904)
        let queuedPayloadID = UUID()
        let queuedIntentID = try await queued.commitIntent(carryingPayloadID: queuedPayloadID)
        queued.session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: queuedPayloadID)
        queued.viewModel.resolvePendingHandoffRecoveryJoin(for: queued.session)
        try await waitUntil("queued carrier holds") { queued.session.pendingHandoff.deliveryHold == .recoveryCarriedByIntent }
        XCTAssertEqual(queued.session.pendingHandoff.payload, "## Handoff", "Never erased or relabeled accepted")
        XCTAssertTrue(queued.session.pendingHandoff.isReservedForSend)
        XCTAssertEqual(
            queued.viewModel.stagePendingHandoffIfNeeded("fresh input", session: queued.session).text,
            "fresh input",
            "A fresh input never prepends a payload its queued carrier retains"
        )

        // Withdrawing the carrier (no unresolved attempt) releases the payload on re-join.
        _ = try await queued.lane.store.withdraw(
            binding: queued.lane.binding,
            expectedRevision: queued.revision(),
            intentID: queuedIntentID
        )
        queued.viewModel.resolvePendingHandoffRecoveryJoin(for: queued.session)
        try await waitUntil("withdrawn carrier releases") { queued.session.pendingHandoff.deliveryHold == nil }
        XCTAssertEqual(queued.viewModel.stagePendingHandoffIfNeeded("user", session: queued.session).text, "## Handoff\n\nuser")

        // A failed carrier (verified non-delivery, not withdrawn) is also still owning.
        let failed = try await makeRecoveryHarness(windowID: 4905)
        let failedPayloadID = UUID()
        let failedIntentID = try await failed.commitIntent(carryingPayloadID: failedPayloadID)
        let failedAttemptID = try await failed.beginDispatch(intentID: failedIntentID)
        _ = try await failed.lane.store.recordDeliveryOutcome(
            binding: failed.lane.binding,
            expectedRevision: failed.revision(),
            intentID: failedIntentID,
            attemptID: failedAttemptID,
            outcome: .failed(.verifiedRejection, message: nil)
        )
        failed.session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: failedPayloadID)
        failed.viewModel.resolvePendingHandoffRecoveryJoin(for: failed.session)
        try await waitUntil("failed carrier holds") { failed.session.pendingHandoff.deliveryHold == .recoveryCarriedByIntent }
        XCTAssertEqual(failed.session.pendingHandoff.payload, "## Handoff")

        XCTAssertEqual(
            AgentModeViewModel.pendingHandoffRecoveryJoin(payloadID: UUID(), recordState: .success(.absent)),
            .release,
            "An authorized read with no record (payload created before any send) is a legitimate release"
        )
    }

    func testVerifiedNonHandoffOrUnlinkedEvidenceReleasesOnlyTheJoinedPayload() async throws {
        let harness = try await makeRecoveryHarness(windowID: 4902)
        let payloadID = UUID()
        let settledIntentID = try await harness.commitIntent(carryingPayloadID: payloadID)
        let settledAttemptID = try await harness.beginDispatch(intentID: settledIntentID)
        _ = try await harness.lane.store.settleToQueue(
            binding: harness.lane.binding,
            expectedRevision: harness.revision(),
            intentID: settledIntentID,
            attemptID: settledAttemptID,
            evidence: .preHandoff,
            message: nil
        )
        // The re-queued carrier still owns the snapshot until it is withdrawn.
        _ = try await harness.lane.store.withdraw(
            binding: harness.lane.binding,
            expectedRevision: harness.revision(),
            intentID: settledIntentID
        )
        // Another payload's acceptance never consumes this one.
        let otherIntentID = try await harness.commitIntent(carryingPayloadID: UUID())
        let otherAttemptID = try await harness.beginDispatch(intentID: otherIntentID)
        _ = try await harness.lane.store.recordDeliveryOutcome(
            binding: harness.lane.binding,
            expectedRevision: harness.revision(),
            intentID: otherIntentID,
            attemptID: otherAttemptID,
            outcome: .providerAccepted
        )
        harness.session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: payloadID)

        harness.viewModel.resolvePendingHandoffRecoveryJoin(for: harness.session)
        try await waitUntil("released join") { harness.session.pendingHandoff.deliveryHold == nil }
        XCTAssertEqual(harness.session.pendingHandoff.payload, "## Handoff")
        XCTAssertEqual(harness.viewModel.stagePendingHandoffIfNeeded("user", session: harness.session).text, "## Handoff\n\nuser")
    }

    func testUnreadableOrUnavailableAuthorityHoldsThePayload() async throws {
        let payloadID = UUID()
        XCTAssertEqual(
            AgentModeViewModel.pendingHandoffRecoveryJoin(payloadID: payloadID, recordState: .success(.preserved(.malformed("x")))),
            .authorityUnavailable
        )
        XCTAssertEqual(
            AgentModeViewModel.pendingHandoffRecoveryJoin(payloadID: payloadID, recordState: .failure(.retired)),
            .authorityUnavailable
        )
        XCTAssertEqual(AgentModeViewModel.pendingHandoffRecoveryJoin(payloadID: payloadID, recordState: .success(.absent)), .release)

        let harness = try await makeRecoveryHarness(windowID: 4903)
        harness.session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: payloadID)
        harness.session.recoveryLane = nil
        harness.viewModel.resolvePendingHandoffRecoveryJoin(for: harness.session)
        XCTAssertEqual(harness.session.pendingHandoff.deliveryHold, .recoveryAuthorityUnavailable)
        XCTAssertEqual(harness.viewModel.stagePendingHandoffIfNeeded("user", session: harness.session).text, "user")
        XCTAssertEqual(harness.session.pendingHandoff.payload, "## Handoff")
    }

    func testJoinIsInactiveWithoutARecoveryCoordinator() {
        let (vm, session) = makeLiveSession()
        session.pendingHandoff = AgentPendingHandoffState(payload: "## Handoff", payloadID: UUID())
        vm.resolvePendingHandoffRecoveryJoin(for: session)
        XCTAssertNil(session.pendingHandoff.deliveryHold, "Legacy behavior is unchanged while recovery is inactive")
        XCTAssertEqual(vm.stagePendingHandoffIfNeeded("user", session: session).text, "## Handoff\n\nuser")
    }

    // MARK: - Harness

    private func makeLiveSession() -> (AgentModeViewModel, AgentTabSession) {
        let vm = AgentModeViewModel(
            testWindowID: 4900,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        let session = vm.session(for: UUID(), createIfNeeded: true)!
        return (vm, session)
    }

    private struct Timeout: Error {}

    private func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
        throw Timeout()
    }

    @MainActor
    private struct RecoveryHarness {
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let lane: AgentRecoverySessionLane

        func revision() async -> AgentRecoveryRecordRevision? {
            await lane.store.read(sessionID: lane.sessionID).record?.revision
        }

        func commitIntent(carryingPayloadID payloadID: UUID) async throws -> UUID {
            let intentID = UUID()
            let snapshot = AgentRecoveryPendingHandoffSnapshot(
                payloadID: payloadID,
                payload: "## Handoff",
                createdAt: nil,
                sourceItemID: nil,
                prependedText: "## Handoff\n\n"
            )
            _ = try await lane.store.commitQueuedIntent(
                binding: lane.binding,
                expectedRevision: revision(),
                submission: AgentRecoveryIntentSubmission(
                    intentID: intentID,
                    userItemID: UUID(),
                    origin: .composer,
                    target: .session,
                    payload: RecoveryTestSupport.content("user text"),
                    pendingHandoff: snapshot
                ),
                consumption: nil
            )
            return intentID
        }

        func beginDispatch(intentID: UUID) async throws -> UUID {
            let attemptID = UUID()
            _ = try await lane.store.beginDispatch(
                binding: lane.binding,
                expectedRevision: revision(),
                intentID: intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID),
                authorization: .liveQueue
            )
            return attemptID
        }
    }

    private func makeRecoveryHarness(windowID: Int) async throws -> RecoveryHarness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentPendingHandoffJoinWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentPendingHandoffJoinStore")
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
        guard await coordinator.awaitStartup() == .ready else { throw RecoveryLaneFixtureError.startupNotReady }

        let workspace = WorkspaceModel(name: "Pending Handoff Join", repoPaths: [storageURL.path], customStoragePath: storageURL)
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator)
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(session.recoveryLane, "The first save claims the session's lane")
        return RecoveryHarness(viewModel: viewModel, session: session, lane: lane)
    }
}
