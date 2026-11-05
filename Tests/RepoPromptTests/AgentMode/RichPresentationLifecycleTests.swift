import Foundation
import ImageIO
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import UniformTypeIdentifiers
import XCTest

/// Real temporary filesystem and production DataService gates. No network, live app or ledger
/// mutation. Explicit barriers (never sleeps) place deletion, root movement and cancellation at
/// the owning transaction's phase.
@MainActor
final class RichPresentationLifecycleTests: XCTestCase {
    struct Fixture {
        let directory: URL
        let root: URL
        let workspace: WorkspaceModel
        let service: AgentSessionDataService
        let source: AgentSessionEditableLoad

        var tombstoneRoot: URL {
            directory.appendingPathComponent("tombstones")
        }
    }

    struct Failure: Error {}

    @MainActor final class Box<Value> {
        var value: Value
        init(_ value: Value) {
            self.value = value
        }
    }

    private func fixture(sourceID: UUID = UUID(), transcript: AgentTranscript? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RichLifecycle-" + UUID().uuidString)
        let root = directory.appendingPathComponent("workspace")
        let workspace = WorkspaceModel(name: "Rich", repoPaths: [], customStoragePath: root)
        let service = AgentSessionDataService(tombstoneRoot: directory.appendingPathComponent("tombstones"))
        let session = AgentSession(
            id: sourceID, workspaceID: workspace.id, composeTabID: UUID(), name: "Worker",
            transcript: transcript ?? AgentTranscriptIO.handoffTranscript(fromLegacyItems: [
                .user("Question", sequenceIndex: 0), .assistant("Answer", sequenceIndex: 1)
            ])
        )
        let source = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session, for: workspace, preparation: .alreadyCanonicalTranscript
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Fixture(directory: directory, root: root, workspace: workspace, service: service, source: source)
    }

    private func provenance(_ sessionID: UUID) -> AgentRichArtifactProvenance {
        .init(runID: UUID(), attemptID: UUID(), sessionID: sessionID, toolInvocationID: UUID())
    }

    private func chart(_ fixture: Fixture, id: UUID = UUID()) throws -> (AgentRichArtifactManifest, RichPresentationReference) {
        try chart(sessionID: fixture.source.session.id, id: id)
    }

    private func chart(sessionID: UUID, id: UUID = UUID()) throws -> (AgentRichArtifactManifest, RichPresentationReference) {
        let input = RichPresentationInput(title: "Local data", content: .chart(RichPresentationChart(
            chartType: .bar, xLabel: "Item", unit: "count", x: ["A"], series: [.init(name: "Measured", y: [2])],
            sources: [.init(label: "Local fixture")]
        )))
        let manifest = try AgentRichArtifactManifest(artifactID: id, input: input, outcomes: [], provenance: provenance(sessionID))
        return (manifest, RichPresentationReference(artifactID: id, kind: .chart, title: input.title, fallbackText: "Rich presentation summary: Local data"))
    }

    /// A briefing whose single article image is a real normalized local JPEG asset.
    private func briefing(sessionID: UUID) throws -> (AgentRichArtifactManifest, RichPresentationReference, UUID, Data) {
        let id = UUID()
        let assetID = UUID()
        let bytes = try jpeg(width: 4, height: 3)
        let input = RichPresentationInput(title: "Brief", content: .briefing(.init(
            date: "2026-11-05", sections: [.init(heading: "News", articles: [.init(
                headline: "Headline", body: "Accepted text", sources: [.init(label: "Local")],
                image: .init(url: "https://images.example.com/a.jpg?signature=SECRET", alt: "Photo", credit: "Wire")
            )])]
        )))
        let manifest = try AgentRichArtifactManifest(
            artifactID: id, input: input,
            outcomes: [.init(sectionIndex: 0, articleIndex: 0, outcome: .asset(.init(
                assetID: assetID, width: 4, height: 3, alt: "Photo", credit: "Wire", origin: "https://images.example.com"
            )))],
            provenance: provenance(sessionID)
        )
        let reference = RichPresentationReference(artifactID: id, kind: .briefing, title: "Brief", fallbackText: "Rich presentation summary: Brief")
        return (manifest, reference, assetID, bytes)
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func publish(_ fixture: Fixture, manifest: AgentRichArtifactManifest, assets: [UUID: Data] = [:]) async throws {
        try await fixture.service.publishRichArtifact(
            state: fixture.source.persistenceState, root: fixture.root, manifest: manifest, assets: assets, commitCheck: {}
        )
    }

    private func destination(_ fixture: Fixture) -> AgentSession {
        AgentSession(workspaceID: fixture.workspace.id, composeTabID: UUID(), name: "Private fork", transcript: fixture.source.session.transcript)
    }

    private func handoff(
        _ f: Fixture, _ dest: AgentSession, _ references: [RichPresentationReference],
        persistPrivateRecords: @escaping @MainActor () async throws -> Void = {},
        discardPrivateRecords: @escaping @MainActor () async -> Void = {},
        commitCheck: @escaping @MainActor () throws -> Void = {},
        expose: @escaping @MainActor (AgentSessionEditableLoad) throws -> Void = { _ in }
    ) async throws {
        try await f.service.commitPrivateHandoff(
            sourceState: f.source.persistenceState, initialSession: dest, workspace: f.workspace, root: f.root,
            references: references, persistPrivateRecords: persistPrivateRecords,
            discardPrivateRecords: discardPrivateRecords, commitCheck: commitCheck, expose: expose
        )
    }

    // MARK: - Store and publication

    func testBytesPrecedeReferenceAndWorkerReloadUsesItsOwnSession() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let loaded = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(loaded, manifest)
        var session = f.source.session
        let activityID = try XCTUnwrap(session.transcript?.turns.first?.allActivities.first?.id)
        session.transcript?.turns[0].richPresentations = [
            .init(reference: reference, activityID: activityID, activityOrder: 1)
        ]
        _ = try await f.service.saveAgentSession(session, for: f.workspace, persistenceState: f.source.persistenceState)
        let restarted = AgentSessionDataService(tombstoneRoot: f.tombstoneRoot)
        let reloaded = try await restarted.loadAgentSessionForEditing(id: session.id, for: f.workspace)
        let reload = try XCTUnwrap(reloaded)
        XCTAssertEqual(reload.session.transcript?.turns.first?.richPresentations.first?.reference, reference)
        let read = try await restarted.readRichArtifact(state: reload.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read.provenance.sessionID, session.id)
    }

