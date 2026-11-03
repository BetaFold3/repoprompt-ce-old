@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Durable lifecycle foundation (lossless restart Phase 1b). Every service in this suite uses an
/// injected tombstone root and temporary workspace storage under one per-test directory; nothing
/// here touches live Application Support. A "fresh service" on the same roots models a restart.
final class AgentSessionLifecyclePersistenceTests: XCTestCase {
    // MARK: - Codec

    func testLifecycleMemberDecodingIsPresenceSensitiveStrictAndPreservedVerbatim() throws {
        let sessionID = UUID()
        let incarnationID = UUID()
        let receiptID = UUID()
        let inc = incarnationID.uuidString
        let rec = receiptID.uuidString

        XCTAssertNil(try decodeLifecycle(nil, sessionID: sessionID), "Absent member is legacy")
        XCTAssertEqual(try decodeLifecycle("null", sessionID: sessionID), .unreadable(.null))

        let fresh = #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": 0}"#
        XCTAssertEqual(
            try decodeLifecycle(fresh, sessionID: sessionID),
            .v1(AgentSessionLifecycle(incarnationID: incarnationID))
        )
        let reset = #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": 1, "lastTranscriptResetReceipt": {"id": "\#(rec)"}}"#
        XCTAssertEqual(
            try decodeLifecycle(reset, sessionID: sessionID),
            .v1(AgentSessionLifecycle(
                incarnationID: incarnationID,
                transcriptResetGeneration: 1,
                lastTranscriptResetReceipt: AgentSessionTranscriptResetReceipt(id: receiptID)
            ))
        )

        let unreadableInputs = [
            #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": 0, "future": true}"#,
            #"{"schemaVersion": 2, "incarnationID": "\#(inc)", "transcriptResetGeneration": 0}"#,
            #"{"schemaVersion": 1, "incarnationID": "not-a-uuid", "transcriptResetGeneration": 0}"#,
            #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": 1}"#,
            #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": 0, "lastTranscriptResetReceipt": {"id": "\#(rec)"}}"#,
            #"{"schemaVersion": 1, "incarnationID": "\#(inc)", "transcriptResetGeneration": -1}"#,
            #""v1""#
        ]
        for input in unreadableInputs + [fresh, reset, "null"] {
            let member = try XCTUnwrap(try decodeLifecycle(input, sessionID: sessionID))
            if unreadableInputs.contains(input) {
                guard case .unreadable = member else {
                    XCTFail("Expected unreadable lifecycle for \(input)")
                    continue
                }
            }
            // Every member, typed or unreadable, re-encodes to the same JSON value.
            var session = AgentSession(id: sessionID, name: "Codec")
            session.lifecycle = member
            let encoded = try AgentSessionDataCodec.encodeSession(session)
            let reencoded = try JSONDecoder().decode(LifecycleProbe.self, from: encoded).lifecycle
            let original = try JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: Data(input.utf8))
            XCTAssertEqual(reencoded, original, "Lifecycle member must round-trip exactly: \(input)")
        }
    }

    // MARK: - Fail closed

    func testUnsupportedEnvelopesAndUnreadableLifecycleFailClosedWithoutRewrite() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }

        let validLifecycle = #"{"schemaVersion": 1, "incarnationID": "\#(UUID().uuidString)", "transcriptResetGeneration": 0}"#
        let cases: [(version: Int?, lifecycle: String?, error: (UUID) -> AgentScheduledSendMutationError)] = [
            (99, validLifecycle, { .unsupportedSessionEnvelope($0, serializationVersion: 99) }),
            (-1, nil, { .unsupportedSessionEnvelope($0, serializationVersion: -1) }),
            (7, "null", { .unreadableLifecycle($0) }),
            (7, #"{"schemaVersion": 2}"#, { .unreadableLifecycle($0) })
        ]
        for testCase in cases {
            let sessionID = UUID()
            let fileURL = try await installRawSession(
                sessionJSON(id: sessionID, version: testCase.version, lifecycle: testCase.lifecycle),
                id: sessionID,
                env: env
            )
            let bytes = try Data(contentsOf: fileURL)
            let expected = testCase.error(sessionID)
            let service = env.makeService()

            await assertThrows(expected) {
                _ = try await service.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
            }
            await assertThrows(expected) {
                _ = try await service.loadAgentSession(from: fileURL)
            }
            // Cold hydration (overlapped and sequential reference) fails closed the same way.
            for sequential in [false, true] {
                do {
                    _ = try await AgentSessionDataService.$forcesSequentialHydrationPreparation.withValue(sequential) {
                        try await service.preparePersistedHydration(hydrationRequest(sessionID: sessionID, env: env))
                    }
                    XCTFail("Hydration must fail closed for version \(String(describing: testCase.version))")
                } catch {
                    XCTAssertEqual(mutationError(error), expected, "sequential=\(sequential)")
                }
            }
            var claimant = AgentSession(id: sessionID, workspaceID: env.workspace.id, name: "Claimant")
            claimant.lifecycle = .v1(AgentSessionLifecycle(incarnationID: UUID()))
            await assertThrows(expected) {
                _ = try await service.saveAgentSession(
                    claimant,
                    for: env.workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: 0
                )
            }
            // Display-only stub recovery never rewrites an unsupported or unreadable envelope.
            _ = try? await service.loadAgentSessionStub(
                from: fileURL,
                recoverMissingMetadata: true,
                persistRecoveredMetadata: true
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes, "Bytes preserved for version \(String(describing: testCase.version))")
        }
    }

    // MARK: - Migration

    func testLegacyLoadMigratesIdentityOnceUnderTheGate() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }

        for version in [nil, 6, 7] as [Int?] {
            let sessionID = UUID()
            let fileURL = try await installRawSession(
                sessionJSON(id: sessionID, version: version, name: "Legacy"),
                id: sessionID,
                env: env
            )
            let first = env.makeService()
            let loaded = try await first.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
            let load = try XCTUnwrap(loaded)
            let lifecycle = try XCTUnwrap(load.session.lifecycle?.lifecycle)
            XCTAssertEqual(lifecycle.transcriptResetGeneration, 0)
            XCTAssertNil(lifecycle.lastTranscriptResetReceipt)
            XCTAssertEqual(load.persistenceState.stamp.incarnationID, lifecycle.incarnationID)
            XCTAssertEqual(load.persistenceState.transcriptResetGeneration, 0)

            let durable = try durableSession(at: fileURL)
            XCTAssertEqual(durable.lifecycle, .v1(lifecycle), "Migration identity is durable before authority is issued")
            XCTAssertEqual(durable.name, "Legacy")
            XCTAssertEqual(durable.serializationVersion, AgentSession.currentSerializationVersion)

            // A restarted service reads the same identity and does not migrate again.
            let migratedBytes = try Data(contentsOf: fileURL)
            let restarted = env.makeService()
            let reloaded = try await restarted.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
            XCTAssertEqual(reloaded?.session.lifecycle, .v1(lifecycle))
            XCTAssertEqual(reloaded?.persistenceState.stamp.incarnationID, lifecycle.incarnationID)
            XCTAssertEqual(try Data(contentsOf: fileURL), migratedBytes)
        }
    }

    func testMigrationWriteFailureLeavesBytesUnchangedAndGrantsNoAuthority() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let sessionID = UUID()
        let fileURL = try await installRawSession(
            sessionJSON(id: sessionID, version: 7, name: "Legacy"),
            id: sessionID,
            env: env
        )
        let bytes = try Data(contentsOf: fileURL)
        let service = env.makeService()

        await service.test_setSessionWriteFailureInjector { _ in InjectedFailure() }
        do {
            _ = try await service.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
            XCTFail("A failed migration write must not issue editable authority")
        } catch {
            // Expected: the migration rewrite failed.
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        // The in-memory migration identity was not remembered as durable authority.
        let fabricated = AgentSessionLifecycle(incarnationID: UUID())
        var claimant = AgentSession(id: sessionID, workspaceID: env.workspace.id, name: "Claimant")
        claimant.lifecycle = .v1(fabricated)
        await assertThrows(.staleIncarnation(expected: fabricated.incarnationID, actual: nil)) {
            _ = try await service.saveAgentSession(
                claimant,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
        }
        await service.test_setSessionWriteFailureInjector(nil)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        let retried = try await service.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
        let lifecycle = try XCTUnwrap(retried?.session.lifecycle?.lifecycle)
        XCTAssertEqual(try durableSession(at: fileURL).lifecycle, .v1(lifecycle))
    }

    func testHydrationAndStubMigrationAdoptOnlyTheCommittedLifecycle() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }

        // Hydration: the owner's payload and stamp carry exactly the durable migration identity.
        let hydratedID = UUID()
        let hydratedURL = try await installRawSession(
            sessionJSON(id: hydratedID, version: 7, name: "Hydrated"),
            id: hydratedID,
            env: env
        )
        let service = env.makeService()
        let request = AgentSessionHydrationRequest(
            workspace: env.workspace,
            tabID: UUID(),
            sessionID: hydratedID,
            resolvedDisplayName: "Hydrated",
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let prepared = try await service.preparePersistedHydration(request)
        let payload = try XCTUnwrap(prepared)
        let hydratedLifecycle = try XCTUnwrap(payload.persistedSession.lifecycle?.lifecycle)
        XCTAssertEqual(payload.persistenceState.stamp.incarnationID, hydratedLifecycle.incarnationID)
        XCTAssertEqual(try durableSession(at: hydratedURL).lifecycle, .v1(hydratedLifecycle))

        // Stub without a committed rewrite reports no identity and leaves bytes alone.
        let stubID = UUID()
        let stubURL = try await installRawSession(
            sessionJSON(id: stubID, version: 7, name: "Stub"),
            id: stubID,
            env: env
        )
        let stubBytes = try Data(contentsOf: stubURL)
        let displayOnly = try await service.loadAgentSessionStub(
            from: stubURL,
            recoverMissingMetadata: true,
            persistRecoveredMetadata: false
        )
        XCTAssertNil(displayOnly.lifecycle)
        XCTAssertEqual(try Data(contentsOf: stubURL), stubBytes)

        // A committed metadata-recovery rewrite makes the migration identity durable.
        let migrated = try await service.loadAgentSessionStub(
            from: stubURL,
            recoverMissingMetadata: true,
            persistRecoveredMetadata: true
        )
        let stubLifecycle = try XCTUnwrap(migrated.lifecycle?.lifecycle)
        XCTAssertEqual(try durableSession(at: stubURL).lifecycle, .v1(stubLifecycle))
        let editable = try await service.loadAgentSessionForEditing(id: stubID, for: env.workspace)
        XCTAssertEqual(editable?.persistenceState.stamp.incarnationID, stubLifecycle.incarnationID)
    }

    // MARK: - Exclusive creation

    func testInitialCreationIsExclusiveAndValidatesItsInput() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }

        // The app's sole DataService: the session gate serializes two independent creators of one
        // UUID, exactly one commits, and the loser observes the winner's file. (Independent
        // service instances on one directory are outside the sole-writer contract.)
        let sameServiceID = UUID()
        let service = env.makeService()
        async let firstAttempt = createResult(service, id: sameServiceID, name: "First", env: env)
        async let secondAttempt = createResult(service, id: sameServiceID, name: "Second", env: env)
        let sameServiceResults = await [firstAttempt, secondAttempt]
        try await assertExactlyOneCreator(
            sameServiceResults,
            sessionID: sameServiceID,
            env: env
        )

        var lifecycleBearing = AgentSession(id: UUID(), workspaceID: env.workspace.id, name: "Bearing")
        lifecycleBearing.lifecycle = .v1(AgentSessionLifecycle(incarnationID: UUID()))
        await assertThrows(.invalidInitialSession(lifecycleBearing.id)) {
            _ = try await service.prepareInitialAgentSessionPersistence(initialSession: lifecycleBearing, for: env.workspace)
        }
        let foreign = AgentSession(id: UUID(), workspaceID: env.otherWorkspace.id, name: "Foreign")
        await assertThrows(.invalidInitialSession(foreign.id)) {
            _ = try await service.prepareInitialAgentSessionPersistence(initialSession: foreign, for: env.workspace)
        }
    }

    // MARK: - Save fences

    func testSavesRequireCurrentLoadedAuthority() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let created = try await create(service, name: "Fenced", env: env)
        let sessionID = created.load.session.id
        let lifecycle0 = try XCTUnwrap(created.load.session.lifecycle?.lifecycle)

        func compatibilitySave(_ session: AgentSession) async throws {
            _ = try await service.saveAgentSession(
                session,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
        }

        var withoutLifecycle = created.load.session
        withoutLifecycle.lifecycle = nil
        var unreadable = created.load.session
        unreadable.lifecycle = .unreadable(.null)
        let otherIncarnation = AgentSessionLifecycle(incarnationID: UUID())
        var wrongIncarnation = created.load.session
        wrongIncarnation.lifecycle = .v1(otherIncarnation)
        let bytes = try Data(contentsOf: created.fileURL)
        await assertThrows(.missingLifecycle(sessionID)) { try await compatibilitySave(withoutLifecycle) }
        await assertThrows(.unreadableLifecycle(sessionID)) { try await compatibilitySave(unreadable) }
        await assertThrows(.staleIncarnation(expected: otherIncarnation.incarnationID, actual: lifecycle0.incarnationID)) {
            try await compatibilitySave(wrongIncarnation)
        }
        await assertThrows(.transcriptResetRequiresPersistenceState) {
            _ = try await service.saveAgentSession(
                created.load.session,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID())
            )
        }
        XCTAssertEqual(try Data(contentsOf: created.fileURL), bytes, "Rejected saves never write")

        // Load-modify-save with the loaded lifecycle remains supported.
        var renamed = created.load.session
        renamed.name = "Renamed"
        try await compatibilitySave(renamed)

        let reset = try await service.saveAgentSession(
            created.load.session.withItems([]),
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: created.load.persistenceState
        )
        XCTAssertEqual(reset.persistenceState.transcriptResetGeneration, 1)

        // Pre-reset authority, compatibility or state, cannot overwrite the reset transcript.
        await assertThrows(.staleTranscriptResetGeneration(expected: 0, actual: 1)) { try await compatibilitySave(renamed) }
        await assertThrows(.staleTranscriptResetGeneration(expected: 0, actual: 1)) {
            _ = try await service.saveAgentSession(
                renamed,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                fileCreationPolicy: .requireExisting,
                persistenceState: created.load.persistenceState
            )
        }

        // A file removed outside DataService is never reconstructed by a lifecycle-bearing owner.
        try FileManager.default.removeItem(at: created.fileURL)
        await assertThrows(.sessionNotFound(sessionID)) {
            _ = try await service.saveAgentSession(
                renamed,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                fileCreationPolicy: .createIfMissing,
                persistenceState: reset.persistenceState
            )
        }
        var currentOwner = renamed
        currentOwner.lifecycle = try .v1(XCTUnwrap(lifecycle0.advancingTranscriptReset(receipt: AgentSessionTranscriptResetReceipt(id: UUID()))))
        await assertThrows(.sessionNotFound(sessionID)) { try await compatibilitySave(currentOwner) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.fileURL.path))
    }

    // MARK: - Reset receipts

    func testResetReceiptIsIdempotentAcrossRestartAndRejectsSupersededRetries() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let original = env.makeService()
        let created = try await create(original, name: "Reset", env: env)
        let sessionID = created.load.session.id
        let firstReceipt = AgentSessionTranscriptResetReceipt(id: UUID())

        func reset(
            _ service: AgentSessionDataService,
            _ session: AgentSession,
            receipt: AgentSessionTranscriptResetReceipt?,
            state: AgentSessionPersistenceState
        ) async throws -> AgentSessionSaveCommit {
            try await service.saveAgentSession(
                session,
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: session.items.count,
                committingTranscriptReset: receipt,
                fileCreationPolicy: .requireExisting,
                persistenceState: state
            )
        }

        let committed = try await reset(original, created.load.session.withItems([]), receipt: firstReceipt, state: created.load.persistenceState)
        XCTAssertEqual(committed.disposition, .written)
        XCTAssertEqual(committed.persistenceState.transcriptResetGeneration, 1)
        let afterReset = try Data(contentsOf: created.fileURL)
        let retryInProcess = try await reset(original, created.load.session, receipt: firstReceipt, state: created.load.persistenceState)
        XCTAssertEqual(retryInProcess.disposition, .resetAlreadyCommitted)
        XCTAssertEqual(retryInProcess.persistenceState.transcriptResetGeneration, 1)
        XCTAssertEqual(try Data(contentsOf: created.fileURL), afterReset)

        // Restart: the old process's stamp is not authority in the new service.
        let restarted = env.makeService()
        await assertThrows(.invalidPersistenceStamp) {
            _ = try await reset(restarted, created.load.session, receipt: firstReceipt, state: created.load.persistenceState)
        }
        let reloaded = try await restarted.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
        let load = try XCTUnwrap(reloaded)
        XCTAssertEqual(load.persistenceState.transcriptResetGeneration, 1)
        XCTAssertEqual(load.session.lifecycle?.lifecycle?.lastTranscriptResetReceipt, firstReceipt)

        // Newer edits survive a retried, already-committed receipt.
        var newer = load.session.withItems([AgentChatItem.user("After reset", sequenceIndex: 0)])
        newer.name = "Newer"
        _ = try await reset(restarted, newer, receipt: nil, state: load.persistenceState)
        let newerBytes = try Data(contentsOf: created.fileURL)
        let retryAfterRestart = try await reset(restarted, load.session.withItems([]), receipt: firstReceipt, state: load.persistenceState)
        XCTAssertEqual(retryAfterRestart.disposition, .resetAlreadyCommitted)
        XCTAssertEqual(try Data(contentsOf: created.fileURL), newerBytes)
        XCTAssertEqual(try durableSession(at: created.fileURL).name, "Newer")

        // After another reset, the superseded receipt is rejected rather than reapplied.
        let second = try await reset(restarted, newer.withItems([]), receipt: AgentSessionTranscriptResetReceipt(id: UUID()), state: load.persistenceState)
        XCTAssertEqual(second.persistenceState.transcriptResetGeneration, 2)
        await assertThrows(.staleTranscriptResetGeneration(expected: 1, actual: 2)) {
            _ = try await reset(restarted, newer.withItems([]), receipt: firstReceipt, state: load.persistenceState)
        }
    }

    func testResetThroughOneStoragePathAliasFencesAStaleSaveThroughTheOther() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let created = try await create(service, name: "Aliased", env: env)
        let sessionID = created.load.session.id

        // A second storage reference for the same workspace reaches the same directory through a
        // symlink (as `/var` vs `/private/var` does for temporary storage).
        let realStorage = try XCTUnwrap(env.workspace.customStoragePath)
        let aliasStorage = env.root.appendingPathComponent("workspace-a-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasStorage, withDestinationURL: realStorage)
        let aliased = WorkspaceModel(
            id: env.workspace.id,
            name: env.workspace.name,
            repoPaths: ["/tmp/repo"],
            customStoragePath: aliasStorage
        )
        let aliasLoad = try await service.loadAgentSessionForEditing(id: sessionID, for: aliased)
        let staleAlias = try XCTUnwrap(aliasLoad)
        XCTAssertEqual(staleAlias.persistenceState, created.load.persistenceState, "Both spellings share one file identity")

        // Warm the metadata cache through each workspace spelling before any stamp-pinned save.
        _ = try await service.fastMetadataRecordsIfAvailable(for: env.workspace)
        _ = try await service.fastMetadataRecordsIfAvailable(for: aliased)

        // Reset through the original spelling, then a pre-reset save through the alias.
        let resetCommit = try await service.saveAgentSession(
            created.load.session.withItems([]),
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: created.load.persistenceState
        )
        let afterReset = try Data(contentsOf: created.fileURL)
        var staleEdit = staleAlias.session.withItems([AgentChatItem.user("Pre-reset edit", sequenceIndex: 0)])
        staleEdit.name = "Stale"
        await assertThrows(.staleTranscriptResetGeneration(expected: 0, actual: 1)) {
            _ = try await service.saveAgentSession(
                staleEdit,
                for: aliased,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1,
                fileCreationPolicy: .requireExisting,
                persistenceState: staleAlias.persistenceState
            )
        }
        XCTAssertEqual(try Data(contentsOf: created.fileURL), afterReset, "The reset transcript survives")
        XCTAssertEqual(try durableSession(at: created.fileURL).lifecycle?.lifecycle?.transcriptResetGeneration, 1)

        // A save through the stamp's resolved folder updates the one metadata cache both spellings read.
        var renamed = created.load.session.withItems([])
        renamed.name = "Renamed Through Stamp"
        _ = try await service.saveAgentSession(
            renamed,
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            fileCreationPolicy: .requireExisting,
            persistenceState: resetCommit.persistenceState
        )
        for workspace in [env.workspace, aliased] {
            let fast = try await service.fastMetadataRecordsIfAvailable(for: workspace)
            let record = try XCTUnwrap(fast?.records.first { $0.id == sessionID })
            XCTAssertEqual(record.name, "Renamed Through Stamp", "Metadata via \(String(describing: workspace.customStoragePath))")
        }
    }

    // MARK: - Deletion

    func testTombstoneWriteFailureAbortsDeletionBeforeUnlinkOrPublication() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let created = try await create(service, name: "Kept", env: env)
        let sessionID = created.load.session.id
        let generation = await service.scheduledSendDeletionGeneration(for: created.fileURL)

        await service.test_setTombstoneWriteFailureInjector { _ in InjectedFailure() }
        do {
            try await service.deleteAgentSession(id: sessionID, for: env.workspace)
            XCTFail("Deletion must fail when its commit point cannot be written")
        } catch is InjectedFailure {
            // Expected.
        }
        await service.test_setTombstoneWriteFailureInjector(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.tombstoneURL(for: sessionID).path))
        let generationAfterFailure = await service.scheduledSendDeletionGeneration(for: created.fileURL)
        XCTAssertEqual(generationAfterFailure, generation)
        var renamed = created.load.session
        renamed.name = "Still Editable"
        renamed.lastRunState = "running"
        let commit = try await service.saveAgentSession(
            renamed,
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            fileCreationPolicy: .requireExisting,
            persistenceState: created.load.persistenceState
        )
        XCTAssertEqual(commit.disposition, .written)
        let rawBeforeDeletion = try await service.rawLastRunStateForAgentSession(id: sessionID, for: env.workspace)
        XCTAssertEqual(rawBeforeDeletion, "running")

        // Once the tombstone commits, residue left by a failed unlink is not read by ID either.
        await service.test_setAgentSessionDeletionFailureInjector { _ in InjectedFailure() }
        try await service.deleteAgentSession(id: sessionID, for: env.workspace)
        await service.test_setAgentSessionDeletionFailureInjector(nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.fileURL.path), "Residue remains")
        let rawAfterDeletion = try await service.rawLastRunStateForAgentSession(id: sessionID, for: env.workspace)
        XCTAssertNil(rawAfterDeletion)
    }

    func testUnlinkFailureAfterTombstoneKeepsDeletionEffectiveAcrossRestartListingsAndRecovery() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let fixture = try await makeDispatchingRecoveryFixture(service, env: env)
        let sessionID = fixture.load.session.id

        await service.test_setAgentSessionDeletionFailureInjector { _ in InjectedFailure() }
        try await service.deleteAgentSession(id: sessionID, for: env.workspace)
        await service.test_setAgentSessionDeletionFailureInjector(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path), "Residue remains")
        let residue = try Data(contentsOf: fixture.fileURL)
        let tombstone = try JSONDecoder().decode(
            AgentSessionDeletionTombstone.self,
            from: Data(contentsOf: env.tombstoneURL(for: sessionID))
        )
        XCTAssertEqual(tombstone, AgentSessionDeletionTombstone(sessionID: sessionID))

        let outcome = try await service.finalizeScheduledSend(recovery: fixture.requiredPayload)
        guard case .explicitlyDeleted = outcome else {
            return XCTFail("Recovery after a committed deletion is terminal")
        }

        let restarted = env.makeService()
        let files = try await restarted.listAgentSessions(for: env.workspace)
        XCTAssertFalse(files.contains { $0.lastPathComponent == fixture.fileURL.lastPathComponent })
        let metas = try await restarted.listAgentSessionsMeta(for: env.workspace)
        XCTAssertFalse(metas.contains { $0.id == sessionID })
        let loaded = try await restarted.loadAgentSession(id: sessionID, for: env.workspace)
        XCTAssertNil(loaded)
        // Optional editable/hydration lookups read a committed deletion as absence: no authority.
        let editable = try await restarted.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
        XCTAssertNil(editable)
        let hydrated = try await restarted.preparePersistedHydration(hydrationRequest(sessionID: sessionID, env: env))
        XCTAssertNil(hydrated)
        await assertThrows(.sessionDeleted(sessionID)) {
            _ = try await restarted.loadAgentSessionStub(from: fixture.fileURL)
        }
        // The UUID is retired in every workspace.
        await assertThrows(.sessionDeleted(sessionID)) {
            _ = try await restarted.prepareInitialAgentSessionPersistence(
                initialSession: AgentSession(id: sessionID, workspaceID: env.otherWorkspace.id, name: "Elsewhere"),
                for: env.otherWorkspace
            )
        }
        await assertThrows(.sessionDeleted(sessionID)) {
            _ = try await restarted.saveAgentSession(
                AgentSession(id: sessionID, workspaceID: env.otherWorkspace.id, name: "Elsewhere"),
                for: env.otherWorkspace
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), residue)

        // Repeated deletion retries cleanup and stays safe once the residue is gone.
        try await restarted.deleteAgentSession(id: sessionID, for: env.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        try await restarted.deleteAgentSession(id: sessionID, for: env.workspace)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentSessionDeletionTombstone.self, from: Data(contentsOf: env.tombstoneURL(for: sessionID))),
            tombstone
        )
    }

    func testUnreadableTombstoneFailsClosedAndIsNeverReplaced() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let creator = env.makeService()
        let created = try await create(creator, name: "Guarded", env: env)
        let sessionID = created.load.session.id
        let sessionBytes = try Data(contentsOf: created.fileURL)
        let tombstoneURL = env.tombstoneURL(for: sessionID)
        try FileManager.default.createDirectory(at: env.tombstoneRoot, withIntermediateDirectories: true)
        let unreadable = Data(#"{"schemaVersion": 2}"#.utf8)
        try unreadable.write(to: tombstoneURL)

        for service in [creator, env.makeService()] {
            await assertThrows(.unreadableTombstone(sessionID)) {
                _ = try await service.loadAgentSessionForEditing(id: sessionID, for: env.workspace)
            }
            await assertThrows(.unreadableTombstone(sessionID)) {
                _ = try await service.preparePersistedHydration(self.hydrationRequest(sessionID: sessionID, env: env))
            }
            let loaded = try await service.loadAgentSession(id: sessionID, for: env.workspace)
            XCTAssertNil(loaded)
            await assertThrows(.unreadableTombstone(sessionID)) {
                _ = try await service.saveAgentSession(
                    created.load.session,
                    for: env.workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: 0
                )
            }
            await assertThrows(.unreadableTombstone(sessionID)) {
                try await service.deleteAgentSession(id: sessionID, for: env.workspace)
            }
        }
        XCTAssertEqual(try Data(contentsOf: tombstoneURL), unreadable)
        XCTAssertEqual(try Data(contentsOf: created.fileURL), sessionBytes)
    }

    // MARK: - Rewrites preserve lifecycle

    func testScheduleMutationFinalizationAndHydrationPreserveLifecycle() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let fixture = try await makeDispatchingRecoveryFixture(service, env: env, prepareRecovery: false)
        let lifecycle = try XCTUnwrap(fixture.load.session.lifecycle?.lifecycle)

        _ = try await service.finalizeScheduledSend(
            sessionID: fixture.load.session.id,
            for: env.workspace,
            expectedUpdatedAt: fixture.schedule.updatedAt,
            expectedAttempt: fixture.attempt,
            acceptedUserItem: fixture.acceptedItem,
            receipt: fixture.receipt
        )
        XCTAssertEqual(try durableSession(at: fixture.fileURL).lifecycle, .v1(lifecycle))

        var next = makeSchedule()
        next.rawText = "Next"
        _ = try await service.mutateScheduledSend(
            sessionID: fixture.load.session.id,
            for: env.workspace,
            persistenceStamp: fixture.load.persistenceState.stamp,
            mutation: .upsert(expectedUpdatedAt: nil, value: next)
        )
        XCTAssertEqual(try durableSession(at: fixture.fileURL).lifecycle, .v1(lifecycle))

        let restarted = env.makeService()
        let prepared = try await restarted.preparePersistedHydration(AgentSessionHydrationRequest(
            workspace: env.workspace,
            tabID: UUID(),
            sessionID: fixture.load.session.id,
            resolvedDisplayName: "Hydrated",
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        ))
        XCTAssertEqual(prepared?.persistedSession.lifecycle, .v1(lifecycle))
        XCTAssertEqual(prepared?.persistenceState.stamp.incarnationID, lifecycle.incarnationID)
        XCTAssertEqual(try durableSession(at: fixture.fileURL).lifecycle, .v1(lifecycle))

        // A stamp issued for another session cannot drive this session's schedule CAS.
        let other = try await create(restarted, name: "Other", env: env)
        await assertThrows(.invalidPersistenceStamp) {
            _ = try await restarted.mutateScheduledSend(
                sessionID: fixture.load.session.id,
                for: env.workspace,
                persistenceStamp: other.load.persistenceState.stamp,
                mutation: .upsert(expectedUpdatedAt: next.updatedAt, value: next)
            )
        }
    }

    // MARK: - Recovery

    func testRecoveryAfterDurableResetCannotResurrectAcceptedItem() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()
        let fixture = try await makeDispatchingRecoveryFixture(service, env: env)
        let lifecycle = try XCTUnwrap(fixture.load.session.lifecycle?.lifecycle)
        let receipt = AgentSessionTranscriptResetReceipt(id: UUID())
        _ = try await service.saveAgentSession(
            fixture.load.session.withItems([]),
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            committingTranscriptReset: receipt,
            fileCreationPolicy: .requireExisting,
            persistenceState: fixture.load.persistenceState
        )

        let outcome = try await service.finalizeScheduledSend(recovery: fixture.requiredPayload)
        guard case .committed = outcome else {
            return XCTFail("Recovery settles the attempt on the existing incarnation")
        }
        let durable = try durableSession(at: fixture.fileURL)
        XCTAssertFalse(durable.toLiveItems().contains { $0.id == fixture.attempt.itemID })
        XCTAssertEqual(durable.lifecycle?.lifecycle?.incarnationID, lifecycle.incarnationID)
        XCTAssertEqual(durable.lifecycle?.lifecycle?.transcriptResetGeneration, 1)
        XCTAssertEqual(durable.lifecycle?.lifecycle?.lastTranscriptResetReceipt, receipt)
    }

    func testMissingFileRecoveryReconstructsOnlyWithSameProcessLifecycleAuthority() async throws {
        let env = makeEnvironment()
        defer { env.cleanup() }
        let service = env.makeService()

        let reconstructed = try await makeDispatchingRecoveryFixture(service, env: env)
        let lifecycle = try XCTUnwrap(reconstructed.load.session.lifecycle?.lifecycle)
        try FileManager.default.removeItem(at: reconstructed.fileURL)
        let outcome = try await service.finalizeScheduledSend(recovery: reconstructed.requiredPayload)
        guard case .committed = outcome else {
            return XCTFail("Same-process recovery reconstructs the accidentally missing file")
        }
        let durable = try durableSession(at: reconstructed.fileURL)
        XCTAssertEqual(durable.lifecycle, .v1(lifecycle))
        XCTAssertTrue(durable.toLiveItems().contains { $0.id == reconstructed.attempt.itemID })

        let unproven = try await makeDispatchingRecoveryFixture(service, env: env)
        try FileManager.default.removeItem(at: unproven.fileURL)
        // Key the seam by the destination the recovery context pinned (listing URLs may differ by symlink).
        try await service.test_forgetLifecycleAuthority(for: unproven.requiredPayload.context.fileURL)
        do {
            _ = try await service.finalizeScheduledSend(recovery: unproven.requiredPayload)
            XCTFail("Reconstruction without lifecycle authority must fail closed")
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendRecoveryError, .lifecycleAuthorityUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unproven.fileURL.path))
    }

    // MARK: - Fixtures

    private struct InjectedFailure: Error {}

    private struct LifecycleProbe: Decodable {
        let lifecycle: AgentScheduledSendJSONValue
    }

    private struct Environment {
        let root: URL
        let tombstoneRoot: URL
        let workspace: WorkspaceModel
        let otherWorkspace: WorkspaceModel

        func makeService() -> AgentSessionDataService {
            AgentSessionDataService(tombstoneRoot: tombstoneRoot)
        }

        func tombstoneURL(for sessionID: UUID) -> URL {
            tombstoneRoot.appendingPathComponent("\(sessionID.uuidString).json")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeEnvironment() -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLifecyclePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Environment(
            root: root,
            tombstoneRoot: root.appendingPathComponent("AgentRecovery/v1/tombstones", isDirectory: true),
            workspace: WorkspaceModel(
                name: "Lifecycle A",
                repoPaths: ["/tmp/repo"],
                customStoragePath: root.appendingPathComponent("workspace-a", isDirectory: true)
            ),
            otherWorkspace: WorkspaceModel(
                name: "Lifecycle B",
                repoPaths: ["/tmp/repo"],
                customStoragePath: root.appendingPathComponent("workspace-b", isDirectory: true)
            )
        )
    }

    private struct Created {
        let load: AgentSessionEditableLoad
        let fileURL: URL
    }

    private func create(
        _ service: AgentSessionDataService,
        id: UUID = UUID(),
        name: String,
        scheduledSend: AgentScheduledSendMember? = nil,
        env: Environment
    ) async throws -> Created {
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: AgentSession(id: id, workspaceID: env.workspace.id, name: name, scheduledSend: scheduledSend),
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let files = try await service.listAgentSessions(for: env.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(id.uuidString).json" })
        return Created(load: load, fileURL: fileURL)
    }

    private func createResult(
        _ service: AgentSessionDataService,
        id: UUID,
        name: String,
        env: Environment
    ) async -> Result<AgentSessionEditableLoad, Error> {
        do {
            return try await .success(service.prepareInitialAgentSessionPersistence(
                initialSession: AgentSession(id: id, workspaceID: env.workspace.id, name: name),
                for: env.workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            ))
        } catch {
            return .failure(error)
        }
    }

    private func assertExactlyOneCreator(
        _ results: [Result<AgentSessionEditableLoad, Error>],
        sessionID: UUID,
        env: Environment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var winners: [AgentSessionEditableLoad] = []
        for result in results {
            switch result {
            case let .success(load):
                winners.append(load)
            case let .failure(error):
                XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionAlreadyExists(sessionID), file: file, line: line)
            }
        }
        XCTAssertEqual(winners.count, 1, "Exactly one creator commits", file: file, line: line)
        let winner = try XCTUnwrap(winners.first, file: file, line: line)
        let fileURL = try XCTUnwrap(env.workspace.customStoragePath)
        let sessions = try FileManager.default.subpathsOfDirectory(atPath: fileURL.path)
            .filter { $0.hasSuffix("AgentSession-\(sessionID.uuidString).json") }
        XCTAssertEqual(sessions.count, 1, file: file, line: line)
        let durable = try durableSession(at: fileURL.appendingPathComponent(XCTUnwrap(sessions.first)))
        XCTAssertEqual(durable.lifecycle?.lifecycle?.incarnationID, winner.persistenceState.stamp.incarnationID, file: file, line: line)
        XCTAssertEqual(durable.name, winner.session.name, file: file, line: line)
    }

    private struct DispatchingFixture {
        let load: AgentSessionEditableLoad
        let fileURL: URL
        let schedule: AgentScheduledSendPersist
        let attempt: AgentScheduledSendPersist.Attempt
        let acceptedItem: AgentChatItem
        let receipt: AgentScheduledSendProvenance
        let payload: AgentScheduledSendAcceptedPayload?

        var requiredPayload: AgentScheduledSendAcceptedPayload {
            get throws { try XCTUnwrap(payload) }
        }
    }

    private func makeDispatchingRecoveryFixture(
        _ service: AgentSessionDataService,
        env: Environment,
        prepareRecovery: Bool = true
    ) async throws -> DispatchingFixture {
        var schedule = makeSchedule()
        let attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: UUID(),
            startedAt: schedule.notBefore.addingTimeInterval(1)
        )
        schedule.state = .dispatching
        schedule.attempt = attempt
        schedule.updatedAt = attempt.startedAt
        let created = try await create(service, name: "Dispatching", scheduledSend: .v1(schedule), env: env)
        let receipt = AgentScheduledSendProvenance(
            scheduleID: schedule.id,
            attemptID: attempt.attemptID,
            scheduledFor: schedule.notBefore,
            sentAt: schedule.notBefore.addingTimeInterval(30)
        )
        var acceptedItem = AgentChatItem.user(schedule.rawText, id: attempt.itemID, sequenceIndex: 0)
        acceptedItem.scheduledSend = receipt
        var payload: AgentScheduledSendAcceptedPayload?
        if prepareRecovery {
            let context = try await service.prepareScheduledSendRecovery(
                sessionID: created.load.session.id,
                for: env.workspace,
                persistenceStamp: created.load.persistenceState.stamp,
                expectedUpdatedAt: schedule.updatedAt,
                expectedAttempt: attempt
            )
            payload = AgentScheduledSendAcceptedPayload(
                context: context,
                attempt: attempt,
                receipt: receipt,
                acceptedItem: acceptedItem,
                expectedUpdatedAt: schedule.updatedAt
            )
        }
        return DispatchingFixture(
            load: created.load,
            fileURL: created.fileURL,
            schedule: schedule,
            attempt: attempt,
            acceptedItem: acceptedItem,
            receipt: receipt,
            payload: payload
        )
    }

    private func makeSchedule() -> AgentScheduledSendPersist {
        let createdAt = Date(timeIntervalSinceReferenceDate: 1000)
        return AgentScheduledSendPersist(
            id: UUID(),
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(10),
            notBefore: createdAt.addingTimeInterval(900),
            state: .scheduled,
            confirmationReason: nil,
            rawText: "A scheduled message",
            attachments: [],
            taggedFileAttachments: [],
            workflow: nil,
            interviewFirst: true,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )
    }

    private func sessionJSON(id: UUID, version: Int?, name: String = "Raw", lifecycle: String? = nil) -> Data {
        let versionMember = version.map { #", "serializationVersion": \#($0)"# } ?? ""
        let lifecycleMember = lifecycle.map { #", "lifecycle": \#($0)"# } ?? ""
        return Data(
            #"{"id": "\#(id.uuidString)"\#(versionMember), "name": "\#(name)", "savedAt": 0, "autoEditEnabled": true\#(lifecycleMember)}"#.utf8
        )
    }

    private func decodeLifecycle(_ lifecycleJSON: String?, sessionID: UUID) throws -> AgentSessionLifecycleMember? {
        try AgentSessionDataCodec.decodeSession(from: sessionJSON(id: sessionID, version: 7, lifecycle: lifecycleJSON)).lifecycle
    }

    /// Seeds a session file through a throwaway service on the same roots, then replaces its bytes.
    /// Callers use a fresh service so no process-local authority describes the replaced bytes.
    private func installRawSession(_ data: Data, id: UUID, env: Environment) async throws -> URL {
        let seeding = env.makeService()
        let fileURL = try await seeding.saveAgentSession(
            AgentSession(id: id, workspaceID: env.workspace.id, name: "Seed"),
            for: env.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func hydrationRequest(sessionID: UUID, env: Environment) -> AgentSessionHydrationRequest {
        AgentSessionHydrationRequest(
            workspace: env.workspace,
            tabID: UUID(),
            sessionID: sessionID,
            resolvedDisplayName: "Hydrated",
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
    }

    /// The typed mutation error, directly or wrapped as a load failure.
    private func mutationError(_ error: Error) -> AgentScheduledSendMutationError? {
        if let typed = error as? AgentScheduledSendMutationError {
            return typed
        }
        if case let .loadFailed(inner)? = error as? AgentSessionDataError {
            return inner as? AgentScheduledSendMutationError
        }
        return nil
    }

    private func durableSession(at fileURL: URL) throws -> AgentSession {
        try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: fileURL))
    }

    private func assertThrows(
        _ expected: AgentScheduledSendMutationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendMutationError, expected, file: file, line: line)
        }
    }
}
