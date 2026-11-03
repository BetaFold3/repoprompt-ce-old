import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class CodemapBindingEngineOverlayTests: CodemapBindingEngineTestCase {
    func testProjectionRestartsAgainstConcurrentOverlayContributionGeneration() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let overlay = WorkspaceCodemapLiveOverlay()
        let recorder = EngineProjectionRecorder()
        let publicationGate = EngineAsyncGate()
        let publisher = EngineProjectionGenerationRacePublisher(
            gate: publicationGate,
            recorder: recorder
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            overlay: overlay,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder,
                    publishProjectionOverride: { snapshot in
                        await publisher.publish(snapshot)
                    }
                ).client
            }
        )
        addTeardownBlock { publicationGate.release() }
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let publicationEntered = await publicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            publicationGate.release()
            return XCTFail("Expected concurrent live overlay publication.")
        }
        publicationGate.release()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)

        let snapshots = await publisher.snapshots
        let segmentGenerations = snapshots.compactMap { snapshot -> WorkspaceCodemapProjectionGeneration? in
            guard case let .segment(segment) = snapshot else { return nil }
            return segment.generation
        }
        XCTAssertGreaterThanOrEqual(segmentGenerations.count, 2)
        XCTAssertLessThan(
            try XCTUnwrap(segmentGenerations.first?.contributionGeneration),
            try XCTUnwrap(segmentGenerations.last?.contributionGeneration)
        )
        let segmentSequences = snapshots.compactMap { snapshot -> UInt64? in
            guard case let .segment(segment) = snapshot else { return nil }
            return segment.sequence
        }
        XCTAssertEqual(segmentSequences, [0, 0])
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionCoveragesSuperseded, 1)
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
        let repeatedSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(repeatedSchedule, .handedOff)
    }

    func testCompletedProjectionPreparesAndCommitsOverlayGenerationSuccessorWithoutReplay() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let retainedDemand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(retainedTicket, initialRetainedStatus) = retainedDemand,
              case .ready = initialRetainedStatus
        else {
            return XCTFail("Expected retained demand to observe generation-1 coverage.")
        }

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            return XCTFail("Expected live publication to advance overlay generation.")
        }
        let frozenBundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(frozenBundle)
        defer { bundle.close() }
        let liveSnapshot = try bundle.graphSnapshot()
        let registeredSessionID = await fixture.engine.projectionSessionID(for: fixture.registration)
        let sessionID = try XCTUnwrap(registeredSessionID)
        let preparedSeal = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot,
            expectedSessionID: sessionID
        )
        let seal = try XCTUnwrap(preparedSeal)
        let fencedStatus = await fixture.engine.projectionDemandStatus(retainedTicket)
        XCTAssertEqual(fencedStatus, .stale)
        XCTAssertEqual(seal.predecessorProof.generation.contributionGeneration.rawValue, 1)
        XCTAssertEqual(
            seal.successorProof.generation.contributionGeneration,
            liveSnapshot.contributionGeneration
        )
        let committed = await fixture.engine.commitCompletedProjectionSuccessor(seal)
        XCTAssertTrue(committed)
        let duplicate = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot,
            expectedSessionID: sessionID
        )
        XCTAssertNil(duplicate)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
    }

    func testRejectedCompletedProjectionSuccessorRestartsWorkerAndCoalescesRetainedDemand() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let initialCompleted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(initialCompleted)

        let retainedDemand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(retainedTicket, initialStatus) = retainedDemand,
              case .ready = initialStatus
        else {
            return XCTFail("Expected retained demand to observe initial projection coverage.")
        }

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            return XCTFail("Expected live publication to advance overlay generation.")
        }
        let frozenBundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(frozenBundle)
        defer { bundle.close() }
        let liveSnapshot = try bundle.graphSnapshot()
        let registeredSessionID = await fixture.engine.projectionSessionID(for: fixture.registration)
        let sessionID = try XCTUnwrap(registeredSessionID)
        let preparedSeal = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot,
            expectedSessionID: sessionID
        )
        let seal = try XCTUnwrap(preparedSeal)

        let restarted = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: liveSnapshot.contributionGeneration,
            expectedSessionID: sessionID
        )
        XCTAssertTrue(restarted)
        let duplicateRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: liveSnapshot.contributionGeneration,
            expectedSessionID: sessionID
        )
        XCTAssertFalse(duplicateRestart)
        let successorCompleted = await fixture.engine.waitForCurrentProjectionCoverage(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertTrue(successorCompleted)
        let completedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(completedAccounting.projectionRoots.first?.phase, .complete)
        XCTAssertEqual(completedAccounting.activeProjectionBatchCount, 0)
        XCTAssertEqual(completedAccounting.queuedProjectionBatchCount, 0)

        let retainedStatus = await fixture.engine.projectionDemandStatus(retainedTicket)
        XCTAssertEqual(retainedStatus, .ready(seal.successorProof))
        var accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 1)
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 2)
        await fixture.engine.releaseProjectionDemand(retainedTicket)
        accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0)
    }

    func testReplacementSessionOwnsFreshContributionWatermarkAndRejectsRetiredWrites() async throws {
        let fixture = try await makeSingleCandidateProjectionFixture(name: #function)
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let retiredCompleted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(retiredCompleted)
        let retiredRegistration = await fixture.engine.projectionSessionID(for: fixture.registration)
        let retiredSessionID = try XCTUnwrap(retiredRegistration)

        // Advance the retired session's overlay and watermark above the replacement's restarted sequence.
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            return XCTFail("Expected live publication to advance the retired overlay.")
        }
        let retiredBundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let retiredSnapshot = try XCTUnwrap(retiredBundle).graphSnapshot()
        retiredBundle?.close()
        let retiredRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: retiredSnapshot.contributionGeneration,
            expectedSessionID: retiredSessionID
        )
        XCTAssertTrue(retiredRestart)
        let retiredRecovered = await fixture.engine.waitForCurrentProjectionCoverage(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(retiredRecovered)
        let retiredObservation = await fixture.engine.debugProjectionContributionObservation(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertEqual(retiredObservation?.sessionID, retiredSessionID)
        XCTAssertEqual(retiredObservation?.latestGeneration, retiredSnapshot.contributionGeneration)
        XCTAssertGreaterThan(retiredSnapshot.contributionGeneration.rawValue, 1)

        _ = await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
        let invalidatedObservation = await fixture.engine.debugProjectionContributionObservation(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertNil(invalidatedObservation)
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected the same registration to install a replacement engine session.")
        }
        let replacementRegistration = await fixture.engine.projectionSessionID(for: fixture.registration)
        let replacementSessionID = try XCTUnwrap(replacementRegistration)
        XCTAssertNotEqual(replacementSessionID, retiredSessionID)
        let freshObservation = await fixture.engine.debugProjectionContributionObservation(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertEqual(freshObservation?.sessionID, replacementSessionID)
        XCTAssertNil(freshObservation?.latestGeneration)

        // Late retired-session observer and snapshot writes are rejected before observation.
        let lateRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: retiredSnapshot.contributionGeneration,
            expectedSessionID: retiredSessionID
        )
        XCTAssertFalse(lateRestart)
        let lateSeal = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: retiredSnapshot,
            expectedSessionID: retiredSessionID
        )
        XCTAssertNil(lateSeal)
        let afterLateObservation = await fixture.engine.debugProjectionContributionObservation(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertEqual(afterLateObservation?.sessionID, replacementSessionID)
        XCTAssertNil(afterLateObservation?.latestGeneration)

        // The replacement completes at its own restarted sequence in exactly one schedule, with no
        // watermark-driven restart or supersession inherited from the retired session.
        let beforeReplacement = await fixture.engine.accounting()
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let replacementCompleted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(replacementCompleted)
        let replacementCurrent = await fixture.engine.waitForCurrentProjectionCoverage(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(replacementCurrent)
        let afterReplacement = await fixture.engine.accounting()
        XCTAssertEqual(
            afterReplacement.counters.projectionPreloadsScheduled,
            beforeReplacement.counters.projectionPreloadsScheduled + 1
        )
        XCTAssertEqual(
            afterReplacement.counters.projectionCoveragesSuperseded,
            beforeReplacement.counters.projectionCoveragesSuperseded
        )
        let demand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(ticket, status) = demand, case let .ready(proof) = status else {
            return XCTFail("Expected replacement projection demand to be ready: \(demand)")
        }
        XCTAssertLessThan(proof.generation.contributionGeneration, retiredSnapshot.contributionGeneration)
        await fixture.engine.releaseProjectionDemand(ticket)
    }

    func testActiveWorkerRetainsCurrentSessionOverlayAdvanceMonotonically() async throws {
        let overlay = WorkspaceCodemapLiveOverlay()
        let recorder = EngineProjectionRecorder()
        let publicationGate = EngineAsyncGate()
        let publisher = EngineProjectionGenerationRacePublisher(
            gate: publicationGate,
            recorder: recorder
        )
        let fixture = try await makeSingleCandidateProjectionFixture(
            name: #function,
            overlay: overlay,
            recorder: recorder,
            publishProjectionOverride: { snapshot in
                await publisher.publish(snapshot)
            }
        )
        addTeardownBlock { publicationGate.release() }
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let publicationEntered = await publicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)
        let registeredSessionID = await fixture.engine.projectionSessionID(for: fixture.registration)
        let sessionID = try XCTUnwrap(registeredSessionID)

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            publicationGate.release()
            return XCTFail("Expected a live overlay advance while the worker is active.")
        }
        let advancedSnapshot = await overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let advanced = try XCTUnwrap(advancedSnapshot).contributionGeneration
        XCTAssertGreaterThan(advanced.rawValue, 1)

        // The active worker cannot restart, but the current-session advance is still recorded.
        let activeRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: advanced,
            expectedSessionID: sessionID
        )
        XCTAssertFalse(activeRestart)
        var observation = await fixture.engine.debugProjectionContributionObservation(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(observation?.sessionID, sessionID)
        XCTAssertEqual(observation?.latestGeneration, advanced)

        // A lower same-session observation never regresses the watermark.
        _ = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: .init(rawValue: 1),
            expectedSessionID: sessionID
        )
        // A foreign session's observation is rejected without mutation.
        let foreignRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: .init(rawValue: advanced.rawValue + 100),
            expectedSessionID: UUID()
        )
        XCTAssertFalse(foreignRestart)
        observation = await fixture.engine.debugProjectionContributionObservation(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(observation?.sessionID, sessionID)
        XCTAssertEqual(observation?.latestGeneration, advanced)

        publicationGate.release()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)
        let current = await fixture.engine.waitForCurrentProjectionCoverage(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(current)
        let demand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(ticket, status) = demand, case let .ready(proof) = status else {
            return XCTFail("Expected coverage at the retained advance to be ready: \(demand)")
        }
        XCTAssertEqual(proof.generation.contributionGeneration, advanced)
        await fixture.engine.releaseProjectionDemand(ticket)
    }

    func testProjectionResourceBudgetExposesTypedTerminalCoverage() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Budget.swift": SwiftFixtureSource.emptyStruct("Budget")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRetainedProjectionByteCountPerRoot: 1,
                maximumRetainedProjectionByteCount: 1
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Budget.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let budgeted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .budgetLimited &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(budgeted)
        let accounting = await fixture.engine.accounting()
        let budget = try XCTUnwrap(accounting.projectionRoots.first?.budget)
        XCTAssertEqual(budget.dimension, .retainedProjectionBytes)
        XCTAssertGreaterThan(budget.attempted, 1)
        XCTAssertEqual(budget.limit, 1)
        XCTAssertEqual(accounting.suspendedProjectionJobCount, 0)
        XCTAssertNil(accounting.projectionRoots.first?.retry)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)

        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: [],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case let .budget(dimension, attempted, limit) = disposition else {
            return XCTFail("Expected typed terminal budget coverage.")
        }
        XCTAssertEqual(dimension, budget.dimension)
        XCTAssertEqual(attempted, budget.attempted)
        XCTAssertEqual(limit, budget.limit)
    }

    func testStaleProjectionCatalogRetainsTerminalSupersededCoverageWithoutRestart() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Stale.swift": SwiftFixtureSource.emptyStruct("Stale")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { _, _ in
                WorkspaceCodemapBindingCatalogClient {
                    _, _ in nil
                } readProjectionCatalogPage: { _ in
                    .stale
                } revalidateProjectionCatalogToken: { _, _ in
                    .stale
                } publishProjection: { snapshot in
                    await recorder.publish(snapshot)
                }
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let scheduled = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(scheduled, .handedOff)
        let retained = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            let jobID = await fixture.engine.retainedSupersededProjectionJobID(rootEpoch: fixture.rootEpoch)
            return accounting.projectionRoots.first?.phase == .superseded &&
                accounting.activeProjectionBatchCount == 0 &&
                jobID != nil
        }
        XCTAssertTrue(retained)

        // The selected source has no resolved binding, so no provisional plan can stand in.
        let request = WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
            rootEpoch: fixture.rootEpoch,
            sourceTickets: [unresolvedSourceTicket(fixture, path: "Sources/Stale.swift")],
            candidates: [],
            maximumMatchedCandidateCount: 0
        )
        let disposition = await fixture.engine.planAutomaticSelectionCandidates(request)
        guard case .unavailable(.projectionSuperseded) = disposition else {
            return XCTFail("Expected retained superseded coverage to be terminal, got \(disposition).")
        }
        // Provisional control: a request a provisional plan can satisfy keeps that plan.
        let provisional = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: [],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case .provisional = provisional else {
            return XCTFail("Expected a satisfiable provisional plan to take precedence, got \(provisional).")
        }
        let repeatedSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(repeatedSchedule, .superseded)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
        XCTAssertEqual(accounting.counters.projectionCoveragesSuperseded, 1)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)

        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        let afterUnloadJobID = await fixture.engine.retainedSupersededProjectionJobID(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(afterUnloadJobID)
        guard case .unavailable(.rootUnloaded) = await fixture.engine.planAutomaticSelectionCandidates(request) else {
            return XCTFail("Expected an unloaded root to stop reporting retained superseded coverage.")
        }
    }

    func testActiveProjectionCoverageRemainsIncompleteRatherThanTerminal() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Active.swift": SwiftFixtureSource.emptyStruct("Active")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let pageGate = EngineAsyncGate()
        addTeardownBlock { pageGate.release() }
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Active.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder,
                    pageGate: pageGate
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let pageEntered = await pageGate.waitUntilEntered()
        XCTAssertTrue(pageEntered)

        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [unresolvedSourceTicket(fixture, path: "Sources/Active.swift")],
                candidates: [],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case .incomplete = disposition else {
            pageGate.release()
            return XCTFail("Expected active projection work to remain incomplete, got \(disposition).")
        }
        let activeJobID = await fixture.engine.retainedSupersededProjectionJobID(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(activeJobID)
        pageGate.release()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)
        let completedJobID = await fixture.engine.retainedSupersededProjectionJobID(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(completedJobID)
    }

    /// A current-generation source ticket with no resolved overlay binding (never demanded).
    private func unresolvedSourceTicket(
        _ fixture: EngineFixture,
        path: String
    ) -> WorkspaceCodemapArtifactDemandTicket {
        WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: UUID(),
            rootEpoch: fixture.rootEpoch,
            fileID: fixture.fileIDs.id(for: path),
            requestGeneration: 1,
            catalogGeneration: fixture.registration.catalogGeneration,
            pathGeneration: 1,
            ingressGeneration: fixture.registration.ingressGeneration
        )
    }

    func testProjectionCompletenessDoesNotUseManifestAdoptionRetentionCap() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let paths = ["Sources/One.swift", "Sources/Two.swift"]
        let root = try repository.makeRepository(
            named: "repository",
            files: Dictionary(uniqueKeysWithValues: paths.map { ($0, SwiftFixtureSource.emptyStruct("Value")) })
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumManifestAdoptionRecordCount: 1),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let candidates = paths.map { path in
                    WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )
                }
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: candidates,
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let candidates = paths.map { path in
            WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
                identity: WorkspaceCodemapArtifactBindingIdentity(
                    rootID: fixture.rootEpoch.rootID,
                    rootLifetimeID: fixture.rootEpoch.rootLifetimeID,
                    fileID: fixture.fileIDs.id(for: path),
                    standardizedRootPath: root.path,
                    standardizedRelativePath: path,
                    standardizedFullPath: root.appendingPathComponent(path).path
                )!,
                language: .swift,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: candidates,
                maximumMatchedCandidateCount: 0
            )
        )
        guard case let .ready(plan) = disposition else {
            return XCTFail("Expected the complete two-candidate universe above the adoption cap.")
        }
        XCTAssertEqual(plan.indexedCandidateCount, 2)
        XCTAssertTrue(plan.necessaryCandidates.isEmpty)
        XCTAssertEqual(plan.coverageProof.catalogCompletion.supportedCandidateCount, 2)

        let subsetDisposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: [candidates[0]],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case .stale = subsetDisposition else {
            return XCTFail("Expected a subset to be rejected against the full-catalog coverage proof.")
        }
    }

    func testAutomaticSelectionMatchedCandidateBytesAreBounded() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source"),
                "Sources/Candidate.swift": SwiftFixtureSource.emptyStruct("Candidate")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                .ready(CodeMapSyntaxArtifact(
                    imports: [],
                    classes: [ClassInfo(name: "Target", methods: [], properties: [])],
                    functions: [],
                    enums: [],
                    globalVars: [],
                    macros: [],
                    referencedTypes: ["Target"]
                ))
            })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumAutomaticSelectionMatchedCandidateByteCount: 1
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Candidate.swift"
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case let .ready(source) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Source.swift")
        ) else { return XCTFail("Expected the source contribution.") }
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let candidatePath = "Sources/Candidate.swift"
        let candidate = try WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
            identity: XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
                rootID: fixture.rootEpoch.rootID,
                rootLifetimeID: fixture.rootEpoch.rootLifetimeID,
                fileID: fixture.fileIDs.id(for: candidatePath),
                standardizedRootPath: root.path,
                standardizedRelativePath: candidatePath,
                standardizedFullPath: root.appendingPathComponent(candidatePath).path
            )),
            language: .swift,
            requestGeneration: 1,
            catalogGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1
        )
        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [WorkspaceCodemapArtifactDemandTicket(
                    retainID: UUID(),
                    requestID: UUID(),
                    rootEpoch: fixture.rootEpoch,
                    fileID: source.fileID,
                    requestGeneration: source.requestGeneration,
                    catalogGeneration: 1,
                    pathGeneration: 1,
                    ingressGeneration: 1
                )],
                candidates: [candidate],
                maximumMatchedCandidateCount: 1
            )
        )
        guard case let .budget(dimension, attempted, limit) = disposition else {
            return XCTFail("Expected matched candidate byte-budget rejection.")
        }
        XCTAssertEqual(dimension, .retainedProjectionBytes)
        XCTAssertGreaterThan(attempted, 1)
        XCTAssertEqual(limit, 1)
    }

    /// One-candidate projection catalog (`Sources/Preload.swift`) plus an uncataloged live file
    /// (`Sources/Live.swift`) whose demand advances the overlay contribution sequence.
    private func makeSingleCandidateProjectionFixture(
        name: String,
        overlay: WorkspaceCodemapLiveOverlay? = nil,
        recorder: EngineProjectionRecorder = EngineProjectionRecorder(),
        publishProjectionOverride: (@Sendable (
            WorkspaceCodemapProjectionSnapshot
        ) async -> WorkspaceCodemapProjectionSnapshotDisposition)? = nil
    ) async throws -> EngineFixture {
        let repository = try makeRepositoryFixture(name: name)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        return try await makeEngineFixture(
            root: root,
            runtime: runtime,
            overlay: overlay,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder,
                    publishProjectionOverride: publishProjectionOverride
                ).client
            }
        )
    }
}
