import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class CodemapAutomaticSelectionBasicTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testPublisherIngressAppliesCatalogWhileCorrelatedCodemapInvalidationIsStalled() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Seed.swift": SwiftFixtureSource.emptyStruct("Seed")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let codemapGate = CodemapSuspensionGate()
        addTeardownBlock {
            await codemapGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let seed = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Seed.swift"
        })
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: seed.id))
        _ = try await readyResult(settledResult(store: store, ticket: ticket))

        await store.setCodemapPathInvalidationStageHandlerForTesting { epoch, _, stage in
            guard epoch == ticket.rootEpoch, stage == .rootMutationFence else { return }
            await codemapGate.enterAndWait()
        }

        let createdRelativePath = "Sources/Generated.swift"
        let createdURL = root.appendingPathComponent(createdRelativePath)
        try SwiftFixtureSource.emptyStruct("Generated").write(
            to: createdURL,
            atomically: true,
            encoding: .utf8
        )
        try await store.replayPublisherFileSystemDeltasForCodemapIndependenceTesting(
            rootID: loaded.id,
            deltas: [.fileAdded(createdRelativePath)],
            servicePublicationSequence: 41
        )
        let codemapStalled = await codemapGate.waitUntilEntered()
        XCTAssertTrue(codemapStalled)
        guard codemapStalled else { return }

        let catalogFile = await store.file(rootID: loaded.id, relativePath: createdRelativePath)
        XCTAssertNotNil(catalogFile)

        let demandDuringInvalidation = await store.requestCodemapArtifact(forFileID: seed.id)
        guard case .unavailable(.busy) = demandDuringInvalidation else {
            return XCTFail("Expected the retained codemap invalidation flight to fence demand admission")
        }

        let rootFenceTask = Task {
            await store.fenceCodemapAuthorityForCheckoutMutation(rootIDs: [loaded.id])
        }
        try await Task.sleep(for: .milliseconds(20))

        let explicitlyCreatedRelativePath = "Sources/Explicit.swift"
        let explicitlyCreatedURL = root.appendingPathComponent(explicitlyCreatedRelativePath)
        let createTask = Task {
            try await store.createFile(
                rootID: loaded.id,
                relativePath: explicitlyCreatedRelativePath,
                content: SwiftFixtureSource.emptyStruct("Explicit")
            )
        }
        var createdBeforeDerivedInvalidationReleased = false
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: explicitlyCreatedURL.path) {
                createdBeforeDerivedInvalidationReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            createdBeforeDerivedInvalidationReleased,
            "Explicit create must not wait for publisher-derived codemap convergence"
        )
        _ = try await createTask.value

        let deleteTask = Task {
            try await store.deleteFile(rootID: loaded.id, relativePath: createdRelativePath)
        }
        var deletedBeforeDerivedInvalidationReleased = false
        for _ in 0 ..< 200 {
            if !FileManager.default.fileExists(atPath: createdURL.path) {
                deletedBeforeDerivedInvalidationReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            deletedBeforeDerivedInvalidationReleased,
            "Explicit mutation must not wait for publisher-derived codemap convergence"
        )

        await codemapGate.release()
        try await deleteTask.value
        await rootFenceTask.value
        await store.setCodemapPathInvalidationStageHandlerForTesting(nil)

        let refreshed = try await readyArtifactDemand(store: store, forFileID: seed.id)
        XCTAssertEqual(refreshed.ticket.fileID, seed.id)
    }

    func testProvisionalAutomaticSelectionPublishesReadyTargetWithIncompleteDiagnostics() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let rootEpoch = targetTicket.rootEpoch
        let candidate = try automaticSelectionCandidate(
            file: target,
            root: loaded,
            ticket: targetTicket
        )
        let incomplete = WorkspaceCodemapAutomaticSelectionIncompleteReason.graph(
            .definitionUniverse(
                rootEpoch: rootEpoch,
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        )
        let plan = WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan(
            candidates: [candidate],
            rootScopeEpochs: [rootEpoch],
            incompleteReasons: [incomplete]
        )

        let result = await store.provisionalAutomaticCodemapSelectionResult(
            sources: [sourceIdentity],
            plan: plan,
            readyCandidates: [candidate],
            pendingReasons: [],
            partialReasons: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(result.roots.first?.targets.map(\.fileID), [target.id])
        guard case let .provisional(incompleteReasons, pendingReasons, partialReasons) = result.aggregateCoverage else {
            return XCTFail("Expected provisional aggregate coverage.")
        }
        XCTAssertEqual(incompleteReasons, [incomplete])
        XCTAssertTrue(pendingReasons.isEmpty)
        XCTAssertTrue(partialReasons.isEmpty)
        let receipt = try XCTUnwrap(result.publicationReceipt)
        XCTAssertTrue(receipt.graphKeys.isEmpty)
        XCTAssertTrue(receipt.coverageProofs.isEmpty)
        guard case let .provisionalCandidates(receiptCandidates) = receipt.publicationBasis else {
            return XCTFail("Expected provisional candidate publication basis.")
        }
        XCTAssertEqual(receiptCandidates, [candidate])
        let publicationDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(publicationDisposition, .current(result.targets))

        let duplicatePermit = WorkspaceCodemapAutomaticSelectionPublicationPermit()
        let duplicateReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: UUID(),
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: receipt.targets + receipt.targets,
            publicationBasis: .provisionalCandidates(receiptCandidates + receiptCandidates),
            publicationPermit: duplicatePermit
        )
        let duplicateResult = WorkspaceCodemapAutomaticSelectionResult(
            roots: result.roots,
            aggregateCoverage: result.aggregateCoverage,
            publicationReceipt: duplicateReceipt
        )
        XCTAssertNil(duplicateResult.publicationReceipt)

        let sourceCandidate = try automaticSelectionCandidate(
            file: source,
            root: loaded,
            ticket: sourceTicket
        )
        let targetReceipt = try XCTUnwrap(receipt.targets.first)
        let alternateLogicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Alternate",
            standardizedRelativePath: target.standardizedRelativePath
        ))
        let duplicateSlotTarget = WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: targetReceipt.rootEpoch,
            fileID: targetReceipt.fileID,
            catalogGeneration: targetReceipt.catalogGeneration,
            requestGeneration: targetReceipt.requestGeneration,
            logicalPath: alternateLogicalPath
        )
        let duplicateTargetSlotReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: UUID(),
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: [targetReceipt, duplicateSlotTarget],
            publicationBasis: .provisionalCandidates([candidate, sourceCandidate]),
            publicationPermit: WorkspaceCodemapAutomaticSelectionPublicationPermit()
        )
        let duplicateSlotDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
            duplicateTargetSlotReceipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(duplicateSlotDisposition, .stale(.publicationReceipt))
        await store.unloadRoot(id: loaded.id)
    }

    func testProvisionalAutomaticSelectionDropsStaleCandidateWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let rootEpoch = targetTicket.rootEpoch
        let candidate = try automaticSelectionCandidate(
            file: target,
            root: loaded,
            ticket: targetTicket
        )
        let incomplete = WorkspaceCodemapAutomaticSelectionIncompleteReason.graph(
            .definitionUniverse(
                rootEpoch: rootEpoch,
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        )
        let plan = WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan(
            candidates: [candidate],
            rootScopeEpochs: [rootEpoch],
            incompleteReasons: [incomplete]
        )

        try Self.write(
            "struct Target { let changed = true }\n",
            to: root.appendingPathComponent("Sources/Target.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Target.swift", nil)]
        )

        let result = await store.provisionalAutomaticCodemapSelectionResult(
            sources: [sourceIdentity],
            plan: plan,
            readyCandidates: [candidate],
            pendingReasons: [],
            partialReasons: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .provisional(incompleteReasons, pendingReasons, partialReasons) = result.aggregateCoverage else {
            return XCTFail("Expected provisional aggregate coverage.")
        }
        XCTAssertEqual(incompleteReasons, [incomplete])
        XCTAssertTrue(pendingReasons.isEmpty)
        XCTAssertEqual(partialReasons, [
            .candidateUnavailable(
                rootEpoch: rootEpoch,
                fileID: target.id,
                reason: .staleCurrentness
            )
        ])
        await store.unloadRoot(id: loaded.id)
    }

    func testSecondFlushRecoveryRetiresFlightAndCoalescesSignalsIntoOneSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let recoveryGate = CodemapSuspensionGate()
        addTeardownBlock {
            await recoveryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        for file in await warmStore.files(inRoot: warmRoot.id) {
            let ticket = try await pendingTicket(warmStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        await warmStore.unloadRoot(id: warmRoot.id)

        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let coldFiles = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let unrelated = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: setupTicket
        )

        await store.setCodemapProjectionRecoveryObserverWillWaitHandlerForTesting { epoch in
            guard epoch == rootEpoch else { return }
            await recoveryGate.enterAndWait()
        }
        let before = await store.codemapPresentationOperationCountsForTesting()
        let sourceContributionTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: sourceContributionTicket)
        )

        let recoveryEntered = await recoveryGate.waitUntilEntered()
        XCTAssertTrue(recoveryEntered)
        guard recoveryEntered else { return }
        let stalled = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(stalled.flightActive)
        XCTAssertTrue(stalled.observerActive)
        let stalledSerial = try XCTUnwrap(stalled.observerLatestSignalSerial)

        let newerContributionTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unrelated.id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: newerContributionTicket)
        )
        let revokedNewerContribution = await store
            .revokeReadyCodemapArtifactContributionForTesting(newerContributionTicket)
        XCTAssertTrue(revokedNewerContribution)
        let coalesced = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(coalesced.flightActive)
        XCTAssertTrue(coalesced.observerActive)
        XCTAssertGreaterThan(try XCTUnwrap(coalesced.observerLatestSignalSerial), stalledSerial)
        let whileStalled = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            whileStalled.projectionRecoveryObserversStarted,
            before.projectionRecoveryObserversStarted + 1
        )

        await recoveryGate.release()
        let publicationClock = ContinuousClock()
        let publicationDeadline = publicationClock.now.advanced(by: .seconds(5))
        let publicationCurrent = await store.waitForCodemapGraphPublication(
            rootEpoch: rootEpoch,
            deadline: publicationDeadline
        )
        guard publicationCurrent else {
            return XCTFail("Timed out waiting for the bounded recovery publication.")
        }
        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        let finished = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(finished.flightActive)
        XCTAssertFalse(finished.observerActive)
        let after = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            after.projectionRecoveryObserversStarted,
            before.projectionRecoveryObserversStarted + 1,
            "the bounded successor must reuse the single recovery observer"
        )
        XCTAssertGreaterThanOrEqual(
            after.projectionRecoveryObserverRearms,
            before.projectionRecoveryObserverRearms + 1,
            "the real newer overlay contribution must re-arm the same observer after equivalence fails"
        )
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        _ = await store.cancelCodemapArtifactDemand(sourceContributionTicket)
        _ = await store.cancelCodemapArtifactDemand(newerContributionTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testHeldProjectionRecoveryBoundsLastHolderReleasesAndAutomaticPresentation() async throws {
        let recoveryGate = CodemapSuspensionGate()
        let sealed = try await makeSealedRecoveryRoot(name: #function, recoveryGate: recoveryGate)
        let store = sealed.store

        await store.setCodemapProjectionRecoveryObserverWillWaitHandlerForTesting { epoch in
            guard epoch == sealed.rootEpoch else { return }
            await recoveryGate.enterAndWait()
        }
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: sealed.source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let recoveryEntered = await recoveryGate.waitUntilEntered()
        XCTAssertTrue(recoveryEntered)
        guard recoveryEntered else { return }
        let held = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: sealed.rootEpoch
        )
        XCTAssertTrue(held.observerActive)

        // Last-holder release of a ready demand while the projection rerun is held.
        let readyReleased = await completes(within: Self.heldRecoveryReleaseBound) {
            _ = await store.cancelCodemapArtifactDemand(sourceTicket)
        }
        XCTAssertTrue(readyReleased, "A ready last-holder release must not wait for the held recovery observer")

        // Last-holder release of a still-pending demand while the projection rerun is held.
        let unrelatedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: sealed.unrelated.id)
        )
        let pendingReleased = await completes(within: Self.heldRecoveryReleaseBound) {
            _ = await store.cancelCodemapArtifactDemand(unrelatedTicket)
        }
        XCTAssertTrue(pendingReleased, "A pending last-holder release must not wait for the held recovery observer")

        // An optional automatic enrichment call keeps its short bound while recovery is held.
        let presentationBox = CodemapPresentationBox()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: .optionalAutomaticEnrichment
        )
        let automaticReturned = await completes(within: Self.heldRecoveryAutomaticBound) {
            let presentation = try? await coordinator.withPresentation(
                for: .automatic(sourceFileIDs: [sealed.source.id]),
                rootScope: .visibleWorkspace
            ) { $0 }
            presentationBox.set(presentation)
        }
        XCTAssertTrue(automaticReturned, "Optional automatic enrichment must return within its bound while recovery is held")
        if automaticReturned, let presentation = presentationBox.value {
            if presentation.orderedEntries.isEmpty {
                XCTAssertNil(presentation.publicationReceipt)
            } else {
                XCTAssertNotNil(presentation.publicationReceipt)
            }
        }

        recoveryGate.release()
        let drained = await waitForCodemapGraphPublicationDrain(store: store, rootEpoch: sealed.rootEpoch)
        XCTAssertTrue(drained)
        let converged = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [sealed.source.id],
                rootScope: .visibleWorkspace
            )
        XCTAssertEqual(converged.targets.map(\.fileID), [sealed.target.id])
        if let lease = converged.publicationReceipt?.publicationLease {
            await lease.release()
        }

        _ = await store.cancelCodemapArtifactDemand(sealed.targetTicket)
        await store.evictIdleReadyCodemapDemandsForTesting(rootEpoch: sealed.rootEpoch)
        for file in [sealed.source, sealed.target, sealed.unrelated] {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(
                rootEpoch: sealed.rootEpoch,
                fileID: file.id
            )
            XCTAssertEqual(retainCount, 0, file.standardizedRelativePath)
        }
        await store.unloadRoot(id: sealed.rootID)
    }

    func testPendingDemandCancelPlansOnlyAgainstPublishedCoverageUntilItCatchesUp() async throws {
        let publicationGate = CodemapArmableSuspensionGate()
        let pendingHold = CodemapSuspensionGate()
        let heldFileID = CodemapLockedFileID()
        let sealed = try await makeSealedRecoveryRoot(
            name: #function,
            recoveryGate: CodemapSuspensionGate(),
            graphPublicationWaiter: { _ in
                await publicationGate.enterIfArmedAndWait()
            },
            demandResultHook: { ticket, result in
                if ticket.fileID == heldFileID.value {
                    await pendingHold.enterAndWait()
                }
                return result
            }
        )
        addTeardownBlock {
            pendingHold.release()
            publicationGate.release()
        }
        let store = sealed.store

        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: sealed.source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let converged = await waitForReadyAutomaticPlan(
            store: store,
            sourceFileID: sealed.source.id,
            timeout: .seconds(10)
        )
        XCTAssertEqual(
            converged?.candidates.map(\.identity.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        guard converged != nil else { return }
        let convergedGeneration = await store.codemapOverlayContributionGenerationForTesting(
            rootEpoch: sealed.rootEpoch
        )

        // Hold graph publication, then cancel a demand whose store record is still pending.
        publicationGate.arm()
        heldFileID.set(sealed.unrelated.id)
        let unrelatedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: sealed.unrelated.id)
        )
        let pendingEntered = await pendingHold.waitUntilEntered()
        XCTAssertTrue(pendingEntered)
        let cancelClock = ContinuousClock()
        let cancelled = await store.cancelCodemapArtifactDemand(
            unrelatedTicket,
            deadline: cancelClock.now.advanced(by: .milliseconds(250))
        )
        XCTAssertTrue(cancelled)
        let cancelledStatus = await store.codemapArtifactDemandStatus(unrelatedTicket)
        guard case .unavailable = cancelledStatus else {
            return XCTFail("A cancelled pending ticket must not stay current: \(cancelledStatus)")
        }
        let heldGeneration = await store.codemapOverlayContributionGenerationForTesting(
            rootEpoch: sealed.rootEpoch
        )
        XCTAssertNotEqual(heldGeneration, convergedGeneration, "The pending demand must have changed the overlay")

        // While the newer overlay is unpublished, a plan may only stand on the still-published
        // coverage: either non-ready, or ready on exactly the converged proofs. The brief's
        // stricter property (the plan is never ready while the overlay is unpublished) is
        // deliberately not asserted: the cancelled pending file never entered the published
        // graph, so the older published coverage stays self-consistent and may answer ready.
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [sealed.source.id],
            rootScope: .visibleWorkspace
        )
        let heldPlan = await store.planAutomaticCodemapSelectionCandidates(
            sources: identities,
            rootScope: .visibleWorkspace
        )
        if case let .ready(plan) = heldPlan {
            XCTAssertEqual(plan.coverageProofs, converged?.coverageProofs)
        }

        pendingHold.release()
        publicationGate.release()
        let heldContribution = try XCTUnwrap(heldGeneration)
        let caughtUp = await waitForReadyAutomaticPlan(
            store: store,
            sourceFileID: sealed.source.id,
            timeout: .seconds(10)
        ) { plan in
            plan.coverageProofs.allSatisfy {
                $0.generation.contributionGeneration >= heldContribution
            }
        }
        XCTAssertEqual(
            caughtUp?.candidates.map(\.identity.standardizedRelativePath),
            ["Sources/Target.swift"],
            "The plan must become ready again on coverage that caught up with the cancel"
        )
        if let caughtUp {
            XCTAssertNotEqual(caughtUp.coverageProofs, converged?.coverageProofs)
        }

        _ = await store.cancelCodemapArtifactDemand(sourceTicket)
        _ = await store.cancelCodemapArtifactDemand(sealed.targetTicket)
        await store.unloadRoot(id: sealed.rootID)
    }

    private static let heldRecoveryReleaseBound: Duration = .milliseconds(500)
    private static let heldRecoveryAutomaticBound: Duration = .milliseconds(
        workspaceCodemapOptionalEnrichmentWaitMilliseconds + 750
    )

    private struct SealedRecoveryRoot {
        let store: WorkspaceFileContextStore
        let rootID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let source: WorkspaceFileRecord
        let target: WorkspaceFileRecord
        let unrelated: WorkspaceFileRecord
        let targetTicket: WorkspaceCodemapArtifactDemandTicket
    }

    /// Warm CAS, completed projection, ready Target, and a generation-matched sealed graph.
    private func makeSealedRecoveryRoot(
        name: String,
        recoveryGate: CodemapSuspensionGate,
        graphPublicationWaiter: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in },
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result }
    ) async throws -> SealedRecoveryRoot {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: name)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
        )
        let fixture = try CodemapStoreFixture(name: name, syntheticGraphArtifacts: true)
        addTeardownBlock {
            recoveryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        for file in await warmStore.files(inRoot: warmRoot.id) {
            let ticket = try await pendingTicket(warmStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        await warmStore.unloadRoot(id: warmRoot.id)

        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: graphPublicationWaiter,
            demandResultHook: demandResultHook
        )
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: targetTicket
        )
        return SealedRecoveryRoot(
            store: store,
            rootID: loaded.id,
            rootEpoch: rootEpoch,
            source: source,
            target: target,
            unrelated: unrelated,
            targetTicket: targetTicket
        )
    }

    /// Runs `operation` unstructured and reports whether it finished within `bound`; a late
    /// operation keeps running and drains once the test releases its gates.
    private func completes(
        within bound: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: bound)
        let completion = CodemapBoundedCompletionState()
        Task {
            await operation()
            completion.recordCompletion(beforeDeadline: clock.now < deadline)
        }
        return await waitForCompletionBeforeExternalDeadline(
            completion,
            clock: clock,
            deadline: deadline
        )
    }

    private func waitForReadyAutomaticPlan(
        store: WorkspaceFileContextStore,
        sourceFileID: UUID,
        timeout: Duration,
        accepting isAccepted: (WorkspaceCodemapAutomaticSelectionCandidatePlan) -> Bool = { _ in true }
    ) async -> WorkspaceCodemapAutomaticSelectionCandidatePlan? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: [sourceFileID],
                rootScope: .visibleWorkspace
            )
            let disposition = await store.planAutomaticCodemapSelectionCandidates(
                sources: identities,
                rootScope: .visibleWorkspace
            )
            if case let .ready(plan) = disposition, isAccepted(plan) { return plan }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    func testAutomaticPresentationWatcherInvalidationDuringReconstructionNeverPublishesTargetsWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )

        let reconstructionCount = CodemapLockedCounter()
        let publicationRevalidationCount = CodemapLockedCounter()
        let operationCount = CodemapLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .seconds(2)
            ),
            beforePublicationRevalidation: { _ in
                publicationRevalidationCount.increment()
            },
            afterAutomaticCandidateReconstruction: { _ in
                reconstructionCount.increment()
                try Self.write(
                    "struct Target { let generation = \(reconstructionCount.value) }\n",
                    to: root.appendingPathComponent("Sources/Target.swift")
                )
                await store.replayObservedFileSystemDeltas(
                    rootID: loaded.id,
                    deltas: [.fileModified("Sources/Target.swift", nil)]
                )
            }
        )

        let presentation = try await coordinator.withPresentation(
            for: .automatic(sourceFileIDs: [source.id]),
            rootScope: .visibleWorkspace
        ) { presentation in
            operationCount.increment()
            XCTAssertTrue(presentation.orderedEntries.isEmpty)
            XCTAssertNil(presentation.publicationReceipt)
            return presentation
        }

        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        XCTAssertNil(presentation.publicationReceipt)
        XCTAssertEqual(operationCount.value, 1)
        XCTAssertEqual(publicationRevalidationCount.value, 0)
        XCTAssertTrue((1 ... 2).contains(reconstructionCount.value))
        switch presentation.coverage {
        case .pending, .unavailable:
            break
        case .complete, .partial:
            XCTFail("Watcher-stale automatic targets must return typed retry coverage")
        }
        XCTAssertTrue(presentation.issues.contains { issue in
            switch issue {
            case .automatic(.incomplete(_)), .automatic(.pending(_)), .automatic(.stale(_)),
                 .publicationStale(.automatic(_)):
                true
            case .coordinationUnavailable, .cancelled, .candidate, .pending, .unavailable,
                 .automatic, .freezeUnavailable, .renderUnavailable, .publicationStale:
                false
            }
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionWithIncompleteDefinitionUniversePublishesNoTargets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { _, _ in
                .definitionUniverse(.incomplete(
                    progress: .notStarted,
                    remainingCount: nil,
                    retry: nil
                ))
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })

        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceIdentity.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        let providerCount = fixture.providerAccessCount.value
        let buildCount = fixture.buildCount.value
        let manifestReadCount = fixture.manifestReadCount.value

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 1)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .incomplete(reasons) = result.roots.first?.coverage,
              case let .graph(.definitionUniverse(rootEpoch, _, _, _)) = reasons.first
        else { return XCTFail("Expected typed incomplete definition-universe coverage") }
        XCTAssertEqual(rootEpoch, sourceIdentity.rootEpoch)
        XCTAssertNotEqual(target.id, source.id)
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(fixture.buildCount.value, buildCount)
        XCTAssertEqual(fixture.manifestReadCount.value, manifestReadCount)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDoesNotResolveForeignOnlyDefinition() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func value() -> ForeignDefinition
                }
                """
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/ForeignDefinition.swift": SwiftFixtureSource.emptyStruct("ForeignDefinition")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [firstFile, secondFile] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let firstReady = try XCTUnwrap(readyByFileID[firstFile.id])
        let secondReady = try XCTUnwrap(readyByFileID[secondFile.id])
        let firstGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: firstReady.ticket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(firstGraphPublished)
        let secondGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: secondReady.ticket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(secondGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: firstReady.ticket,
            contributionsByFileID: [
                firstFile.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["ForeignDefinition"]
                )
            ]
        )
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: secondReady.ticket,
            contributionsByFileID: [
                secondFile.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["ForeignDefinition"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.targets.contains { $0.fileID == secondFile.id })
        XCTAssertEqual(result.roots.first?.rootEpoch.rootID, firstLoaded.id)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionQueriesTwoRootsIndependentlyAndMergesAtResponseBoundary() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol FirstSource {
                    func value() -> FirstTarget
                }
                """,
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("FirstTarget")
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": """
                protocol SecondSource {
                    func value() -> SecondTarget
                }
                """,
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        var targetIDs = Set<UUID>()
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
            let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
            sourceIDs.append(source.id)
            targetIDs.insert(target.id)
            let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
            let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
            let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
            let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceTicket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceTicket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [root == firstRoot ? "FirstSource" : "SecondSource"],
                        references: [root == firstRoot ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [root == firstRoot ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: Array(sourceIDs.reversed()),
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(Set(result.targets.map(\.fileID)), targetIDs)
        XCTAssertEqual(Set(result.roots.map(\.rootEpoch.rootID)), Set(loadedRoots.map(\.id)))
        for rootResult in result.roots {
            XCTAssertTrue(rootResult.targets.allSatisfy { $0.rootEpoch == rootResult.rootEpoch })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)
        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionReportsMissingPendingUnavailableAndStaleSourcesWithoutNewWork() async throws {
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Pending.swift": SwiftFixtureSource.emptyStruct("Pending")]
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let pending = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let missing = try WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000")),
            catalogGeneration: identity.catalogGeneration
        )
        let stale = WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: file.id,
            catalogGeneration: identity.catalogGeneration &+ 1
        )
        let providerCount = fixture.providerAccessCount.value

        let expectedIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue] = [
            .notCataloged(missing),
            .pending(identity, pending),
            .staleCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        ]
        let firstResult = try await store.resolveAutomaticCodemapSelection(
            sources: [identity, missing, stale],
            rootScope: .visibleWorkspace
        )
        let secondResult = try await store.resolveAutomaticCodemapSelection(
            sources: [stale, identity, missing],
            rootScope: .visibleWorkspace
        )

        let expectedCoverage = WorkspaceCodemapAutomaticSelectionCoverage.stale(
            .sourceCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        )
        XCTAssertEqual(firstResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(secondResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(firstResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(secondResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: store, ticket: pending)

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Unavailable.swift": SwiftFixtureSource.emptyStruct("Unavailable")
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainIdentities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [plainFile.id],
            rootScope: .visibleWorkspace
        )
        let plainIdentity = try XCTUnwrap(plainIdentities.first)
        let plainTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: plainFile.id))
        let unavailable = try await settledResult(store: store, ticket: plainTicket)
        guard case let .unavailable(unavailableReason) = unavailable else {
            return XCTFail("Expected non-Git demand to become unavailable.")
        }
        let unavailableResult = try await store.resolveAutomaticCodemapSelection(
            sources: [plainIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(
            unavailableResult.roots.first?.sourceIssues,
            [.unavailable(plainIdentity, unavailableReason)]
        )
        await store.unloadRoot(id: loaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testAutomaticSelectionRejectsSourceOutsideRequestedRootScopeBeforeGraphQuery() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/First.swift": SwiftFixtureSource.emptyStruct("First")]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let secondOnlyScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [secondRoot.path],
            physicalRootPaths: []
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: secondOnlyScope
        )

        XCTAssertEqual(result.targets, [])
        XCTAssertEqual(result.roots.first?.sourceIssues, [.outsideRootScope(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionRootReloadDropsOldTargets() async throws {
        let graphProbe = CodemapSelectionGraphProbe()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let targetReady = try XCTUnwrap(readyByFileID[target.id])
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceReady.ticket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let beforeReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertFalse(beforeReload.targets.isEmpty)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let afterReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(afterReload.targets.isEmpty)
        XCTAssertEqual(afterReload.roots.first?.coverage, .stale(.rootEpochNotCurrent(identity.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testAutomaticSelectionGraphProofRevocationAfterQueryFailsClosedWithoutTargets() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { _ in
                await queryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, target] {
            readyByFileID[file.id] = try await readyArtifactDemand(store: store, forFileID: file.id).ready
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let targetReady = try XCTUnwrap(readyByFileID[target.id])
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceReady.ticket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let current = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(current.targets.map(\.fileID), [target.id])
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let targetCancelled = await store.cancelCodemapArtifactDemand(targetReady.ticket)
        XCTAssertTrue(targetCancelled)
        // A last-holder release keeps the ready target warm; evicting it is the revocation.
        let targetEvicted = await store.evictIdleReadyCodemapDemandsForTesting(rootEpoch: targetReady.ticket.rootEpoch)
        XCTAssertEqual(targetEvicted, 1)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        let rootResult = try XCTUnwrap(result.roots.first)
        // Eviction revokes the target without tearing down the published graph, so the query
        // either sees the revoked target as a stale generation or the advanced graph as invalid.
        // Both fail closed: no targets and no publication receipt.
        let staleTarget = WorkspaceCodemapAutomaticSelectionTargetIssue.staleGeneration(
            rootEpoch: identity.rootEpoch,
            fileID: target.id,
            requestGeneration: targetReady.ticket.requestGeneration
        )
        switch rootResult.coverage {
        case .stale(.targetStateChanged(staleTarget)):
            XCTAssertEqual(rootResult.targetIssues, [staleTarget])
        case .unavailable(.graph(.invalidGraphResult(identity.rootEpoch))):
            XCTAssertTrue(rootResult.targetIssues.isEmpty)
        default:
            XCTFail("Expected fail-closed coverage, got \(rootResult.coverage)")
        }
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDropsResultWhenSourceChangesAfterGraphQuery() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(automaticSelectionQueryHook: { _ in
            await queryGate.enterIfArmedAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        var sourceTicket: WorkspaceCodemapArtifactDemandTicket?
        for file in files {
            let demand = try await readyArtifactDemand(store: store, forFileID: file.id)
            if file.id == source.id { sourceTicket = demand.ticket }
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let ticket = try XCTUnwrap(sourceTicket)
        let cancelled = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(cancelled)
        // A last-holder release keeps the ready source warm; evicting it is the source change.
        let sourceEvicted = await store.evictIdleReadyCodemapDemandsForTesting(rootEpoch: ticket.rootEpoch)
        XCTAssertGreaterThanOrEqual(sourceEvicted, 1)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(
            result.roots.first?.coverage,
            .stale(.graph(.currentness(identity.rootEpoch)))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesWhenPendingSourceBecomesReadyDuringGraphAwait() async throws {
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { let missing: Missing }\n",
                "Sources/Pending.swift": SwiftFixtureSource.emptyStruct("Pending")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await pendingPublicationGate.release()
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await pendingPublicationGate.enterIfArmedAndWait()
            },
            automaticSelectionQueryHook: { _ in
                await queryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let readyFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Ready.swift"
        })
        let pendingFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })
        let readyTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: readyFile.id
        ))
        _ = try await readyResult(settledResult(store: store, ticket: readyTicket))
        let graphPublished = await graphProbe.waitUntilPublished(rootEpoch: readyTicket.rootEpoch)
        XCTAssertTrue(graphPublished)

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: pendingFile.id
        ))
        let publicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [readyFile.id, pendingFile.id],
            rootScope: .visibleWorkspace
        )
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)

        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))
        await queryGate.release()
        let result = try await task.value

        XCTAssertFalse(result.roots.flatMap(\.sourceIssues).contains {
            if case .pending = $0 { return true }
            return false
        })
        XCTAssertFalse(result.roots.contains {
            if case .stale(.sourceStateChanged(_)) = $0.coverage { return true }
            return false
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionResnapshotsScopeChangeBetweenRootPartitions() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": "struct FirstSource { let target: FirstTarget }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("FirstTarget")
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": "struct SecondSource { let target: SecondTarget }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryGate = CodemapRootSuspensionGate()
        let queriedRootEpochs = CodemapLockedValues<WorkspaceCodemapRootEpoch>()
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { rootEpoch in
                queriedRootEpochs.append(rootEpoch)
                await queryGate.enterAndWait(rootEpoch)
            }
        )
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        var targetIDs = Set<UUID>()
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Source.swift"
            })
            let target = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Target.swift"
            })
            sourceIDs.append(source.id)
            targetIDs.insert(target.id)
            var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
            for file in [source, target] {
                let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
                readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
            }
            let sourceReady = try XCTUnwrap(readyByFileID[source.id])
            let targetReady = try XCTUnwrap(readyByFileID[target.id])
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceReady.ticket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            let isFirstRoot = root == firstRoot
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceReady.ticket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [isFirstRoot ? "FirstSource" : "SecondSource"],
                        references: [isFirstRoot ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [isFirstRoot ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceIDs,
            rootScope: .visibleWorkspace
        )
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let entered = await queryGate.waitUntilEntered()
        let enteredRootEpoch = try XCTUnwrap(entered)
        let removedRoot = try XCTUnwrap(loadedRoots.first {
            $0.id != enteredRootEpoch.rootID
        })
        await store.unloadRoot(id: removedRoot.id)
        await queryGate.release()
        let result = try await task.value

        XCTAssertEqual(queriedRootEpochs.values, [enteredRootEpoch, enteredRootEpoch])
        XCTAssertEqual(targetIDs.count, 2)
        XCTAssertEqual(result.roots.count, 1)
        let removedResult = try XCTUnwrap(result.roots.first {
            $0.rootEpoch.rootID == removedRoot.id
        })
        XCTAssertEqual(
            removedResult.coverage,
            .stale(.rootEpochNotCurrent(removedResult.rootEpoch))
        )
        XCTAssertTrue(removedResult.targets.isEmpty)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.targets.allSatisfy { !targetIDs.contains($0.fileID) })
        XCTAssertNil(result.publicationReceipt)
        for loaded in loadedRoots where loaded.id != removedRoot.id {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionLaterRootBudgetDiscardsEarlierTargetsAndReceipt() async throws {
        let graphProbe = CodemapSelectionGraphProbe()
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": "protocol FirstSource { var target: FirstTarget { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("FirstTarget")
            ]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": "protocol SecondSource { var target: SecondTarget { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await store.loadRoot(path: rootURL.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Source.swift"
            })
            let target = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Target.swift"
            })
            sourceIDs.append(source.id)
            let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
            let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
            let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
            let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceTicket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceTicket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [rootURL == firstRootURL ? "FirstSource" : "SecondSource"],
                        references: [rootURL == firstRootURL ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [rootURL == firstRootURL ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceIDs,
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .budget(reason) = result.aggregateCoverage else {
            return XCTFail("Expected aggregate target budget")
        }
        XCTAssertEqual(reason, .targetLimit(attempted: 2, limit: 1))
        for root in loadedRoots {
            await store.unloadRoot(id: root.id)
        }
    }

    func testAutomaticSelectionReturnsTypedTargetLimitBudgetCoverage() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("FirstTarget"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let budgetGraphProbe = CodemapSelectionGraphProbe()
        let budgetStore = fixture.makeStore(
            selectionGraphFactory: budgetGraphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        let loaded = try await budgetStore.loadRoot(path: root.path)
        let files = await budgetStore.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, first, second] {
            let ticket = try await pendingTicket(budgetStore.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: budgetStore, ticket: ticket))
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let firstReady = try XCTUnwrap(readyByFileID[first.id])
        let secondReady = try XCTUnwrap(readyByFileID[second.id])
        let identities = await budgetStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let budgetGraphPublished = await budgetGraphProbe.waitUntilPublished(
            rootEpoch: identity.rootEpoch,
            minimumNodeCount: files.count
        )
        XCTAssertTrue(budgetGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: budgetGraphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["FirstTarget", "SecondTarget"]
                ),
                first.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["FirstTarget"],
                    references: []
                ),
                second.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["SecondTarget"],
                    references: []
                )
            ]
        )
        let budgetResult = try await budgetStore.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(budgetResult.roots.isEmpty)
        XCTAssertTrue(budgetResult.targets.isEmpty)
        XCTAssertNil(budgetResult.publicationReceipt)
        XCTAssertEqual(
            budgetResult.aggregateCoverage,
            .budget(.targetLimit(attempted: 2, limit: 1))
        )
        await budgetStore.unloadRoot(id: loaded.id)
    }
}

private final class CodemapLockedFileID: @unchecked Sendable {
    private let lock = NSLock()
    private var fileID: UUID?

    var value: UUID? {
        lock.withLock { fileID }
    }

    func set(_ fileID: UUID) {
        lock.withLock { self.fileID = fileID }
    }
}

private final class CodemapPresentationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var presentation: WorkspaceCodemapOperationPresentation?

    var value: WorkspaceCodemapOperationPresentation? {
        lock.withLock { presentation }
    }

    func set(_ presentation: WorkspaceCodemapOperationPresentation?) {
        lock.withLock { self.presentation = presentation }
    }
}
