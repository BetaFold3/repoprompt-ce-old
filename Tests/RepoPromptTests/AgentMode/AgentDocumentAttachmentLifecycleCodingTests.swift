@testable import RepoPromptAgentCore
import XCTest

/// Step 2 document lifecycle carriers: old JSON stays readable, documents round-trip as structured
/// records (never as images or tags), malformed or unknown document data fails closed, recovery
/// validates the global managed originals, and the delivery capability matrix is explicit.
final class AgentDocumentAttachmentLifecycleCodingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDocumentAttachmentLifecycleCodingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func document(_ kind: AgentDocumentKind = .pdf, name: String = "report.pdf") -> AgentDocumentAttachment {
        AgentDocumentAttachment(
            id: UUID(),
            kind: kind,
            originalFilename: name,
            byteCount: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Chat items

    func testChatItemOldJSONWithoutDocumentsDecodesAsEmpty() throws {
        let item = AgentChatItem.user("hello", sequenceIndex: 1)
        var object = try jsonObject(JSONEncoder().encode(item))
        object.removeValue(forKey: "documentAttachments")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: old)
        XCTAssertEqual(decoded.documentAttachments, [])
        XCTAssertEqual(decoded.text, "hello")

        let persist = try JSONDecoder().decode(AgentChatItemPersist.self, from: old)
        XCTAssertEqual(persist.toItem().documentAttachments, [])
    }

    func testChatItemDocumentsRoundTripSeparatelyFromImagesAndTags() throws {
        let docs = [document(), document(.html, name: "page.html")]
        let item = AgentChatItem.user("see attached", documentAttachments: docs, sequenceIndex: 3)
        XCTAssertTrue(item.attachments.isEmpty, "Documents are never stored as images")
        XCTAssertTrue(item.taggedFileAttachments.isEmpty, "Documents are never stored as tagged files")

        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.documentAttachments, docs)

