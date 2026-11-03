@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentScheduledSendPersistenceTests: XCTestCase {
    func testV1SessionRoundTripStaysVersionSevenAndOmitsNilMembers() throws {
        let schedule = makeSchedule()
        let provenance = makeProvenance(schedule: schedule)
        let session = AgentSession(
            id: UUID(),
            name: "Scheduled",
            scheduledSend: .v1(schedule),
            lastScheduledDispatch: provenance
        )

        let data = try AgentSessionDataCodec.encodeSession(session)
        let decoded = try AgentSessionDataCodec.decodeSession(from: data)

        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.scheduledSend, .v1(schedule))
        XCTAssertEqual(decoded.lastScheduledDispatch, provenance)

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(#""confirmationReason""#))
        XCTAssertFalse(text.contains(#""firstEligibleAt""#))
        XCTAssertFalse(text.contains(#""attempt""#))
        XCTAssertFalse(text.contains(#""lastFailureMessage""#))
    }

    func testLegacySessionWithoutScheduledSendFieldsDecodesAsNil() throws {
        let sessionID = UUID()
        let data = Data(
            """
            {
              "id": "\(sessionID.uuidString)",
              "serializationVersion": 7,
              "name": "Legacy",
              "savedAt": 0,
              "autoEditEnabled": true
            }
            """.utf8
        )

        let session = try AgentSessionDataCodec.decodeSession(from: data)

        XCTAssertEqual(session.serializationVersion, 7)
        XCTAssertNil(session.scheduledSend)
        XCTAssertNil(session.lastScheduledDispatch)
    }

    func testMalformedScheduledSendBecomesUnreadableAndIsReemittedSemantically() throws {
        let sessionID = UUID()
        let data = Data(
            """
            {
              "id": "\(sessionID.uuidString)",
              "serializationVersion": 7,
              "name": "Unreadable",
              "savedAt": 0,
              "autoEditEnabled": true,
              "scheduledSend": {
                "schemaVersion": 2,
                "rawText": 7,
                "future": {"nested": [1, true, null]}
              }
            }
            """.utf8
        )

        let session = try AgentSessionDataCodec.decodeSession(from: data)
        guard case let .unreadable(originalJSON)? = session.scheduledSend else {
            return XCTFail("Malformed/future scheduled send must remain unreadable")
        }

        let encoded = try AgentSessionDataCodec.encodeSession(session)
        let probe = try JSONDecoder().decode(ScheduledSendProbe.self, from: encoded)
        XCTAssertEqual(probe.scheduledSend, originalJSON)
    }

    func testOtherwiseValidMemberWithUnknownFieldStaysUnreadableAndPreserved() throws {
        let schedule = makeSchedule()
        let encoded = try AgentSessionDataCodec.encodeSession(
            AgentSession(id: UUID(), name: "Future Field", scheduledSend: .v1(schedule))
        )
        let original = String(decoding: encoded, as: UTF8.self)
        let mutated = original.replacingOccurrences(
            of: #""scheduledSend":{"#,
            with: #""scheduledSend":{"futureField":{"nested":true},"#
        )
        XCTAssertNotEqual(mutated, original)

        let expected = try JSONDecoder().decode(ScheduledSendProbe.self, from: Data(mutated.utf8))
        let decoded = try AgentSessionDataCodec.decodeSession(from: Data(mutated.utf8))
        guard case .unreadable = decoded.scheduledSend else {
            return XCTFail("A future field must not be silently narrowed into the v1 record")
        }

        let reencoded = try AgentSessionDataCodec.encodeSession(decoded)
        let actual = try JSONDecoder().decode(ScheduledSendProbe.self, from: reencoded)
        XCTAssertEqual(actual.scheduledSend, expected.scheduledSend)
    }

    func testUnknownStateNormalizesToNeedsConfirmationWithoutMakingMemberUnreadable() throws {
        let schedule = makeSchedule()
        let data = try AgentSessionDataCodec.encodeSession(
            AgentSession(id: UUID(), name: "Unknown State", scheduledSend: .v1(schedule))
        )
        let original = String(decoding: data, as: UTF8.self)
        let mutated = original.replacingOccurrences(
            of: #""state":"scheduled""#,
            with: #""state":"futureState""#
        )
        XCTAssertNotEqual(mutated, original)

        let decoded = try AgentSessionDataCodec.decodeSession(from: Data(mutated.utf8))

        guard case let .v1(value)? = decoded.scheduledSend else {
            return XCTFail("An unknown state must remain a typed record requiring confirmation")
        }
        XCTAssertEqual(value.state, .needsConfirmation)

        let reencoded = try String(decoding: AgentSessionDataCodec.encodeSession(decoded), as: UTF8.self)
        XCTAssertTrue(reencoded.contains(#""state":"needsConfirmation""#))
        XCTAssertFalse(reencoded.contains("futureState"))
    }

    func testStubHeaderAndListStubRetainScheduledSendFields() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let schedule = makeSchedule()
        let provenance = makeProvenance(schedule: schedule)
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Stub",
            itemCount: 0,
            scheduledSend: .v1(schedule),
            lastScheduledDispatch: provenance
        )

        let inMemoryStub = session.listStub()
        XCTAssertEqual(inMemoryStub.scheduledSend, .v1(schedule))
        XCTAssertEqual(inMemoryStub.lastScheduledDispatch, provenance)

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let diskStub = try await service.loadAgentSessionStub(from: fileURL)

        XCTAssertTrue(diskStub.isListStub)
        XCTAssertEqual(diskStub.scheduledSend, .v1(schedule))
        XCTAssertEqual(diskStub.lastScheduledDispatch, provenance)
    }

    func testSchemaSixIndexIsInvalidatedAndRebuiltFromScheduleAwareStubs() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let schedule = makeSchedule()
        let receipt = makeProvenance(schedule: schedule)
        let pending = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Pending",
            itemCount: 0,
            scheduledSend: .v1(schedule)
        )
        let unreadable = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Unreadable",
            itemCount: 0,
            scheduledSend: .unreadable(.object(["future": .bool(true)]))
        )
        let historical = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Historical",
            itemCount: 0,
            lastScheduledDispatch: receipt
        )
        var indexURL: URL?
        for session in [pending, unreadable, historical] {
            let fileURL = try await service.saveAgentSession(
                session,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
            indexURL = fileURL.deletingLastPathComponent().appendingPathComponent("AgentSessionIndex.json")
        }
        let indexFile = try XCTUnwrap(indexURL)
        let staleIndex = AgentSessionMetadataIndex(schemaVersion: 6, entries: [])
        try JSONEncoder().encode(staleIndex).write(to: indexFile, options: .atomic)

        let freshService = AgentSessionDataService()
        let staleFastResult = try await freshService.fastMetadataRecordsIfAvailable(for: workspace)
        XCTAssertNil(staleFastResult)
        let rebuilt = try await freshService.indexedAgentSessionMetadataRecords(for: workspace)
        XCTAssertEqual(rebuilt.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.id, $0) })
        XCTAssertEqual(byID[pending.id]?.scheduledSendSummary?.id, schedule.id)
        XCTAssertEqual(byID[pending.id]?.scheduledSendSummary?.previewText, schedule.rawText)
        XCTAssertTrue(try XCTUnwrap(byID[unreadable.id]).hasUnreadableScheduledSend)
        XCTAssertEqual(byID[historical.id]?.lastScheduledDispatch, receipt)
        XCTAssertNil(byID[historical.id]?.scheduledSendSummary)
        XCTAssertEqual(try XCTUnwrap(byID[pending.id]).sidebarEntry()?.scheduledSendSummary?.id, schedule.id)
        XCTAssertTrue(try XCTUnwrap(byID[unreadable.id]).sidebarEntry()?.hasUnreadableScheduledSend == true)
        XCTAssertEqual(try XCTUnwrap(byID[historical.id]).sidebarEntry()?.lastScheduledDispatch, receipt)

        let rewritten = try JSONDecoder().decode(
            AgentSessionMetadataIndex.self,
            from: Data(contentsOf: indexFile)
        )
        // Phase 2 schema 8 (bounded recovery hint); a schema-6 index is still rebuilt.
        XCTAssertEqual(rewritten.schemaVersion, 8)
        XCTAssertEqual(rewritten.entries.count, 3)
    }

    func testStaleFullSessionSavePreservesNewerScheduleWhileSavingUnrelatedState() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let originalSchedule = makeSchedule()
        var staleSession = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Before",
            scheduledSend: .v1(originalSchedule)
        )
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        staleSession = try await carryingLoadedLifecycle(staleSession, service: service, workspace: workspace)

        var newerSchedule = originalSchedule
        newerSchedule.updatedAt = originalSchedule.updatedAt.addingTimeInterval(60)
        newerSchedule.notBefore = originalSchedule.notBefore.addingTimeInterval(600)
        newerSchedule.rawText = "Newer scheduled message"
        _ = try await service.mutateScheduledSend(
            sessionID: staleSession.id,
            for: workspace,
            mutation: .upsert(expectedUpdatedAt: originalSchedule.updatedAt, value: newerSchedule)
        )

        staleSession.name = "Saved VM State"
        staleSession.scheduledSend = .v1(originalSchedule)
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let loaded = try await service.loadAgentSession(id: staleSession.id, for: workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.name, "Saved VM State")
        XCTAssertEqual(reloaded.scheduledSend, .v1(newerSchedule))
    }

    func testStaleFullSessionSaveCannotResurrectCancelledSchedule() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let schedule = makeSchedule()
        var staleSession = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Before Clear",
            scheduledSend: .v1(schedule)
        )
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        staleSession = try await carryingLoadedLifecycle(staleSession, service: service, workspace: workspace)

        _ = try await service.mutateScheduledSend(
            sessionID: staleSession.id,
            for: workspace,
            mutation: .clear(expectedUpdatedAt: schedule.updatedAt, completedDispatch: nil)
        )

        staleSession.name = "After Clear"
        staleSession.scheduledSend = .v1(schedule)
        staleSession.lastScheduledDispatch = nil
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let loaded = try await service.loadAgentSession(id: staleSession.id, for: workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.name, "After Clear")
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertNil(reloaded.lastScheduledDispatch)
    }

    func testProvenanceRoundTripsThroughChatPersistenceAndBothTranscriptShapes() throws {
        let schedule = makeSchedule()
        let provenance = makeProvenance(schedule: schedule)
        let itemID = UUID()
        let item = AgentChatItem.user(
            "send later",
            id: itemID,
            sequenceIndex: 4,
            scheduledSend: provenance
        )

        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.scheduledSend, provenance)

        let persisted = AgentChatItemPersist(from: item, sanitizeToolResults: false)
        let persistedRoundTrip = try JSONDecoder().decode(
            AgentChatItemPersist.self,
            from: JSONEncoder().encode(persisted)
        )
        XCTAssertEqual(persistedRoundTrip.scheduledSend, provenance)
        XCTAssertEqual(persistedRoundTrip.toItem().scheduledSend, provenance)

        let activity = AgentTranscriptActivity(from: item)
        let activityRoundTrip = try JSONDecoder().decode(
            AgentTranscriptActivity.self,
            from: JSONEncoder().encode(activity)
        )
        XCTAssertEqual(activityRoundTrip.scheduledSend, provenance)
        XCTAssertEqual(activityRoundTrip.toItem().scheduledSend, provenance)

        let requestAnchor = AgentTranscriptRequestAnchor(from: item)
        let anchorRoundTrip = try JSONDecoder().decode(
            AgentTranscriptRequestAnchor.self,
            from: JSONEncoder().encode(requestAnchor)
        )
        XCTAssertEqual(anchorRoundTrip.scheduledSend, provenance)
        XCTAssertEqual(anchorRoundTrip.toItem().scheduledSend, provenance)
    }

    func testExpectedUpdatedAtMutationRejectsStaleEditAndClearsMatchingSchedule() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let session = AgentSession(id: UUID(), workspaceID: workspace.id, name: "Mutation")
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let schedule = makeSchedule()
        let inserted = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .upsert(expectedUpdatedAt: nil, value: schedule)
        )
        XCTAssertEqual(inserted.metadataIndexStatus, .updated)
        XCTAssertEqual(inserted.session.scheduledSend, .v1(schedule))

        do {
            _ = try await service.mutateScheduledSend(
                sessionID: session.id,
                for: workspace,
                mutation: .upsert(expectedUpdatedAt: nil, value: schedule)
            )
            XCTFail("Expected a stale creation to be rejected")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleExpectedUpdatedAt(expected: nil, actual: schedule.updatedAt)
            )
        }

        let cleared = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .clear(expectedUpdatedAt: schedule.updatedAt, completedDispatch: nil)
        )
        XCTAssertNil(cleared.session.scheduledSend)
        XCTAssertNil(cleared.session.lastScheduledDispatch)

        let reloaded = try await service.loadAgentSession(from: cleared.fileURL)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertNil(reloaded.lastScheduledDispatch)
    }

    func testMutationReportsPostCommitMetadataIndexFailureAsRepairNeeded() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let session = AgentSession(id: UUID(), workspaceID: workspace.id, name: "Index Failure")
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let indexURL = fileURL.deletingLastPathComponent().appendingPathComponent("AgentSessionIndex.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)

        let schedule = makeSchedule()
        let result = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .upsert(expectedUpdatedAt: nil, value: schedule)
        )

        guard case .repairNeeded = result.metadataIndexStatus else {
            return XCTFail("A post-commit index failure must not be reported as a session-save failure")
        }
        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(reloaded.scheduledSend, .v1(schedule))
    }

    func testFinalizeAtomicallyPersistsAcceptedItemProvenanceReceiptAndRemovalBeforeDebounce() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Finalize",
            scheduledSend: .v1(schedule)
        )
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)

        let finalized = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        XCTAssertNil(finalized.session.scheduledSend)
        XCTAssertEqual(finalized.session.lastScheduledDispatch, receipt)

        // A matching persistence retry is idempotent and must not append another user item.
        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let loaded = try await service.loadAgentSession(id: session.id, for: workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertEqual(reloaded.itemCount, 1)
        let matchingItems = reloaded.toLiveItems().filter { $0.id == attempt.itemID }
        XCTAssertEqual(matchingItems.count, 1)
        XCTAssertEqual(matchingItems.first?.scheduledSend, receipt)
        XCTAssertEqual(matchingItems.first?.text, schedule.rawText)
    }

    func testStaleFullSaveCannotDropFinalizedItemOrScheduledMarker() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        var staleSession = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Before Acceptance",
            scheduledSend: .v1(schedule)
        )
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        staleSession = try await carryingLoadedLifecycle(staleSession, service: service, workspace: workspace)
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        _ = try await service.finalizeScheduledSend(
            sessionID: staleSession.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        // Simulates a VM snapshot captured before append/acceptance and queued behind finalization.
        staleSession.name = "Stale Save Completed"
        _ = try await service.saveAgentSession(
            staleSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let loaded = try await service.loadAgentSession(id: staleSession.id, for: workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.name, "Stale Save Completed")
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertEqual(reloaded.itemCount, 1)
        let matchingItems = reloaded.toLiveItems().filter { $0.id == attempt.itemID }
        XCTAssertEqual(matchingItems.count, 1)
        XCTAssertEqual(matchingItems.first?.scheduledSend, receipt)
    }

    func testFinalizeAttemptMismatchLeavesDispatchingRecordAndItemUnchanged() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, persistedAttempt) = makeDispatchingSchedule()
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Finalize Failure",
            scheduledSend: .v1(schedule)
        )
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let wrongAttempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: persistedAttempt.itemID,
            startedAt: persistedAttempt.startedAt
        )
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: wrongAttempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: wrongAttempt)

        do {
            _ = try await service.finalizeScheduledSend(
                sessionID: session.id,
                for: workspace,
                expectedUpdatedAt: schedule.updatedAt,
                expectedAttempt: wrongAttempt,
                acceptedUserItem: acceptedItem,
                receipt: receipt
            )
            XCTFail("Expected an immutable attempt mismatch")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleExpectedAttempt(expected: wrongAttempt, actual: persistedAttempt)
            )
        }

        let loaded = try await service.loadAgentSession(id: session.id, for: workspace)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.scheduledSend, .v1(schedule))
        XCTAssertNil(reloaded.lastScheduledDispatch)
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == persistedAttempt.itemID })
    }

    func testFinalizeStampedItemWithSameAttemptAtNewerRevisionRetiresSchedule() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        var session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Stamped Before Finalization",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        session = try await carryingLoadedLifecycle(session, service: service, workspace: workspace)
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        var stampedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        stampedItem.scheduledSend = receipt
        _ = try await service.saveAgentSession(
            session.withItems([stampedItem]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )

        var newerRevision = schedule
        newerRevision.updatedAt = schedule.updatedAt.addingTimeInterval(1)
        _ = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .upsert(expectedUpdatedAt: schedule.updatedAt, value: newerRevision)
        )

        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: stampedItem,
            receipt: receipt
        )

        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertEqual(
            reloaded.toLiveItems().count(where: {
                $0.id == attempt.itemID && $0.scheduledSend == receipt
            }),
            1
        )
    }

    func testFinalizePreservesDifferentSuccessorWhileCompletingAcceptedTurn() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Successor",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        var successor = makeSchedule()
        successor.updatedAt = schedule.updatedAt.addingTimeInterval(1)
        _ = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .upsert(expectedUpdatedAt: schedule.updatedAt, value: successor)
        )

        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(reloaded.scheduledSend, .v1(successor))
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertEqual(
            reloaded.toLiveItems().count(where: {
                $0.id == attempt.itemID && $0.scheduledSend == receipt
            }),
            1
        )
    }

    func testFinalizeRepairsReceiptOnlyStateWithAcceptedItem() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Receipt Only",
            lastScheduledDispatch: receipt
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )

        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertEqual(
            reloaded.toLiveItems().count(where: {
                $0.id == attempt.itemID && $0.scheduledSend == receipt
            }),
            1
        )
    }

    func testIntentionalFinalizedItemRemovalIsExactAndCannotBeResurrected() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        var stalePreAcceptance = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Before Acceptance",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            stalePreAcceptance,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        stalePreAcceptance = try await carryingLoadedLifecycle(stalePreAcceptance, service: service, workspace: workspace)
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        _ = try await service.finalizeScheduledSend(
            sessionID: stalePreAcceptance.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let postFinalizationSnapshot = try await service.loadAgentSession(from: fileURL)
        _ = try await service.saveAgentSession(
            postFinalizationSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: postFinalizationSnapshot.itemCount
        )

        // Protection survives a post-finalization save and still repairs an older queued snapshot.
        stalePreAcceptance.name = "Older Save"
        _ = try await service.saveAgentSession(
            stalePreAcceptance,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let protectedReload = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(
            protectedReload.toLiveItems().count(where: { $0.id == attempt.itemID }),
            1
        )

        let removalSession = protectedReload.withItems([])
        let wrongReceipt = AgentScheduledSendProvenance(
            scheduleID: receipt.scheduleID,
            attemptID: UUID(),
            scheduledFor: receipt.scheduledFor,
            sentAt: receipt.sentAt
        )
        do {
            _ = try await service.saveAgentSession(
                removalSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                intentionallyRemovingFinalizedScheduledSendItems: [
                    AgentScheduledSendFinalizedItemRemoval(
                        itemID: attempt.itemID,
                        receipt: wrongReceipt
                    )
                ]
            )
            XCTFail("A stale finalized-item identity must not authorize removal")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleExpectedFinalizedItem(
                    itemID: attempt.itemID,
                    expected: wrongReceipt,
                    actual: receipt
                )
            )
        }

        _ = try await service.saveAgentSession(
            removalSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: attempt.itemID,
                    receipt: receipt
                )
            ]
        )
        let removedReload = try await service.loadAgentSession(from: fileURL)
        XCTAssertFalse(removedReload.toLiveItems().contains { $0.id == attempt.itemID })

        // A stale post-finalization snapshot cannot resurrect an explicitly removed item.
        _ = try await service.saveAgentSession(
            postFinalizationSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: postFinalizationSnapshot.itemCount
        )
        let finalReload = try await service.loadAgentSession(from: fileURL)
        XCTAssertFalse(finalReload.toLiveItems().contains { $0.id == attempt.itemID })
    }

    func testMatchingFinalizationRetryAfterExactRemovalPreservesTombstone() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Finalize Then Reset",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let finalizedSnapshot = try await service.loadAgentSession(from: fileURL)
        _ = try await service.saveAgentSession(
            finalizedSnapshot.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: attempt.itemID,
                    receipt: receipt
                )
            ]
        )

        // A persistence-only retry must settle successfully without revoking the reset.
        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )
        let afterRetry = try await service.loadAgentSession(from: fileURL)
        XCTAssertNil(afterRetry.scheduledSend)
        XCTAssertEqual(afterRetry.lastScheduledDispatch, receipt)
        XCTAssertFalse(afterRetry.toLiveItems().contains { $0.id == attempt.itemID })

        // The retry must also leave the tombstone authoritative for later stale ordinary saves.
        _ = try await service.saveAgentSession(
            finalizedSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: finalizedSnapshot.itemCount
        )
        let finalReload = try await service.loadAgentSession(from: fileURL)
        XCTAssertNil(finalReload.scheduledSend)
        XCTAssertEqual(finalReload.lastScheduledDispatch, receipt)
        XCTAssertFalse(finalReload.toLiveItems().contains { $0.id == attempt.itemID })
    }

    func testFirstSuccessfulFinalizationAfterResetRetiresAttemptWithoutRestoringItem() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        var session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Reset Before Retry",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        session = try await carryingLoadedLifecycle(session, service: service, workspace: workspace)
        let acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: 0
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)

        // Models the durable boundary after an initial finalization write failed: the
        // dispatching attempt remains on disk, while reset commits the exact local marker.
        _ = try await service.saveAgentSession(
            session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: attempt.itemID,
                    receipt: receipt
                )
            ]
        )
        let afterReset = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(afterReset.scheduledSend, .v1(schedule))
        XCTAssertNil(afterReset.lastScheduledDispatch)
        XCTAssertFalse(afterReset.toLiveItems().contains { $0.id == attempt.itemID })

        _ = try await service.finalizeScheduledSend(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, receipt)
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == attempt.itemID })
    }

    func testRecoveryPreparedBeforeDeleteSettlesAsDeletedAndSessionIDCannotBeRecreated() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Original Incarnation"
        )
        try await service.deleteAgentSession(id: fixture.session.id, for: workspace)

        let replacementItem = AgentChatItem.user("Replacement history", sequenceIndex: 0)
        let replacement = AgentSession(
            id: fixture.session.id,
            workspaceID: workspace.id,
            name: "Replacement Incarnation"
        ).withItems([replacementItem])
        do {
            _ = try await service.saveAgentSession(
                replacement,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            XCTFail("A tombstoned session UUID must not be recreated")
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionDeleted(fixture.session.id))
        }

        let outcome = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .explicitlyDeleted = outcome else {
            return XCTFail("Old recovery must settle as explicitly deleted")
        }
        let loaded = try await service.loadAgentSession(
            id: fixture.session.id,
            for: workspace
        )
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testRecoveryFinalizationBeforeDeleteRemainsTerminatedByDeletion() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Finalize Before Delete"
        )
        let firstOutcome = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = firstOutcome else {
            return XCTFail("Expected recovery to commit before deletion")
        }

        try await service.deleteAgentSession(id: fixture.session.id, for: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))

        let lateRetry = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .explicitlyDeleted = lateRetry else {
            return XCTFail("Deletion must remain terminal for a late retry")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testMissingFileRecoveryUsesCommittedResetSnapshotAndAllRemovalAuthority() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let unscheduledHistory = AgentChatItem.user(
            "Unscheduled history removed by reset",
            sequenceIndex: 0
        )
        let priorSchedule = makeSchedule()
        let priorReceipt = makeProvenance(schedule: priorSchedule)
        var priorScheduledItem = AgentChatItem.user(
            "Earlier finalized scheduled item",
            id: UUID(),
            sequenceIndex: 1
        )
        priorScheduledItem.scheduledSend = priorReceipt

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Reset Before Loss",
            priorItems: [unscheduledHistory, priorScheduledItem]
        )
        let resetReceipt = AgentSessionTranscriptResetReceipt(id: UUID())
        // Resets commit only through editable persistence-state authority.
        let loadedEditable = try await service.loadAgentSessionForEditing(id: fixture.session.id, for: workspace)
        let editable = try XCTUnwrap(loadedEditable)
        _ = try await service.saveAgentSession(
            fixture.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: priorScheduledItem.id,
                    receipt: priorReceipt
                ),
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: fixture.attempt.itemID,
                    receipt: fixture.receipt
                )
            ],
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: .requireExisting,
            persistenceState: editable.persistenceState
        )

        // External loss is not an explicit deletion: generation and reset authority remain.
        try FileManager.default.removeItem(at: fixture.fileURL)
        let outcome = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = outcome else {
            return XCTFail("Accidental loss should reconstruct from the committed reset")
        }

        let loaded = try await service.loadAgentSession(
            id: fixture.session.id,
            for: workspace
        )
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, fixture.receipt)
        XCTAssertTrue(reloaded.toLiveItems().isEmpty)
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == unscheduledHistory.id })
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == priorScheduledItem.id })
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == fixture.attempt.itemID })
    }

    func testRequireExistingSaveDoesNotRecreateExplicitlyDeletedSession() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Creation Policy"
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        try await service.deleteAgentSession(id: session.id, for: workspace)

        do {
            _ = try await service.saveAgentSession(
                session,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                fileCreationPolicy: .requireExisting
            )
            XCTFail("An existing-incarnation save must not recreate an explicitly deleted file")
        } catch {
            // Durable deletion evidence is reported before file absence.
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .sessionDeleted(session.id)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // `.createIfMissing` never overrides the durable tombstone.
        do {
            _ = try await service.saveAgentSession(
                session,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                fileCreationPolicy: .createIfMissing
            )
            XCTFail("A tombstoned session UUID must not be recreated by a compatibility save")
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionDeleted(session.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCommittedResetIgnoresStaleRemovalWithoutPoisoningLaterSaves() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Stale Reset Removal"
        )
        let outcome = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = outcome else {
            return XCTFail("Expected accepted item to finalize before reset")
        }
        let loadedFinalized = try await service.loadAgentSession(
            id: fixture.session.id,
            for: workspace
        )
        let finalized = try XCTUnwrap(loadedFinalized)
        let staleReceipt = AgentScheduledSendProvenance(
            scheduleID: fixture.receipt.scheduleID,
            attemptID: UUID(),
            scheduledFor: fixture.receipt.scheduledFor,
            sentAt: fixture.receipt.sentAt
        )

        let loadedEditable = try await service.loadAgentSessionForEditing(id: fixture.session.id, for: workspace)
        let editable = try XCTUnwrap(loadedEditable)
        _ = try await service.saveAgentSession(
            finalized.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [
                AgentScheduledSendFinalizedItemRemoval(
                    itemID: fixture.attempt.itemID,
                    receipt: staleReceipt
                )
            ],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: editable.persistenceState
        )

        let loadedAfterReset = try await service.loadAgentSession(
            id: fixture.session.id,
            for: workspace
        )
        let afterReset = try XCTUnwrap(loadedAfterReset)
        // The stale marker does not block the reset: reset authority independently converts
        // the absent protected item into its exact current tombstone.
        XCTAssertFalse(afterReset.toLiveItems().contains { $0.id == fixture.attempt.itemID })

        // The ignored stale marker is not retained and cannot poison later saves.
        _ = try await service.saveAgentSession(
            afterReset,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: afterReset.itemCount,
            fileCreationPolicy: .requireExisting
        )
    }

    func testCapturedLifetimeFencesStaleFullAndScheduledWritesAfterSameIDReplacement() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let sessionID = UUID()
        let originalSchedule = makeSchedule()
        let original = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Original Lifetime",
            scheduledSend: .v1(originalSchedule)
        )
        let initialLoad = try await service.prepareInitialAgentSessionPersistence(
            initialSession: original,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let originalCommit = try await service.saveAgentSession(
            original,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            persistenceState: initialLoad.persistenceState
        )

        try await service.deleteAgentSession(id: sessionID, for: workspace)

        // Same-ID replacement is refused: the durable tombstone retires the UUID permanently.
        let replacementSchedule = makeSchedule()
        let replacementItem = AgentChatItem.user("Replacement", sequenceIndex: 0)
        let replacement = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Replacement Lifetime",
            scheduledSend: .v1(replacementSchedule)
        ).withItems([replacementItem])
        do {
            _ = try await service.prepareInitialAgentSessionPersistence(
                initialSession: replacement,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            XCTFail("A tombstoned session UUID must not be recreated")
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionDeleted(sessionID))
        }

        do {
            _ = try await service.saveAgentSession(
                original,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0,
                fileCreationPolicy: .requireExisting,
                persistenceState: originalCommit.persistenceState
            )
            XCTFail("A stale full save must not mutate the replacement lifetime")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleDeletionGeneration(expected: 0, actual: 1)
            )
        }

        do {
            _ = try await service.mutateScheduledSend(
                sessionID: sessionID,
                for: workspace,
                persistenceStamp: originalCommit.persistenceState.stamp,
                mutation: .clear(
                    expectedUpdatedAt: replacementSchedule.updatedAt,
                    completedDispatch: nil
                )
            )
            XCTFail("A stale schedule mutation must not mutate the replacement lifetime")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleDeletionGeneration(expected: 0, actual: 1)
            )
        }

        let loaded = try await service.loadAgentSession(
            id: sessionID,
            for: workspace
        )
        XCTAssertNil(loaded, "Neither the stale owner nor a replacement recreated the deleted session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalCommit.fileURL.path))
    }

    func testResetWithoutVisibleMarkersRemovesProtectedItemAndRecoveryCannotRestoreIt() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Protected Item Reset Without Markers"
        )
        let finalized = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = finalized else {
            return XCTFail("Expected accepted item finalization")
        }
        let loadedEditable = try await service.loadAgentSessionForEditing(
            id: fixture.session.id,
            for: workspace
        )
        let editable = try XCTUnwrap(loadedEditable)
        XCTAssertTrue(editable.session.toLiveItems().contains { $0.id == fixture.attempt.itemID })

        let resetCommit = try await service.saveAgentSession(
            editable.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: editable.persistenceState
        )
        XCTAssertEqual(resetCommit.disposition, .written)
        let afterReset = try await service.loadAgentSession(from: resetCommit.fileURL)
        XCTAssertFalse(afterReset.toLiveItems().contains { $0.id == fixture.attempt.itemID })

        try FileManager.default.removeItem(at: fixture.fileURL)
        let retry = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = retry else {
            return XCTFail("Expected missing-file recovery from the committed reset")
        }
        let reloaded = try await service.loadAgentSession(from: fixture.fileURL)
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == fixture.attempt.itemID })
        XCTAssertEqual(reloaded.lastScheduledDispatch, fixture.receipt)
    }

    func testResetBeforeFinalizationWithoutVisibleMarkersSuppressesAcceptedItem() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Reset Before Finalization Without Markers"
        )
        let loadedEditable = try await service.loadAgentSessionForEditing(
            id: fixture.session.id,
            for: workspace
        )
        let editable = try XCTUnwrap(loadedEditable)
        _ = try await service.saveAgentSession(
            editable.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: editable.persistenceState
        )

        let outcome = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = outcome else {
            return XCTFail("Expected bookkeeping-only finalization after reset")
        }
        let loaded = try await service.loadAgentSession(
            id: fixture.session.id,
            for: workspace
        )
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertNil(reloaded.scheduledSend)
        XCTAssertEqual(reloaded.lastScheduledDispatch, fixture.receipt)
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == fixture.attempt.itemID })
    }

    func testResetGenerationRejectsStaleFullSaveAndDuplicateResetPreservesLaterEdits() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let sessionID = UUID()
        let oldItem = AgentChatItem.user("Before reset", sequenceIndex: 0)
        let original = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Before Reset"
        ).withItems([oldItem])
        let initialLoad = try await service.prepareInitialAgentSessionPersistence(
            initialSession: original,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let initialCommit = try await service.saveAgentSession(
            original,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1,
            persistenceState: initialLoad.persistenceState
        )

        let resetReceipt = AgentSessionTranscriptResetReceipt(id: UUID())
        let resetSnapshot = original.withItems([])
        let resetCommit = try await service.saveAgentSession(
            resetSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: .requireExisting,
            persistenceState: initialCommit.persistenceState
        )
        XCTAssertEqual(resetCommit.persistenceState.transcriptResetGeneration, 1)

        let laterItem = AgentChatItem.user("After reset", sequenceIndex: 0)
        var laterSnapshot = resetSnapshot.withItems([laterItem])
        laterSnapshot.name = "Later Edits"
        _ = try await service.saveAgentSession(
            laterSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1,
            fileCreationPolicy: .requireExisting,
            persistenceState: resetCommit.persistenceState
        )

        let duplicate = try await service.saveAgentSession(
            resetSnapshot,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: .requireExisting,
            persistenceState: initialCommit.persistenceState
        )
        XCTAssertEqual(duplicate.disposition, .resetAlreadyCommitted)
        XCTAssertEqual(duplicate.persistenceState.transcriptResetGeneration, 1)

        do {
            _ = try await service.saveAgentSession(
                original,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1,
                fileCreationPolicy: .requireExisting,
                persistenceState: initialCommit.persistenceState
            )
            XCTFail("A pre-reset full save must not cross the committed reset generation")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleTranscriptResetGeneration(expected: 0, actual: 1)
            )
        }

        let reloaded = try await service.loadAgentSession(from: resetCommit.fileURL)
        XCTAssertEqual(reloaded.name, "Later Edits")
        XCTAssertEqual(reloaded.toLiveItems().map(\.id), [laterItem.id])
        XCTAssertFalse(reloaded.toLiveItems().contains { $0.id == oldItem.id })
    }

    func testDiscardUnreadableRequiresExactOpaqueMember() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let original = AgentScheduledSendJSONValue.object([
            "schemaVersion": .number(2),
            "future": .object(["value": .string("original")])
        ])
        let replacement = AgentScheduledSendJSONValue.object([
            "schemaVersion": .number(3),
            "future": .object(["value": .string("replacement")])
        ])
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Unreadable Discard",
            scheduledSend: .unreadable(original)
        )
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        do {
            _ = try await service.mutateScheduledSend(
                sessionID: session.id,
                for: workspace,
                mutation: .discardUnreadable(expected: replacement)
            )
            XCTFail("A replaced opaque member must not be discarded")
        } catch {
            XCTAssertEqual(
                error as? AgentScheduledSendMutationError,
                .staleExpectedScheduledSendMember(
                    expected: .unreadable(replacement),
                    actual: .unreadable(original)
                )
            )
        }
        let loaded = try await service.loadAgentSession(id: session.id, for: workspace)
        let preserved = try XCTUnwrap(loaded)
        XCTAssertEqual(preserved.scheduledSend, .unreadable(original))

        let discarded = try await service.mutateScheduledSend(
            sessionID: session.id,
            for: workspace,
            mutation: .discardUnreadable(expected: original)
        )
        XCTAssertNil(discarded.session.scheduledSend)
    }

    func testCachedScheduleAuthorityAvoidsReparsingExistingSessionOnOrdinarySave() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let schedule = makeSchedule()
        var session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Cached Authority",
            scheduledSend: .v1(schedule)
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        // Load-modify-save: the compatibility save carries the loaded lifecycle authority.
        session = try await service.loadAgentSession(from: fileURL)
        try Data("{".utf8).write(to: fileURL, options: .atomic)

        session.name = "Recovered From Cached Authority"
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let reloaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(reloaded.name, "Recovered From Cached Authority")
        XCTAssertEqual(reloaded.scheduledSend, .v1(schedule))
    }

    func testUnlinkFailureAfterTombstoneCommitKeepsDeletionEffectiveForSavesAndRecovery() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let fixture = try await makeRecoveryFixture(
            service: service,
            workspace: workspace,
            name: "Failed Deletion"
        )
        let initialFinalization = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .committed = initialFinalization else {
            return XCTFail("Expected initial accepted-item finalization")
        }

        let loadedEditable = try await service.loadAgentSessionForEditing(
            id: fixture.session.id,
            for: workspace
        )
        let editable = try XCTUnwrap(loadedEditable)
        _ = try await service.saveAgentSession(
            editable.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: editable.persistenceState
        )

        let generationBeforeFailure = await service.scheduledSendDeletionGeneration(for: fixture.fileURL)
        await service.test_setAgentSessionDeletionFailureInjector { _ in
            InjectedDeletionFailure()
        }
        // The tombstone is the commit point: an unlink failure afterwards is cleanup residue,
        // not a failed deletion.
        try await service.deleteAgentSession(id: fixture.session.id, for: workspace)
        await service.test_setAgentSessionDeletionFailureInjector(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path), "Residue remains after unlink failure")
        let residueBytes = try Data(contentsOf: fixture.fileURL)
        let generationAfterFailure = await service.scheduledSendDeletionGeneration(for: fixture.fileURL)
        XCTAssertEqual(generationAfterFailure, generationBeforeFailure + 1)

        // A stale compatibility save cannot rewrite or resurrect the logically deleted session.
        let staleSession = fixture.session.withItems([fixture.acceptedItem])
        do {
            _ = try await service.saveAgentSession(
                staleSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            XCTFail("A save must not target a tombstoned session")
        } catch {
            XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionDeleted(fixture.session.id))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), residueBytes)
        let loadedAfterDeletion = try await service.loadAgentSession(id: fixture.session.id, for: workspace)
        XCTAssertNil(loadedAfterDeletion, "Residue is never served as a session")

        let retry = try await service.finalizeScheduledSend(recovery: fixture.payload)
        guard case .explicitlyDeleted = retry else {
            return XCTFail("Recovery after a committed deletion must be terminal")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), residueBytes)

        // Repeated deletion retries cleanup of the residue without publishing the logical
        // deletion again (one generation bump and one notification per tombstone commit).
        let republished = expectation(forNotification: .agentSessionDeletionDidCommit, object: nil) { notification in
            notification.userInfo?["sessionID"] as? UUID == fixture.session.id
        }
        republished.isInverted = true
        try await service.deleteAgentSession(id: fixture.session.id, for: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        await fulfillment(of: [republished], timeout: 0.2)
        let generationAfterRetry = await service.scheduledSendDeletionGeneration(for: fixture.fileURL)
        XCTAssertEqual(generationAfterRetry, generationAfterFailure)
    }

    func testDeleteRetiresSessionIDSoFinalizedAuthorityCannotReachARecreation() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storagePath = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storagePath) }

        let (schedule, attempt) = makeDispatchingSchedule()
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Delete Finalized",
            scheduledSend: .v1(schedule)
        )
        _ = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let acceptedItem = AgentChatItem.user(schedule.rawText, id: attempt.itemID)
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        _ = try await service.finalizeScheduledSend(
            sessionID: sessionID,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt,
            acceptedUserItem: acceptedItem,
            receipt: receipt
        )

        try await service.deleteAgentSession(id: sessionID, for: workspace)
        let replacement = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Replacement"
        )
        // The tombstone retires the UUID: neither a first nor a repeated replacement save creates it.
        for _ in 0 ..< 2 {
            do {
                _ = try await service.saveAgentSession(
                    replacement,
                    for: workspace,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: 0
                )
                XCTFail("A tombstoned session UUID must not be recreated")
            } catch {
                XCTAssertEqual(error as? AgentScheduledSendMutationError, .sessionDeleted(sessionID))
            }
        }

        let loaded = try await service.loadAgentSession(id: sessionID, for: workspace)
        XCTAssertNil(loaded)
    }

    private struct InjectedDeletionFailure: Error {}

    private struct RecoveryFixture {
        let session: AgentSession
        let schedule: AgentScheduledSendPersist
        let attempt: AgentScheduledSendPersist.Attempt
        let acceptedItem: AgentChatItem
        let receipt: AgentScheduledSendProvenance
        let fileURL: URL
        let context: AgentScheduledSendRecoveryContext
        let payload: AgentScheduledSendAcceptedPayload
    }

    private func makeRecoveryFixture(
        service: AgentSessionDataService,
        workspace: WorkspaceModel,
        name: String,
        priorItems: [AgentChatItem] = []
    ) async throws -> RecoveryFixture {
        let (schedule, attempt) = makeDispatchingSchedule()
        var session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: name,
            scheduledSend: .v1(schedule)
        )
        session = session.withItems(priorItems)
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: priorItems.count
        )
        let context = try await service.prepareScheduledSendRecovery(
            sessionID: session.id,
            for: workspace,
            expectedUpdatedAt: schedule.updatedAt,
            expectedAttempt: attempt
        )
        var acceptedItem = AgentChatItem.user(
            schedule.rawText,
            id: attempt.itemID,
            sequenceIndex: priorItems.count
        )
        let receipt = makeProvenance(schedule: schedule, attempt: attempt)
        acceptedItem.scheduledSend = receipt
        let payload = AgentScheduledSendAcceptedPayload(
            context: context,
            attempt: attempt,
            receipt: receipt,
            acceptedItem: acceptedItem,
            expectedUpdatedAt: schedule.updatedAt
        )
        return RecoveryFixture(
            session: session,
            schedule: schedule,
            attempt: attempt,
            acceptedItem: acceptedItem,
            receipt: receipt,
            fileURL: fileURL,
            context: context,
            payload: payload
        )
    }

    private struct ScheduledSendProbe: Decodable {
        let scheduledSend: AgentScheduledSendJSONValue
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

    private func makeDispatchingSchedule() -> (
        schedule: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt
    ) {
        var schedule = makeSchedule()
        let attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: UUID(),
            startedAt: schedule.notBefore.addingTimeInterval(1)
        )
        schedule.state = .dispatching
        schedule.attempt = attempt
        schedule.updatedAt = attempt.startedAt
        return (schedule, attempt)
    }

    private func makeProvenance(
        schedule: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt? = nil
    ) -> AgentScheduledSendProvenance {
        AgentScheduledSendProvenance(
            scheduleID: schedule.id,
            attemptID: attempt?.attemptID ?? UUID(),
            scheduledFor: schedule.notBefore,
            sentAt: schedule.notBefore.addingTimeInterval(30)
        )
    }

    /// Load-modify-save owners carry the lifecycle authority they loaded. Adopts only that
    /// authority onto an otherwise unchanged (possibly stale) in-memory snapshot.
    private func carryingLoadedLifecycle(
        _ session: AgentSession,
        service: AgentSessionDataService,
        workspace: WorkspaceModel
    ) async throws -> AgentSession {
        let loaded = try await service.loadAgentSession(id: session.id, for: workspace)
        var carrier = session
        carrier.lifecycle = try XCTUnwrap(loaded?.lifecycle)
        return carrier
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentScheduledSendPersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Agent Scheduled Send Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
