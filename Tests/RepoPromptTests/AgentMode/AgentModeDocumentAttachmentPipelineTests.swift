@_spi(TestSupport) @testable import RepoPromptAgentCore
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Step 2 view-model pipeline for attached documents (no composer UI yet): provider augmentation
/// preflights the real originals and appends only the manifest, blocked sends keep the composer,
/// queued document records survive to dequeue, and copy seams (pending-tab transfer, first-send
/// snapshot, recovery composer content, bubble text) carry the records.
@MainActor
final class AgentModeDocumentAttachmentPipelineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeDocumentAttachmentPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentTabSession
        let store: AgentDocumentAttachmentStore
    }

    private func makeHarness(agent: AgentProviderKind = .claudeCode) async throws -> Harness {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 9301,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in DocumentPipelineNoopCodexController() }
        )
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        viewModel.documentAttachmentStore = store
        // Deterministic: never read (or depend on) the real Codex shell-tool preference.
        viewModel.codexShellToolPreference = { true }
        viewModel.test_setAvailableAgents([.claudeCode, .codexExec, .openCode])
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = agent
        return Harness(viewModel: viewModel, tabID: tabID, session: session, store: store)
    }

    /// The document store every harness uses (same root), so a recovery fixture resolves the
    /// references its intents carry.
    private func harnessDocumentStore() -> AgentDocumentAttachmentStore {
        AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
    }

    private static let secretBody = "SECRET-DOCUMENT-BODY-7f3a"

    private func importPDF(into store: AgentDocumentAttachmentStore, name: String = "Q3 report.pdf") async throws -> AgentDocumentAttachment {
        let source = root.appendingPathComponent(name)
        try Data("%PDF-1.4 \(Self.secretBody)".utf8).write(to: source)
        let imported = try await store.importDocuments(from: [source])
        return try XCTUnwrap(imported.first)
    }

    private func neverImported() -> AgentDocumentAttachment {
        AgentDocumentAttachment(kind: .pdf, originalFilename: "gone.pdf", byteCount: 10)
    }

    /// A composer image backed by a real file (its identity is what restoration must preserve).
    private func makeImage(_ name: String = "shot.png") throws -> AgentImageAttachment {
        let url = root.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return AgentImageAttachment(source: .localFile(path: url.path))
    }

    /// A composer tagged file backed by a real workspace file.
    private func makeTaggedFile(_ name: String = "Notes.md") throws -> AgentTaggedFileAttachment {
        try Data("notes".utf8).write(to: root.appendingPathComponent(name))
        return AgentTaggedFileAttachment(relativePath: name, displayName: name)
    }

    // MARK: Provider augmentation

    func testQualifiedClaudeSendGetsManifestWithManagedPathAndNoInlineContent() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)

        let staged = await harness.viewModel.augmentUserMessageForProviderSend(
            "Summarize the attachment",
            documentAttachments: [doc],
            session: harness.session,
            carriers: []
        )

        XCTAssertNil(staged.blockedReason)
        XCTAssertTrue(staged.text.hasPrefix("Summarize the attachment\n\n<attached_documents>"), staged.text)
        XCTAssertTrue(staged.text.contains(harness.store.managedFileURL(for: doc).path), "Manifest names the managed original")
        XCTAssertTrue(staged.text.contains("Q3 report.pdf"))
        XCTAssertFalse(staged.text.contains(Self.secretBody), "Document content is never inlined")
    }

    func testDocumentOnlySendIsTheManifestAlone() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)

        let staged = await harness.viewModel.augmentUserMessageForProviderSend(
            "",
            documentAttachments: [doc],
            session: harness.session,
            carriers: []
        )

        XCTAssertNil(staged.blockedReason)
        XCTAssertTrue(staged.text.hasPrefix("<attached_documents>"), staged.text)
    }

    func testUnsupportedProviderAndMissingOriginalBlockBeforeAnyText() async throws {
        let harness = try await makeHarness(agent: .openCode)
        let doc = try await importPDF(into: harness.store)

        let unsupported = await harness.viewModel.augmentUserMessageForProviderSend(
            "hi",
            documentAttachments: [doc],
            session: harness.session,
            carriers: []
        )
        XCTAssertEqual(unsupported.blockedReason, AgentDocumentDeliveryPolicy.unsupportedProviderReason(.openCode))

        harness.session.selectedAgent = .claudeCode
        let missing = await harness.viewModel.augmentUserMessageForProviderSend(
            "hi",
            documentAttachments: [neverImported()],
            session: harness.session,
            carriers: []
        )
        let reason = try XCTUnwrap(missing.blockedReason, "A missing original blocks the send")
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(missing.pendingHandoffStage, "Nothing is staged for a blocked send")
    }

    // MARK: Submit (pre-consumption)

    func testBlockedDocumentOnlySubmitKeepsComposerAndAppendsNothing() async throws {
        let harness = try await makeHarness(agent: .openCode)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]
        harness.session.draftText = ""

        let result = harness.viewModel.submitUserTurn(
            text: "",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )

        guard case let .blocked(message) = result else { return XCTFail("Expected a block, got \(result)") }
        XCTAssertFalse(message.isEmpty, "A document-only draft counts as content and is refused visibly")
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc], "The draft's documents are kept")
        XCTAssertTrue(harness.session.items.isEmpty, "No bubble for a refused send")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
    }

    func testMissingOriginalBlocksSubmitBeforeConsumption() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let missing = neverImported()
        harness.session.pendingDocumentAttachments = [missing]

        XCTAssertNotNil(harness.viewModel.documentAttachmentBlockedMessage([missing], session: harness.session))
        let result = harness.viewModel.submitUserTurn(
            text: "with a missing document",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )

        guard case .blocked = result else { return XCTFail("Expected a block, got \(result)") }
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [missing])
        XCTAssertTrue(harness.session.items.isEmpty)
        if case let .blocked(initial)? = harness.viewModel.preflightInitialUserTurn(text: "x", session: harness.session) {
            XCTAssertFalse(initial.isEmpty, "The initial-turn preflight refuses too")
        } else {
            XCTFail("preflightInitialUserTurn must refuse a missing original")
        }
    }

    // MARK: Generic queue dequeue

    func testQueuedDocumentHeadIsDeliveredWithManifestAtDequeue() async throws {
        // The wait tool is called by the agent of a live run (its owner, run, and attempt are checked).
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingInstructions = [AgentPendingInstruction(
            text: "queued follow-up",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [doc]
        )]

        let response = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)

        let text = try XCTUnwrap(response.text)
        XCTAssertTrue(text.contains("queued follow-up"))
        XCTAssertTrue(text.contains("<attached_documents>"), "The record becomes the manifest only at dequeue: \(text)")
        XCTAssertFalse(text.contains(Self.secretBody))
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
    }

    /// F1 (deliberate contract change): a head refused by its own documents would be refused again
    /// at every later wait and wedge the queue behind it, so untracked input leaves the queue and
    /// returns to the composer with a visible reason; it is never handed to the wait.
    func testQueuedDocumentHeadWithMissingOriginalLeavesQueueAndReturnsToComposer() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let missing = neverImported()
        let head = AgentPendingInstruction(
            text: "",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [missing]
        )
        let behind = AgentPendingInstruction(text: "next in line", identity: .inactiveForTesting(in: harness.session))
        harness.session.pendingInstructions = [head, behind]

        do {
            _ = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)
            XCTFail("A blocked document head must not be handed to the wait")
        } catch is AgentModeViewModel.QueuedInstructionDeliveryError {
            // expected
        }
        XCTAssertEqual(harness.session.pendingInstructions, [behind], "The refused head no longer blocks the queue")
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [missing], "Its document record returns")
        XCTAssertTrue(harness.session.items.contains { $0.kind == .error }, "A document-only restore is announced")

        let next = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)
        XCTAssertEqual(next.text, "next in line", "The input behind it drains next")
    }

    // MARK: Pre-consumption destination blocks

    func testRemoteHostBlocksDocumentsBeforeConsumption() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        harness.session.remoteHost = AgentSessionRemoteHostBinding(
            hostID: "host",
            hostDisplayName: "Host",
            remoteSessionID: "remote-session"
        )
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "send to the remote host",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )

        XCTAssertEqual(result, .blocked(message: AgentDocumentDeliveryPolicy.remoteHostReason))
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc], "The draft's documents are kept")
        XCTAssertTrue(harness.session.items.isEmpty, "Nothing was appended or sent")
    }

    func testCodexShellDisabledBlocksDocumentsBeforeConsumption() async throws {
        let harness = try await makeHarness(agent: .codexExec)
        harness.viewModel.codexShellToolPreference = { false }
        harness.session.permissionProfile = .userConfigured
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "read this",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )

        XCTAssertEqual(result, .blocked(message: AgentDocumentDeliveryPolicy.codexShellDisabledReason))
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc])
        XCTAssertTrue(harness.session.items.isEmpty)
        XCTAssertTrue(harness.session.codexFallbackQueue.isEmpty)
    }

    // MARK: Waiting continuation (generic live wait)

    /// Installs a live instruction wait on a running non-Codex run (the waiting tool's channel).
    private func installLiveWait(_ harness: Harness) async throws -> Task<UserInstructionResponse, Error> {
        harness.session.runID = UUID()
        harness.session.runState = .running
        harness.session.beginRunAttempt(source: "test.documentPipeline.wait")
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where harness.session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(harness.session.instructionContinuation, "The wait was installed")
        XCTAssertEqual(harness.session.runState, .waitingForUser)
        return wait
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    func testContinuationBlockedAtAugmentationReturnsUntrackedDraftAndDocuments() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        let wait = try await installLiveWait(harness)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "answer with the attachment",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted, "Submit-time preflight passed")
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "Consumed by the submit")
        // The original disappears before the continuation's augmentation runs (same main-actor turn).
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "answer with the attachment",
            "Untracked draft text returns to the composer"
        )
        XCTAssertNotNil(harness.session.instructionContinuation, "Nothing was handed to the wait")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty, "Not queued twice")

        harness.session.instructionContinuation?.resume(throwing: CancellationError())
        harness.session.instructionContinuation = nil
        _ = try? await wait.value
    }

    func testContinuationWaitEndedReturnsUntrackedDraftAndDocuments() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        let wait = try await installLiveWait(harness)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "late answer",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        // The wait ends before the continuation task runs.
        harness.session.instructionContinuation?.resume(throwing: CancellationError())
        harness.session.instructionContinuation = nil

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "late answer")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
        _ = try? await wait.value
    }

    /// R1-01: mixed untracked input (text, tagged file, document) whose wait ended before the
    /// continuation ran returns whole, by identity and exactly once, before its bubble is removed.
    /// (Claude routes image input around the waiting continuation, so this mix carries no image.)
    func testContinuationWaitEndedReturnsWholeMixedInputByIdentity() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        let tag = try makeTaggedFile()
        let wait = try await installLiveWait(harness)
        harness.session.pendingTaggedFileAttachments = [tag]
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "late mixed answer",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(harness.session.pendingTaggedFileAttachments.isEmpty, "Consumed by the submit")
        harness.session.instructionContinuation?.resume(throwing: CancellationError())
        harness.session.instructionContinuation = nil

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments.map(\.id), [tag.id], "The tagged file returns once, same identity")
        XCTAssertEqual(harness.session.pendingDocumentAttachments.map(\.id), [doc.id])
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "late mixed answer")
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover optimistic bubble")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
        _ = try? await wait.value
    }

    func testUnsentDurableContinuationIsHeldWithoutComposerCopy() async throws {
        let fixture = try await RecoveryLaneFixture.make(
            "document-pipeline-durable-continuation",
            documentStore: harnessDocumentStore()
        )
        defer { fixture.tearDown() }
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        harness.session.recoveryLane = fixture.lane
        // N11: the stored intent really carries the document reference, so its preservation is checked.
        let durable = try await fixture.queuedIdentity("durable answer", documents: [doc])
        XCTAssertTrue(durable.isDurable)
        let intentID = try XCTUnwrap(durable.intentID)
        harness.session.draftText = ""

        harness.viewModel.settleUnsentInput(
            durable,
            draftText: "durable answer",
            images: [],
            taggedFiles: [],
            documents: [doc],
            session: harness.session,
            reason: AgentModeViewModel.instructionWaitEndedHoldReason
        )

        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "Its intent is the only copy")
        XCTAssertEqual(harness.session.draftText, "", "No draft duplicate of durable input")
        try await waitUntil("durable input held") {
            fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID] != nil
        }
        XCTAssertEqual(
            fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID],
            AgentModeViewModel.instructionWaitEndedHoldReason
        )
        let storedIntent = await fixture.intent(durable)
        let intent = try XCTUnwrap(storedIntent)
        XCTAssertEqual(intent.deliveryState, .queued, "The durable intent stays queued (held), never withdrawn")
        XCTAssertEqual(intent.payload.documents.map(\.id), [doc.id], "The held intent keeps its document reference")
    }

    // MARK: Codex handoff re-preflight (injected store)

    /// A running Codex user turn (untracked input, inactive admission) whose controller records
    /// every provider handoff.
    private func makeRunningCodexHarness() async throws -> (Harness, DocumentPipelineNoopCodexController) {
        let controller = DocumentPipelineNoopCodexController(hasActiveThread: true)
        // No test workspace path, so the running controller is not invalidated for a path change.
        let viewModel = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in controller })
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        viewModel.documentAttachmentStore = store
        viewModel.codexShellToolPreference = { true }
        viewModel.test_initializeRunService()
        let session = try XCTUnwrap(viewModel.session(for: UUID(), createIfNeeded: true))
        session.selectedAgent = .codexExec
        session.permissionProfile = .userConfigured
        let harness = Harness(viewModel: viewModel, tabID: session.tabID, session: session, store: store)
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.documentPipeline.codex")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        session.codexController = controller
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        return (harness, controller)
    }

    private func codexContext(
        _ session: AgentTabSession,
        text: String,
        documents: [AgentDocumentAttachment],
        taggedFiles: [AgentTaggedFileAttachment] = [],
        userItemID: UUID? = nil
    ) -> AgentTabSession.CodexFallbackSubmissionContext {
        AgentTabSession.CodexFallbackSubmissionContext(
            queueID: UUID(),
            providerText: text,
            images: [],
            taggedFileAttachments: taggedFiles,
            documentAttachments: documents,
            draftText: text,
            identity: .inactiveForTesting(userItemID: userItemID, in: session),
            origin: .manual,
            dispatchTicket: nil
        )
    }

    func testCodexSteerHandoffResolvesDocumentsThroughInjectedStore() async throws {
        let (harness, controller) = try await makeRunningCodexHarness()
        let doc = try await importPDF(into: harness.store)

        let outcome = await harness.viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: harness.session,
            text: "steer with document",
            attachments: [],
            fallbackContext: codexContext(harness.session, text: "steer with document", documents: [doc])
        )

        guard case .sent = outcome else { return XCTFail("Expected a steer through the injected store, got \(outcome)") }
        XCTAssertEqual(controller.steerTexts, ["steer with document"])
    }

    func testCodexSteerWithOriginalMissingAfterAdmissionSendsNothingAndRestoresUntrackedInput() async throws {
        let (harness, controller) = try await makeRunningCodexHarness()
        let doc = try await importPDF(into: harness.store)
        let tag = try makeTaggedFile()
        XCTAssertNil(harness.viewModel.documentAttachmentBlockedMessage([doc], session: harness.session), "Admitted while present")
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))
        harness.session.draftText = ""
        let bubble = AgentChatItem.user("steer with document", sequenceIndex: harness.session.nextSequenceIndex)
        harness.session.appendItem(bubble)

        let outcome = await harness.viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: harness.session,
            text: "steer with document",
            attachments: [],
            fallbackContext: codexContext(
                harness.session,
                text: "steer with document",
                documents: [doc],
                taggedFiles: [tag],
                userItemID: bubble.id
            )
        )

        guard case let .failed(message) = outcome else { return XCTFail("Expected a refused handoff, got \(outcome)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(controller.steerTexts.isEmpty, "No turn/steer for a missing original")
        XCTAssertTrue(controller.startTexts.isEmpty)
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc], "Untracked document records return")
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments.map(\.id), [tag.id], "B N12: its tagged file returns once")
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "steer with document")
        XCTAssertTrue(harness.session.runState.isActive, "One refused steer does not end the active run")
        XCTAssertTrue(harness.session.items.contains { $0.kind == .error && $0.text == message })
        XCTAssertFalse(
            harness.session.items.contains { $0.id == bubble.id },
            "F6: the restored untracked input's optimistic bubble is removed, so a retry is not shown twice"
        )
    }

    private func queuedFallbackEntry(
        _ session: AgentTabSession,
        controller: DocumentPipelineNoopCodexController,
        text: String,
        documents: [AgentDocumentAttachment],
        taggedFiles: [AgentTaggedFileAttachment] = []
    ) throws -> AgentTabSession.CodexFallbackQueueEntry {
        var entry = try AgentTabSession.CodexFallbackQueueEntry(
            id: UUID(),
            providerText: text,
            images: [],
            taggedFileAttachments: taggedFiles,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            attachmentReservationID: nil,
            identity: .inactiveForTesting(in: session),
            draftText: text,
            origin: .manual,
            fallbackReason: .activeWithoutAuthoritativeIdentity,
            originThreadID: "thread",
            originControllerInstanceID: ObjectIdentifier(controller),
            originControllerGeneration: session.codexControllerGeneration,
            originRunID: XCTUnwrap(session.runID),
            originRunAttemptID: XCTUnwrap(session.activeRunAttemptID),
            blockingTurn: nil,
            state: .queued
        )
        entry.documentAttachments = documents
        return entry
    }

    func testQueuedCodexFallbackResolvesDocumentsThroughInjectedStoreAtDispatch() async throws {
        let (harness, controller) = try await makeRunningCodexHarness()
        let doc = try await importPDF(into: harness.store)
        let entry = try queuedFallbackEntry(harness.session, controller: controller, text: "queued with document", documents: [doc])
        harness.session.codexFallbackQueue = [entry]
        let coordinator = harness.viewModel.test_codexCoordinator
        XCTAssertTrue(coordinator.test_claimCodexFallbackHead(
            session: harness.session,
            expectedQueueID: entry.id,
            beginsSuccessorAttempt: false
        ))

        await coordinator.test_dispatchClaimedCodexFallback(session: harness.session)

        XCTAssertEqual(controller.startTexts, ["queued with document"], "Resolved through the store that owns the original")
    }

    func testQueuedCodexFallbackWithOriginalMissingAfterEnqueueSendsNothing() async throws {
        let (harness, controller) = try await makeRunningCodexHarness()
        let doc = try await importPDF(into: harness.store)
        let tag = try makeTaggedFile()
        let entry = try queuedFallbackEntry(
            harness.session,
            controller: controller,
            text: "queued with document",
            documents: [doc],
            taggedFiles: [tag]
        )
        harness.session.codexFallbackQueue = [entry]
        harness.session.draftText = ""
        let coordinator = harness.viewModel.test_codexCoordinator
        XCTAssertTrue(coordinator.test_claimCodexFallbackHead(
            session: harness.session,
            expectedQueueID: entry.id,
            beginsSuccessorAttempt: false
        ))
        // Removed after enqueue and claim, before the dispatch.
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))

        await coordinator.test_dispatchClaimedCodexFallback(session: harness.session)

        XCTAssertTrue(controller.startTexts.isEmpty, "No turn/start for a missing original")
        XCTAssertNil(harness.session.codexFallbackDispatchInFlight)
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc], "Untracked document records return")
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments.map(\.id), [tag.id], "B N12: its tagged file returns once")
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "queued with document")
        XCTAssertTrue(harness.session.items.contains { $0.kind == .error })
    }

    // MARK: Consumed input settlement and final handoff checks (Step 2 review fixes)

    private func waitUntilAsync(_ description: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    /// Removes `doc`'s managed original the first time a document augmentation completes (after
    /// the manifest was appended, before the route's final document check at its handoff).
    private func removeOriginalAfterAugmentation(_ harness: Harness, _ doc: AgentDocumentAttachment) {
        let url = harness.store.managedFileURL(for: doc)
        var fired = false
        harness.viewModel.test_afterDocumentAugmentationHook = { _ in
            guard !fired else { return }
            fired = true
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The production view model whose Claude runtime is the recording fake (no process), with inert
    /// MCP policy and routing hooks, as the run-service lifecycle and recovery compositions use.
    private var claudeRecorder = LifecycleRecorder()

    private func makeClaudeRunnerHarness(
        startGate: LifecycleAsyncGate? = nil,
        invokesWriteAdmission: Bool = false
    ) async throws -> (Harness, LifecycleFakeNativeController) {
        let controller = LifecycleFakeNativeController(
            recorder: claudeRecorder,
            startGate: startGate,
            invokesWriteAdmission: invokesWriteAdmission
        )
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 9303,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in DocumentPipelineNoopCodexController() },
            claudeControllerFactory: { _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _, _, _, _ in
                if let runID {
                    await MCPRoutingWaiter.notifyRouted(runID: runID)
                }
            },
            mcpRunRoutingCleaner: { _, _, _ in }
        )
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        viewModel.documentAttachmentStore = store
        viewModel.codexShellToolPreference = { true }
        viewModel.test_setAvailableAgents([.claudeCode, .codexExec, .openCode])
        viewModel.test_setCurrentTabIDOverride(tabID)
        // No real pending MCP policy exists for the fake runtime (the run-service lifecycle harness
        // injects the same always-armed policy armer).
        viewModel.test_expectedPIDPolicyArmerOverride = { _ in true }
        viewModel.test_initializeRunService()
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .claudeCode
        addTeardownBlock { await controller.shutdown() }
        return (Harness(viewModel: viewModel, tabID: tabID, session: session, store: store), controller)
    }

    /// A running Claude turn whose native runtime is the recording fake (steering route).
    private func startRunningClaudeTurn(_ harness: Harness, controller: LifecycleFakeNativeController) {
        harness.session.claudeController = controller
        harness.session.runID = UUID()
        harness.session.runState = .running
        harness.session.beginRunAttempt(source: "test.documentPipeline.claudeSteering")
    }

    private func assertManifest(_ text: String, typed: String, doc: AgentDocumentAttachment, store: AgentDocumentAttachmentStore) {
        XCTAssertTrue(text.contains(typed), text)
        XCTAssertTrue(text.contains("<attached_documents>"), "The provider receives the manifest: \(text)")
        XCTAssertTrue(text.contains(store.managedFileURL(for: doc).path), "The manifest names the managed original")
        XCTAssertFalse(text.contains(Self.secretBody), "Document content is never inlined")
    }

    /// DOC-01: an idle composer submit whose original disappears after submit-time preflight (the
    /// input already consumed) is refused at the start's augmentation and returns to the composer:
    /// draft text, document record, and no leftover optimistic bubble; nothing starts.
    func testIdleStartWithOriginalMissingAfterSubmitReturnsUntrackedInputWithoutBubble() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "start with the attachment",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted, "Submit-time preflight passed")
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "Consumed by the submit")
        XCTAssertTrue(harness.session.items.contains { $0.kind == .user }, "Optimistic bubble shown")
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "start with the attachment"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No duplicate bubble on retry")
        XCTAssertFalse(harness.session.runState.isActive, "Nothing started")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
    }

    /// R1-01: a mixed idle start (text, image, tagged file, document) refused at its augmentation
    /// returns its whole snapshot by identity, exactly once, and only then loses its bubble.
    func testMixedIdleStartRefusedEarlyReturnsWholeInputByIdentity() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let doc = try await importPDF(into: harness.store)
        let image = try makeImage()
        let tag = try makeTaggedFile()
        harness.session.pendingImageAttachments = [image]
        harness.session.pendingTaggedFileAttachments = [tag]
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "mixed start",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(harness.session.pendingImageAttachments.isEmpty, "Consumed by the submit")
        XCTAssertTrue(harness.session.pendingTaggedFileAttachments.isEmpty)
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        XCTAssertEqual(harness.session.pendingImageAttachments.map(\.id), [image.id], "The image returns once, same identity")
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments.map(\.id), [tag.id], "The tagged file returns once")
        XCTAssertEqual(harness.session.pendingDocumentAttachments.map(\.id), [doc.id])
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "mixed start")
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover optimistic bubble")
        XCTAssertFalse(harness.session.runState.isActive, "Nothing started")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shot.png").path), "The image file is kept")
        // B N16: with non-empty text the composer projection republishes the restored attachments.
        let strip = harness.viewModel.ui.composer.props.attachments
        XCTAssertEqual(strip.imageAttachments.map(\.id), [image.id])
        XCTAssertEqual(strip.taggedFileAttachments.map(\.id), [tag.id])
    }

    /// DOC-02 / F14: an idle Claude start delivers the manifest through the production runner to
    /// the native runtime.
    func testClaudeStartDeliversManifestThroughRunner() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "Summarize via the runner",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntilAsync("Claude received the turn") {
            await !controller.recordedSentMessages().isEmpty
        }
        let sent = await controller.recordedSentMessages()
        XCTAssertEqual(sent.count, 1)
        try assertManifest(XCTUnwrap(sent.first), typed: "Summarize via the runner", doc: doc, store: harness.store)
        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)
    }

    /// DOC-02 at the send seam: the original disappears while the runner is starting the provider
    /// (after every pre-runner check). The send seam's final document authority refuses the write:
    /// nothing reaches the runtime, and untracked input returns to the composer without its bubble.
    ///
    /// R1-01: mixed input (image, tagged file, document): the runner reserved the image, so it
    /// returns through that reservation (released, never deleted by the runner's failure cleanup).
    func testClaudeStartRefusesOriginalRemovedDuringProviderStartup() async throws {
        let startGate = LifecycleAsyncGate()
        let (harness, controller) = try await makeClaudeRunnerHarness(startGate: startGate)
        let doc = try await importPDF(into: harness.store)
        let image = try makeImage()
        let tag = try makeTaggedFile()
        harness.session.pendingImageAttachments = [image]
        harness.session.pendingTaggedFileAttachments = [tag]
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "lose the original during startup",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        try await waitUntil("provider startup suspended") { self.claudeRecorder.events.contains("claude:start") }
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "The runner owns the input during startup")
        guard case let .reserved(_, reserved) = harness.session.attachmentTurnState else {
            return XCTFail("The runner reserved the image: \(harness.session.attachmentTurnState)")
        }
        XCTAssertEqual(reserved.map(\.id), [image.id])
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([doc], session: harness.session))
        await startGate.release()

        try await waitUntil("untracked input restored") { harness.session.pendingDocumentAttachments == [doc] }
        try await waitUntil("run ended") { !harness.session.runState.isActive }
        await harness.session.agentTask?.value
        XCTAssertEqual(harness.session.pendingImageAttachments.map(\.id), [image.id], "The reserved image returns once")
        XCTAssertEqual(harness.session.attachmentTurnState, .idle, "Its reservation was released by the restore")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("shot.png").path),
            "The runner's failure cleanup deleted nothing"
        )
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments.map(\.id), [tag.id])
        XCTAssertEqual(harness.session.pendingDocumentAttachments.map(\.id), [doc.id])
        XCTAssertEqual(harness.viewModel.ui.composer.props.attachments.imageAttachments.map(\.id), [image.id], "B N16: republished")
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "No user message reached the provider: \(sent)")
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "lose the original during startup"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover optimistic bubble")
        // The restored draft carries the refusal (shown by the composer's draft-restoration notice).
        XCTAssertEqual(harness.viewModel.draftRestorationEvent?.tabID, harness.tabID)
        XCTAssertEqual(harness.viewModel.draftRestorationEvent?.message, refusal, "The refusal is shown")
    }

    /// DOC-02 at the send seam, durable input: refused at the final boundary after provider
    /// startup, nothing is written, and the intent is held (still saved, `queued`) with the reason.
    func testDurableClaudeStartRefusedDuringProviderStartupIsHeld() async throws {
        let fixture = try await RecoveryLaneFixture.make("document-pipeline-boundary", documentStore: harnessDocumentStore())
        defer { fixture.tearDown() }
        let startGate = LifecycleAsyncGate()
        let (harness, controller) = try await makeClaudeRunnerHarness(startGate: startGate)
        // The durable session: bound to the fixture's persisted session and its recovery lane.
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        session.recoveryAdmissionMode = .mandatory
        harness.viewModel.test_installLiveSession(session)
        let doc = try await importPDF(into: harness.store)
        // N11: the stored intent really carries the document reference.
        let identity = try await fixture.queuedIdentity("durable start with document", documents: [doc])
        let intentID = try XCTUnwrap(identity.intentID)

        let start = Task { @MainActor in
            await harness.viewModel.startAgentRun(
                tabID: session.tabID,
                initialMessage: "durable start with document",
                documentAttachments: [doc],
                inputConstituents: [identity]
            )
        }
        try await waitUntil("provider startup suspended") { self.claudeRecorder.events.contains("claude:start") }
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([doc], session: session))
        await startGate.release()
        let outcome = await start.value
        XCTAssertNil(outcome, "The runner owned the input when it was refused")

        try await waitUntil("durable input held") {
            fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID] != nil
        }
        try await waitUntil("run ended") { !session.runState.isActive }
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "No user message reached the provider: \(sent)")
        XCTAssertEqual(fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID], refusal)
        let stored = await fixture.intent(identity)
        XCTAssertEqual(stored?.deliveryState, .queued, "Still saved, never withdrawn or marked delivered")
        XCTAssertEqual(stored?.payload.documents.map(\.id), [doc.id], "The held intent keeps its document reference")
        XCTAssertTrue(session.pendingDocumentAttachments.isEmpty, "Durable input is never also restored to the composer")
        XCTAssertEqual(
            session.items.count { $0.kind == .error && $0.text == refusal },
            1,
            "N5: the boundary refusal is settled (and shown) exactly once"
        )
    }

    /// DOC-02: an original removed after augmentation (handoff staged, manifest built) is refused
    /// by the final check before any runner is invoked; untracked input returns to the composer.
    func testClaudeStartRefusesOriginalRemovedAfterAugmentationAtFinalCheck() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]
        removeOriginalAfterAugmentation(harness, doc)

        let result = harness.viewModel.submitUserTurn(
            text: "start then lose the original",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("untracked input restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "Nothing reached the provider")
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "start then lose the original"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user })
        XCTAssertFalse(harness.session.runState.isActive)
    }

    /// F14: Claude steering delivers the manifest through the run service's flush and the native
    /// send seam.
    func testClaudeSteeringDeliversManifestToNativeRuntime() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "steer with the attachment",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntilAsync("Claude received the steering") {
            await !controller.recordedSentMessages().isEmpty
        }
        let sent = await controller.recordedSentMessages()
        try assertManifest(XCTUnwrap(sent.first), typed: "steer with the attachment", doc: doc, store: harness.store)
        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)
    }

    /// F14: an original removed after the steering was queued (before its flush augments it) sends
    /// nothing; the untracked input returns to the composer.
    func testClaudeSteeringWithOriginalMissingAfterEnqueueSendsNothing() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "steer then lose it",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([doc], session: harness.session))

        try await waitUntil("untracked steering restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        await harness.session.claudeSteeringFlushTask?.value
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "No native send for a missing original")
        XCTAssertTrue(harness.session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "steer then lose it")
        // N8: one shared settlement shows the refusal once (the draft notice), with no second
        // "documents returned" notice and no leftover steering bubble.
        XCTAssertEqual(harness.viewModel.draftRestorationEvent?.message, refusal, "The refusal is shown")
        XCTAssertFalse(
            harness.session.items.contains { $0.text == AgentModeRunService.unsentDocumentsReturnedNotice },
            "No duplicate notice"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover steering bubble")
        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)
    }

    /// B N13: a refused Claude steering carrying an image (restored directly, no runner reservation)
    /// keeps the image file and its composer identity, exactly once, after its run ends.
    func testRefusedClaudeSteeringImageSurvivesRunEnd() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        let image = try makeImage()
        harness.session.pendingImageAttachments = [image]
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "steer with an image, lose the document",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        try FileManager.default.removeItem(at: harness.store.managedFileURL(for: doc))

        try await waitUntil("untracked steering restored") { harness.session.pendingDocumentAttachments == [doc] }
        await harness.session.claudeSteeringFlushTask?.value
        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)
        try await waitUntil("run ended") { !harness.session.runState.isActive }
        await harness.session.agentTask?.value

        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "Nothing reached the provider: \(sent)")
        XCTAssertEqual(harness.session.pendingImageAttachments.map(\.id), [image.id], "The image returns once")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("shot.png").path),
            "Ending the run deletes no restored steering image"
        )
        XCTAssertEqual(harness.session.pendingDocumentAttachments.map(\.id), [doc.id])
    }

    /// DOC-02 / F10: Claude steering re-checks documents after the dispatch preparation awaits,
    /// with no suspension before the native send.
    func testClaudeSteeringRefusesOriginalRemovedAfterAugmentationAtFinalCheck() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]
        removeOriginalAfterAugmentation(harness, doc)

        let result = harness.viewModel.submitUserTurn(
            text: "steer, lose it after augmentation",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("untracked steering restored") {
            harness.session.pendingDocumentAttachments == [doc]
        }
        await harness.session.claudeSteeringFlushTask?.value
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "The final check refused the native send")
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "steer, lose it after augmentation"
        )
    }

    /// Removes `doc`'s original inside the transport's pre-byte write admission (after the send
    /// seam's first boundary check passed), through the host's existing DEBUG baseline-admission
    /// seam, so the admission's own document re-check is the one that refuses.
    private func removeOriginalDuringWriteAdmission(_ harness: Harness, _ doc: AgentDocumentAttachment) {
        let url = harness.store.managedFileURL(for: doc)
        harness.viewModel.test_claudeDispatchBaselineAdmission = { _, _, _ in
            try? FileManager.default.removeItem(at: url)
            return .admittedWithoutIdentity
        }
    }

    /// R1-02 / B N4: a start refused at the transport's write admission writes nothing; the route
    /// owns the settlement (untracked input back to the composer once, no bubble) and its run ends.
    func testClaudeStartRefusedInsideWriteAdmissionWritesNothingAndReturnsInput() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness(invokesWriteAdmission: true)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]
        removeOriginalDuringWriteAdmission(harness, doc)

        let result = harness.viewModel.submitUserTurn(
            text: "start, lose it at the write",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("untracked input restored") { harness.session.pendingDocumentAttachments == [doc] }
        try await waitUntil("run ended") { !harness.session.runState.isActive }
        XCTAssertTrue(claudeRecorder.events.contains("claude:admission-refused"), "\(claudeRecorder.events)")
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "Zero bytes for a refused admission: \(sent)")
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([doc], session: harness.session))
        XCTAssertEqual(harness.viewModel.draftRestorationEvent?.message, refusal, "The refusal is shown")
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "start, lose it at the write"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover optimistic bubble")
    }

    /// R1-02 / B N4: steering refused at the transport's write admission writes nothing and never
    /// ends an otherwise active run (the coordinator no longer fails it); the steering returns to
    /// the composer once, without its bubble.
    func testClaudeSteeringRefusedInsideWriteAdmissionKeepsActiveRun() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness(invokesWriteAdmission: true)
        startRunningClaudeTurn(harness, controller: controller)
        // The run still owes an earlier written turn, so a refused steering strands nothing.
        harness.session.claudeExpectedTurnIDs.insert(UUID())
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]
        removeOriginalDuringWriteAdmission(harness, doc)

        let result = harness.viewModel.submitUserTurn(
            text: "steer, lose it at the write",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("untracked steering restored") { harness.session.pendingDocumentAttachments == [doc] }
        await harness.session.claudeSteeringFlushTask?.value
        XCTAssertTrue(claudeRecorder.events.contains("claude:admission-refused"), "\(claudeRecorder.events)")
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty, "Zero bytes for a refused admission: \(sent)")
        XCTAssertEqual(harness.session.runState, .running, "The refused steering does not end the active run")
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([doc], session: harness.session))
        XCTAssertEqual(harness.viewModel.draftRestorationEvent?.message, refusal, "The refusal is shown once")
        XCTAssertEqual(
            harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "steer, lose it at the write"
        )
        XCTAssertFalse(harness.session.items.contains { $0.kind == .user }, "No leftover steering bubble")
        XCTAssertTrue(harness.session.pendingClaudeSteeringInstructions.isEmpty, "Never re-queued")
        harness.session.claudeExpectedTurnIDs.removeAll()
        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)
    }

    /// B N5: a document refusal at the provider boundary is sticky. A repeated check (a transport
    /// re-entering write admission) returns the same reason, never admits, and settles once.
    func testBoundaryDocumentRefusalIsStickyAndSettlesExactlyOnce() async throws {
        let fixture = try await RecoveryLaneFixture.make("document-pipeline-sticky-refusal")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("refused once")
        let intentID = try XCTUnwrap(identity.intentID)
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        ).get()
        let probe = BoundaryRefusalProbe()
        probe.refusal = "original missing"
        handoff.installDocumentAuthority(AgentDocumentBoundaryAuthority(
            refusal: { probe.refusal },
            settleRefused: { probe.settlements.append($0) }
        ))

        XCTAssertEqual(handoff.documentRefusalAtProviderBoundary(), "original missing")
        // Even if a later check would pass, the settled refusal stands.
        probe.refusal = nil
        XCTAssertEqual(handoff.documentRefusalAtProviderBoundary(), "original missing", "Sticky")
        XCTAssertEqual(handoff.documentRefusalAtProviderBoundary(), "original missing")
        XCTAssertEqual(probe.settlements, ["original missing"], "The route settles exactly once")
        XCTAssertEqual(fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID], "original missing")

        handoff.settleIfUnresolved()
        _ = await handoff.evidence.settled()
        XCTAssertEqual(handoff.observation, .notHandedOff)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued, "Held, never withdrawn")
    }

    /// DOC-03: an untracked document head being augmented when its wait is superseded is never
    /// consumed by the obsolete wait; it stays at the head for the current owner.
    func testQueuedDocumentHeadIsNotConsumedByASupersededWait() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        let head = AgentPendingInstruction(
            text: "queued with document",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [doc]
        )
        harness.session.pendingInstructions = [head]
        let session = harness.session
        harness.viewModel.test_afterDocumentAugmentationHook = { _ in
            // A newer wait call took ownership while this one was preparing the head.
            session.instructionWaitOwnerID = UUID()
        }

        do {
            _ = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)
            XCTFail("A superseded wait must not receive the head")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(harness.session.pendingInstructions, [head], "The head stays queued for the current owner")
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "Nothing was restored as a second copy")
    }

    /// DOC-02 / F1: a queued untracked document head whose original disappears after augmentation
    /// is refused at the wait handoff and leaves the queue (no wedge), returning to the composer.
    func testQueuedDocumentHeadRemovedAfterAugmentationIsRefusedAtHandoff() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingInstructions = [AgentPendingInstruction(
            text: "queued, lose it",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [doc]
        )]
        removeOriginalAfterAugmentation(harness, doc)

        do {
            _ = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)
            XCTFail("A refused head must not be handed to the wait")
        } catch is AgentModeViewModel.QueuedInstructionDeliveryError {
            // expected
        }
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty, "The refused head left the queue")
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc])
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "queued, lose it")
    }

    /// F1 / F4: queued follow-up settlement after a start that handed nothing off.
    func testFollowUpSettlementUnwedgesDocumentRefusalsAndKeepsOtherDurableFailuresQueued() async throws {
        let fixture = try await RecoveryLaneFixture.make("document-pipeline-follow-up")
        defer { fixture.tearDown() }
        let harness = try await makeHarness(agent: .claudeCode)
        let missing = neverImported()
        let refusal = try XCTUnwrap(harness.viewModel.documentAttachmentBlockedMessage([missing], session: harness.session))

        // Untracked, refused by its documents: back to the composer, not re-queued.
        let untracked = AgentPendingInstruction(
            text: "untracked follow-up",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [missing]
        )
        harness.viewModel.settleUnsentFollowUpInstruction(untracked, outcome: .failed(message: refusal), session: harness.session)
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty, "F1: never re-queued at the head")
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [missing])
        XCTAssertEqual(harness.session.draftText.trimmingCharacters(in: .whitespacesAndNewlines), "untracked follow-up")
        XCTAssertFalse(harness.session.items.contains { $0.kind == .error }, "F4: no duplicated error item")

        // Durable, refused by its documents: held for recovery, not re-queued, no composer copy.
        harness.session.recoveryLane = fixture.lane
        harness.session.pendingDocumentAttachments = []
        harness.session.draftText = ""
        let durableIdentity = try await fixture.queuedIdentity("durable follow-up")
        let durable = AgentPendingInstruction(text: "durable follow-up", identity: durableIdentity, documentAttachments: [missing])
        harness.viewModel.settleUnsentFollowUpInstruction(durable, outcome: .failed(message: refusal), session: harness.session)
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty, "F1: a durable document refusal does not wedge the queue")
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        XCTAssertEqual(harness.session.draftText, "")
        let storedIntent = await fixture.intent(durableIdentity)
        XCTAssertEqual(storedIntent?.deliveryState, .queued, "Held, never withdrawn")

        // Durable, failed for another reason: stays queued with the same intents.
        let doc = try await importPDF(into: harness.store)
        let other = AgentPendingInstruction(text: "durable other", identity: durableIdentity, documentAttachments: [doc])
        harness.viewModel.settleUnsentFollowUpInstruction(other, outcome: .failed(message: "startup failed"), session: harness.session)
        XCTAssertEqual(harness.session.pendingInstructions, [other])
    }

    /// F11 / F7: an ordinary stop drops queued follow-up text as before, but untracked document
    /// records have no other copy and return to the composer with a notice.
    func testStopReturnsUntrackedQueuedDocumentsWithNotice() async throws {
        let (harness, controller) = try await makeClaudeRunnerHarness()
        startRunningClaudeTurn(harness, controller: controller)
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingInstructions = [AgentPendingInstruction(
            text: "queued behind the run",
            identity: .inactiveForTesting(in: harness.session),
            documentAttachments: [doc]
        )]

        await harness.viewModel.cancelAgentRun(tabID: harness.tabID, cause: .ordinary)

        XCTAssertTrue(harness.session.pendingInstructions.isEmpty)
        XCTAssertEqual(harness.session.pendingDocumentAttachments, [doc], "Untracked document records are not dropped")
        XCTAssertTrue(
            harness.session.items.contains { $0.text == AgentModeRunService.unsentDocumentsReturnedNotice },
            "A document-only restore is announced"
        )
    }

    /// F14: the Codex steer the view model hands to the coordinator carries the manifest (the
    /// production submit path, not a parallel assembly).
    func testCodexSteerFromSubmitCarriesManifest() async throws {
        let (harness, controller) = try await makeRunningCodexHarness()
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let result = harness.viewModel.submitUserTurn(
            text: "codex steer with document",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("Codex received the steer") { !controller.steerTexts.isEmpty || !controller.startTexts.isEmpty }
        let delivered = try XCTUnwrap((controller.steerTexts + controller.startTexts).first)
        assertManifest(delivered, typed: "codex steer with document", doc: doc, store: harness.store)
    }

    /// F14: an idle Codex submit starts through the production run service and the `turn/start`
    /// text carries the manifest.
    func testCodexIdleStartFromSubmitCarriesManifest() async throws {
        let controller = DocumentPipelineNoopCodexController()
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _, _, _, _ in
                if let runID {
                    await MCPRoutingWaiter.notifyRouted(runID: runID)
                }
            },
            mcpRunRoutingCleaner: { _, _, _ in }
        )
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        viewModel.documentAttachmentStore = store
        viewModel.codexShellToolPreference = { true }
        viewModel.test_expectedPIDPolicyArmerOverride = { _ in true }
        viewModel.test_initializeRunService()
        let session = try XCTUnwrap(viewModel.session(for: UUID(), createIfNeeded: true))
        session.selectedAgent = .codexExec
        session.permissionProfile = .userConfigured
        let doc = try await importPDF(into: store)
        session.pendingDocumentAttachments = [doc]

        let result = viewModel.submitUserTurn(
            text: "codex start with document",
            tabID: session.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)

        try await waitUntil("Codex received turn/start") { !controller.startTexts.isEmpty }
        XCTAssertEqual(
            controller.startTexts.count,
            1,
            "runState=\(session.runState) items=\(session.items.map { "\($0.kind):\($0.text.prefix(160))" })"
        )
        XCTAssertTrue(controller.steerTexts.isEmpty, "An idle submit starts a turn")
        try assertManifest(XCTUnwrap(controller.startTexts.first), typed: "codex start with document", doc: doc, store: store)
        await viewModel.cancelAgentRun(tabID: session.tabID, cause: .ordinary)
    }

    /// B N2: an idle Codex composer start refused at its augmentation (the original removed after
    /// submit, before the start task ran) sends nothing and returns the raw typed draft and its
    /// documents to the composer once, without its bubble.
    func testCodexIdleStartRefusedEarlyReturnsUntrackedInputWithoutBubble() async throws {
        let controller = DocumentPipelineNoopCodexController()
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _, _, _, _ in
                if let runID {
                    await MCPRoutingWaiter.notifyRouted(runID: runID)
                }
            },
            mcpRunRoutingCleaner: { _, _, _ in }
        )
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Documents", isDirectory: true))
        viewModel.documentAttachmentStore = store
        viewModel.codexShellToolPreference = { true }
        viewModel.test_expectedPIDPolicyArmerOverride = { _ in true }
        viewModel.test_initializeRunService()
        let session = try XCTUnwrap(viewModel.session(for: UUID(), createIfNeeded: true))
        session.selectedAgent = .codexExec
        session.permissionProfile = .userConfigured
        let doc = try await importPDF(into: store)
        session.pendingDocumentAttachments = [doc]

        let result = viewModel.submitUserTurn(
            text: "codex start, lose it",
            tabID: session.tabID,
            codexAttemptID: nil,
            admitted: nil
        )
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(session.items.contains { $0.kind == .user }, "Optimistic bubble shown")
        try FileManager.default.removeItem(at: store.managedFileURL(for: doc))

        try await waitUntil("untracked input restored") { session.pendingDocumentAttachments == [doc] }
        try await waitUntil("start settled") { !session.runState.isActive }
        XCTAssertTrue(controller.startTexts.isEmpty, "No turn/start for a missing original")
        XCTAssertEqual(session.pendingDocumentAttachments.map(\.id), [doc.id], "Restored once")
        XCTAssertEqual(
            session.draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            "codex start, lose it",
            "The raw typed draft returns (never the wrapped provider text), once"
        )
        XCTAssertFalse(session.items.contains { $0.kind == .user }, "No leftover optimistic bubble")
    }

    // MARK: Copy seams

    func testPendingTabTransferAndFirstSendSnapshotCarryDocuments() async throws {
        let harness = try await makeHarness()
        let doc = try await importPDF(into: harness.store)
        harness.session.pendingDocumentAttachments = [doc]

        let state = AgentModeViewModel.pendingUserTurnState(from: harness.session)
        XCTAssertEqual(state.documentAttachments, [doc])
        XCTAssertFalse(state.isEmpty, "A documents-only pending state is not empty")

        let destination = AgentTabSession(tabID: UUID())
        harness.viewModel.installPendingUserTurnState(state, on: destination)
        XCTAssertEqual(destination.pendingDocumentAttachments, [doc])
        harness.viewModel.clearPendingUserTurnState(on: harness.session)
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)

        let snapshot = AgentModeViewModel.FirstSendSourceSnapshot(
            session: destination,
            fallbackSelectedAgent: destination.selectedAgent,
            fallbackSelectedModelRaw: destination.selectedModelRaw,
            fallbackSelectedReasoningEffortRaw: destination.selectedReasoningEffortRaw,
            fallbackAutoEditEnabled: destination.autoEditEnabled
        )
        XCTAssertEqual(snapshot.documentAttachments, [doc])
        XCTAssertTrue(snapshot.matches(destination))
        destination.pendingDocumentAttachments = []
        XCTAssertFalse(snapshot.matches(destination), "A document change invalidates the first-send snapshot")
        XCTAssertTrue(harness.viewModel.isFreshFirstSendDestination(destination))
        destination.pendingDocumentAttachments = [doc]
        XCTAssertFalse(harness.viewModel.isFreshFirstSendDestination(destination))
    }

    func testRecoveryComposerContentCarriesDocumentReferences() async throws {
        let harness = try await makeHarness()
        let doc = try await importPDF(into: harness.store)
        harness.session.draftText = ""
        harness.session.pendingDocumentAttachments = [doc]
        let recoveryStore = AgentRecoveryStore(rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true))

        let content = try XCTUnwrap(harness.viewModel.recoveryInputContent(
            for: harness.session,
            store: recoveryStore,
            sessionID: UUID()
        ))

        XCTAssertFalse(content.isEmpty, "A documents-only composer is saved")
        XCTAssertEqual(content.documents.map(\.id), [doc.id])
        XCTAssertEqual(content.documents.first?.attachment.originalFilename, doc.originalFilename)
        XCTAssertTrue(content.images.isEmpty)
    }

    func testDocumentOnlyBubbleText() {
        let docs = [
            AgentDocumentAttachment(kind: .pdf, originalFilename: "a.pdf", byteCount: 1),
            AgentDocumentAttachment(kind: .html, originalFilename: "b.html", byteCount: 1)
        ]
        XCTAssertEqual(
            AgentModeViewModel.userBubbleText(trimmedText: "", attachments: [], taggedFiles: [], documents: docs, workflow: nil),
            "Attached 2 documents"
        )
        XCTAssertEqual(
            AgentModeViewModel.userBubbleText(trimmedText: "", attachments: [], taggedFiles: [], documents: [docs[0]], workflow: nil),
            "Attached 1 document"
        )
        XCTAssertEqual(
            AgentModeViewModel.userBubbleText(trimmedText: "typed", attachments: [], taggedFiles: [], documents: docs, workflow: nil),
            "typed",
            "Typed text stays the bubble; documents never add manifest text to it"
        )
    }
}

/// Records a boundary authority's refusal source and its settlements (B N5).
@MainActor
private final class BoundaryRefusalProbe {
    var refusal: String?
    var settlements: [String] = []
}

/// Codex controller that records provider handoffs (`turn/start` and `turn/steer` texts) and
/// performs no other work.
private final class DocumentPipelineNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    private let activeThread: Bool
    /// A thread is loaded once started or resumed (`hasActiveThread`); `activeThread` is a running turn.
    private var threadLoaded: Bool
    private(set) var startTexts: [String] = []
    private(set) var steerTexts: [String] = []

    init(hasActiveThread: Bool = false) {
        activeThread = hasActiveThread
        threadLoaded = hasActiveThread
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        threadLoaded
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
        threadLoaded = true
        return CodexNativeSessionController.SessionRef(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: activeThread ? .active(activeFlags: []) : .idle,
            currentTurnID: activeThread ? "turn" : nil,
            activeTurnIDs: activeThread ? ["turn"] : [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(text: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws -> CodexTurnStartReceipt {
        startTexts.append(text)
        return CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(text: String, images _: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        steerTexts.append(text)
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
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