        let persist = AgentChatItemPersist(from: item)
        let decodedPersist = try JSONDecoder().decode(AgentChatItemPersist.self, from: JSONEncoder().encode(persist))
        XCTAssertEqual(decodedPersist.toItem().documentAttachments, docs)
        XCTAssertEqual(item.replacingID(UUID()).documentAttachments, docs)
        XCTAssertEqual(item.replacingTimestamp(Date()).documentAttachments, docs)
    }

    func testChatItemMalformedDocumentsFailClosed() throws {
        let item = AgentChatItem.user("hello", sequenceIndex: 1)
        var object = try jsonObject(JSONEncoder().encode(item))
        object["documentAttachments"] = "not-an-array"
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentChatItem.self, from: malformed))

        object["documentAttachments"] = [["id": UUID().uuidString, "kind": "docx", "originalFilename": "a.docx", "byteCount": 1, "createdAt": 0]]
        let unknownKind = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentChatItem.self, from: unknownKind))
    }

    // MARK: Transcript

    func testTranscriptCarriersOmitEmptyDocumentsAndRoundTripPresentOnes() throws {
        let plain = AgentChatItem.user("plain", sequenceIndex: 1)
        let plainActivity = AgentTranscriptActivity(from: plain)
        XCTAssertNil(plainActivity.documentAttachments)
        XCTAssertNil(try jsonObject(JSONEncoder().encode(plainActivity))["documentAttachments"], "Old shape unchanged")
        XCTAssertNil(try jsonObject(JSONEncoder().encode(AgentTranscriptRequestAnchor(from: plain)))["documentAttachments"])

        let docs = [document()]
        let item = AgentChatItem.user("", documentAttachments: docs, sequenceIndex: 2)
        let activity = AgentTranscriptActivity(from: item)
        let decodedActivity = try JSONDecoder().decode(AgentTranscriptActivity.self, from: JSONEncoder().encode(activity))
        XCTAssertEqual(decodedActivity.toItem().documentAttachments, docs)

        let anchor = AgentTranscriptRequestAnchor(from: item)
        let decodedAnchor = try JSONDecoder().decode(AgentTranscriptRequestAnchor.self, from: JSONEncoder().encode(anchor))
        XCTAssertEqual(decodedAnchor.toItem().documentAttachments, docs)
    }

    func testForkedUserRowNamesDocumentsWithoutPaths() {
        let doc = document(name: "Q3 plan.pdf")
        let item = AgentChatItem.user("summarize", documentAttachments: [doc], sequenceIndex: 1)
        let text = AgentTranscriptIO.forkUserText(item)
        XCTAssertEqual(text, "summarize\n[Attached documents: Q3 plan.pdf (PDF)]")
        XCTAssertFalse(text.contains("/"), "No managed path is exported")

        let docOnly = AgentChatItem.user("", documentAttachments: [doc], sequenceIndex: 2)
        XCTAssertEqual(AgentTranscriptIO.forkUserText(docOnly), "[Attached documents: Q3 plan.pdf (PDF)]")
        XCTAssertEqual(AgentTranscriptIO.forkUserText(AgentChatItem.user("x", sequenceIndex: 3)), "x")
    }

    // MARK: Scheduled sends

    private func scheduledRecord(documents: [AgentDocumentAttachment] = []) -> AgentScheduledSendPersist {
        AgentScheduledSendPersist(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notBefore: Date(timeIntervalSince1970: 1_700_003_600),
            state: .scheduled,
            rawText: "later",
            attachments: [],
            taggedFileAttachments: [],
            documentAttachments: documents,
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false
        )
    }

    func testScheduledSendWithoutDocumentsKeepsOldShapeAndStrictMemberRoundTrip() throws {
        let record = scheduledRecord()
        let data = try JSONEncoder().encode(record)
        XCTAssertNil(try jsonObject(data)["documentAttachments"], "No key written when empty")

        let member = try JSONDecoder().decode(AgentScheduledSendMember.self, from: data)
        XCTAssertEqual(member.persistedValue, record, "An old-shape record stays strictly readable")
        XCTAssertEqual(member.persistedValue?.documents, [])
    }

    func testScheduledSendDocumentsRoundTripStrictly() throws {
        let docs = [document(), document(.html, name: "p.htm")]
        var record = scheduledRecord(documents: docs)
        let member = try JSONDecoder().decode(AgentScheduledSendMember.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(member.persistedValue?.documents, docs)

        record.documents = []
        XCTAssertNil(try jsonObject(JSONEncoder().encode(record))["documentAttachments"])
    }

    func testScheduledSendMalformedDocumentsArePreservedUnreadable() throws {
        var object = try jsonObject(JSONEncoder().encode(scheduledRecord()))
        object["documentAttachments"] = [["id": "nope"]]
        let member = try JSONDecoder().decode(
            AgentScheduledSendMember.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(member.isUnreadable, "Malformed documents never decode as an empty list")
    }

    // MARK: Generic queue

    @MainActor
    func testCoalescedPendingInstructionKeepsStructuredDocumentRecords() throws {
        let session = AgentTabSession(tabID: UUID())
        let first = AgentQueuedInputIdentity.inactiveForTesting(in: session)
        let second = AgentQueuedInputIdentity.inactiveForTesting(in: session)
        let docs = [document(), document(.html, name: "b.html")]
        let coalesced = try XCTUnwrap(AgentPendingInstruction(
            coalescedText: "one\n\ntwo",
            constituents: [first, second],
            documentAttachments: docs
        ))
        XCTAssertEqual(coalesced.documentAttachments, docs)
        XCTAssertFalse(coalesced.text.contains("attached_documents"), "Queue text never carries the manifest")
        XCTAssertNil(AgentPendingInstruction(coalescedText: "x", constituents: [], documentAttachments: docs))
    }

    // MARK: Capability

    func testDeliveryCapabilityMatrix() {
        func isLocal(_ capability: AgentDocumentDeliveryCapability) -> Bool {
            if case .localFileAccess = capability { return true }
            return false
        }
        func reason(_ capability: AgentDocumentDeliveryCapability) -> String? {
            if case let .unavailable(reason) = capability { return reason }
            return nil
        }
        XCTAssertTrue(isLocal(AgentDocumentDeliveryPolicy.capability(
            agent: .claudeCode, profile: .standard, isRemoteHost: false, codexShellToolEnabled: false
        )))
        XCTAssertTrue(isLocal(AgentDocumentDeliveryPolicy.capability(
            agent: .codexExec, profile: .standard, isRemoteHost: false, codexShellToolEnabled: true
        )))
        XCTAssertEqual(reason(AgentDocumentDeliveryPolicy.capability(
            agent: .codexExec, profile: .standard, isRemoteHost: false, codexShellToolEnabled: false
        )), AgentDocumentDeliveryPolicy.codexShellDisabledReason)
        XCTAssertEqual(reason(AgentDocumentDeliveryPolicy.capability(
            agent: .claudeCode, profile: .knowledge, isRemoteHost: false, codexShellToolEnabled: true
        )), AgentDocumentDeliveryPolicy.knowledgeReason)
        XCTAssertEqual(reason(AgentDocumentDeliveryPolicy.capability(
            agent: .claudeCode, profile: .standard, isRemoteHost: true, codexShellToolEnabled: true
        )), AgentDocumentDeliveryPolicy.remoteHostReason)
        for agent in [AgentProviderKind.claudeCodeGLM, .openCode] {
            XCTAssertEqual(reason(AgentDocumentDeliveryPolicy.capability(
                agent: agent, profile: .standard, isRemoteHost: false, codexShellToolEnabled: true
            )), AgentDocumentDeliveryPolicy.unsupportedProviderReason(agent))
        }
    }

    // MARK: Recovery codec and store

    private func recoveryStore(documentStore: AgentDocumentAttachmentStore) -> AgentRecoveryStore {
        AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            documentStore: documentStore
        )
    }

    private func importedDocument(into store: AgentDocumentAttachmentStore) async throws -> AgentDocumentAttachment {
        let source = root.appendingPathComponent("source-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4 lifecycle".utf8).write(to: source)
        let imported = try await store.importDocuments(from: [source])
        return try XCTUnwrap(imported.first)
    }

    private func submission(documents: [AgentDocumentAttachment]) -> AgentRecoveryIntentSubmission {
        AgentRecoveryIntentSubmission(
            intentID: UUID(),
            userItemID: UUID(),
            origin: .composer,
            target: .session,
            payload: AgentRecoveryInputContent(
                text: "with documents",
                documents: documents.map(AgentRecoveryDocumentReference.init)
            ),
            scheduleReference: nil
        )
    }

    func testRecoveryRecordRoundTripsDocumentsAndHoldsMissingOriginal() async throws {
        let documentStore = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        let store = recoveryStore(documentStore: documentStore)
        let binding = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        let doc = try await importedDocument(into: documentStore)

        _ = try await store.commitQueuedIntent(
            binding: binding,
            expectedRevision: nil,
            submission: submission(documents: [doc]),
            consumption: nil
        )
        let state = await store.read(sessionID: binding.sessionID)
        let record = try XCTUnwrap(state.record)
        let payload = try XCTUnwrap(record.intents.first?.payload)
        XCTAssertEqual(payload.documents.map(\.id), [doc.id])
        XCTAssertEqual(payload.documents.first?.attachment.kind, .pdf)
        XCTAssertTrue(payload.images.isEmpty, "Documents never become image references")
        XCTAssertTrue(payload.taggedFiles.isEmpty, "Documents never become tagged files")

        let data = try AgentRecoveryRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRecoveryRecordCodec.decode(data, expectedSessionID: binding.sessionID) else {
            return XCTFail("A record with documents must decode")
        }
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try AgentRecoveryRecordCodec.encode(decoded), data, "Exact re-encode")
        let held = await store.derivedHolds(for: record)
        XCTAssertTrue(held.isEmpty, "A present original raises no hold")

        try FileManager.default.removeItem(at: documentStore.managedFileURL(for: doc))
        let holds = await store.derivedHolds(for: record)
        XCTAssertEqual(holds[record.intents[0].intentID], [.missingAttachment], "A missing original holds the intent")
    }

    func testRecoveryRefusesAnIntentWhoseOriginalIsMissing() async throws {
        let documentStore = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        let store = recoveryStore(documentStore: documentStore)
        let binding = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        let neverImported = document()
        do {
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: nil,
                submission: submission(documents: [neverImported]),
                consumption: nil
            )
            XCTFail("An intent naming a missing original must not commit")
        } catch let error as AgentRecoveryStoreError {
            guard case let .documentUnavailable(documentID) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(documentID, neverImported.id)
        }
        let state = await store.read(sessionID: binding.sessionID)
        XCTAssertEqual(state, .absent)
    }

    func testRecoveryCodecOldRecordsReadAndMalformedDocumentsFailClosed() async throws {
        let documentStore = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        let store = recoveryStore(documentStore: documentStore)
        let binding = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        _ = try await store.commitQueuedIntent(
            binding: binding,
            expectedRevision: nil,
            submission: submission(documents: []),
            consumption: nil
        )
        let state = await store.read(sessionID: binding.sessionID)
        let record = try XCTUnwrap(state.record)
        let json = AgentRecoveryRecordCodec.encodeJSON(record)

        func payload(of json: AgentRecoveryJSONValue) -> [String: AgentRecoveryJSONValue]? {
            guard case let .object(object) = json, case let .array(intents)? = object["intents"],
                  case let .object(intent)? = intents.first, case let .object(payload)? = intent["payload"]
            else { return nil }
            return payload
        }
        func replacingPayloadDocuments(_ value: AgentRecoveryJSONValue) throws -> Data {
            guard case var .object(object) = json, case var .array(intents)? = object["intents"],
                  case var .object(intent)? = intents.first, case var .object(payload)? = intent["payload"]
            else { throw XCTSkip("unexpected record shape") }
            payload["documents"] = value
            intent["payload"] = .object(payload)
            intents[0] = .object(intent)
            object["intents"] = .array(intents)
            return try JSONEncoder().encode(AgentRecoveryJSONValue.object(object))
        }

        XCTAssertNil(payload(of: json)?["documents"], "Records without documents keep the old shape")
        let oldShape = try JSONEncoder().encode(json)
        guard case .success = AgentRecoveryRecordCodec.decode(
            oldShape,
            expectedSessionID: binding.sessionID
        ) else { return XCTFail("An old-shape record stays readable") }

        let explicitEmpty = try replacingPayloadDocuments(.array([]))
        guard case .failure = AgentRecoveryRecordCodec.decode(explicitEmpty, expectedSessionID: binding.sessionID) else {
            return XCTFail("An explicit empty documents array would not re-encode exactly")
        }

        let unknownKind = try replacingPayloadDocuments(.array([.object([
            "id": .string(UUID().uuidString),
            "kind": .string("docx"),
            "originalFilename": .string("a.docx"),
            "byteCount": .number(1),
            "createdAt": .number(0)
        ])]))
        guard case let .failure(reason) = AgentRecoveryRecordCodec.decode(unknownKind, expectedSessionID: binding.sessionID),
              case .unknownVariant = reason
        else { return XCTFail("An unknown document kind preserves the record as unreadable") }

        let notArray = try replacingPayloadDocuments(.string("x"))
        guard case .failure = AgentRecoveryRecordCodec.decode(notArray, expectedSessionID: binding.sessionID) else {
            return XCTFail("Malformed documents never decode as empty")
        }
    }

    func testComposerReplacementKeepsUnknownDocumentMembers() async throws {
        let documentStore = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        let store = recoveryStore(documentStore: documentStore)
        let binding = AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
        let doc = try await importedDocument(into: documentStore)
        var reference = AgentRecoveryDocumentReference(doc)
        reference.extras = ["futureMember": .string("kept")]
        let first = AgentRecoveryComposerSnapshot(
            revision: .make(),
            capturedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1),
            transcriptResetGeneration: 0,
            content: AgentRecoveryInputContent(text: "draft", documents: [reference])
        )
        let receipt = try await store.commitComposer(
            binding: binding, expectedRevision: nil, expectedComposerRevision: nil, snapshot: first
        )
        let second = AgentRecoveryComposerSnapshot(
            revision: .make(),
            capturedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2),
            transcriptResetGeneration: 0,
            content: AgentRecoveryInputContent(text: "draft edited", documents: [AgentRecoveryDocumentReference(doc)])
        )
        _ = try await store.commitComposer(
            binding: binding,
            expectedRevision: receipt.recordRevision,
            expectedComposerRevision: first.revision,
            snapshot: second
        )
        let state = await store.read(sessionID: binding.sessionID)
        let composer = try XCTUnwrap(state.record?.composer)
        XCTAssertEqual(composer.content.documents.first?.extras["futureMember"], .string("kept"))
        XCTAssertEqual(composer.content.text, "draft edited")
    }
}
