@testable import RepoPromptAgentCore
import XCTest

/// Recovery store behind the real `AgentSessionDataService` gate (lossless restart Phase 1b,
/// inactive in production). Every service, tombstone root, recovery root, and workspace is an
/// injected temporary directory. Ordering is forced with latches held inside the session gate.
final class AgentSessionRecoveryIntegrationTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private struct Workspace: AgentWorkspaceStorageReference {
        let id = UUID()
        let name = "Recovery Integration"
        let customStoragePath: URL?
    }

    /// Records the order in which work actually ran under the session gate.
    private actor EventLog {
        private(set) var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }
    }

    private var root: URL!
    private var recoveryRoot: URL!
    private var workspace: Workspace!
    private var failures: RecoveryStoreWriteFailureSwitch!

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentSessionRecoveryIntegrationTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        workspace = Workspace(customStoragePath: root.appendingPathComponent("workspaceA", isDirectory: true))
        failures = RecoveryStoreWriteFailureSwitch()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeStore(instance: UUID = UUID()) -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: instance, fileOperations: failures.fileOperations())
    }

    private func makeService(store: AgentRecoveryStore) -> AgentSessionDataService {
        AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
    }

    private func makeSession(
        _ service: AgentSessionDataService,
        workspace: Workspace? = nil,
        composeTabID: UUID = UUID()
    ) async throws -> AgentSessionEditableLoad {
        let workspace = workspace ?? self.workspace!
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: composeTabID,
            name: "Recovery"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
    }

    private func candidate(_ load: AgentSessionEditableLoad) throws -> AgentSessionDeletionCandidate {
        try AgentSessionDeletionCandidate(
            composeTabID: XCTUnwrap(load.session.composeTabID),
            persistenceState: load.persistenceState
        )
    }

    private func resetTranscript(
        _ service: AgentSessionDataService,
        _ load: AgentSessionEditableLoad
    ) async throws -> AgentSessionSaveCommit {
        try await service.saveAgentSession(
            load.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: load.persistenceState
        )
    }

    private func discovery(
        _ service: AgentSessionDataService,
        workspace: Workspace? = nil
    ) async throws -> [AgentSessionRecoveryDiscovery] {
        try await service.discoverRecoveryRecords(for: workspace ?? self.workspace!)
    }

    private func assertLifecycleRejection(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> some Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected lifecycle rejection", file: file, line: line)
        } catch is AgentScheduledSendMutationError {
            // Rejected by the foundation gate before the recovery body ran.
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Deletion races

    func testRecoveryCommitLinearizedBeforeDeletionKeepsItsHistoricalReceipt() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let gate = try service.recoveryLifecycleGate(for: load.persistenceState)
        XCTAssertEqual(gate.binding.transcriptResetGeneration, 0)
        let log = EventLog()
        let latch = RecoveryGateLatch()
        await service.test_setConditionalDeletionHook { _ in await log.append("deletion acquired gate") }
        let submission = Support.submission("sent before delete")

        // The recovery transaction holds the session gate, paused before its store write.
        let recoveryTask = Task {
            try await gate.performRecoveryTransaction {
                await latch.pause()
                let receipt = try await store.commitQueuedIntent(
                    binding: gate.binding, expectedRevision: nil, submission: submission, consumption: nil
                )
                await log.append("recovery committed")
                return receipt
            }
        }
        await latch.waitUntilPaused()
        let deletion = try candidate(load)
        let deleteTask = Task { try await service.deleteAgentSession(ifCurrent: deletion, for: self.workspace) }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let whilePaused = await log.events
        XCTAssertEqual(whilePaused, [], "deletion cannot enter the gate while the recovery body holds it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletion.storagePath))

        await latch.open()
        let receipt = try await recoveryTask.value
        let deleted = try await deleteTask.value
        XCTAssertEqual(deleted, .deleted)
        let order = await log.events
        XCTAssertEqual(order, ["recovery committed", "deletion acquired gate"])

        // The recovery commit linearized first, so its receipt is a valid historical receipt even
        // though deletion won before the caller resumed.
        XCTAssertEqual(receipt.intent.disposition, .committed)
        XCTAssertEqual(receipt.intent.intentID, submission.intentID)
        XCTAssertEqual(receipt.intent.deliveryState, .queued)

        // Deletion then removed the record under the same gate; later stale writes are rejected.
        let afterDelete = await store.read(sessionID: load.session.id)
        XCTAssertEqual(afterDelete, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletion.storagePath))
        await assertLifecycleRejection {
            try await gate.performRecoveryTransaction {
                try await store.commitComposer(
                    binding: gate.binding, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("late")
                )
            }
        }
        let afterRejection = await store.read(sessionID: load.session.id)
        XCTAssertEqual(afterRejection, .absent, "no stale-authority write after deletion")
        let entries = try await discovery(service)
        XCTAssertTrue(entries.isEmpty)
    }

    func testDeletionLinearizedFirstRejectsRecoveryWithoutWriting() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let gate = try service.recoveryLifecycleGate(for: load.persistenceState)
        let log = EventLog()
        let latch = RecoveryGateLatch()
        // Deletion holds the session gate, paused before its tombstone commit.
        await service.test_setConditionalDeletionHook { _ in
            await log.append("deletion acquired gate")
            await latch.pause()
        }
        let deletion = try candidate(load)
        let deleteTask = Task { try await service.deleteAgentSession(ifCurrent: deletion, for: self.workspace) }
        await latch.waitUntilPaused()

        let recoveryTask = Task {
            try await gate.performRecoveryTransaction {
                await log.append("recovery body ran")
                return try await store.commitComposer(
                    binding: gate.binding, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("draft")
                )
            }
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let whilePaused = await store.read(sessionID: load.session.id)
        XCTAssertEqual(whilePaused, .absent, "the recovery write waits for the gate")

        await latch.open()
        let deleted = try await deleteTask.value
        XCTAssertEqual(deleted, .deleted)
        await assertLifecycleRejection { try await recoveryTask.value }
        let order = await log.events
        XCTAssertEqual(order, ["deletion acquired gate"], "the recovery body never runs after deletion")
        let afterDelete = await store.read(sessionID: load.session.id)
        XCTAssertEqual(afterDelete, .absent)
    }

    // MARK: - Reset races

    func testRecoveryCommitBeforeResetSucceedsAndResetRetiresTheOldGate() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let gate0 = try service.recoveryLifecycleGate(for: load.persistenceState)
        let log = EventLog()
        let latch = RecoveryGateLatch()
        let submission = Support.submission("before reset", target: Support.liveRunTarget())

        let recoveryTask = Task {
            try await gate0.performRecoveryTransaction {
                await latch.pause()
                let receipt = try await store.commitQueuedIntent(
                    binding: gate0.binding, expectedRevision: nil, submission: submission, consumption: nil
                )
                await log.append("recovery committed")
                return receipt
            }
        }
        await latch.waitUntilPaused()
        let resetTask = Task {
            let commit = try await self.resetTranscript(service, load)
            await log.append("reset committed")
            return commit
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let whilePaused = await log.events
        XCTAssertEqual(whilePaused, [], "the reset waits for the recovery transaction")

        await latch.open()
        let receipt = try await recoveryTask.value
        let reset = try await resetTask.value
        let order = await log.events
        XCTAssertEqual(order, ["recovery committed", "reset committed"])
        XCTAssertEqual(receipt.intent.disposition, .committed)
        XCTAssertEqual(receipt.intent.binding.transcriptResetGeneration, 0)
        XCTAssertEqual(reset.persistenceState.transcriptResetGeneration, 1)

        // Linearized after the reset, the old-generation gate is rejected before writing.
        let beforeStale = await store.read(sessionID: load.session.id).record?.revision
        await assertLifecycleRejection {
            try await gate0.performRecoveryTransaction {
                try await store.commitComposer(
                    binding: gate0.binding, expectedRevision: beforeStale, expectedComposerRevision: nil,
                    snapshot: Support.snapshot("old generation")
                )
            }
        }
        let afterStale = await store.read(sessionID: load.session.id).record
        XCTAssertEqual(afterStale?.revision, beforeStale)
        XCTAssertNil(afterStale?.composer)

        // The new-generation gate writes; the pre-reset intent stays held, never retargeted.
        let gate1 = try service.recoveryLifecycleGate(for: reset.persistenceState)
        XCTAssertEqual(gate1.binding.transcriptResetGeneration, 1)
        let composer = try await gate1.performRecoveryTransaction {
            try await store.commitComposer(
                binding: gate1.binding, expectedRevision: beforeStale, expectedComposerRevision: nil,
                snapshot: Support.snapshot("after reset", generation: 1)
            )
        }
        XCTAssertEqual(composer.disposition, .committed)
        let entries = try await discovery(service)
        guard case let .eligible(discovered, binding) = try XCTUnwrap(entries.first), entries.count == 1 else {
            return XCTFail("expected one eligible record, got \(entries)")
        }
        XCTAssertEqual(binding, gate1.binding)
        XCTAssertEqual(discovered.record.intent(id: submission.intentID)?.transcriptResetGeneration, 0)
        XCTAssertEqual(discovered.record.intent(id: submission.intentID)?.target, submission.target)
        XCTAssertEqual(discovered.holdsByIntentID[submission.intentID], [.staleTarget])
        await assertStoreHeld(store, gate1.binding, submission.intentID)
    }

    @MainActor
    func testResetLinearizedFirstRejectsOldGateAndHoldsOldGenerationComposer() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let gate0 = try service.recoveryLifecycleGate(for: load.persistenceState)
        let draft = try await gate0.performRecoveryTransaction {
            try await store.commitComposer(
                binding: gate0.binding, expectedRevision: nil, expectedComposerRevision: nil,
                snapshot: Support.snapshot("typed before reset")
            )
        }

        let reset = try await resetTranscript(service, load)
        await assertLifecycleRejection {
            try await gate0.performRecoveryTransaction {
                try await store.commitQueuedIntent(
                    binding: gate0.binding, expectedRevision: draft.recordRevision,
                    submission: Support.submission("stale"), consumption: nil
                )
            }
        }
        let state = await store.read(sessionID: load.session.id)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.revision, draft.recordRevision, "nothing written by the stale gate")

        // Restoration under the new generation holds the old draft instead of adopting it.
        let gate1 = try service.recoveryLifecycleGate(for: reset.persistenceState)
        let controller = AgentRecoveryComposerPersistenceController(store: store, gate: gate1)
        let outcome = await controller.loadRestorableComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("expected held composer, got \(outcome)")
        }
        XCTAssertEqual(held.content.text, "typed before reset")
        XCTAssertEqual(held.transcriptResetGeneration, 0)
    }

    // MARK: - Discovery and cleanup

    func testDiscoveryClassifiesAgainstTombstonesWorkspaceAndPreservedBytes() async throws {
        let storeA = makeStore()
        let serviceA = makeService(store: storeA)

        // 1. Live session with a queued intent from this launch.
        let live = try await makeSession(serviceA)
        let liveGate = try serviceA.recoveryLifecycleGate(for: live.persistenceState)
        let queued = Support.submission("queued")
        _ = try await liveGate.performRecoveryTransaction {
            try await storeA.commitQueuedIntent(binding: liveGate.binding, expectedRevision: nil, submission: queued, consumption: nil)
        }

        // 2. Deleted session whose recovery cleanup fails: the record survives as residue.
        let residue = try await makeSession(serviceA)
        let residueGate = try serviceA.recoveryLifecycleGate(for: residue.persistenceState)
        _ = try await residueGate.performRecoveryTransaction {
            try await storeA.commitComposer(
                binding: residueGate.binding, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("gone")
            )
        }
        failures.shouldFailRemovals = true
        try await serviceA.deleteAgentSession(id: residue.session.id, for: workspace)
        failures.shouldFailRemovals = false
        let residueState = await storeA.read(sessionID: residue.session.id)
        XCTAssertNotNil(residueState.record, "cleanup failure leaves residue")

        // 3. Deleted session with managed attachments and successful cleanup.
        let cleaned = try await makeSession(serviceA)
        let cleanedGate = try serviceA.recoveryLifecycleGate(for: cleaned.persistenceState)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let image = try await storeA.importManagedImage(
            sessionID: cleaned.session.id, sourceURL: Support.makeImageSource(in: sources)
        )
        _ = try await cleanedGate.performRecoveryTransaction {
            try await storeA.commitComposer(
                binding: cleanedGate.binding, expectedRevision: nil, expectedComposerRevision: nil,
                snapshot: Support.snapshot("with image", images: [image])
            )
        }
        let attachmentDirectory = storeA.managedAttachmentDirectoryURL(sessionID: cleaned.session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentDirectory.path))
        try await serviceA.deleteAgentSession(id: cleaned.session.id, for: workspace)
        let cleanedState = await storeA.read(sessionID: cleaned.session.id)
        XCTAssertEqual(cleanedState, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentDirectory.path))

        // 4. Deleted session whose record bytes are from a future schema: bytes are preserved.
        let future = try await makeSession(serviceA)
        let futureBytes = Data(#"{"schemaVersion":99,"futureOnly":true}"#.utf8)
        try FileManager.default.createDirectory(at: storeA.sessionsDirectoryURL, withIntermediateDirectories: true)
        try futureBytes.write(to: storeA.recordFileURL(sessionID: future.session.id))
        try await serviceA.deleteAgentSession(id: future.session.id, for: workspace)
        XCTAssertEqual(try Data(contentsOf: storeA.recordFileURL(sessionID: future.session.id)), futureBytes)

        // 5. Session in another workspace; 6. a record file that is not a session UUID.
        let otherWorkspace = Workspace(customStoragePath: root.appendingPathComponent("workspaceB", isDirectory: true))
        let elsewhere = try await makeSession(serviceA, workspace: otherWorkspace)
        let elsewhereGate = try serviceA.recoveryLifecycleGate(for: elsewhere.persistenceState)
        _ = try await elsewhereGate.performRecoveryTransaction {
            try await storeA.commitComposer(
                binding: elsewhereGate.binding, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("b")
            )
        }
        let strayBytes = Data("{}".utf8)
        try strayBytes.write(to: storeA.sessionsDirectoryURL.appendingPathComponent("stray.json"))

        // Relaunch: a fresh service and store instance on the same roots.
        let instanceB = UUID()
        let storeB = makeStore(instance: instanceB)
        let serviceB = makeService(store: storeB)
        let entries = try await discovery(serviceB)
        var bySession: [UUID: AgentSessionRecoveryDiscovery] = [:]
        var anonymous: [AgentSessionRecoveryDiscovery] = []
        for entry in entries {
            switch entry {
            case let .eligible(discovered, _):
                bySession[discovered.record.sessionID] = entry
            case let .tombstoned(sessionID):
                bySession[sessionID] = entry
            case let .nonactionable(sessionID, _):
                if let sessionID {
                    bySession[sessionID] = entry
                } else {
                    anonymous.append(entry)
                }
            }
        }
        XCTAssertEqual(entries.count, 5)

        guard case let .eligible(liveRecord, liveBinding) = try XCTUnwrap(bySession[live.session.id]) else {
            return XCTFail("live session must be eligible")
        }
        XCTAssertEqual(liveBinding, liveGate.binding)
        XCTAssertEqual(liveRecord.holdsByIntentID[queued.intentID], [.previousInstance])
        XCTAssertEqual(bySession[residue.session.id], .tombstoned(sessionID: residue.session.id), "tombstone hides residue")
        XCTAssertEqual(bySession[future.session.id], .tombstoned(sessionID: future.session.id))
        XCTAssertEqual(
            bySession[elsewhere.session.id],
            .nonactionable(sessionID: elsewhere.session.id, reason: .sessionFileUnavailable)
        )
        guard case let .nonactionable(nil, .unreadableRecord(reason)) = try XCTUnwrap(anonymous.first) else {
            return XCTFail("stray file must be nonactionable")
        }
        XCTAssertEqual(reason, .malformed("file name is not a session UUID"))
        XCTAssertNil(bySession[cleaned.session.id])

        // The other workspace sees its own session as eligible; discovery never rewrote any bytes.
        let otherEntries = try await discovery(serviceB, workspace: otherWorkspace)
        XCTAssertTrue(otherEntries.contains { entry in
            if case let .eligible(discovered, _) = entry { return discovered.record.sessionID == elsewhere.session.id }
            return false
        })
        XCTAssertEqual(try Data(contentsOf: storeB.recordFileURL(sessionID: future.session.id)), futureBytes)
        XCTAssertEqual(try Data(contentsOf: storeB.sessionsDirectoryURL.appendingPathComponent("stray.json")), strayBytes)

        // A tombstoned session yields no editable authority, so no recovery gate can be issued for it.
        let reopened = try await serviceB.loadAgentSessionForEditing(id: residue.session.id, for: workspace)
        XCTAssertNil(reopened)
        // Repeated deletion retries the cleanup.
        try await serviceB.deleteAgentSession(id: residue.session.id, for: workspace)
        let retriedState = await storeB.read(sessionID: residue.session.id)
        XCTAssertEqual(retriedState, .absent)
    }

    // MARK: - Helpers

    private func assertStoreHeld(
        _ store: AgentRecoveryStore,
        _ binding: AgentRecoveryLifecycleBinding,
        _ intentID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.issueQueueReceipt(binding: binding, intentID: intentID)
            XCTFail("expected held intent", file: file, line: line)
        } catch let error as AgentRecoveryStoreError {
            XCTAssertEqual(error, .heldIntent(intentID: intentID, holds: [.staleTarget]), file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