    func testExclusiveInstallFailurePreservesExistingBundleAndRemovesStage() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        do { try await publish(f, manifest: manifest)
            XCTFail("Immutable artifact cannot be replaced")
        } catch {}
        let read = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read, manifest)
        let entries = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory(f, f.source.session.id).path)
        XCTAssertEqual(entries, [reference.artifactID.uuidString])
    }

    func testCancellationAfterStageCleansBeforeReturningAndReleasesFence() async throws {
        let f = try await fixture()
        let (manifest, _) = try chart(f)
        let barrier = RichLifecycleBarrier()
        await f.service.test_setRichArtifactPhase { phase, _ in
            if phase == "afterStage" { await barrier.arriveAndWait() }
        }
        let operation = Task { try await self.publish(f, manifest: manifest) }
        await barrier.waitForArrival()
        operation.cancel()
        await barrier.release()
        do { try await operation.value
            XCTFail("Cancellation before install must fail")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessionDirectory(f, f.source.session.id).path), [])
        await f.service.test_setRichArtifactPhase(nil)
        try await publish(f, manifest: manifest)
    }

    func testCancellationInsideFinalCommitSectionDoesNotFailOrRollBackInstalledArtifact() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        let operation = Box<Task<Void, Error>?>(nil)
        // The final main-actor check cancels its own caller; the rename in the same section still
        // commits, and a committed artifact never reports a post-commit cancellation.
        operation.value = Task {
            try await f.service.publishRichArtifact(
                state: f.source.persistenceState, root: f.root, manifest: manifest, assets: [:],
                commitCheck: { operation.value?.cancel() }
            )
        }
        try await XCTUnwrap(operation.value).value
        let read = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read, manifest)
    }

    func testDeletionFirstRefusesLatePublicationAndCopiesWithoutRecreatingTree() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        try await f.service.deleteAgentSession(id: f.source.session.id, for: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, f.source.session.id).path))
        do { try await publish(f, manifest: manifest)
            XCTFail("Tombstone must refuse late work")
        } catch {}
        let dest = destination(f)
        do {
            try await handoff(f, dest, [reference], expose: { _ in XCTFail("Never expose") })
            XCTFail("Deleted source cannot be copied")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, f.source.session.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
    }

    func testCopyFirstHoldsSourceDeletionUntilIndependentDestinationIsSaved() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let dest = destination(f)
        let barrier = RichLifecycleBarrier()
        let committed = Box<AgentSessionEditableLoad?>(nil)
        let copy = Task {
            try await self.handoff(
                f, dest, [reference, reference], persistPrivateRecords: { await barrier.arriveAndWait() },
                expose: { committed.value = $0 }
            )
        }
        await barrier.waitForArrival()
        let deletion = Task { try await f.service.deleteAgentSession(id: f.source.session.id, for: f.workspace) }
        var waiter = false
        for _ in 0 ..< 1000 {
            if await f.service.test_richSessionWaiterCount(f.source.session.id) > 0 { waiter = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(waiter, "Deletion must wait behind the both-session copy gates")
        await barrier.release()
        try await copy.value
        try await deletion.value
        let saved = try XCTUnwrap(committed.value)
        let read = try await f.service.readRichArtifact(state: saved.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read, manifest, "Original provenance is retained, not access authority")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, f.source.session.id).path))
    }

    func testLaterMissingArtifactAbortsAndCleansEarlierCopiesWithNoExposure() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        let (_, missing) = try chart(f)
        try await publish(f, manifest: manifest)
        let sourceBytes = try Data(contentsOf: sessionFile(f, f.source.session.id))
        let dest = destination(f)
        let exposed = Box(false)
        let discarded = Box(false)
        do {
            try await handoff(
                f, dest, [reference, missing], discardPrivateRecords: { discarded.value = true },
                expose: { _ in exposed.value = true }
            )
            XCTFail("Missing required artifact must abort, not substitute a fallback")
        } catch {
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.missingArtifact(missing.artifactID).localizedDescription)
        }
        XCTAssertFalse(exposed.value)
        XCTAssertTrue(discarded.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, dest.id).path))
        XCTAssertEqual(try Data(contentsOf: sessionFile(f, f.source.session.id)), sourceBytes)
    }

    func testSessionWriteFailureAbortsCopiedDestination() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let dest = destination(f)
        await f.service.test_setSessionWriteFailureInjector { _ in Failure() }
        do {
            try await handoff(f, dest, [reference], expose: { _ in XCTFail("Never expose") })
            XCTFail("Write must fail")
        } catch {}
        await f.service.test_setSessionWriteFailureInjector(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, dest.id).path))
        _ = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
    }

    func testFailureAfterInitialSaveRollsBackThroughTombstoneDeletionAndKeepsSource() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let sourceBytes = try Data(contentsOf: sessionFile(f, f.source.session.id))
        let dest = destination(f)
        let discarded = Box(false)
        await f.service.test_setRichArtifactPhase { phase, _ in
            if phase == "afterSave" { throw Failure() }
        }
        do {
            try await handoff(
                f, dest, [reference], discardPrivateRecords: { discarded.value = true },
                expose: { _ in XCTFail("Never expose") }
            )
            XCTFail("Injected post-save failure must abort")
        } catch is Failure {}
        await f.service.test_setRichArtifactPhase(nil)
        XCTAssertTrue(discarded.value)
        // The committed destination went through the existing tombstone-first deletion.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, dest.id).path))
        let restarted = AgentSessionDataService(tombstoneRoot: f.tombstoneRoot)
        let listed = try await restarted.listAgentSessions(for: f.workspace)
        XCTAssertFalse(listed.contains { $0.lastPathComponent.contains(dest.id.uuidString) })
        XCTAssertEqual(try Data(contentsOf: sessionFile(f, f.source.session.id)), sourceBytes)
        let read = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read, manifest)
    }

    func testOrdinaryHandoffWithoutReferencesNeedsNoSourceAuthorityButKeepsStorageIdentity() async throws {
        let f = try await fixture()
        // Destination storage identity is protected for every handoff: a root that is not the
        // workspace's session-persistence root refuses before anything is written or created.
        let stale = destination(f)
        let staleRoot = f.directory.appendingPathComponent("stale-root")
        do {
            try await f.service.commitPrivateHandoff(
                sourceState: nil, initialSession: stale, workspace: f.workspace, root: staleRoot, references: [],
                commitCheck: {}, expose: { _ in XCTFail("Never expose") }
            )
            XCTFail("A mismatched destination root is refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.storageMoved.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, stale.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRoot.path))
        XCTAssertEqual(f.service.workspaceStorageRoot(for: f.workspace), f.root)

        let dest = destination(f)
        let exposed = Box<AgentSessionEditableLoad?>(nil)
        try await f.service.commitPrivateHandoff(
            sourceState: nil, initialSession: dest, workspace: f.workspace, root: f.root, references: [],
            commitCheck: {}, expose: { exposed.value = $0 }
        )
        XCTAssertEqual(exposed.value?.session.id, dest.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("agent_rich_artifacts").path))

        let (_, reference) = try chart(f)
        let other = destination(f)
        do {
            try await f.service.commitPrivateHandoff(
                sourceState: nil, initialSession: other, workspace: f.workspace, root: f.root, references: [reference],
                commitCheck: {}, expose: { _ in XCTFail("Never expose") }
            )
            XCTFail("References without a durable source are refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.sourceUnavailable.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, other.id).path))
    }

    func testCorruptSourceAssetAbortsCopyWithoutExposureOrSourceMutation() async throws {
        let sourceID = UUID()
        let (manifest, reference, assetID, bytes) = try briefing(sessionID: sourceID)
        let f = try await fixture(sourceID: sourceID)
        try await publish(f, manifest: manifest, assets: [assetID: bytes])
        let assetURL = sessionDirectory(f, sourceID)
            .appendingPathComponent(reference.artifactID.uuidString).appendingPathComponent(assetID.uuidString + ".jpg")
        let corrupt = Data(bytes.prefix(bytes.count / 2))
        try corrupt.write(to: assetURL)
        let dest = destination(f)
        do {
            try await handoff(f, dest, [reference], expose: { _ in XCTFail("Never expose") })
            XCTFail("Corrupt asset must abort the copy")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: assetURL), corrupt, "The handoff never repairs or rewrites the source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(f, dest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, dest.id).path))
    }

    func testCompactedTurnReferenceCopiesIndependentJPEGThatSurvivesSourceDeletion() async throws {
        let sourceID = UUID()
        let (manifest, reference, assetID, bytes) = try briefing(sessionID: sourceID)
        var transcript = twoTurnToolTranscript()
        transcript.turns[0].retentionTier = .summary
        let toolActivity = try XCTUnwrap(transcript.turns[0].allActivities.first { $0.toolExecution != nil })
        transcript.turns[0].richPresentations = [
            .init(reference: reference, activityID: toolActivity.id, activityOrder: toolActivity.sequenceIndex)
        ]
        let f = try await fixture(sourceID: sourceID, transcript: transcript)
        let sourceTranscript = try XCTUnwrap(f.source.session.transcript)
        XCTAssertEqual(sourceTranscript.turns[0].retentionTier, .summary, "Precondition: compacted owner")
        XCTAssertEqual(sourceTranscript.turns[0].richPresentations.map(\.reference), [reference])
        try await publish(f, manifest: manifest, assets: [assetID: bytes])

        let cutoff = try XCTUnwrap(sourceTranscript.turns[1].allActivities.last?.id)
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: sourceTranscript, upToRowID: cutoff)
        XCTAssertEqual(selection.references, [reference])
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(
            selection, sourceTranscript: sourceTranscript,
            to: AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        )
        XCTAssertEqual(attached.turns.flatMap(\.richPresentations).map(\.reference), [reference])
        let dest = AgentSession(workspaceID: f.workspace.id, composeTabID: UUID(), name: "Fork", transcript: attached)
        let committed = Box<AgentSessionEditableLoad?>(nil)
        try await handoff(f, dest, selection.references, expose: { committed.value = $0 })

        try await f.service.deleteAgentSession(id: sourceID, for: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory(f, sourceID).path))
        let saved = try XCTUnwrap(committed.value)
        let read = try await f.service.readRichArtifact(state: saved.persistenceState, root: f.root, reference: reference)
        XCTAssertEqual(read, manifest)
        let copiedAsset = sessionDirectory(f, dest.id)
            .appendingPathComponent(reference.artifactID.uuidString).appendingPathComponent(assetID.uuidString + ".jpg")
        XCTAssertEqual(try Data(contentsOf: copiedAsset), bytes)
        let restarted = AgentSessionDataService(tombstoneRoot: f.tombstoneRoot)
        let reloaded = try await restarted.loadAgentSessionForEditing(id: dest.id, for: f.workspace)
        let reload = try XCTUnwrap(reloaded)
        XCTAssertEqual(reload.session.transcript?.turns.flatMap(\.richPresentations).map(\.reference), [reference])
    }

    // MARK: - Root mutation

    func testRootMutationRequestedAfterStagingWaitsForCleanupAndDoesNotRecreateOldRoot() async throws {
        let f = try await fixture()
        let (manifest, _) = try chart(f)
        let service = RichPresentationPublicationService()
        let storage = try service.capture(workspaceID: f.workspace.id, root: f.root)
        let barrier = RichLifecycleBarrier()
        await f.service.test_setRichArtifactPhase { phase, _ in
            if phase == "afterStage" { await barrier.arriveAndWait() }
        }
        let publication = Task {
            try await service.withPublication(workspaceID: f.workspace.id) {
                try await f.service.publishRichArtifact(
                    state: f.source.persistenceState, root: f.root, manifest: manifest, assets: [:],
                    commitCheck: { try service.validate(storage, currentRoot: f.root) }
                )
            }
        }
        await barrier.waitForArrival()
        let moved = f.directory.appendingPathComponent("renamed-custom")
        let move = moveRoot(f, to: moved, service: service)
        await barrier.release()
        do { try await publication.value
            XCTFail("Old revision cannot commit")
        } catch {}
        try await move.value
        await f.service.test_setRichArtifactPhase(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        let rich = moved.appendingPathComponent("agent_rich_artifacts").appendingPathComponent(f.source.session.id.uuidString)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rich.path), [])
    }

    func testRootMoveDuringHandoffCopyAbortsCleansDestinationAndMovesIntactSource() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let service = RichPresentationPublicationService()
        let storage = try service.capture(workspaceID: f.workspace.id, root: f.root)
        let barrier = RichLifecycleBarrier()
        await f.service.test_setRichArtifactPhase { phase, _ in
            if phase == "afterCopy" { await barrier.arriveAndWait() }
        }
        let dest = destination(f)
        let transaction = Task {
            try await service.withPublication(workspaceID: f.workspace.id) {
                try await self.handoff(
                    f, dest, [reference], commitCheck: { try service.validate(storage, currentRoot: f.root) },
                    expose: { _ in XCTFail("Never expose") }
                )
            }
        }
        await barrier.waitForArrival()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDirectory(f, dest.id).appendingPathComponent(reference.artifactID.uuidString).path
        ), "Precondition: the private copy exists before the move is requested")
        let moved = f.directory.appendingPathComponent("moved-root")
        let move = moveRoot(f, to: moved, service: service)
        await barrier.release()
        do { try await transaction.value
            XCTFail("A copy cannot commit across a root move")
        } catch {}
        try await move.value
        await f.service.test_setRichArtifactPhase(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "The old root is never recreated")
        let movedRich = moved.appendingPathComponent("agent_rich_artifacts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedRich.appendingPathComponent(dest.id.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("AgentSessions/AgentSession-\(dest.id.uuidString).json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: movedRich
                .appendingPathComponent(f.source.session.id.uuidString)
                .appendingPathComponent(reference.artifactID.uuidString)
                .appendingPathComponent("manifest.json").path
        ))
    }

    func testTwoNonqueuedPublicationSlotsAndMutationRevision() async throws {
        let service = RichPresentationPublicationService()
        let workspaceID = UUID()
        let first = RichLifecycleBarrier()
        let second = RichLifecycleBarrier()
        let a = Task { try await service.withPublication(workspaceID: workspaceID) { await first.arriveAndWait() } }
        await first.waitForArrival()
        let b = Task { try await service.withPublication(workspaceID: workspaceID) { await second.arriveAndWait() } }
        await second.waitForArrival()
        do { try await service.withPublication(workspaceID: workspaceID) {}
            XCTFail("Third job must not queue")
        } catch { XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.busy.localizedDescription) }
        let root = FileManager.default.temporaryDirectory
        let storage = try service.capture(workspaceID: workspaceID, root: root)
        let mutation = service.beginMutation(workspaceIDs: [workspaceID])
        XCTAssertThrowsError(try service.capture(workspaceID: workspaceID, root: root))
        service.endMutation(mutation)
        XCTAssertThrowsError(try service.validate(storage, currentRoot: root))
        await first.release()
        await second.release()
        try await a.value
        try await b.value
    }

    func testSymlinkManifestAndIntermediateSessionDirectoryAreRefused() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let bundle = sessionDirectory(f, f.source.session.id).appendingPathComponent(reference.artifactID.uuidString)
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let outside = f.directory.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: manifestURL, to: outside)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outside)
        do { _ = try await f.service.readRichArtifact(state: f.source.persistenceState, root: f.root, reference: reference)
            XCTFail("Symlink read")
        } catch {}
        try FileManager.default.removeItem(at: sessionDirectory(f, f.source.session.id))
        try FileManager.default.createSymbolicLink(at: sessionDirectory(f, f.source.session.id), withDestinationURL: f.directory)
        do { try await publish(f, manifest: manifest)
            XCTFail("Intermediate symlink")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testManifestDiscardsOriginalImageURLAndPreservesTerminalPlaceholderText() throws {
        let input = RichPresentationInput(title: "Briefing", content: .briefing(.init(
            date: "2026-11-05", sections: [.init(heading: "News", articles: [.init(
                headline: "Headline", body: "Complete accepted text", sources: [.init(label: "Local")],
                image: .init(url: "https://images.example.com/private/photo.jpg?signature=SECRET", alt: "Photo", credit: "Wire")
            )])]
        )))
        let manifest = try AgentRichArtifactManifest(
            artifactID: UUID(), input: input, outcomes: [.init(sectionIndex: 0, articleIndex: 0, outcome: .failed(.hostNotApproved))],
            provenance: provenance(UUID())
        )
        let bytes = try AgentRichArtifactManifest.encoded(manifest)
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["SECRET", "signature", "/private", "photo.jpg", "https://images"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertTrue(text.contains("Complete accepted text"))
        XCTAssertEqual(try JSONDecoder().decode(AgentRichArtifactManifest.self, from: bytes), manifest)
    }

    // MARK: - Cutoff selection, placement and retention (pure transcript paths)

    func testCutoffSelectsOnlyCoveredReferencesAndRefusesUnknownCutoff() throws {
        var transcript = twoTurnTranscriptWithProgress()
        let answerA = try XCTUnwrap(transcript.turns[0].allActivities.last)
        let progressB = try XCTUnwrap(transcript.turns[1].allActivities.first)
        let finalB = try XCTUnwrap(transcript.turns[1].allActivities.last)
        let requestB = try XCTUnwrap(transcript.turns[1].request)
        let rA = try entry(on: answerA)
        let rB1 = try entry(on: progressB)
        let rB2 = try entry(on: finalB)
        transcript.turns[0].richPresentations = [rA]
        transcript.turns[1].richPresentations = [rB1, rB2]
        for row in [answerA.id, progressB.id, finalB.id, requestB.id] {
            XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(row, in: transcript), "Precondition: export row")
        }

        func selected(_ cutoff: UUID?) throws -> [RichPresentationReference] {
            try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: cutoff).references
        }
        XCTAssertEqual(try selected(nil), [rA, rB1, rB2].map(\.reference))
        XCTAssertEqual(try selected(answerA.id), [rA.reference])
        XCTAssertEqual(try selected(requestB.id), [rA.reference], "A request cutoff excludes the turn's references")
        XCTAssertEqual(try selected(progressB.id), [rA, rB1].map(\.reference))
        XCTAssertEqual(try selected(finalB.id), [rA, rB1, rB2].map(\.reference))
        XCTAssertEqual(try selected(finalB.id), try selected(finalB.id), "Selection is deterministic")
        XCTAssertThrowsError(try selected(UUID())) { error in
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.invalidHandoffCutoff.localizedDescription)
        }

        // An identical duplicate is one artifact; a conflicting duplicate is corruption.
        var duplicated = transcript
        duplicated.turns[1].richPresentations.append(rA)
        XCTAssertEqual(try AgentTranscriptIO.selectHandoffTranscript(from: duplicated, upToRowID: nil).references, [rA, rB1, rB2].map(\.reference))
        var conflicting = transcript
        conflicting.turns[1].richPresentations.append(.init(reference: rA.reference, activityID: finalB.id, activityOrder: finalB.sequenceIndex))
        XCTAssertThrowsError(try AgentTranscriptIO.selectHandoffTranscript(from: conflicting, upToRowID: nil))
    }

    func testSelectedReferencesAttachToMigratedRowsWithRemappedOrder() throws {
        var transcript = twoTurnTranscriptWithProgress()
        let answerA = try XCTUnwrap(transcript.turns[0].allActivities.last)
        let finalB = try XCTUnwrap(transcript.turns[1].allActivities.last)
        transcript.turns[0].richPresentations = try [entry(on: answerA)]
        transcript.turns[1].richPresentations = try [entry(on: finalB)]
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: nil)
        let destination = AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(selection, sourceTranscript: transcript, to: destination)
        XCTAssertEqual(attached.turns.count, 2)
        for (turnIndex, activityID) in [(0, answerA.id), (1, finalB.id)] {
            let turn = attached.turns[turnIndex]
            let entry = try XCTUnwrap(turn.richPresentations.first)
            XCTAssertEqual(turn.richPresentations.count, 1)
            XCTAssertEqual(entry.activityID, activityID)
            let migrated = try XCTUnwrap(turn.allActivities.first { $0.id == activityID })
            XCTAssertEqual(entry.activityOrder, migrated.sequenceIndex, "Order is remapped to the renumbered destination row")
        }
        XCTAssertEqual(
            try AgentTranscriptIO.attachingHandoffRichPresentations(selection, sourceTranscript: transcript, to: destination),
            attached, "Attachment is deterministic"
        )
    }

    func testArchivedAndSyntheticOnlyTurnsKeepReferencesThroughCutoffAndAttach() throws {
        var transcript = twoTurnToolTranscript()
        transcript.turns[0].retentionTier = .archived
        let hiddenTool = try XCTUnwrap(transcript.turns[0].allActivities.first { $0.toolExecution != nil })
        let hidden = try entry(on: hiddenTool)
        transcript.turns[0].richPresentations = [hidden]
        let finalB = try XCTUnwrap(transcript.turns[1].allActivities.last)
        transcript.turns[1].richPresentations = try [entry(on: finalB)]

        // A synthetic summary row of the compacted turn covers that whole turn, not later turns.
        let realRows = Set(transcript.turns.flatMap { turn in turn.allActivities.map(\.id) + [turn.request?.id].compactMap(\.self) })
        let synthetic = AgentTranscriptIO.handoffExportCutoffRowIDs(from: transcript).subtracting(realRows)
        let syntheticCutoff = try XCTUnwrap(synthetic.first, "Precondition: archived turn exports a synthetic row")
        XCTAssertEqual(try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: syntheticCutoff).references, [hidden.reference])

        // The hidden activity is not migrated; the reference lands on its turn's retained request.
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: finalB.id)
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(
            selection, sourceTranscript: transcript,
            to: AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        )
        let owner = try XCTUnwrap(attached.turns.first { $0.request?.id == transcript.turns[0].request?.id })
        XCTAssertEqual(owner.richPresentations.map(\.reference), [hidden.reference])
        XCTAssertEqual(attached.turns.flatMap(\.richPresentations).count, 2)

        // With the request relocated away, only synthetic rows remain: still placed, never dropped.
        var requestless = transcript
        requestless.turns[0].request = nil
        requestless.turns[0].summary?.requestText = nil
        let requestlessSelection = try AgentTranscriptIO.selectHandoffTranscript(from: requestless, upToRowID: finalB.id)
        XCTAssertEqual(requestlessSelection.references.count, 2)
        let requestlessAttached = try AgentTranscriptIO.attachingHandoffRichPresentations(
            requestlessSelection, sourceTranscript: requestless,
            to: AgentTranscriptIO.buildTranscript(from: requestlessSelection.items, compact: false)
        )
        let laterOwner = try XCTUnwrap(requestlessAttached.turns.first { $0.request?.id == transcript.turns[1].request?.id })
        XCTAssertEqual(laterOwner.richPresentations.map(\.activityID), [finalB.id])
        XCTAssertEqual(
            Set(requestlessAttached.turns.flatMap(\.richPresentations).map(\.reference.artifactID)),
            Set(transcript.turns.flatMap(\.richPresentations).map(\.reference.artifactID))
        )
    }

    func testReferencesSurviveFullAndIncrementalRebuildsAndCompaction() throws {
        let items = twoTurnTranscriptItems()
        var existing = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: items.count, compact: false)
        let rA = try entry(on: XCTUnwrap(existing.turns[0].allActivities.last))
        let rB = try entry(on: XCTUnwrap(existing.turns[1].allActivities.last))
        existing.turns[0].richPresentations = [rA]
        existing.turns[1].richPresentations = [rB]

        // Full rebuild with a new trailing turn.
        let extended = items + [.user("Third", sequenceIndex: items.count), .assistant("Third answer", sequenceIndex: items.count + 1)]
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existing, workingItems: extended, terminalState: .completed, nextSequenceIndex: extended.count
        )
        XCTAssertEqual(rebuilt.turns.map(\.richPresentations), [[rA], [rB], []])

        // Incremental final-turn update: a new row in the final turn keeps its references.
        let appended = items + [.assistant("More detail", sequenceIndex: items.count)]
        let diagnostic = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics(
            existingTranscript: existing, items: appended, earliestChangedIndex: items.count,
            terminalState: .completed, nextSequenceIndex: appended.count
        )
        guard case let .updated(incremental, _, _) = diagnostic else { return XCTFail("Expected incremental update, got \(diagnostic)") }
        XCTAssertEqual(incremental.turns.map(\.richPresentations), [[rA], [rB]])
        let viaRefresh = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existing, workingItems: appended, earliestChangedIndex: items.count,
            terminalState: .completed, nextSequenceIndex: appended.count
        )
        XCTAssertEqual(viaRefresh.turns.map(\.richPresentations), [[rA], [rB]])

        // Compaction tiers and a rebuild over the compacted prefix keep every reference on its turn.
        var sequence = 0
        var manyItems: [AgentChatItem] = []
        for index in 0 ..< 24 {
            manyItems += toolTurnItems(label: "turn \(index)", toolCount: 4, sequenceIndex: &sequence)
        }
        var many = AgentTranscriptIO.buildTranscript(from: manyItems, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
        var expected: [UUID: [AgentTranscriptRichPresentation]] = [:]
        for index in many.turns.indices {
            let owned = try entry(on: XCTUnwrap(many.turns[index].allActivities.first { $0.toolExecution != nil }))
            many.turns[index].richPresentations = [owned]
            expected[many.turns[index].id] = [owned]
        }
        let compacted = AgentTranscriptCompactor.compact(many)
        XCTAssertTrue(compacted.turns.contains { $0.retentionTier != .full }, "Precondition: compaction downshifted turns")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: compacted.turns.map { ($0.id, $0.richPresentations) }), expected)
        let afterRebuild = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: compacted, workingItems: AgentTranscriptIO.workingSourceItems(from: compacted),
            terminalState: .completed, nextSequenceIndex: sequence
        )
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: afterRebuild.turns.map { ($0.id, $0.richPresentations) }), expected)
        let persisted = AgentTranscriptIO.persistedTranscript(afterRebuild)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: persisted.turns.map { ($0.id, $0.richPresentations) }), expected)
    }

    // MARK: - Step 3 review fixes (storage identity, cleanup, decoding, ordering)

    /// B3-01: a completed move leaves the live source's stamp naming the old path (stamps are
    /// never refreshed); rich authority follows the session's own file under the current root.
    func testCompletedMoveKeepsRichAuthorityAtCurrentRootAndNeverAcceptsOrRecreatesOldRoot() async throws {
        let f = try await fixture()
        let (manifest, reference) = try chart(f)
        try await publish(f, manifest: manifest)
        let moved = f.directory.appendingPathComponent("moved-workspace")
        try await moveRoot(f, to: moved, service: RichPresentationPublicationService()).value
        var movedWorkspace = f.workspace
        movedWorkspace.customStoragePath = moved
        let state = f.source.persistenceState

        let root = try await f.service.captureRichArtifactRoot(state: state, workspace: movedWorkspace, resolvedRoot: moved)
        let read = try await f.service.readRichArtifact(state: state, root: root, reference: reference)
        XCTAssertEqual(read, manifest)
        let (second, secondReference) = try chart(f)
        try await f.service.publishRichArtifact(state: state, root: root, manifest: second, assets: [:], commitCheck: {})
        let secondRead = try await f.service.readRichArtifact(state: state, root: root, reference: secondReference)
        XCTAssertEqual(secondRead, second)

        let dest = AgentSession(workspaceID: f.workspace.id, composeTabID: UUID(), name: "Fork", transcript: f.source.session.transcript)
        let committed = Box<AgentSessionEditableLoad?>(nil)
        try await f.service.commitPrivateHandoff(
            sourceState: state, initialSession: dest, workspace: movedWorkspace, root: moved,
            references: [reference, secondReference], commitCheck: {}, expose: { committed.value = $0 }
        )
        let copied = try await f.service.readRichArtifact(
            state: XCTUnwrap(committed.value).persistenceState, root: moved, reference: secondReference
        )
        XCTAssertEqual(copied, second)

        do {
            _ = try await f.service.captureRichArtifactRoot(state: state, workspace: movedWorkspace, resolvedRoot: f.root)
            XCTFail("The pre-move root is not the workspace's current storage")
        } catch {
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.storageMoved.localizedDescription)
        }
        do {
            _ = try await f.service.readRichArtifact(state: state, root: f.root, reference: reference)
            XCTFail("No session file exists under the pre-move root")
        } catch {
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.storageMoved.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "The old root is never recreated")

        // The tombstone stays authoritative over the relocated file and the stale stamp.
        try await f.service.deleteAgentSession(id: f.source.session.id, for: movedWorkspace)
        do {
            _ = try await f.service.readRichArtifact(state: state, root: moved, reference: reference)
            XCTFail("A deleted session has no rich authority")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("agent_rich_artifacts").appendingPathComponent(f.source.session.id.uuidString).path
        ))
    }

    /// S3-03: a deletion whose stamp URL predates a completed move still removes the tree at the
    /// workspace's current root (the tombstone commit is the deletion's authority).
    func testConditionalDeletionWithStaleStampRemovesRichTreeAtCurrentRoot() async throws {
        let f = try await fixture()
        let (manifest, _) = try chart(f)
        try await publish(f, manifest: manifest)
        let moved = f.directory.appendingPathComponent("moved-workspace")
        try await moveRoot(f, to: moved, service: RichPresentationPublicationService()).value
        var movedWorkspace = f.workspace
        movedWorkspace.customStoragePath = moved
        let sourceID = f.source.session.id
        let movedTree = moved.appendingPathComponent("agent_rich_artifacts").appendingPathComponent(sourceID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTree.path), "Precondition: the move carried the tree")

        let candidate = try AgentSessionDeletionCandidate(
            composeTabID: XCTUnwrap(f.source.session.composeTabID), persistenceState: f.source.persistenceState
        )
        let result = try await f.service.deleteAgentSession(ifCurrent: candidate, for: movedWorkspace)
        XCTAssertEqual(result, .alreadyAbsent, "The stale stamp URL names no file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL(f, sourceID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedTree.path), "The moved tree is removed at the current root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "Cleanup never recreates the old root")
    }

    /// B3-07: a symlinked storage root is resolved once before the no-follow store removes a tree.
    func testDeletionResolvesSymlinkedStorageRootBeforeRichCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RichSymlink-" + UUID().uuidString)
        let real = directory.appendingPathComponent("real")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Linked", repoPaths: [], customStoragePath: link)
        let service = AgentSessionDataService(tombstoneRoot: directory.appendingPathComponent("tombstones"))
        let session = AgentSession(
            workspaceID: workspace.id, composeTabID: UUID(), name: "Linked",
            transcript: AgentTranscriptIO.handoffTranscript(fromLegacyItems: [.user("Q", sequenceIndex: 0), .assistant("A", sequenceIndex: 1)])
        )
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session, for: workspace, preparation: .alreadyCanonicalTranscript
        )
        let storage = try RichPresentationPublicationService().capture(
            workspaceID: workspace.id, root: service.workspaceStorageRoot(for: workspace)
        )
        XCTAssertEqual(storage.root, real.standardizedFileURL.resolvingSymlinksInPath(), "Publication captures the resolved root")
        let root = try await service.captureRichArtifactRoot(state: load.persistenceState, workspace: workspace, resolvedRoot: storage.root)
        let (manifest, _) = try chart(sessionID: session.id)
        try await service.publishRichArtifact(state: load.persistenceState, root: root, manifest: manifest, assets: [:], commitCheck: {})
        let tree = real.appendingPathComponent("agent_rich_artifacts").appendingPathComponent(session.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))

        try await service.deleteAgentSession(id: session.id, for: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path), "Cleanup through the symlinked root removes the tree")
    }

    /// B3-06/B3-10: an undecodable persisted value never fails the session or its text history,
    /// round-trips unchanged through rebuild and save, and makes handoff refuse instead of dropping
    /// it. An empty list is omitted, so legacy session bytes are unchanged.
    func testUnreadableRichPresentationsKeepSessionTextRoundTripUnchangedAndRefuseHandoff() async throws {
        let f = try await fixture(transcript: twoTurnTranscriptWithProgress())
        let sourceID = f.source.session.id
        let file = sessionFile(f, sourceID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var transcriptJSON = try XCTUnwrap(json["transcript"] as? [String: Any])
        var turnsJSON = try XCTUnwrap(transcriptJSON["turns"] as? [[String: Any]])
        XCTAssertTrue(turnsJSON.allSatisfy { $0["richPresentations"] == nil }, "Empty references are not encoded")
        let future: [Any] = [[
            "reference": ["version": 2, "kind": "timeline", "artifactID": "future-id"],
            "activityID": "not-a-uuid", "activityOrder": 3
        ]]
        turnsJSON[0]["richPresentations"] = future
        transcriptJSON["turns"] = turnsJSON
        json["transcript"] = transcriptJSON
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let restarted = AgentSessionDataService(tombstoneRoot: f.tombstoneRoot)
        let loadedOrNil = try await restarted.loadAgentSessionForEditing(id: sourceID, for: f.workspace)
        let loaded = try XCTUnwrap(loadedOrNil)
        let transcript = try XCTUnwrap(loaded.session.transcript)
        XCTAssertEqual(
            transcript.turns.map { $0.request?.text },
            f.source.session.transcript?.turns.map { $0.request?.text },
            "The session and its text history still open"
        )
        let raw = try XCTUnwrap(transcript.turns[0].unreadableRichPresentations)
        XCTAssertTrue(transcript.turns[0].richPresentations.isEmpty)
        XCTAssertThrowsError(try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: nil)) { error in
            XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.unreadableReferences.localizedDescription)
        }

        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: transcript, workingItems: AgentTranscriptIO.workingSourceItems(from: transcript),
            terminalState: .completed, nextSequenceIndex: transcript.nextSequenceIndex
        )
        XCTAssertEqual(rebuilt.turns.compactMap(\.unreadableRichPresentations), [raw], "A rebuild carries it exactly once")
        var next = loaded.session
        next.transcript = rebuilt
        _ = try await restarted.saveAgentSession(
            next, for: f.workspace, preparation: .alreadyCanonicalTranscript, persistenceState: loaded.persistenceState
        )
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let savedTurns = try XCTUnwrap((saved["transcript"] as? [String: Any])?["turns"] as? [[String: Any]])
        XCTAssertEqual(savedTurns[0]["richPresentations"] as? NSArray, future as NSArray, "The next save writes it back unchanged")
        XCTAssertTrue(savedTurns.dropFirst().allSatisfy { $0["richPresentations"] == nil })
    }

    /// B3-11: references captured out of activity order (a later-started call finishing first)
    /// attach to the destination turn ordered by remapped activity order.
    func testAttachedReferencesAreOrderedByRemappedActivityOrder() throws {
        var source = twoTurnToolTranscript()
        let tools = source.turns[0].allActivities.filter { $0.toolExecution != nil }
        XCTAssertGreaterThanOrEqual(tools.count, 2, "Precondition: two tool activities")
        let early = try entry(on: tools[0])
        let late = try entry(on: tools[tools.count - 1])
        source.turns[0].richPresentations = [late, early]
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: source, upToRowID: nil)
        XCTAssertEqual(selection.references, [late.reference, early.reference], "Selection keeps capture order")
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(
            selection, sourceTranscript: source, to: AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        )
        let owner = try XCTUnwrap(attached.turns.first { !$0.richPresentations.isEmpty })
        XCTAssertEqual(owner.richPresentations.map(\.reference), [early.reference, late.reference])
        XCTAssertEqual(owner.richPresentations.map(\.activityOrder), owner.richPresentations.map(\.activityOrder).sorted())
    }

    /// S3-04: a rebuild that displaces an explicit canonical turn (its rows are gone) keeps that
    /// turn's only reference exactly once, on the final turn, through persistence and a later
    /// cutoff handoff.
    func testDisplacedExplicitTurnReferenceIsRetainedOncePersistedAndSelectedByLaterCutoff() throws {
        var sequence = 0
        var items = toolTurnItems(label: "explicit", toolCount: 1, sequenceIndex: &sequence)
        items += [.user("Next", sequenceIndex: sequence), .assistant("Next answer", sequenceIndex: sequence + 1)]
        sequence += 2
        var transcript = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
        // An explicit canonical envelope: the importer's turn identity and deterministic span, with
        // a request row whose identity differs from the turn ID.
        let explicitRequest = AgentChatItem.user("explicit request", sequenceIndex: 0)
        transcript.turns[0].request = AgentTranscriptRequestAnchor(from: explicitRequest)
        let explicitTurnID = transcript.turns[0].id
        XCTAssertTrue(
            AgentTranscriptIO.explicitWorkingTurnOwnership(in: transcript).explicitTurnIDs.contains(explicitTurnID),
            "Precondition: turn 0 is an explicit envelope"
        )
        let tool = try XCTUnwrap(transcript.turns[0].allActivities.first { $0.toolExecution != nil })
        let owned = try entry(on: tool)
        transcript.turns[0].richPresentations = [owned]

        let removedRowIDs = Set([explicitRequest.id] + transcript.turns[0].allActivities.map(\.id))
        let working = AgentTranscriptIO.workingSourceItems(from: transcript).filter { !removedRowIDs.contains($0.id) }
        XCTAssertEqual(working.map(\.text), ["Next", "Next answer"], "Precondition: the explicit turn's rows are gone")
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: transcript, workingItems: working, terminalState: .completed, nextSequenceIndex: sequence
        )
        XCTAssertFalse(rebuilt.turns.contains { $0.id == explicitTurnID }, "Precondition: the explicit turn was displaced")
        XCTAssertEqual(rebuilt.turns.flatMap(\.richPresentations), [owned], "Retained exactly once, unchanged")
        XCTAssertEqual(rebuilt.turns.last?.richPresentations, [owned], "Re-homed onto the final turn")

        let data = try JSONEncoder().encode(AgentTranscriptIO.persistedTranscript(rebuilt))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)
        XCTAssertEqual(decoded.turns.flatMap(\.richPresentations), [owned], "Persists unchanged")

        let finalTurn = try XCTUnwrap(decoded.turns.last)
        let cutoff = try XCTUnwrap(finalTurn.allActivities.last?.id)
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: decoded, upToRowID: cutoff)
        XCTAssertEqual(selection.references, [owned.reference])
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(
            selection, sourceTranscript: decoded, to: AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        )
        XCTAssertEqual(attached.turns.flatMap(\.richPresentations).map(\.reference), [owned.reference])
        let requestCutoff = try XCTUnwrap(finalTurn.request?.id)
        let excluded = try AgentTranscriptIO.selectHandoffTranscript(from: decoded, upToRowID: requestCutoff)
        XCTAssertTrue(excluded.references.isEmpty, "A request-row cutoff excludes that turn's references")
    }

    /// R1-01 / B3-R1-01 (forward): two displaced explicit turns holding unreadable values, and a
    /// surviving turn holding a readable reference. Each opaque value stays verbatim on its own
    /// evidence-only envelope (never combined, never moved onto the readable owner), and both kinds
    /// survive repeated rebuild, real save and reload. Handoff still refuses.
    func testDisplacedUnreadableValuesKeepSeparateEnvelopesBesideReadableReferenceThroughRepeatedSaves() async throws {
        var sequence = 0
        var items = toolTurnItems(label: "first", toolCount: 1, sequenceIndex: &sequence)
        items += toolTurnItems(label: "second", toolCount: 1, sequenceIndex: &sequence)
        items += [.user("Next", sequenceIndex: sequence), .assistant("Next answer", sequenceIndex: sequence + 1)]
        sequence += 2
        var transcript = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
        XCTAssertEqual(transcript.turns.count, 3, "Precondition: three turns")
        var removed = Set<UUID>()
        for index in 0 ..< 2 {
            let request = AgentChatItem.user("explicit \(index)", sequenceIndex: transcript.turns[index].request?.sequenceIndex ?? 0)
            transcript.turns[index].request = AgentTranscriptRequestAnchor(from: request)
            removed.formUnion([request.id] + transcript.turns[index].allActivities.map(\.id))
        }
        let rawA = AgentScheduledSendJSONValue.object(["future": .string("A"), "version": .number(9)])
        let rawB = AgentScheduledSendJSONValue.array([.object(["future": .string("B")])])
        transcript.turns[0].unreadableRichPresentations = rawA
        transcript.turns[1].unreadableRichPresentations = rawB
        let finalAnswer = try XCTUnwrap(transcript.turns[2].allActivities.last)
        let valid = try entry(on: finalAnswer)
        transcript.turns[2].richPresentations = [valid]
        let (envelopeA, envelopeB) = (transcript.turns[0].id, transcript.turns[1].id)
        XCTAssertEqual(
            AgentTranscriptIO.explicitWorkingTurnOwnership(in: transcript).explicitTurnIDs.intersection([envelopeA, envelopeB]),
            [envelopeA, envelopeB], "Precondition: both displaced turns are explicit envelopes"
        )

        let f = try await fixture(transcript: transcript)
        let reloaded = try await rebuildSaveReloadCycles(f, removing: removed)
        XCTAssertEqual(reloaded.count, 3)
        for (cycle, result) in reloaded.enumerated() {
            XCTAssertEqual(result.turns.compactMap(\.unreadableRichPresentations), [rawA, rawB], "Cycle \(cycle): separate and verbatim")
            XCTAssertEqual(result.turns.first { $0.id == envelopeA }?.unreadableRichPresentations, rawA)
            XCTAssertEqual(result.turns.first { $0.id == envelopeB }?.unreadableRichPresentations, rawB)
            for envelope in result.turns where envelope.unreadableRichPresentations != nil {
                XCTAssertNil(envelope.request, "Cycle \(cycle): evidence only")
                XCTAssertTrue(envelope.allActivities.isEmpty)
                XCTAssertTrue(envelope.richPresentations.isEmpty)
            }
            XCTAssertEqual(result.turns.flatMap(\.richPresentations), [valid], "Cycle \(cycle): the readable reference survives")
            XCTAssertEqual(result.turns.last?.richPresentations, [valid])
            XCTAssertEqual(result.turns.compactMap { $0.request?.text }, ["Next"], "Cycle \(cycle): text history intact")
            XCTAssertThrowsError(try AgentTranscriptIO.selectHandoffTranscript(from: result, upToRowID: nil)) { error in
                XCTAssertEqual(error.localizedDescription, AgentRichArtifactError.unreadableReferences.localizedDescription)
            }
        }
        XCTAssertEqual(reloaded[1], reloaded[2], "Repeated rebuilds and saves are stable")
    }

    /// R1-01 / B3-R1-01 (reverse): a displaced readable reference whose fallback owner holds an
    /// unreadable value is never placed on that turn (only the opaque value would be encoded). It
    /// re-homes onto the last turn that can encode it, or stays on its own envelope when none can.
    func testDisplacedReadableReferenceNeverLandsOnUnreadableOwnerThroughRepeatedSaves() async throws {
        for withPlainMiddleTurn in [true, false] {
            var sequence = 0
            var items = toolTurnItems(label: "explicit", toolCount: 1, sequenceIndex: &sequence)
            if withPlainMiddleTurn {
                items += [.user("Middle", sequenceIndex: sequence), .assistant("Middle answer", sequenceIndex: sequence + 1)]
                sequence += 2
            }
            items += [.user("Last", sequenceIndex: sequence), .assistant("Last answer", sequenceIndex: sequence + 1)]
            sequence += 2
            var transcript = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
            let explicitRequest = AgentChatItem.user("explicit request", sequenceIndex: 0)
            transcript.turns[0].request = AgentTranscriptRequestAnchor(from: explicitRequest)
            let explicitTurnID = transcript.turns[0].id
            let removed = Set([explicitRequest.id] + transcript.turns[0].allActivities.map(\.id))
            let owned = try entry(on: XCTUnwrap(transcript.turns[0].allActivities.first { $0.toolExecution != nil }))
            transcript.turns[0].richPresentations = [owned]
            let raw = AgentScheduledSendJSONValue.object(["future": .string("last")])
            let lastIndex = transcript.turns.count - 1
            transcript.turns[lastIndex].unreadableRichPresentations = raw
            let lastTurnID = transcript.turns[lastIndex].id

            let f = try await fixture(transcript: transcript)
            let reloaded = try await rebuildSaveReloadCycles(f, removing: removed)
            for (cycle, result) in reloaded.enumerated() {
                let label = "middle=\(withPlainMiddleTurn) cycle \(cycle)"
                XCTAssertEqual(result.turns.flatMap(\.richPresentations), [owned], "\(label): the readable reference survives once")
                XCTAssertEqual(result.turns.compactMap(\.unreadableRichPresentations), [raw], "\(label): the opaque value is unchanged")
                let rawOwner = try XCTUnwrap(result.turns.first { $0.unreadableRichPresentations != nil })
                XCTAssertEqual(rawOwner.id, lastTurnID)
                XCTAssertTrue(rawOwner.richPresentations.isEmpty, "\(label): never shares a turn with the opaque value")
                let owner = try XCTUnwrap(result.turns.first { !$0.richPresentations.isEmpty })
                if withPlainMiddleTurn {
                    XCTAssertEqual(owner.request?.text, "Middle", "\(label): re-homed onto the last turn that encodes it")
                    XCTAssertFalse(result.turns.contains { $0.id == explicitTurnID }, "\(label): the emptied envelope is removed")
                } else {
                    XCTAssertEqual(owner.id, explicitTurnID, "\(label): no encodable owner, so it stays on its envelope")
                    XCTAssertNil(owner.request)
                    XCTAssertTrue(owner.allActivities.isEmpty)
                }
            }
            XCTAssertEqual(reloaded[1], reloaded[2], "Repeated rebuilds and saves are stable")
        }
    }

    /// S3-R2-01: an earlier implicit turn Y loses all its rows while a later explicit turn X keeps
    /// them, so the positional fallback gives X's rebuilt rows (under X's ID) Y's slot and X finds no
    /// match. X's request, activities and rich state all survive, every turn ID stays unique, and
    /// nothing is lost through repeated rebuild, save and reload: X's state joins its own rebuilt
    /// turn when that turn holds none, else it keeps an envelope under a fresh ID.
    func testDisplacedExplicitTurnWhoseRowsSurviveUnderEarlierSlotKeepsTextAndRichStateWithUniqueIDs() async throws {
        enum Variant: CaseIterable { case opaqueOnX, readableOnX, readableOnYOpaqueOnX }
        for variant in Variant.allCases {
            var sequence = 0
            var items = toolTurnItems(label: "implicit y", toolCount: 1, sequenceIndex: &sequence)
            items += toolTurnItems(label: "x", toolCount: 1, sequenceIndex: &sequence)
            var transcript = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
            XCTAssertEqual(transcript.turns.count, 2, "Precondition: two turns")
            let explicitRequest = AgentChatItem.user("explicit x", sequenceIndex: transcript.turns[1].request?.sequenceIndex ?? 0)
            transcript.turns[1].request = AgentTranscriptRequestAnchor(from: explicitRequest)
            let (yID, xID) = (transcript.turns[0].id, transcript.turns[1].id)
            let ownership = AgentTranscriptIO.explicitWorkingTurnOwnership(in: transcript).explicitTurnIDs
            XCTAssertTrue(ownership.contains(xID) && !ownership.contains(yID), "Precondition: X explicit, Y implicit")
            let xActivityIDs = transcript.turns[1].allActivities.map(\.id)
            let yRequestID = try XCTUnwrap(transcript.turns[0].request?.id)
            let removed = Set([yRequestID] + transcript.turns[0].allActivities.map(\.id))
            let raw = AgentScheduledSendJSONValue.object(["future": .string("x")])
            var readable: [AgentTranscriptRichPresentation] = []
            switch variant {
            case .opaqueOnX:
                transcript.turns[1].unreadableRichPresentations = raw
            case .readableOnX:
                readable = try [entry(on: XCTUnwrap(transcript.turns[1].allActivities.first { $0.toolExecution != nil }))]
                transcript.turns[1].richPresentations = readable
            case .readableOnYOpaqueOnX:
                readable = try [entry(on: XCTUnwrap(transcript.turns[0].allActivities.first { $0.toolExecution != nil }))]
                transcript.turns[0].richPresentations = readable
                transcript.turns[1].unreadableRichPresentations = raw
            }
            let expectsRaw = variant != .readableOnX

            let f = try await fixture(transcript: transcript)
            let reloaded = try await rebuildSaveReloadCycles(f, removing: removed)
            for (cycle, result) in reloaded.enumerated() {
                let label = "\(variant) cycle \(cycle)"
                XCTAssertEqual(Set(result.turns.map(\.id)).count, result.turns.count, "\(label): turn IDs are unique")
                let x = try XCTUnwrap(result.turns.first { $0.id == xID }, "\(label): X's rebuilt turn survives")
                XCTAssertEqual(x.request?.text, "explicit x", label)
                XCTAssertEqual(x.allActivities.map(\.id), xActivityIDs, "\(label): X's rows survive")
                XCTAssertEqual(result.turns.compactMap { $0.request?.text }, ["explicit x"], "\(label): text history intact")
                XCTAssertEqual(result.turns.compactMap(\.unreadableRichPresentations), expectsRaw ? [raw] : [], "\(label): opaque value once")
                XCTAssertEqual(result.turns.flatMap(\.richPresentations), readable, "\(label): readable references once")
                for turn in result.turns {
                    XCTAssertTrue(turn.richPresentations.isEmpty || turn.unreadableRichPresentations == nil, "\(label): one representation per turn")
                }
            }
            XCTAssertEqual(reloaded[0], reloaded[1], "\(variant): stable from the first rebuild")
            XCTAssertEqual(reloaded[1], reloaded[2], "\(variant): stable across repeated saves")
        }
    }

    /// R1-02: references captured out of activity order on a compacted turn whose activities are
    /// not migrated tie on the retained request; they attach in source activity order.
    func testCompactedFallbackPlacementKeepsSourceActivityOrderOnTies() throws {
        var source = twoTurnToolTranscript()
        source.turns[0].retentionTier = .archived
        let tools = source.turns[0].allActivities.filter { $0.toolExecution != nil }
        XCTAssertGreaterThanOrEqual(tools.count, 2, "Precondition: two tool activities")
        let early = try entry(on: tools[0])
        let late = try entry(on: tools[tools.count - 1])
        source.turns[0].richPresentations = [late, early]
        let selection = try AgentTranscriptIO.selectHandoffTranscript(from: source, upToRowID: nil)
        XCTAssertEqual(selection.references, [late.reference, early.reference], "Selection keeps capture order")
        let destination = AgentTranscriptIO.buildTranscript(from: selection.items, compact: false)
        XCTAssertFalse(
            destination.turns.flatMap(\.allActivities).contains { $0.id == early.activityID || $0.id == late.activityID },
            "Precondition: the compacted turn's tool activities are not migrated"
        )
        let attached = try AgentTranscriptIO.attachingHandoffRichPresentations(selection, sourceTranscript: source, to: destination)
        let owner = try XCTUnwrap(attached.turns.first { $0.request?.id == source.turns[0].request?.id })
        XCTAssertEqual(owner.richPresentations.map(\.reference), [early.reference, late.reference])
        XCTAssertEqual(Set(owner.richPresentations.map(\.activityOrder)).count, 1, "Precondition: both tie on the retained request")
    }

    /// B3-03: with no turn-owned references, selection is exactly the existing export.
    func testSelectionWithoutReferencesIsExactlyTheExistingExport() throws {
        let transcript = twoTurnToolTranscript()
        for cutoff in [nil, transcript.turns[1].allActivities.last?.id, transcript.turns[0].request?.id] {
            let selection = try AgentTranscriptIO.selectHandoffTranscript(from: transcript, upToRowID: cutoff)
            XCTAssertEqual(selection.items, AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: cutoff))
            XCTAssertEqual(selection.items.count, selection.itemSourceTurnIDs.count)
            XCTAssertTrue(selection.richPresentations.isEmpty)
        }
    }

    // MARK: - Helpers

    private func entry(on activity: AgentTranscriptActivity) throws -> AgentTranscriptRichPresentation {
        let (_, reference) = try chart(sessionID: UUID())
        return AgentTranscriptRichPresentation(reference: reference, activityID: activity.id, activityOrder: activity.sequenceIndex)
    }

    private func twoTurnTranscriptItems() -> [AgentChatItem] {
        [
            .user("First", sequenceIndex: 0), .assistant("First answer", sequenceIndex: 1),
            .user("Second", sequenceIndex: 2), .assistant("Second answer", sequenceIndex: 3)
        ]
    }

    private func twoTurnTranscriptWithProgress() -> AgentTranscript {
        let items: [AgentChatItem] = [
            .user("First", sequenceIndex: 0), .assistant("First answer", sequenceIndex: 1),
            .user("Second", sequenceIndex: 2), .assistant("Checking", sequenceIndex: 3),
            .assistant("Second answer", sequenceIndex: 4)
        ]
        return AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: items.count, compact: false)
    }

    /// Turn 0 has tool activity (hidden when compacted); turn 1 is a plain question and answer.
    private func twoTurnToolTranscript() -> AgentTranscript {
        var sequence = 0
        var items = toolTurnItems(label: "tools", toolCount: 2, sequenceIndex: &sequence)
        items += [.user("Follow up", sequenceIndex: sequence), .assistant("Follow-up answer", sequenceIndex: sequence + 1)]
        sequence += 2
        return AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, nextSequenceIndex: sequence, compact: false)
    }

    private func toolTurnItems(label: String, toolCount: Int, sequenceIndex: inout Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = [.user("\(label) request", sequenceIndex: sequenceIndex)]
        sequenceIndex += 1
        for _ in 0 ..< toolCount {
            let invocationID = UUID()
            items.append(.toolCall(name: "read_file", invocationID: invocationID, argsJSON: #"{"path":"/tmp/file.swift"}"#, sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            items.append(.toolResult(name: "read_file", invocationID: invocationID, resultJSON: #"{"content":"ok"}"#, sequenceIndex: sequenceIndex))
            sequenceIndex += 1
        }
        items.append(.assistant("\(label) done", sequenceIndex: sequenceIndex))
        sequenceIndex += 1
        return items
    }

    /// Rebuilds the saved session from its working rows (without `removedRowIDs`), saves it through
    /// the real service, and reloads it with a restarted service, `cycles` times.
    private func rebuildSaveReloadCycles(
        _ f: Fixture, removing removedRowIDs: Set<UUID>, cycles: Int = 3
    ) async throws -> [AgentTranscript] {
        var service = f.service
        var load = f.source
        var reloaded: [AgentTranscript] = []
        for _ in 0 ..< cycles {
            let transcript = try XCTUnwrap(load.session.transcript)
            let working = AgentTranscriptIO.workingSourceItems(from: transcript).filter { !removedRowIDs.contains($0.id) }
            var next = load.session
            next.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript, workingItems: working, terminalState: .completed,
                nextSequenceIndex: transcript.nextSequenceIndex
            )
            _ = try await service.saveAgentSession(
                next, for: f.workspace, preparation: .alreadyCanonicalTranscript, persistenceState: load.persistenceState
            )
            service = AgentSessionDataService(tombstoneRoot: f.tombstoneRoot)
            let loaded = try await service.loadAgentSessionForEditing(id: next.id, for: f.workspace)
            load = try XCTUnwrap(loaded)
            try reloaded.append(XCTUnwrap(load.session.transcript))
        }
        return reloaded
    }

    private func moveRoot(_ f: Fixture, to moved: URL, service: RichPresentationPublicationService) -> Task<Void, Error> {
        let mutation = service.beginMutation(workspaceIDs: [f.workspace.id])
        return Task {
            let fence = AgentRichArtifactFilesystemFence.shared
            await fence.acquire()
            defer {
                fence.release()
                service.endMutation(mutation)
            }
            try await AgentRichArtifactStore.offMain { try FileManager.default.moveItem(at: f.root, to: moved) }
        }
    }

    private func sessionDirectory(_ f: Fixture, _ id: UUID) -> URL {
        f.root.appendingPathComponent("agent_rich_artifacts").appendingPathComponent(id.uuidString)
    }

    private func sessionFile(_ f: Fixture, _ id: UUID) -> URL {
        f.root.appendingPathComponent("AgentSessions").appendingPathComponent("AgentSession-" + id.uuidString + ".json")
    }

    private func tombstoneURL(_ f: Fixture, _ id: UUID) -> URL {
        f.tombstoneRoot.appendingPathComponent(id.uuidString + ".json")
    }
}

/// Idempotent deterministic barrier, not a timer or sleep-based race oracle.
private actor RichLifecycleBarrier {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
