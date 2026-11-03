import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class RemoteAgentSessionTests: XCTestCase {
    func testLegacyAgentSessionJSONDecodesWithoutRemoteHostBinding() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000301",
          "serializationVersion": 6,
          "name": "Legacy Remote Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertNil(decoded.remoteHost)
        XCTAssertEqual(decoded.serializationVersion, 6)
    }

    func testRemoteHostBindingSequenceEpochRoundTripsAndLegacyDecodesNil() throws {
        let binding = makeBinding(seqEpoch: "epoch-1")
        let roundTripped = try JSONDecoder().decode(
            AgentSessionRemoteHostBinding.self,
            from: JSONEncoder().encode(binding)
        )
        let legacy = try JSONDecoder().decode(
            AgentSessionRemoteHostBinding.self,
            from: Data(
                #"{"hostID":"host","hostDisplayName":"Host","remoteSessionID":"session","lastAppliedSeq":9,"nextLogOffset":3}"#.utf8
            )
        )

        XCTAssertEqual(roundTripped.seqEpoch, "epoch-1")
        XCTAssertNil(legacy.seqEpoch)
    }

    func testAgentSessionRoundTripsRemoteHostBindingWithoutVersionBump() throws {
        let binding = makeBinding()
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000302")),
            name: "Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            remoteHost: binding,
            autoEditEnabled: false
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("remoteHost"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.remoteHost, binding)
    }

    func testDataServiceStubMetadataAndSidebarExposeRemoteHostBinding() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let binding = makeBinding()
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000303"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000304"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Remote Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 40),
            itemCount: 4,
            lastRunState: AgentSessionRunState.running.rawValue,
            remoteHost: binding,
            autoEditEnabled: true,
            origin: .remote(deviceID: "device-abc")
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 4
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Remote Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.remoteHost, binding)

        let meta = try XCTUnwrap(metadata.first)
        XCTAssertEqual(meta.remoteHostID, binding.hostID)
        XCTAssertEqual(meta.remoteHostName, binding.hostDisplayName)
        XCTAssertEqual(meta.remoteSessionID, binding.remoteSessionID)

        let sidebarEntry = try XCTUnwrap(sidebar.entriesBySessionID[sessionID])
        XCTAssertEqual(sidebarEntry.remoteHostID, binding.hostID)
        XCTAssertEqual(sidebarEntry.remoteHostName, binding.hostDisplayName)
        XCTAssertEqual(sidebarEntry.remoteSessionID, binding.remoteSessionID)
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testMetadataIndexRemoteHostFieldsParticipateInStaleComparison() throws {
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000305")),
            name: "Indexed Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 50),
            itemCount: 2,
            remoteHost: makeBinding(),
            autoEditEnabled: true
        )
        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-00000000-0000-0000-0000-000000000305.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 52)
        )
        let sameRecord = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 53)
        )
        XCTAssertTrue(record.matchesIndexedSessionMetadata(sameRecord))

        var changed = session
        changed.remoteHost?.hostDisplayName = "Renamed Host"
        let changedRecord = AgentSessionMetadataRecord.record(
            from: changed,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 54)
        )
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedRecord))
    }

    func testMetadataIndexRemoteSessionIDRoundTripsAcrossAllProjections() throws {
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000307")),
            name: "Indexed Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 60),
            itemCount: 3,
            remoteHost: makeBinding(remoteSessionID: "remote-session-indexed"),
            autoEditEnabled: true
        )
        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-00000000-0000-0000-0000-000000000307.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 321,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 61)
        )
        let encoded = try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [record]))
        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: encoded)
        let decodedRecord = try XCTUnwrap(decoded.entries.first)

        XCTAssertEqual(decodedRecord.remoteSessionID, "remote-session-indexed")
        XCTAssertEqual(decodedRecord.sidebarEntry(tabID: UUID())?.remoteSessionID, "remote-session-indexed")
        XCTAssertEqual(decodedRecord.agentSessionMeta().remoteSessionID, "remote-session-indexed")

        var changedSession = session
        changedSession.remoteHost?.remoteSessionID = "remote-session-recreated"
        let changedRecord = AgentSessionMetadataRecord.record(
            from: changedSession,
            fileURL: fileURL,
            observedFileSize: 321,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 61)
        )
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedRecord))

        var unstartedSession = session
        unstartedSession.remoteHost?.remoteSessionID = "   "
        let unstartedRecord = AgentSessionMetadataRecord.record(
            from: unstartedSession,
            fileURL: fileURL,
            observedFileSize: 321,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 61)
        )
        XCTAssertNil(unstartedRecord.remoteSessionID)
    }

    @MainActor
    func testCoordinatorLocalSessionExistsChecksLiveAndPersistedRemoteSessionIDs() {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RemoteAgentSessionNoopCodexController() }
        )
        let workspace = WorkspaceModel(name: "Dedupe Workspace", repoPaths: ["/tmp/repo"])
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        let indexedSessionID = UUID()
        let indexedTabID = UUID()
        let indexedEntry = AgentSessionIndexEntry(
            id: indexedSessionID,
            tabID: indexedTabID,
            name: "Persisted Remote",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSinceReferenceDate: 70),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 1,
            agentKindRaw: AgentProviderKind.codexExec.rawValue,
            agentModelRaw: "codex",
            agentReasoningEffortRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: "host-index",
            remoteHostName: "Index Host",
            remoteSessionID: "remote-index",
            isMCPOriginated: false,
            origin: .user,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        viewModel.test_installSessionIndexSnapshot(
            [indexedSessionID: indexedEntry],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )

        let liveSession = AgentTabSession(tabID: UUID())
        liveSession.remoteHost = makeBinding(hostID: "host-live", remoteSessionID: "remote-live")
        viewModel.test_installLiveSession(liveSession)

        let coordinator = RemoteAgentModeCoordinator()
        coordinator.attach(viewModel: viewModel)

        XCTAssertTrue(coordinator.localSessionExists(hostID: "host-index", remoteSessionID: "remote-index"))
        XCTAssertTrue(coordinator.localSessionExists(hostID: "host-live", remoteSessionID: "remote-live"))
        XCTAssertFalse(coordinator.localSessionExists(hostID: "host-index", remoteSessionID: "remote-live"))
        XCTAssertFalse(coordinator.localSessionExists(hostID: "host-live", remoteSessionID: "   "))
    }

    func testLegacyMetadataIndexRecordsDecodeWithoutRemoteHostFields() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000306",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000306.json",
              "name": "Indexed Legacy Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(payload.utf8))
        let record = try XCTUnwrap(decoded.entries.first)

        XCTAssertNil(record.remoteHostID)
        XCTAssertNil(record.remoteHostName)
        XCTAssertNil(record.remoteSessionID)
        XCTAssertNil(record.agentSessionMeta().remoteHostID)
        XCTAssertNil(record.agentSessionMeta().remoteHostName)
        XCTAssertNil(record.agentSessionMeta().remoteSessionID)
    }

    func testStartWithNewRemoteSessionResetsCountersAndAcceptsSeqOne() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(sessionID: "remote-session-new")],
            "poll": [Self.snapshotPayload()],
            "get_log": [
                Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>")
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "remote-session-old"),
            connection: connection
        )

        let sessionID = try await controller.start(
            message: "hello",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-new")
        let logOffsets = await connection.getLogOffsets()
        XCTAssertEqual(logOffsets.first, 0)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-new",
            seq: 1,
            payload: Self.snapshotPayload()
        ))
        await waitForRemoteAgentSessionCondition {
            await (controller.currentBinding())?.lastAppliedSeq == 1
        }

        let currentBinding = await controller.currentBinding()
        let binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.lastAppliedSeq, 1)
        XCTAssertEqual(binding.nextLogOffset, 0)
    }

    func testStartRetainsAdoptedBindingAfterTransientSubscribeFailureAndRecovers() async throws {
        let connection = RecordingRemoteAgentSessionConnection(
            responses: [
                "start": [Self.snapshotPayload(sessionID: "remote-session-recovered")],
                "poll": [Self.snapshotPayload()],
                "get_log": [Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>")]
            ],
            subscribeErrors: [.timeout(operation: "subscribe", seconds: 30)]
        )
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        let sessionID = try await controller.start(
            message: "hello",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-recovered")
        let adoptedBinding = await controller.currentBinding()
        XCTAssertEqual(adoptedBinding?.remoteSessionID, "remote-session-recovered")
        await waitForRemoteAgentSessionCondition {
            let subscribeCount = await connection.subscribeCallCount()
            let pollCount = await connection.commandCount(type: "poll")
            return subscribeCount >= 2 && pollCount >= 1
        }
        let startCount = await connection.commandCount(type: "start")
        let messages = await recorder.recordedSystemMessages()
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(messages.contains { $0.contains("without resending") })
        XCTAssertTrue(messages.contains("Remote observation restored."))
    }

    func testDefinitiveSubscribeFailureStillThrowsAfterPersistingAdoptedBinding() async throws {
        let connection = RecordingRemoteAgentSessionConnection(
            responses: [
                "start": [Self.snapshotPayload(sessionID: "remote-session-bound")]
            ],
            subscribeErrors: [
                .bindingRequired(.init(code: "binding_required", message: "bind first"))
            ]
        )
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        do {
            _ = try await controller.start(
                message: "hello",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil
            )
            XCTFail("Expected binding_required to remain a definitive observation failure")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }

        let adoptedBinding = await controller.currentBinding()
        let startCount = await connection.commandCount(type: "start")
        XCTAssertEqual(adoptedBinding?.remoteSessionID, "remote-session-bound")
        XCTAssertEqual(startCount, 1)
    }

    func testUnsubscribeDuringGatedRecoveryCompensatesStaleSubscription() async throws {
        let subscribeGate = RemoteSubscribeGate()
        let connection = RecordingRemoteAgentSessionConnection(
            responses: [
                "start": [Self.snapshotPayload(sessionID: "remote-session-recovery-cancel")]
            ],
            subscribeErrors: [.timeout(operation: "subscribe", seconds: 30)],
            subscribeGate: subscribeGate
        )
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        _ = try await controller.start(
            message: "hello",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        await subscribeGate.waitUntilEntered()

        await controller.unsubscribe()
        await subscribeGate.release()
        await waitForRemoteAgentSessionCondition {
            await connection.unsubscribeCallCount() >= 2
        }

        let pollCount = await connection.commandCount(type: "poll")
        let unsubscribed = await connection.unsubscribedSessionIDBatches()
        XCTAssertEqual(pollCount, 0)
        XCTAssertEqual(unsubscribed.last, ["remote-session-recovery-cancel"])
    }

    func testWithheldPushStaleRecoveryCompletesParkedTurnWithoutResending() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "remote-session-stale-complete"
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
            "poll": [
                Self.snapshotPayload(status: "running", sessionID: sessionID),
                Self.snapshotPayload(status: "completed", sessionID: sessionID)
            ],
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>",
                    completed: 0
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Completed reply</assistant>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Completed reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        _ = try await controller.start(
            message: "Prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }
        await assertCommandCount(connection, type: "poll", equals: 1)
        await assertCommandCount(connection, type: "get_log", equals: 1)

        scheduler.advance(by: 9)
        await Task.yield()
        await assertCommandCount(connection, type: "poll", equals: 1)

        scheduler.advance(by: 1)
        await waitForDeterministicRemoteAgentSessionCondition {
            let rows = await recorder.upsertedTranscriptRows()
            let runStates = await recorder.recordedRunStates()
            return rows.map(\.text) == ["Prompt", "Completed reply"] && runStates.last == .completed
        }
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") == 3
        }
        await assertCommandCount(connection, type: "get_log", equals: 3)

        let binding = await controller.currentBinding()
        let rows = await recorder.upsertedTranscriptRows()
        let runStates = await recorder.recordedRunStates()
        XCTAssertEqual(binding?.nextLogOffset, 1)
        XCTAssertEqual(rows.map(\.text), ["Prompt", "Completed reply"])
        XCTAssertEqual(runStates.last, .completed)
        await assertCommandCount(connection, type: "start", equals: 1)
        await assertSubscribeCount(connection, equals: 1)
        await assertCommandCount(connection, type: "steer", equals: 0)
        await assertCommandCount(connection, type: "respond", equals: 0)
        await assertCommandCount(connection, type: "cancel", equals: 0)
    }

    func testSteerAfterTerminalReArmsStaleRecoveryAndCompletesParkedTurnWithoutPush() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "remote-session-terminal-steer"
        let completePage = Self.logPayload(
            offset: 1,
            returned: 1,
            total: 2,
            xml: "<assistant>Recovered reply</assistant>",
            completed: 2
        )
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "steer": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
            "poll": [
                Self.snapshotPayload(status: "completed", sessionID: sessionID),
                Self.snapshotPayload(status: "running", sessionID: sessionID),
                Self.snapshotPayload(status: "completed", sessionID: sessionID)
            ],
            "get_log": [
                Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1),
                Self.logPayload(
                    offset: 1,
                    returned: 1,
                    total: 2,
                    xml: "<assistant>Still working</assistant>",
                    completed: 1
                ),
                completePage,
                completePage
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 1),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        try await controller.attachAndCatchUp()
        XCTAssertEqual(scheduler.pendingSleeperCount(), 0)

        try await controller.steer("Continue")
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }
        let parkedBinding = await controller.currentBinding()
        XCTAssertEqual(parkedBinding?.nextLogOffset, 1)

        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            let rows = await recorder.upsertedTranscriptRows()
            let runStates = await recorder.recordedRunStates()
            return await connection.commandCount(type: "get_log") == 4
                && scheduler.pendingSleeperCount() == 0
                && rows.contains { $0.text == "Recovered reply" }
                && runStates.last == .completed
        }

        let binding = await controller.currentBinding()
        let rows = await recorder.upsertedTranscriptRows()
        let runStates = await recorder.recordedRunStates()
        XCTAssertEqual(binding?.nextLogOffset, 2)
        XCTAssertTrue(rows.contains { $0.text == "Recovered reply" })
        XCTAssertEqual(runStates.last, .completed)
        await assertCommandCount(connection, type: "steer", equals: 1)

        let pollCountAtTerminal = await connection.commandCount(type: "poll")
        scheduler.advance(by: 100)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(scheduler.pendingSleeperCount(), 0)
        await assertCommandCount(connection, type: "poll", equals: pollCountAtTerminal)
    }

    func testSteerInDoubtCatchUpReArmsStaleRecoveryWithoutResending() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "remote-session-in-doubt-steer"
        let connection = RecordingRemoteAgentSessionConnection(
            responses: [
                "poll": [
                    Self.snapshotPayload(status: "completed", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1),
                    Self.logPayload(
                        offset: 1,
                        returned: 1,
                        total: 2,
                        xml: "<assistant>Still working</assistant>",
                        completed: 1
                    )
                ]
            ],
            commandErrors: [
                "steer": [
                    .inDoubt(.init(code: "in_doubt", message: "Outcome uncertain"))
                ]
            ]
        )
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 1),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        defer { Task { await controller.shutdown() } }

        try await controller.attachAndCatchUp()
        XCTAssertEqual(scheduler.pendingSleeperCount(), 0)

        do {
            try await controller.steer("Continue")
            XCTFail("Expected the steer outcome to remain in doubt")
        } catch RemoteClientError.inDoubt {}

        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }
        let binding = await controller.currentBinding()
        XCTAssertEqual(binding?.nextLogOffset, 1)
        await assertCommandCount(connection, type: "steer", equals: 1)
        await assertCommandCount(connection, type: "poll", equals: 2)
    }

    func testRespondAlreadyResolvedReArmsStaleRecoveryAndCompletesWithoutResending() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "remote-session-resolved-respond"
        let completePage = Self.logPayload(
            offset: 1,
            returned: 1,
            total: 2,
            xml: "<assistant>Authoritative reply</assistant>",
            completed: 2
        )
        let connection = RecordingRemoteAgentSessionConnection(
            responses: [
                "poll": [
                    Self.snapshotPayload(status: "completed", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID),
                    Self.snapshotPayload(status: "completed", sessionID: sessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1),
                    Self.logPayload(
                        offset: 1,
                        returned: 1,
                        total: 2,
                        xml: "<assistant>Pending reply</assistant>",
                        completed: 1
                    ),
                    completePage,
                    completePage
                ]
            ],
            commandErrors: [
                "respond": [
                    .interactionAlreadyResolved(.init(
                        code: "interaction_already_resolved",
                        message: "Already resolved"
                    ))
                ]
            ]
        )
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 1),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        try await controller.attachAndCatchUp()
        XCTAssertEqual(scheduler.pendingSleeperCount(), 0)

        try await controller.respond(
            interactionID: "interaction-1",
            payload: .init(response: "Approved")
        )
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }

        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") == 4
                && scheduler.pendingSleeperCount() == 0
        }

        let rows = await recorder.upsertedTranscriptRows()
        let binding = await controller.currentBinding()
        XCTAssertTrue(rows.contains { $0.text == "Authoritative reply" })
        XCTAssertEqual(binding?.nextLogOffset, 2)
        await assertCommandCount(connection, type: "respond", equals: 1)
    }

    func testCancelCommandTailKeepsTerminalSettledAndReArmsWhileStillRunning() async throws {
        do {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let sessionID = "remote-session-terminal-cancel"
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "cancel": [Self.snapshotPayload(status: "cancelled", sessionID: sessionID)],
                "poll": [
                    Self.snapshotPayload(status: "completed", sessionID: sessionID),
                    Self.snapshotPayload(status: "cancelled", sessionID: sessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1),
                    Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1)
                ]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 1),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )
            defer { Task { await controller.shutdown() } }

            try await controller.attachAndCatchUp()
            try await controller.cancel()
            XCTAssertEqual(scheduler.pendingSleeperCount(), 0)

            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "cancel", equals: 1)
            await assertCommandCount(connection, type: "poll", equals: 2)
            await controller.shutdown()
        }

        do {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let sessionID = "remote-session-running-cancel"
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "cancel": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "poll": [
                    Self.snapshotPayload(status: "completed", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 1, returned: 0, total: 1, xml: "<transcript/>", completed: 1),
                    Self.logPayload(
                        offset: 1,
                        returned: 1,
                        total: 2,
                        xml: "<assistant>Cancelling</assistant>",
                        completed: 1
                    )
                ]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 1),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )
            defer { Task { await controller.shutdown() } }

            try await controller.attachAndCatchUp()
            try await controller.cancel()
            await waitForDeterministicRemoteAgentSessionCondition {
                scheduler.pendingSleeperCount() == 1
            }
            await assertCommandCount(connection, type: "cancel", equals: 1)
            await controller.shutdown()
        }
    }

    func testStaleRecoveryBackoffIsBoundedSingleFlightAndDeduplicatesRows() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "remote-session-stale-bounded"
        let parked = Self.logPayload(
            offset: 0,
            returned: 1,
            total: 1,
            xml: "<user>Prompt</user>\n<assistant>Still working</assistant>",
            completed: 0
        )
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
            "poll": Array(repeating: Self.snapshotPayload(status: "running", sessionID: sessionID), count: 4),
            "get_log": Array(repeating: parked, count: 4)
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        _ = try await controller.start(
            message: "Prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }

        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "poll") == 2
                && scheduler.pendingSleeperCount() == 1
        }
        scheduler.advance(by: 5)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "poll") == 3
                && scheduler.pendingSleeperCount() == 1
        }
        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "poll") == 4
        }
        scheduler.advance(by: 100)
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let rows = await recorder.upsertedTranscriptRows()
        await assertCommandCount(connection, type: "poll", equals: 4)
        await assertCommandCount(connection, type: "get_log", equals: 4)
        await assertCommandCount(connection, type: "start", equals: 1)
        await assertSubscribeCount(connection, equals: 1)
        await assertCommandCount(connection, type: "steer", equals: 0)
        await assertCommandCount(connection, type: "respond", equals: 0)
        await assertCommandCount(connection, type: "cancel", equals: 0)
        await assertMaximumObservationConcurrency(connection, equals: 1)
        XCTAssertEqual(rows.map(\.text), ["Prompt", "Still working"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testObservationProgressResetsStaleDeadlineAndCoalescesPushScheduledAndCommandCatchUp() async throws {
        let parked = Self.logPayload(
            offset: 0,
            returned: 1,
            total: 1,
            xml: "<user>Prompt</user>\n<assistant>Working</assistant>",
            completed: 0
        )

        do {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let sessionID = "remote-session-unrelated-progress"
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "start": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "poll": [
                    Self.snapshotPayload(status: "running", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID)
                ],
                "get_log": [parked, parked]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )

            _ = try await controller.start(
                message: "Prompt",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil
            )
            await waitForDeterministicRemoteAgentSessionCondition {
                scheduler.pendingSleeperCount() == 1
            }
            scheduler.advance(by: 9)
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: "unrelated-session",
                seq: 1,
                payload: Self.snapshotPayload(status: "running", sessionID: "unrelated-session")
            ))
            scheduler.advance(by: 1)
            await waitForDeterministicRemoteAgentSessionCondition {
                let pollCount = await connection.commandCount(type: "poll")
                let getLogCount = await connection.commandCount(type: "get_log")
                return pollCount == 2 && getLogCount == 2
            }
            await controller.shutdown()
        }

        do {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let sessionID = "remote-session-current-progress"
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "start": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "poll": [
                    Self.snapshotPayload(status: "running", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID)
                ],
                "get_log": [parked, parked, parked]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )

            _ = try await controller.start(
                message: "Prompt",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil
            )
            await waitForDeterministicRemoteAgentSessionCondition {
                scheduler.pendingSleeperCount() == 1
            }
            scheduler.advance(by: 9)
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: sessionID,
                seq: 1,
                payload: Self.snapshotPayload(status: "running", sessionID: sessionID)
            ))
            await waitForDeterministicRemoteAgentSessionCondition {
                await connection.commandCount(type: "get_log") == 2
                    && scheduler.pendingSleeperCount() == 1
            }

            scheduler.advance(by: 1)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", equals: 1)

            scheduler.advance(by: 9)
            await waitForDeterministicRemoteAgentSessionCondition {
                let pollCount = await connection.commandCount(type: "poll")
                let getLogCount = await connection.commandCount(type: "get_log")
                return pollCount == 2 && getLogCount == 3
            }
            await controller.shutdown()
        }

        do {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let sessionID = "remote-session-catchup-coalescing"
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "start": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "steer": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "respond": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "poll": [
                    Self.snapshotPayload(status: "running", sessionID: sessionID),
                    Self.snapshotPayload(status: "running", sessionID: sessionID)
                ],
                "get_log": [parked, parked, parked]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )
            let recorder = RemoteSessionEventRecorder()
            let eventTask = Task {
                for await event in controller.events {
                    await recorder.record(event)
                }
            }
            defer {
                eventTask.cancel()
                Task { await controller.shutdown() }
            }

            _ = try await controller.start(
                message: "Prompt",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil
            )
            await waitForDeterministicRemoteAgentSessionCondition {
                scheduler.pendingSleeperCount() == 1
            }

            let gate = RemoteObservationCommandGate()
            await connection.setObservationGate(gate, type: "get_log")
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: sessionID,
                seq: 1,
                payload: Self.snapshotPayload(status: "running", sessionID: sessionID)
            ))
            await gate.waitUntilEntered()

            let steerTask = Task { try await controller.steer("Continue") }
            let respondTask = Task {
                try await controller.respond(
                    interactionID: "interaction-1",
                    payload: .init(response: "Approved")
                )
            }
            await waitForDeterministicRemoteAgentSessionCondition {
                let steerCount = await connection.commandCount(type: "steer")
                let respondCount = await connection.commandCount(type: "respond")
                return steerCount == 1 && respondCount == 1
            }
            await assertCommandCount(connection, type: "poll", equals: 1)
            await assertCommandCount(connection, type: "get_log", equals: 2)
            await assertMaximumObservationConcurrency(connection, equals: 1)

            await gate.release()
            try await steerTask.value
            try await respondTask.value
            await waitForDeterministicRemoteAgentSessionCondition {
                let pollCount = await connection.commandCount(type: "poll")
                let getLogCount = await connection.commandCount(type: "get_log")
                return pollCount == 2 && getLogCount == 3
            }
            let rowsAfterOverlap = await recorder.upsertedTranscriptRows()
            XCTAssertEqual(rowsAfterOverlap.map(\.text), ["Prompt", "Working"])
            XCTAssertEqual(Set(rowsAfterOverlap.map(\.id)).count, rowsAfterOverlap.count)
            await assertMaximumObservationConcurrency(connection, equals: 1)

            await connection.setObservationGate(nil, type: nil)
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_terminal",
                sessionID: sessionID,
                seq: 2,
                payload: Self.snapshotPayload(status: "completed", sessionID: sessionID)
            ))
            await waitForDeterministicRemoteAgentSessionCondition {
                await (recorder.recordedTerminalStatuses()).contains("completed")
            }
            let pollCountAtTerminal = await connection.commandCount(type: "poll")
            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", equals: pollCountAtTerminal)
            await controller.shutdown()
            eventTask.cancel()
        }
    }

    func testStaleRecoveryCancelsAcrossTerminalExpiredStartUnsubscribeShutdownAndReplacement() async throws {
        func makeAttached(
            sessionID: String
        ) async throws -> (
            RemoteAgentSessionController,
            RecordingRemoteAgentSessionConnection,
            ManualRemoteAgentSessionRecoveryScheduler
        ) {
            let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
            let connection = RecordingRemoteAgentSessionConnection(responses: [
                "poll": [Self.snapshotPayload(status: "running", sessionID: sessionID)],
                "get_log": [Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>")]
            ])
            let controller = RemoteAgentSessionController(
                binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 0),
                connection: connection,
                recoveryScheduler: scheduler,
                recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
            )
            try await controller.attachAndCatchUp()
            await waitForDeterministicRemoteAgentSessionCondition {
                scheduler.pendingSleeperCount() == 1
            }
            return (controller, connection, scheduler)
        }

        do {
            let (controller, connection, scheduler) = try await makeAttached(sessionID: "terminal-session")
            await connection.enqueue(
                Self.snapshotPayload(status: "completed", sessionID: "terminal-session"),
                forType: "poll"
            )
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_terminal",
                sessionID: "terminal-session",
                seq: 1,
                payload: Self.snapshotPayload(status: "completed", sessionID: "terminal-session")
            ))
            await waitForDeterministicRemoteAgentSessionCondition {
                await connection.commandCount(type: "get_log", sessionID: "terminal-session") == 2
            }
            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", sessionID: "terminal-session", equals: 1)
            await controller.shutdown()
        }

        do {
            let (controller, connection, scheduler) = try await makeAttached(sessionID: "expired-session")
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_expired",
                sessionID: "expired-session",
                seq: 1,
                payload: Self.snapshotPayload(status: "expired", sessionID: "expired-session")
            ))
            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", sessionID: "expired-session", equals: 1)
            await controller.shutdown()
        }

        for replacementID in ["same-start-session", "replacement-session"] {
            let oldSessionID = replacementID == "same-start-session" ? replacementID : "old-session"
            let (controller, connection, scheduler) = try await makeAttached(sessionID: oldSessionID)
            await connection.enqueue(
                Self.snapshotPayload(status: "running", sessionID: replacementID),
                forType: "start"
            )
            await connection.enqueue(
                Self.snapshotPayload(status: "running", sessionID: replacementID),
                forType: "poll"
            )
            await connection.enqueue(
                Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>"),
                forType: "get_log"
            )
            _ = try await controller.start(
                message: "New turn",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil
            )
            if replacementID == oldSessionID {
                let countAfterStart = await connection.commandCount(type: "poll")
                scheduler.advance(by: 9)
                for _ in 0 ..< 20 {
                    await Task.yield()
                }
                await assertCommandCount(connection, type: "poll", equals: countAfterStart)
            } else {
                scheduler.advance(by: 100)
                await waitForDeterministicRemoteAgentSessionCondition {
                    await connection.commandCount(type: "poll") >= 2
                }
                await assertCommandCount(connection, type: "poll", sessionID: oldSessionID, equals: 1)
            }
            await controller.shutdown()
        }

        do {
            let (controller, connection, scheduler) = try await makeAttached(sessionID: "unsubscribe-session")
            let gate = RemoteObservationCommandGate()
            await connection.setObservationGate(gate, type: "get_log")
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: "unsubscribe-session",
                seq: 1,
                payload: Self.snapshotPayload(status: "running", sessionID: "unsubscribe-session")
            ))
            await gate.waitUntilEntered()
            await controller.unsubscribe()
            await gate.release()
            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", sessionID: "unsubscribe-session", equals: 1)
            await assertCommandCount(connection, type: "get_log", sessionID: "unsubscribe-session", equals: 2)
            await controller.shutdown()
        }

        do {
            let (controller, connection, scheduler) = try await makeAttached(sessionID: "shutdown-session")
            await controller.shutdown()
            scheduler.advance(by: 100)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            await assertCommandCount(connection, type: "poll", sessionID: "shutdown-session", equals: 1)
        }
    }

    func testStaleRecoveryPausesOnDisconnectResumesSameSessionAndDefersToTransientRecovery() async throws {
        let scheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let sessionID = "pause-resume-session"
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "poll": Array(repeating: Self.snapshotPayload(status: "running", sessionID: sessionID), count: 4),
            "get_log": Array(
                repeating: Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>"),
                count: 4
            )
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection,
            recoveryScheduler: scheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        defer { Task { await controller.shutdown() } }

        try await controller.attachAndCatchUp()
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }

        await controller.handleConnectionState(.degraded(code: "network", retryAt: Date()))
        scheduler.advance(by: 100)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await assertCommandCount(connection, type: "poll", equals: 1)

        await controller.handleConnectionState(.connected(scopes: []))
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }
        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "poll") == 2
        }

        await controller.handleConnectionState(.idle)
        scheduler.advance(by: 100)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await assertCommandCount(connection, type: "poll", equals: 2)

        await controller.handleConnectionState(.connected(scopes: []))
        await waitForDeterministicRemoteAgentSessionCondition {
            scheduler.pendingSleeperCount() == 1
        }
        scheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await connection.commandCount(type: "poll") == 3
        }
        await assertMaximumObservationConcurrency(connection, equals: 1)

        let transientScheduler = ManualRemoteAgentSessionRecoveryScheduler()
        let transientSessionID = "transient-owner-session"
        let subscribeGate = RemoteSubscribeGate()
        let transientConnection = RecordingRemoteAgentSessionConnection(
            responses: [
                "start": [Self.snapshotPayload(status: "running", sessionID: transientSessionID)],
                "poll": [
                    Self.snapshotPayload(status: "running", sessionID: transientSessionID),
                    Self.snapshotPayload(status: "running", sessionID: transientSessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>"),
                    Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>")
                ]
            ],
            subscribeErrors: [.timeout(operation: "subscribe", seconds: 30)],
            subscribeGate: subscribeGate
        )
        let transientController = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: transientConnection,
            recoveryScheduler: transientScheduler,
            recoveryPolicy: .init(staleIntervalSeconds: 10, retryDelaySeconds: [5, 10])
        )
        defer { Task { await transientController.shutdown() } }

        _ = try await transientController.start(
            message: "Prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        await subscribeGate.waitUntilEntered()
        transientScheduler.advance(by: 100)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await assertCommandCount(transientConnection, type: "poll", equals: 0)

        await subscribeGate.release()
        await waitForDeterministicRemoteAgentSessionCondition {
            await transientConnection.commandCount(type: "poll") == 1
                && transientScheduler.pendingSleeperCount() == 1
        }
        transientScheduler.advance(by: 10)
        await waitForDeterministicRemoteAgentSessionCondition {
            await transientConnection.commandCount(type: "poll") == 2
        }
        await assertSubscribeCount(transientConnection, equals: 2)
        await assertCommandCount(transientConnection, type: "start", equals: 1)
        await assertMaximumObservationConcurrency(transientConnection, equals: 1)
    }

    func testEpochChangeResetsEventCursorKeepsLogOffsetAndRejectsRetiredEpoch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "poll": [Self.snapshotPayload()],
            "get_log": [
                Self.logPayload(offset: 7, returned: 0, total: 7, xml: "<transcript/>")
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(lastAppliedSeq: 42, seqEpoch: "epoch-old", nextLogOffset: 7),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            seqEpoch: "epoch-new",
            payload: Self.snapshotPayload()
        ))

        var currentBinding = await controller.currentBinding()
        var binding = try XCTUnwrap(currentBinding)
        let firstLogOffset = await connection.getLogOffsets().first
        XCTAssertEqual(binding.seqEpoch, "epoch-new")
        XCTAssertEqual(binding.lastAppliedSeq, 1)
        XCTAssertEqual(binding.nextLogOffset, 7)
        XCTAssertEqual(firstLogOffset, 7)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 43,
            seqEpoch: "epoch-old",
            payload: Self.snapshotPayload()
        ))

        currentBinding = await controller.currentBinding()
        binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.seqEpoch, "epoch-new")
        XCTAssertEqual(binding.lastAppliedSeq, 1)
    }

    func testPersistedEpochTransitionsToLegacyDomainAndRejectsDelayedRetiredEpoch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "poll": [Self.snapshotPayload()],
            "get_log": [
                Self.logPayload(offset: 7, returned: 0, total: 7, xml: "<transcript/>")
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(lastAppliedSeq: 42, seqEpoch: "epoch-known", nextLogOffset: 7),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload()
        ))

        var currentBinding = await controller.currentBinding()
        var binding = try XCTUnwrap(currentBinding)
        XCTAssertNil(binding.seqEpoch)
        XCTAssertEqual(binding.lastAppliedSeq, 1)
        XCTAssertEqual(binding.nextLogOffset, 7)
        let pollCount = await connection.commandCount(type: "poll")
        XCTAssertGreaterThanOrEqual(pollCount, 1)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 43,
            seqEpoch: "epoch-known",
            payload: Self.snapshotPayload()
        ))

        currentBinding = await controller.currentBinding()
        binding = try XCTUnwrap(currentBinding)
        XCTAssertNil(binding.seqEpoch)
        XCTAssertEqual(binding.lastAppliedSeq, 1)
    }

    func testContiguousSessionUpdateTriggersLogFetch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Remote reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload()
        ))

        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Remote reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    func testRapidSessionUpdatesCoalesceLogCatchUpWork() async {
        let connection = RecordingRemoteAgentSessionConnection(getLogDelayNanoseconds: 50_000_000)
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        for seq in UInt64(1) ... UInt64(10) {
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: "remote-session-abc",
                seq: seq,
                payload: Self.snapshotPayload()
            ))
        }

        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertGreaterThanOrEqual(getLogCount, 1)
        XCTAssertLessThanOrEqual(getLogCount, 2)
    }

    func testSessionTerminalTriggersFinalLogFetch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed")
        ))

        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Final reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 2)
        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 1])
    }

    func testCompletedDetachedStartStillFetchesInitialReplyLog() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "completed", sessionID: "remote-session-done")],
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Initial reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        let sessionID = try await controller.start(
            message: "Halo",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: 2,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-done")
        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Initial reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    func testStartCatchUpCapsPoisonedCompletedTurnWhileRunActive() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "running", sessionID: "remote-session-race")],
            "poll": [Self.snapshotPayload(status: "running", sessionID: "remote-session-race")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        let sessionID = try await controller.start(
            message: "Prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-race")
        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 0)
        await waitForRemoteAgentSessionCondition {
            await recorder.hasTranscriptBatchCount(1)
        }
        let initialRows = await recorder.allTranscriptRows()
        XCTAssertEqual(initialRows.first?.map(\.text), ["Prompt"])

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-race",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed", sessionID: "remote-session-race")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }

        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows[1].map(\.text), ["Prompt", "Reply"])
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 1)
        let getLogOffsets = await connection.getLogOffsets()
        XCTAssertEqual(getLogOffsets, [0, 0, 0])
    }

    func testCompletedRemoteLogPageConsumesWhenRunInactive() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Old reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }

        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 1)
    }

    func testWaitingRemoteTurnIsRefetchedUntilCompletedTurnCountAdvances() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Need approval</assistant>",
                    completed: 0
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Need approval</assistant>\n<assistant>Approved reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 0)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }
        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows[0].map(\.text), ["Prompt", "Need approval"])
        XCTAssertEqual(allRows[1].map(\.text), ["Prompt", "Need approval", "Approved reply"])
        XCTAssertEqual(Set(allRows[0].map(\.id)).count, allRows[0].count)
        XCTAssertEqual(Set(allRows[1].map(\.id)).count, allRows[1].count)
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 1)
        let systemMessages = await recorder.recordedSystemMessages()
        XCTAssertFalse(systemMessages.contains("Remote log page did not advance; stopped catch-up paging."))
        let getLogOffsets = await connection.getLogOffsets()
        XCTAssertEqual(getLogOffsets, [0, 0, 0])
    }

    func testMixedCompletedAndIncompletePageIsSplitBeforeEmittingRows() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 2,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>\n<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 1,
                    returned: 1,
                    total: 2,
                    xml: "<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 1,
                    returned: 1,
                    total: 2,
                    xml: "<user>Second prompt</user>\n<assistant>Second reply</assistant>",
                    completed: 2
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 3
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }

        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 1)
        let requestsAfterPark = await connection.getLogRequests()
        XCTAssertEqual(requestsAfterPark.prefix(3).map(\.offset), [0, 0, 1])
        XCTAssertEqual(requestsAfterPark.prefix(3).map(\.limit), [20, 1, 20])

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 4
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 3
        }

        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows.filter { !$0.isEmpty }.map { $0.map(\.text) }, [
            ["First prompt", "First reply"],
            ["Second prompt"],
            ["Second prompt", "Second reply"]
        ])
        let upsertedRows = await recorder.upsertedTranscriptRows()
        XCTAssertEqual(upsertedRows.count(where: { $0.text == "Second prompt" }), 1)
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 2)
    }

    func testMixedCompletedSubpageRegressionIsDiscardedWithoutAdvancing() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 2,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>\n<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>",
                    completed: 0
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 1])
        let transcriptRows = await recorder.allTranscriptRows()
        XCTAssertTrue(transcriptRows.isEmpty)
        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 0)
    }

    func testSeqGapCatchUpFailureEmitsSystemMessageOncePerFailureStreak() async {
        let connection = FailingGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await (recorder.recordedSystemMessages()).contains { $0.contains("Remote transcript catch-up failed:") }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let messages = await (recorder.recordedSystemMessages()).filter { $0.contains("Remote transcript catch-up failed:") }
        XCTAssertEqual(messages.count, 1)
    }

    func testRepeatedScheduledSessionExpiredCatchUpYieldsOnce() async {
        let connection = SessionExpiredGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await recorder.sessionExpiredCount() == 1
        }
        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let expiredCount = await recorder.sessionExpiredCount()
        XCTAssertEqual(expiredCount, 1)
    }

    func testScheduledCatchUpFailureEmitsSystemMessageOncePerFailureStreak() async {
        let connection = FailingGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await (recorder.recordedSystemMessages()).contains { $0.contains("Remote transcript catch-up failed:") }
        }
        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let messages = await (recorder.recordedSystemMessages()).filter { $0.contains("Remote transcript catch-up failed:") }
        XCTAssertEqual(messages.count, 1)
    }

    func testLogPageWithoutCompletedTurnCountAdvancesCursorCompatibly() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Legacy reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 1)
    }

    func testRemoteTurnPolicySteersCompletedSessionWhenRemoteSessionIDExists() {
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .idle,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .waitingForQuestion,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: nil
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: "  \n"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .failed,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .cancelled,
            remoteSessionID: "remote-session-abc"
        ))
    }

    func testRemoteStartSessionNameDerivationUsesDefaultTitlesOnly() {
        let derived = AgentSessionTitleNaming.sessionNameForRemoteStart(
            currentTitle: "T10",
            userText: "Fix the flaky auth test by avoiding sleeps in worker startup"
        )
        XCTAssertEqual(derived, "Fix the flaky auth test by avoiding")
        XCTAssertLessThanOrEqual(derived.count, 40)

        XCTAssertEqual(
            AgentSessionTitleNaming.sessionNameForRemoteStart(
                currentTitle: "Customer Chosen Title",
                userText: "Fix the flaky auth test"
            ),
            "Customer Chosen Title"
        )
        XCTAssertEqual(
            AgentSessionTitleNaming.sessionNameForRemoteStart(
                currentTitle: "T11",
                userText: "   \nSecond line should not be used"
            ),
            "T11"
        )
    }

    @MainActor
    func testCoordinatorAdoptsHostSessionNameForDefaultTitleAndUpdatesIndex() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T10")

        fixture.coordinator.test_applyMetadata(sessionName: "  Host Derived Session  ", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "Host Derived Session")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "Host Derived Session")
    }

    @MainActor
    func testCoordinatorDoesNotOverwriteUserTypedSessionName() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "User Typed Session")

        fixture.coordinator.test_applyMetadata(sessionName: "Host Suggested Session", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "User Typed Session")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "User Typed Session")
    }

    @MainActor
    func testCoordinatorReadoptsPreviouslyAdoptedHostSessionName() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T12")

        fixture.coordinator.test_applyMetadata(sessionName: "Host First Name", tabID: fixture.tabID)
        fixture.coordinator.test_applyMetadata(sessionName: "Host Better Name", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "Host Better Name")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "Host Better Name")
    }

    @MainActor
    func testChannelClosingReasonSurfacesAsBannerAndDedupedSystemRows() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding()
        session.runState = .running

        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(session.runningStatusText, "Remote reconnecting (app_link_unavailable)…")
        XCTAssertEqual(
            systemMessages(in: session),
            ["Remote channel degraded: app_link_unavailable. Reconnecting…"]
        )

        coordinator.test_applyChannel(.init(kind: .connected), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(systemMessages(in: session).count(where: { $0.contains("app_link_unavailable") }), 2)
    }

    @MainActor
    func testIdleChannelDegradeThenConnectedAppendsOneRestoredRow() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding()
        session.runState = .completed

        coordinator.test_applyChannel(.init(kind: .degraded(reason: "reconnect_failed")), to: session)
        coordinator.test_applyChannel(.init(kind: .connected), to: session)

        XCTAssertEqual(
            systemMessages(in: session),
            [
                "Remote channel degraded: reconnect_failed. Reconnecting…",
                "Remote channel restored."
            ]
        )
    }

    @MainActor
    func testConnectedWithoutSurfacedDegradationAppendsNoRestoredRow() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding()

        coordinator.test_applyChannel(.init(kind: .connected), to: session)
        coordinator.test_applyChannel(.init(kind: .connected), to: session)

        XCTAssertTrue(systemMessages(in: session).isEmpty)
    }

    @MainActor
    func testRepeatedDegradeRecoverCyclesAppendTwoPairedSequencesWithoutSpam() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding()

        for _ in 0 ..< 2 {
            coordinator.test_applyChannel(.init(kind: .degraded(reason: "reconnect_failed")), to: session)
            coordinator.test_applyChannel(.init(kind: .connected), to: session)
            coordinator.test_applyChannel(.init(kind: .connected), to: session)
        }

        XCTAssertEqual(
            systemMessages(in: session),
            [
                "Remote channel degraded: reconnect_failed. Reconnecting…",
                "Remote channel restored.",
                "Remote channel degraded: reconnect_failed. Reconnecting…",
                "Remote channel restored."
            ]
        )
    }

    @MainActor
    func testBindingRequiredErrorUsesFriendlyRemoteCopy() {
        let error = RemoteClientError.fromCommandError(
            code: "binding_required",
            message: "Call bind_context with {\"op\":\"bind\"} before using agent_run."
        )

        let description = RemoteAgentModeCoordinator.describe(error)

        XCTAssertEqual(
            description,
            "The host couldn't route this message to its window. Try again — if it keeps failing, the session's window may have been closed on the host."
        )
        XCTAssertFalse(description.contains("bind_context"))
    }

    func testListChildSessionsSendsParentFilterAndParsesDescriptors() async throws {
        let parentRemoteID = "11111111-1111-1111-1111-111111111111"
        let childRemoteID = "22222222-2222-2222-2222-222222222222"
        let siblingRemoteID = "33333333-3333-3333-3333-333333333333"
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [Self.listSessionsPayload(children: [
                Self.sessionDescriptorPayload(
                    sessionID: childRemoteID,
                    name: "Child Worker",
                    state: "running",
                    agentID: AgentProviderKind.codexExec.rawValue,
                    model: "codex",
                    parentSessionID: parentRemoteID
                ),
                Self.sessionDescriptorPayload(
                    sessionID: siblingRemoteID,
                    name: "Sibling Worker",
                    state: "completed",
                    agentID: AgentProviderKind.claudeCode.rawValue,
                    model: "claude",
                    parentSessionID: "44444444-4444-4444-4444-444444444444"
                )
            ])]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: parentRemoteID),
            connection: connection
        )

        let children = try await controller.listChildSessions()

        XCTAssertEqual(children.count, 1)
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(child.sessionID, childRemoteID)
        XCTAssertEqual(child.name, "Child Worker")
        XCTAssertEqual(child.stateRaw, "running")
        XCTAssertEqual(child.agentKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(child.agentModelRaw, "codex")
        XCTAssertEqual(child.parentSessionID, parentRemoteID)
        let frames = await connection.frames(type: "list_sessions")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertNil(frame.sessionID)
        XCTAssertEqual(frame.payload?.objectValue?["parent_session_id"]?.stringValue, parentRemoteID)
        XCTAssertEqual(frame.payload?.objectValue?["limit"]?.intValue, 500)
    }

    func testMetadataEventCarriesReasoningEffortFromSnapshot() async throws {
        let connection = RecordingRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(
            binding: makeBinding(lastAppliedSeq: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(
                agentID: "codexExec",
                agentModel: "gpt-5.4-mini",
                agentReasoningEffort: "high"
            )
        ))

        await waitForRemoteAgentSessionCondition {
            await !recorder.metadataEvents().isEmpty
        }
        let maybeEvent = await recorder.metadataEvents().first
        let event = try XCTUnwrap(maybeEvent)
        guard case let .metadata(agentKindRaw, modelRaw, reasoningEffortRaw, sessionName) = event else {
            return XCTFail("Expected metadata event")
        }
        XCTAssertEqual(agentKindRaw, "codexExec")
        XCTAssertEqual(modelRaw, "gpt-5.4-mini")
        XCTAssertEqual(reasoningEffortRaw, "high")
        XCTAssertNil(sessionName)
    }

    @MainActor
    func testCoordinatorMaterializesRemoteChildrenFromListSessionsAndDedupes() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let childRemoteID = UUID()
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: childRemoteID.uuidString,
                name: "Child Worker",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [childListPayload, childListPayload]
        ])
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        defer { fixture.coordinator.stop(tabID: fixture.tabID) }
        var attachedRemoteSessionIDs: [String] = []
        fixture.coordinator.test_setMaterializedRemoteChildAttachHandler { childSession in
            if let remoteSessionID = childSession.remoteHost?.remoteSessionID {
                attachedRemoteSessionIDs.append(remoteSessionID)
            }
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)

        await waitForRemoteCoordinatorLifecycle {
            fixture.viewModel.sessions.values.contains { $0.remoteHost?.remoteSessionID == childRemoteID.uuidString }
        }
        let listFrames = await recordingConnection.frames(type: "list_sessions")
        let firstListFrame = try XCTUnwrap(listFrames.first)
        XCTAssertEqual(firstListFrame.payload?.objectValue?["parent_session_id"]?.stringValue, parentRemoteID.uuidString)
        XCTAssertEqual(firstListFrame.payload?.objectValue?["limit"]?.intValue, 500)
        let materializedChildren = fixture.viewModel.sessions.values.filter {
            $0.remoteHost?.remoteSessionID == childRemoteID.uuidString
        }
        XCTAssertEqual(materializedChildren.count, 1)
        let childSession = try XCTUnwrap(materializedChildren.first)
        XCTAssertEqual(childSession.activeAgentSessionID, childRemoteID)
        XCTAssertEqual(childSession.parentSessionID, fixture.sessionID)
        XCTAssertEqual(childSession.remoteHost?.hostID, parentSession.remoteHost?.hostID)
        XCTAssertEqual(childSession.remoteHost?.remoteSessionID, childRemoteID.uuidString)
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[childRemoteID]?.parentSessionID, fixture.sessionID)
        XCTAssertEqual(attachedRemoteSessionIDs, [childRemoteID.uuidString])

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 2
        }
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count(where: { $0.remoteHost?.remoteSessionID == childRemoteID.uuidString }),
            1
        )
        XCTAssertEqual(attachedRemoteSessionIDs, [childRemoteID.uuidString])
    }

    @MainActor
    func testStopClearsStartSessionNameRecord() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T10")
        fixture.coordinator.test_recordStartSessionName("Derived Name", tabID: fixture.tabID)
        XCTAssertEqual(fixture.coordinator.test_startSessionNameRecord(tabID: fixture.tabID), "Derived Name")

        fixture.coordinator.stop(tabID: fixture.tabID)

        XCTAssertNil(fixture.coordinator.test_startSessionNameRecord(tabID: fixture.tabID))
    }

    @MainActor
    func testStopPrunesRemoteSubscriptionAndSendsUnsubscribe() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Parent")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-stop")
        let connection = RecordingRemoteAgentSessionConnection()
        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(session.remoteHost),
            connection: connection
        )
        let fanoutConnection = RemoteHostConnection(hostID: session.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: session.remoteHost?.hostID ?? "host-abc",
            controller: controller,
            connection: fanoutConnection
        )

        fixture.coordinator.stop(tabID: fixture.tabID)

        await waitForRemoteAgentSessionCondition {
            await connection.unsubscribedSessionIDBatches().contains(["remote-session-stop"])
        }
        let unsubscribedBatches = await connection.unsubscribedSessionIDBatches()
        XCTAssertEqual(unsubscribedBatches, [["remote-session-stop"]])
    }

    @MainActor
    func testStopCatchesBindingRequiredUnsubscribeFailure() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Parent")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-old-host")
        let connection = RecordingRemoteAgentSessionConnection(
            unsubscribeError: RemoteClientError.fromCommandError(
                code: "binding_required",
                message: "old host"
            )
        )
        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(session.remoteHost),
            connection: connection
        )
        let fanoutConnection = RemoteHostConnection(hostID: session.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: session.remoteHost?.hostID ?? "host-abc",
            controller: controller,
            connection: fanoutConnection
        )

        fixture.coordinator.stop(tabID: fixture.tabID)

        await waitForRemoteAgentSessionCondition {
            await connection.unsubscribedSessionIDBatches().contains(["remote-session-old-host"])
        }
        let counts = fixture.coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.eventTasks, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
    }

    @MainActor
    func testAttachPersistedTerminalChildSessionDoesNotAttachController() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Terminal Child")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-child-terminal")
        session.parentSessionID = UUID()
        session.runState = .completed

        fixture.coordinator.attachPersistedSessionIfNeeded(session)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let counts = fixture.coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.eventTasks, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
    }

    @MainActor
    func testSteerAttachesObservationForNeverAttachedSessionBeforeSending() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Terminal Child Steer")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        let sessionID = "remote-child-terminal-steer"
        session.remoteHost = makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 0)
        session.parentSessionID = UUID()
        session.runState = .completed

        // Restore deliberately skips attaching terminal child sessions.
        fixture.coordinator.attachPersistedSessionIfNeeded(session)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.coordinator.test_lifecycleCounts().controllers, 0)

        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "poll": [
                Self.snapshotPayload(status: "completed", sessionID: sessionID),
                Self.snapshotPayload(status: "completed", sessionID: sessionID)
            ],
            "steer": [Self.snapshotPayload(status: "running", sessionID: sessionID)]
        ])
        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(session.remoteHost),
            connection: connection
        )
        let fanoutConnection = RemoteHostConnection(hostID: session.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: session.remoteHost?.hostID ?? "host-abc",
            controller: controller,
            connection: fanoutConnection
        )

        // The first steer must self-heal observation: subscribe + catch-up, then send.
        try await fixture.coordinator.steer(
            session: session,
            text: "Continue",
            dispatch: RemoteInputDispatch(input: .inactiveForTesting(in: session))
        )

        let subscribeCount = await connection.subscribeCallCount()
        let steerCount = await connection.commandCount(type: "steer")
        let attached = await controller.hasAttachedObservation()
        XCTAssertEqual(subscribeCount, 1)
        XCTAssertEqual(steerCount, 1)
        XCTAssertTrue(attached)
        fixture.coordinator.stop(tabID: fixture.tabID)
    }

    @MainActor
    func testSteerWithheldWhenObservationAttachFailsHard() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Attach Fail Steer")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        let sessionID = "remote-attach-fail-steer"
        session.remoteHost = makeBinding(remoteSessionID: sessionID, lastAppliedSeq: 0, nextLogOffset: 0)

        let connection = RecordingRemoteAgentSessionConnection(
            subscribeErrors: [RemoteClientError.protocolViolation("subscribe rejected")]
        )
        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(session.remoteHost),
            connection: connection
        )
        let fanoutConnection = RemoteHostConnection(hostID: session.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: session.remoteHost?.hostID ?? "host-abc",
            controller: controller,
            connection: fanoutConnection
        )

        do {
            try await fixture.coordinator.steer(
                session: session,
                text: "Continue",
                dispatch: RemoteInputDispatch(input: .inactiveForTesting(in: session))
            )
            XCTFail("Expected steer to be withheld when observation attach fails hard")
        } catch {
            // Hard (non-transient) attach failure must surface as a send failure.
        }

        let subscribeCount = await connection.subscribeCallCount()
        let steerCount = await connection.commandCount(type: "steer")
        let attached = await controller.hasAttachedObservation()
        XCTAssertEqual(subscribeCount, 1)
        XCTAssertEqual(steerCount, 0)
        XCTAssertFalse(attached)
        fixture.coordinator.stop(tabID: fixture.tabID)
    }

    @MainActor
    func testInboundRunStateEventBumpsParentLastActivityAndIndexSavedAt() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Parent")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        let oldActivity = Date(timeIntervalSinceReferenceDate: 10)
        session.lastActivityAt = oldActivity
        session.remoteHost = makeBinding(remoteSessionID: "remote-parent-before")

        fixture.coordinator.test_handleEvent(
            .runState(.running, pendingInteraction: nil, statusText: nil),
            tabID: fixture.tabID
        )

        XCTAssertGreaterThan(session.lastActivityAt, oldActivity)
        XCTAssertGreaterThan(
            try XCTUnwrap(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.savedAt),
            oldActivity
        )
        XCTAssertEqual(session.remoteHost?.remoteSessionID, "remote-parent-before")
    }

    @MainActor
    func testApplyTranscriptRowsPreservesNewerOptimisticUserTimestamp() {
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-optimistic")
        let optimisticTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let projectedTimestamp = Date(timeIntervalSince1970: 2)
        let existingProjected = AgentChatItem(
            id: UUID(),
            timestamp: projectedTimestamp,
            kind: .user,
            text: "Hello remote",
            sequenceIndex: 0
        )
        let optimistic = AgentChatItem(
            timestamp: optimisticTimestamp,
            kind: .user,
            text: "Hello remote",
            sequenceIndex: 1
        )
        session.appendItem(existingProjected)
        session.appendItem(optimistic)
        session.pendingRemoteOptimisticUserItemIDs.insert(optimistic.id)
        let newProjected = AgentChatItem(
            id: UUID(),
            timestamp: projectedTimestamp,
            kind: .user,
            text: "Hello remote",
            sequenceIndex: 2
        )
        let coordinator = RemoteAgentModeCoordinator()

        coordinator.test_applyTranscriptRows([existingProjected, newProjected], to: session)

        let users = session.items.filter { $0.kind == .user }
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users.first { $0.id == existingProjected.id }?.timestamp, projectedTimestamp)
        XCTAssertEqual(users.first { $0.id == newProjected.id }?.timestamp, optimisticTimestamp)
        XCTAssertEqual(session.lastUserMessageAt, optimisticTimestamp)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.isEmpty)

        coordinator.test_applyTranscriptRows([existingProjected, newProjected], to: session)

        let usersAfterReprojection = session.items.filter { $0.kind == .user }
        XCTAssertEqual(usersAfterReprojection.count, 2)
        XCTAssertEqual(usersAfterReprojection.first { $0.id == existingProjected.id }?.timestamp, projectedTimestamp)
        XCTAssertEqual(usersAfterReprojection.first { $0.id == newProjected.id }?.timestamp, optimisticTimestamp)
        XCTAssertEqual(session.lastUserMessageAt, optimisticTimestamp)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.isEmpty)
    }

    @MainActor
    func testApplyTranscriptRowsKeepsLastUserMessageAtWhenOnlySyntheticUserRows() {
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-synthetic-only")
        let existingLastUserMessageAt = Date(timeIntervalSince1970: 1_700_000_000)
        let syntheticTimestamp = Date(timeIntervalSince1970: 3)
        session.lastUserMessageAt = existingLastUserMessageAt
        let row = AgentChatItem(
            id: UUID(),
            timestamp: syntheticTimestamp,
            kind: .user,
            text: "Synthetic only",
            sequenceIndex: 3
        )
        let coordinator = RemoteAgentModeCoordinator()

        coordinator.test_applyTranscriptRows([row], to: session)

        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.items.first?.timestamp, syntheticTimestamp)
        XCTAssertEqual(session.lastUserMessageAt, existingLastUserMessageAt)
        XCTAssertTrue(session.hasSentFirstMessage)
    }

    @MainActor
    func testTerminalSettlesResultlessToolCallsAlreadyApplied() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Tools")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-tools-before-terminal")
        session.runState = .running
        let toolCall = Self.remoteToolCall(name: "read_file")

        fixture.coordinator.test_applyTranscriptRows([toolCall], to: session)

        let runningTool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertNil(runningTool.toolResultJSON)
        XCTAssertNil(runningTool.toolIsError)
        // Step 4d6: an unresolved call renders neutral but stays eligible for run-scoped cancel.
        XCTAssertEqual(ToolCallCardStateResolver.status(for: runningTool), .neutral)
        XCTAssertTrue(ToolCallCardStateResolver.allowsRunScopedCancel(for: runningTool))

        fixture.coordinator.test_handleEvent(.terminal(status: "completed"), tabID: fixture.tabID)

        let settledTool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertNotNil(settledTool.toolResultJSON)
        XCTAssertEqual(settledTool.toolIsError, false)
        XCTAssertNotEqual(ToolCallCardStateResolver.status(for: settledTool), .running)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: settledTool), .success)
        XCTAssertFalse(ToolCallCardStateResolver.allowsRunScopedCancel(for: settledTool))
        XCTAssertEqual(session.runState, .completed)
    }

    @MainActor
    func testPostTerminalTranscriptRowsSettleResultlessToolCalls() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Tools")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-tools-after-terminal")
        session.runState = .running

        fixture.coordinator.test_handleEvent(.terminal(status: "completed"), tabID: fixture.tabID)
        XCTAssertEqual(session.runState, .completed)

        let toolCall = Self.remoteToolCall(name: "read_file")
        fixture.coordinator.test_handleEvent(.transcriptRows(items: [toolCall], removedIDs: [], hostRowIDByClientItemID: [:]), tabID: fixture.tabID)

        let settledTool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertNotNil(settledTool.toolResultJSON)
        XCTAssertEqual(settledTool.toolIsError, false)
        XCTAssertNotEqual(ToolCallCardStateResolver.status(for: settledTool), .running)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: settledTool), .success)
        XCTAssertFalse(ToolCallCardStateResolver.allowsRunScopedCancel(for: settledTool))
    }

    @MainActor
    func testTerminalFailedSettlesResultlessToolCallsAlreadyAppliedAsFailure() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Failed Tools")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-tools-failed-before-terminal")
        session.runState = .running
        let toolCall = Self.remoteToolCall(name: "read_file")

        fixture.coordinator.test_applyTranscriptRows([toolCall], to: session)
        fixture.coordinator.test_handleEvent(.terminal(status: "failed"), tabID: fixture.tabID)

        let settledTool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertEqual(session.runState, .failed)
        XCTAssertEqual(settledTool.toolIsError, true)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: settledTool), .failure)
        XCTAssertTrue(settledTool.toolResultJSON?.contains("\"status\":\"failed\"") == true, settledTool.toolResultJSON ?? "nil")
    }

    @MainActor
    func testPostTerminalTranscriptRowsSettleCancelledResultlessToolCallsAsFailure() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "Remote Cancelled Tools")
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-tools-cancelled-after-terminal")
        session.runState = .running

        fixture.coordinator.test_handleEvent(.terminal(status: "cancelled"), tabID: fixture.tabID)
        XCTAssertEqual(session.runState, .cancelled)

        let toolCall = Self.remoteToolCall(name: "read_file")
        fixture.coordinator.test_handleEvent(.transcriptRows(items: [toolCall], removedIDs: [], hostRowIDByClientItemID: [:]), tabID: fixture.tabID)

        let settledTool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertEqual(settledTool.toolIsError, true)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: settledTool), .failure)
        XCTAssertTrue(settledTool.toolResultJSON?.contains("\"status\":\"cancelled\"") == true, settledTool.toolResultJSON ?? "nil")
    }

    @MainActor
    func testPostTerminalTranscriptRowsPreserveExplicitFailedToolResult() throws {
        let session = AgentTabSession(tabID: UUID())
        session.remoteHost = makeBinding(remoteSessionID: "remote-session-tools-explicit-failed")
        session.runState = .completed
        let failedJSON = #"{"status":"failed","summary_only":true,"marker":"preserve"}"#
        let failedTool = Self.remoteToolCall(
            name: "read_file",
            toolResultJSON: failedJSON,
            toolIsError: true
        )
        let coordinator = RemoteAgentModeCoordinator()

        coordinator.test_applyTranscriptRows([failedTool], to: session)

        let tool = try XCTUnwrap(session.items.first { $0.kind == .toolCall })
        XCTAssertEqual(tool.toolResultJSON, failedJSON)
        XCTAssertEqual(tool.toolIsError, true)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: tool), .failure)
    }

    @MainActor
    func testStoppedParentDoesNotMaterializeChildrenFromLateDiscovery() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let childRemoteID = UUID()
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: childRemoteID.uuidString,
                name: "Child Worker",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(
            responses: ["list_sessions": [childListPayload]],
            commandDelayNanosecondsByType: ["list_sessions": 150_000_000]
        )
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        var attachedRemoteSessionIDs: [String] = []
        fixture.coordinator.test_setMaterializedRemoteChildAttachHandler { childSession in
            if let remoteSessionID = childSession.remoteHost?.remoteSessionID {
                attachedRemoteSessionIDs.append(remoteSessionID)
            }
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 1
        }

        fixture.coordinator.stop(tabID: fixture.tabID)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(fixture.viewModel.sessions.values.contains {
            $0.remoteHost?.remoteSessionID == childRemoteID.uuidString
        })
        XCTAssertTrue(attachedRemoteSessionIDs.isEmpty)
        let counts = fixture.coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
    }

    @MainActor
    func testCoordinatorReportsRemoteChildMaterializationFailureOnce() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let invalidChildRemoteID = "not-a-child-uuid"
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: invalidChildRemoteID,
                name: "Broken Child",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [childListPayload, childListPayload]
        ])
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        defer { fixture.coordinator.stop(tabID: fixture.tabID) }
        let expectedMessage = "Remote child session materialization failed for '\(invalidChildRemoteID)'."

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteCoordinatorLifecycle {
            self.systemMessages(in: parentSession).contains(expectedMessage)
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 2
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(systemMessages(in: parentSession).count(where: { $0 == expectedMessage }), 1)
    }

    @MainActor
    func testStoppingLastRemoteTabsReleasesControllersAndFanoutTasks() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(record)
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let coordinator = RemoteAgentModeCoordinator()
        let firstTabID = UUID()
        let secondTabID = UUID()
        var firstController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-1"),
            connection: connection
        )
        var secondController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-2"),
            connection: connection
        )
        let weakFirstController = RemoteAgentSessionWeakBox(firstController)
        let weakSecondController = RemoteAgentSessionWeakBox(secondController)

        try coordinator.test_attachController(
            tabID: firstTabID,
            hostID: record.id,
            controller: XCTUnwrap(firstController),
            connection: connection
        )
        try coordinator.test_attachController(
            tabID: secondTabID,
            hostID: record.id,
            controller: XCTUnwrap(secondController),
            connection: connection
        )

        var counts = coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 2)
        XCTAssertEqual(counts.eventTasks, 2)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 2)

        coordinator.stop(tabID: firstTabID)
        firstController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakFirstController.value == nil && coordinator.test_lifecycleCounts().controllers == 1
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakFirstController.value)
        XCTAssertEqual(counts.controllers, 1)
        XCTAssertEqual(counts.eventTasks, 1)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 1)

        coordinator.stop(tabID: secondTabID)
        secondController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakSecondController.value == nil && coordinator.test_lifecycleCounts().controllers == 0
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakSecondController.value)
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.eventTasks, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
        XCTAssertEqual(counts.tabHostBindings, 0)
    }

    @MainActor
    func testTwoCoordinatorsOnSharedConnectionReceiveFramesAndReleaseSubscriptionsOnDeinit() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(record)
        let fanoutConnection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let firstSessionConnection = RecordingRemoteAgentSessionConnection()
        let secondSessionConnection = RecordingRemoteAgentSessionConnection()
        let firstController = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-1", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: firstSessionConnection
        )
        let secondController = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-2", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: secondSessionConnection
        )
        let firstTabID = UUID()
        let secondTabID = UUID()
        var firstCoordinator: RemoteAgentModeCoordinator? = RemoteAgentModeCoordinator()
        var secondCoordinator: RemoteAgentModeCoordinator? = RemoteAgentModeCoordinator()
        let weakFirstCoordinator = RemoteAgentSessionWeakBox(firstCoordinator)
        var firstConnectionStates: [RemoteHostConnection.State] = []
        var secondConnectionStates: [RemoteHostConnection.State] = []
        firstCoordinator?.test_setConnectionStateDeliveryObserver { _, state in
            firstConnectionStates.append(state)
        }
        secondCoordinator?.test_setConnectionStateDeliveryObserver { _, state in
            secondConnectionStates.append(state)
        }
        defer {
            firstCoordinator?.stop(tabID: firstTabID)
            secondCoordinator?.stop(tabID: secondTabID)
            Task {
                await firstController.shutdown()
                await secondController.shutdown()
            }
        }

        firstCoordinator?.test_attachController(
            tabID: firstTabID,
            hostID: record.id,
            controller: firstController,
            connection: fanoutConnection
        )
        secondCoordinator?.test_attachController(
            tabID: secondTabID,
            hostID: record.id,
            controller: secondController,
            connection: fanoutConnection
        )
        await waitForDeterministicRemoteAgentSessionCondition {
            let inboundCount = await fanoutConnection.inboundSubscriberCountForTesting()
            let stateCount = await fanoutConnection.stateSubscriberCountForTesting()
            return inboundCount == 2 && stateCount == 2
        }

        let degradedState = RemoteHostConnection.State.degraded(
            code: "test_reconnect",
            retryAt: Date(timeIntervalSince1970: 0)
        )
        await fanoutConnection.transitionForTesting(to: degradedState)
        await waitForDeterministicRemoteAgentSessionCondition {
            firstConnectionStates.contains(degradedState)
                && secondConnectionStates.contains(degradedState)
        }

        await fanoutConnection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-2",
            seq: 1,
            payload: Self.snapshotPayload()
        ))
        await waitForDeterministicRemoteAgentSessionCondition {
            await secondController.currentBinding()?.lastAppliedSeq == 1
        }
        let firstSequenceAfterSecondFrame = await firstController.currentBinding()?.lastAppliedSeq
        XCTAssertEqual(firstSequenceAfterSecondFrame, 0)

        await fanoutConnection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-1",
            seq: 1,
            payload: Self.snapshotPayload()
        ))
        await waitForDeterministicRemoteAgentSessionCondition {
            await firstController.currentBinding()?.lastAppliedSeq == 1
        }

        firstCoordinator = nil
        await waitForDeterministicRemoteAgentSessionCondition {
            let inboundCount = await fanoutConnection.inboundSubscriberCountForTesting()
            let stateCount = await fanoutConnection.stateSubscriberCountForTesting()
            return weakFirstCoordinator.value == nil && inboundCount == 1 && stateCount == 1
        }

        await fanoutConnection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-2",
            seq: 2,
            payload: Self.snapshotPayload()
        ))
        await waitForDeterministicRemoteAgentSessionCondition {
            await secondController.currentBinding()?.lastAppliedSeq == 2
        }
    }

    @MainActor
    private func makeRemoteNamingFixture(
        tabTitle: String,
        childDiscoveryDebounceInterval: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RemoteNamingFixture {
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Remote Naming",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: tabTitle, activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager, mcpHost: ServerNetworkManager.shared, routingWaiter: .shared, codexAuthRecovery: CodexManagedAuthRecoveryService.shared, modelOverrides: AppModelOverrideReader(), ohMyPiConnectionState: { OhMyPiConnectionAvailability.isEffectivelyConnected() }),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        prompt.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RemoteAgentSessionNoopCodexController() }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: prompt,
            workspaceManager: workspaceManager
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try! await viewModel.ensureSessionReady(tabID: tabID)
        session.remoteHost = makeBinding()
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        let entry = AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: tabTitle,
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            lastRunStateRaw: session.runState.rawValue,
            itemCount: 0,
            agentKindRaw: session.selectedAgent.rawValue,
            agentModelRaw: session.selectedModelRaw,
            agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: session.remoteHost?.hostID,
            remoteHostName: session.remoteHost?.hostDisplayName,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        let owner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        viewModel.test_installSessionIndexSnapshot(
            [sessionID: entry],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        XCTAssertEqual(viewModel.resolvedSessionDisplayName(for: tabID), tabTitle, file: file, line: line)

        let coordinator = RemoteAgentModeCoordinator(childDiscoveryDebounceInterval: childDiscoveryDebounceInterval)
        coordinator.attach(viewModel: viewModel)
        return RemoteNamingFixture(
            tabID: tabID,
            sessionID: sessionID,
            viewModel: viewModel,
            coordinator: coordinator,
            prompt: prompt,
            workspaceManager: workspaceManager
        )
    }

    @MainActor
    private func systemMessages(in session: AgentTabSession) -> [String] {
        session.items.filter { $0.kind == .system }.map(\.text)
    }

    @MainActor
    private func waitForRemoteCoordinatorLifecycle(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTAssertTrue(predicate(), "Timed out waiting for remote coordinator lifecycle cleanup", file: file, line: line)
    }

    private func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String = "remote-session-abc",
        lastAppliedSeq: UInt64 = 42,
        seqEpoch: String? = nil,
        nextLogOffset: Int = 7
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            seqEpoch: seqEpoch,
            nextLogOffset: nextLogOffset
        )
    }

    private struct RemoteNamingFixture {
        let tabID: UUID
        let sessionID: UUID
        let viewModel: AgentModeViewModel
        let coordinator: RemoteAgentModeCoordinator
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
    }

    private final class RemoteAgentSessionWeakBox<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value?) {
            self.value = value
        }
    }

    private static func snapshotPayload(
        status: String = "running",
        sessionID: String? = nil,
        agentID: String? = nil,
        agentModel: String? = nil,
        agentReasoningEffort: String? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let sessionID {
            payload["session_id"] = .string(sessionID)
        }
        var agent: [String: JSONValue] = [:]
        if let agentID {
            agent["id"] = .string(agentID)
        }
        if let agentModel {
            agent["model"] = .string(agentModel)
        }
        if let agentReasoningEffort {
            agent["reasoning_effort"] = .string(agentReasoningEffort)
        }
        if !agent.isEmpty {
            payload["agent"] = .object(agent)
        }
        return .object(payload)
    }

    private static func listSessionsPayload(children: [JSONValue]) -> JSONValue {
        .object(["sessions": .array(children)])
    }

    private static func sessionDescriptorPayload(
        sessionID: String,
        name: String,
        state: String,
        agentID: String,
        model: String,
        parentSessionID: String
    ) -> JSONValue {
        .object([
            "session_id": .string(sessionID),
            "name": .string(name),
            "state": .string(state),
            "agent": .object([
                "id": .string(agentID),
                "model": .string(model)
            ]),
            "parent_session_id": .string(parentSessionID)
        ])
    }

    private static func logPayload(offset: Int, returned: Int, total: Int, xml: String, completed: Int? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turn_offset": .int(offset),
            "returned_turn_count": .int(returned),
            "total_turns": .int(total),
            "transcript_xml": .string(xml)
        ]
        if let completed {
            payload["completed_turn_count"] = .int(completed)
        }
        return .object(payload)
    }

    private static func remoteToolCall(
        name: String,
        toolResultJSON: String? = nil,
        toolIsError: Bool? = nil,
        sequenceIndex: Int = 0
    ) -> AgentChatItem {
        AgentChatItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            kind: .toolCall,
            text: "Using tool: \(name)",
            toolName: name,
            toolArgsJSON: #"{"path":"README.md"}"#,
            toolResultJSON: toolResultJSON,
            toolIsError: toolIsError,
            sequenceIndex: sequenceIndex
        )
    }

    private func assertCommandCount(
        _ connection: RecordingRemoteAgentSessionConnection,
        type: String,
        sessionID: String? = nil,
        equals expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual: Int = if let sessionID {
            await connection.commandCount(type: type, sessionID: sessionID)
        } else {
            await connection.commandCount(type: type)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertSubscribeCount(
        _ connection: RecordingRemoteAgentSessionConnection,
        equals expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await connection.subscribeCallCount()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertMaximumObservationConcurrency(
        _ connection: RecordingRemoteAgentSessionConnection,
        equals expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await connection.maximumConcurrentObservationCommands()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func waitForDeterministicRemoteAgentSessionCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1000 {
            if await predicate() {
                return
            }
            await Task.yield()
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for deterministic remote agent session condition", file: file, line: line)
    }

    private func waitForRemoteAgentSessionCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for remote agent session condition", file: file, line: line)
    }

    private final class ManualRemoteAgentSessionRecoveryScheduler: RemoteAgentSessionRecoveryScheduling, @unchecked Sendable {
        private struct Waiter {
            let deadline: TimeInterval
            let continuation: CheckedContinuation<Void, Error>
        }

        private let lock = NSLock()
        private var now: TimeInterval = 0
        private var waiters: [UUID: Waiter] = [:]

        func sleep(seconds: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let shouldWait = lock.withLock {
                        guard !Task.isCancelled else { return false }
                        let deadline = now + max(0, seconds)
                        guard deadline > now else { return false }
                        waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                        return true
                    }
                    guard !shouldWait else { return }
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            } onCancel: {
                self.cancel(id: id)
            }
        }

        func advance(by seconds: TimeInterval) {
            let ready = lock.withLock {
                now += max(0, seconds)
                let ready = waiters.filter { $0.value.deadline <= now }
                for id in ready.keys {
                    waiters.removeValue(forKey: id)
                }
                return Array(ready.values)
            }
            ready.forEach { $0.continuation.resume() }
        }

        func pendingSleeperCount() -> Int {
            lock.withLock { waiters.count }
        }

        private func cancel(id: UUID) {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private actor RemoteObservationCommandGate {
        private var entered = false
        private var released = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered() async {
            if entered {
                return
            }
            await withCheckedContinuation { enterWaiters.append($0) }
        }

        func enterAndWaitForRelease() async {
            entered = true
            enterWaiters.forEach { $0.resume() }
            enterWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor RemoteSubscribeGate {
        private var entered = false
        private var released = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered() async {
            if entered {
                return
            }
            await withCheckedContinuation { enterWaiters.append($0) }
        }

        func enterAndWaitForRelease() async {
            entered = true
            enterWaiters.forEach { $0.resume() }
            enterWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor RemoteSessionEventRecorder {
        private var transcriptRows: [[AgentChatItem]] = []
        private var systemMessages: [String] = []
        private var metadata: [RemoteSessionEvent] = []
        private var runStates: [AgentSessionRunState] = []
        private var terminalStatuses: [String] = []
        private var expiredCount = 0

        func record(_ event: RemoteSessionEvent) {
            switch event {
            case let .transcriptRows(rows, _, _):
                transcriptRows.append(rows)
            case let .systemMessage(message):
                systemMessages.append(message)
            case .metadata:
                metadata.append(event)
            case let .runState(runState, _, _):
                runStates.append(runState)
            case let .terminal(status):
                terminalStatuses.append(status)
            case .sessionExpired:
                expiredCount += 1
            default:
                break
            }
        }

        func firstTranscriptRows() -> [AgentChatItem]? {
            transcriptRows.first
        }

        func allTranscriptRows() -> [[AgentChatItem]] {
            transcriptRows
        }

        func hasTranscriptBatchCount(_ count: Int) -> Bool {
            transcriptRows.count >= count
        }

        func upsertedTranscriptRows() -> [AgentChatItem] {
            var rowsByID: [UUID: AgentChatItem] = [:]
            var orderedIDs: [UUID] = []
            for batch in transcriptRows {
                for row in batch {
                    if rowsByID[row.id] == nil {
                        orderedIDs.append(row.id)
                    }
                    rowsByID[row.id] = row
                }
            }
            return orderedIDs.compactMap { rowsByID[$0] }
        }

        func recordedSystemMessages() -> [String] {
            systemMessages
        }

        func metadataEvents() -> [RemoteSessionEvent] {
            metadata
        }

        func recordedRunStates() -> [AgentSessionRunState] {
            runStates
        }

        func recordedTerminalStatuses() -> [String] {
            terminalStatuses
        }

        func sessionExpiredCount() -> Int {
            expiredCount
        }
    }

    private struct RemoteLogFailure: Error, CustomStringConvertible {
        var description: String {
            "synthetic log failure"
        }
    }

    private actor FailingGetLogRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            if frame.type == "get_log" {
                throw RemoteLogFailure()
            }
            return RemoteAgentSessionTests.snapshotPayload()
        }

        func ensureConnected() async throws {}
        func subscribe(sessionIDs _: [String]) async throws {}
        func unsubscribe(sessionIDs _: [String]) async throws {}
    }

    private actor SessionExpiredGetLogRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            if frame.type == "get_log" {
                throw RemoteClientError.sessionExpired(.init(code: "session_expired", message: "expired"))
            }
            return RemoteAgentSessionTests.snapshotPayload()
        }

        func ensureConnected() async throws {}
        func subscribe(sessionIDs _: [String]) async throws {}
        func unsubscribe(sessionIDs _: [String]) async throws {}
    }

    private actor RecordingRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        private var responses: [String: [JSONValue]]
        private var commandErrors: [String: [RemoteClientError]]
        private let getLogDelayNanoseconds: UInt64
        private let commandDelayNanosecondsByType: [String: UInt64]
        private var subscribeErrors: [RemoteClientError]
        private let subscribeGate: RemoteSubscribeGate?
        private let unsubscribeError: Error?
        private var observationGate: RemoteObservationCommandGate?
        private var gatedObservationType: String?
        private var activeObservationCommandCount = 0
        private var maximumConcurrentObservationCommandCount = 0
        private var frames: [RemoteClientFrame] = []
        private var subscribedSessionIDs: [[String]] = []
        private var unsubscribedSessionIDs: [[String]] = []
        private var ensureConnectedCallCount = 0

        init(
            responses: [String: [JSONValue]] = [:],
            commandErrors: [String: [RemoteClientError]] = [:],
            getLogDelayNanoseconds: UInt64 = 0,
            commandDelayNanosecondsByType: [String: UInt64] = [:],
            subscribeErrors: [RemoteClientError] = [],
            subscribeGate: RemoteSubscribeGate? = nil,
            unsubscribeError: Error? = nil
        ) {
            self.responses = responses
            self.commandErrors = commandErrors
            self.getLogDelayNanoseconds = getLogDelayNanoseconds
            self.commandDelayNanosecondsByType = commandDelayNanosecondsByType
            self.subscribeErrors = subscribeErrors
            self.subscribeGate = subscribeGate
            self.unsubscribeError = unsubscribeError
        }

        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            frames.append(frame)
            let isObservationCommand = frame.type == "poll" || frame.type == "get_log"
            if isObservationCommand {
                activeObservationCommandCount += 1
                maximumConcurrentObservationCommandCount = max(
                    maximumConcurrentObservationCommandCount,
                    activeObservationCommandCount
                )
            }
            defer {
                if isObservationCommand {
                    activeObservationCommandCount -= 1
                }
            }
            if frame.type == gatedObservationType, let observationGate {
                await observationGate.enterAndWaitForRelease()
            }
            if frame.type == "get_log", getLogDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: getLogDelayNanoseconds)
            }
            if let delay = commandDelayNanosecondsByType[frame.type], delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if var queued = commandErrors[frame.type], !queued.isEmpty {
                let error = queued.removeFirst()
                commandErrors[frame.type] = queued
                throw error
            }
            if var queued = responses[frame.type], !queued.isEmpty {
                let response = queued.removeFirst()
                responses[frame.type] = queued
                return response
            }
            return defaultResponse(for: frame)
        }

        func ensureConnected() async throws {
            ensureConnectedCallCount += 1
        }

        func subscribe(sessionIDs: [String]) async throws {
            subscribedSessionIDs.append(sessionIDs)
            if !subscribeErrors.isEmpty {
                throw subscribeErrors.removeFirst()
            }
            await subscribeGate?.enterAndWaitForRelease()
        }

        func subscribeCallCount() -> Int {
            subscribedSessionIDs.count
        }

        func unsubscribe(sessionIDs: [String]) async throws {
            unsubscribedSessionIDs.append(sessionIDs)
            if let unsubscribeError {
                throw unsubscribeError
            }
        }

        func unsubscribedSessionIDBatches() -> [[String]] {
            unsubscribedSessionIDs
        }

        func unsubscribeCallCount() -> Int {
            unsubscribedSessionIDs.count
        }

        func commandCount(type: String) -> Int {
            frames.count { $0.type == type }
        }

        func commandCount(type: String, sessionID: String) -> Int {
            frames.count { $0.type == type && $0.sessionID == sessionID }
        }

        func maximumConcurrentObservationCommands() -> Int {
            maximumConcurrentObservationCommandCount
        }

        func setObservationGate(_ gate: RemoteObservationCommandGate?, type: String?) {
            observationGate = gate
            gatedObservationType = type
        }

        func enqueue(_ response: JSONValue, forType type: String) {
            responses[type, default: []].append(response)
        }

        func frames(type: String) -> [RemoteClientFrame] {
            frames.filter { $0.type == type }
        }

        func getLogOffsets() -> [Int] {
            frames.compactMap { frame in
                guard frame.type == "get_log" else { return nil }
                return frame.payload?.objectValue?["offset"]?.intValue
            }
        }

        func getLogRequests() -> [(offset: Int, limit: Int)] {
            frames.compactMap { frame in
                guard frame.type == "get_log" else { return nil }
                let payload = frame.payload?.objectValue ?? [:]
                return (
                    offset: payload["offset"]?.intValue ?? 0,
                    limit: payload["limit"]?.intValue ?? 0
                )
            }
        }

        private func defaultResponse(for frame: RemoteClientFrame) -> JSONValue {
            switch frame.type {
            case "start":
                RemoteAgentSessionTests.snapshotPayload(sessionID: "remote-session-abc")
            case "poll":
                RemoteAgentSessionTests.snapshotPayload()
            case "get_log":
                RemoteAgentSessionTests.logPayload(
                    offset: frame.payload?.objectValue?["offset"]?.intValue ?? 0,
                    returned: 0,
                    total: 0,
                    xml: "<transcript/>"
                )
            default:
                .object([:])
            }
        }
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAgentSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Agent Session Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}

private final class RemoteAgentSessionNoopCodexController: CodexSessionControlling {
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

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
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
