@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class RemoteWorkspaceSidebarTests: XCTestCase {
    @MainActor
    func testLoadedCatalogProjectionFiltersAlreadyLocalAndSortsRemoteRows() async throws {
        let localRemoteID = UUID().uuidString
        let newestRemoteID = UUID().uuidString
        let olderRemoteID = UUID().uuidString
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: "host-workspace",
            hostWorkspaceName: "Project Alpha",
            sessions: [
                descriptor(id: localRemoteID, name: "Already here", modified: 30),
                descriptor(id: olderRemoteID, name: "Older remote", modified: 10),
                descriptor(id: newestRemoteID, name: "Newest remote", modified: 20)
            ],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 40)
        )))
        let fixture = try await makeFixture(store: store)
        let localSession = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        localSession.remoteHost = binding(
            host: fixture.host,
            remoteSessionID: localRemoteID
        )

        let section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        guard case let .sessions(descriptors) = section.content else {
            return XCTFail("Expected loaded remote workspace sessions")
        }
        XCTAssertEqual(descriptors.map(\.sessionID), [newestRemoteID, olderRemoteID])
        XCTAssertEqual(section.hostRecord, fixture.host)
        XCTAssertEqual(section.workspaceID, fixture.workspace.id)
    }

    @MainActor
    func testCatalogFailureStatesExposeActionableCopyAndRetry() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let fixture = try await makeFixture(store: store)

        var section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(
            section.content,
            .workspaceNotOpen(
                "Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
            )
        )

        store.state = .unsupported
        section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(
            section.content,
            .unsupported("Studio Mac doesn't support workspace browsing (update RepoPrompt on the host).")
        )

        store.state = .error("Host is offline")
        section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(section.content, .error("Host is offline"))

        await fixture.viewModel.retryRemoteWorkspaceSidebar()
        XCTAssertEqual(store.invalidatedWorkspaceIDs, [fixture.workspace.id])
        XCTAssertEqual(store.fetchForceRefreshValues, [true])
    }

    @MainActor
    func testClosedWorkspaceAutoOpenPublishesInterimThenInvalidatesAndRefreshes() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        store.stateAfterHostInvalidation = .loaded(.init(
            hostWorkspaceID: "host-workspace",
            hostWorkspaceName: "Project Alpha",
            sessions: [],
            fetchedAt: Date()
        ))
        let gate = WorkspaceOpenCommandGate()
        let connection = WorkspaceOpenRecordingConnection(outcomes: [.gatedSuccess(gate)])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        let refresh = Task { await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true) }
        await gate.waitUntilEntered()

        let interim = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(interim.content, .openingWorkspace("Opening 'Project Alpha' on Studio Mac…"))
        let interimCommandCount = await connection.commandCount()
        XCTAssertEqual(interimCommandCount, 1)

        await gate.release()
        await refresh.value
        XCTAssertEqual(store.invalidatedHostIDs, [fixture.host.id])
        XCTAssertEqual(store.invalidatedWorkspaceIDs, [])
        XCTAssertEqual(store.fetchForceRefreshValues, [true, true])
        XCTAssertEqual(store.operationLog.suffix(2), ["invalidate-host", "fetch:true"])
        let final = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(final.content, .sessions([]))
    }

    @MainActor
    func testAutoOpenFailureCodesExposeRetryBearingCopy() async throws {
        let cases = [
            ("workspace_not_found", "Workspace 'Project Alpha' was not found on Studio Mac."),
            ("insufficient_scope", "Denied"),
            ("timeout", "Timed out"),
            ("unsupported_frame_type", "Unsupported")
        ]
        for (code, expected) in cases {
            let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
            let error = RemoteClientError.fromCommandError(code: code, message: expected)
            let connection = WorkspaceOpenRecordingConnection(outcomes: [.failure(error)])
            let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

            await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)

            let section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
            guard case let .error(message) = section.content else {
                return XCTFail("Expected retry-bearing error content for \(code)")
            }
            XCTAssertEqual(message, expected)
        }
    }

    @MainActor
    func testAutoOpenRetriesStaleLearnedIDOnceWithoutID() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        store.learnedWorkspaceID = "stale-workspace-id"
        store.stateAfterHostInvalidation = .loaded(.init(
            hostWorkspaceID: "current-workspace-id",
            hostWorkspaceName: "Project Alpha",
            sessions: [],
            fetchedAt: Date()
        ))
        let connection = WorkspaceOpenRecordingConnection(outcomes: [
            .failure(.fromCommandError(code: "workspace_not_found", message: "Missing stale ID")),
            .success
        ])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)

        let frames = await connection.frames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload?.objectValue?["workspace_id"], .string("stale-workspace-id"))
        XCTAssertEqual(frames[0].payload?.objectValue?["workspace_name"], .string("Project Alpha"))
        XCTAssertNil(frames[1].payload?.objectValue?["workspace_id"])
        XCTAssertEqual(frames[1].payload?.objectValue?["workspace_name"], .string("Project Alpha"))
        XCTAssertEqual(store.invalidatedHostIDs, [fixture.host.id])

        let terminalStore = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        terminalStore.learnedWorkspaceID = "another-stale-id"
        let terminalConnection = WorkspaceOpenRecordingConnection(outcomes: [
            .failure(.fromCommandError(code: "workspace_not_found", message: "Missing ID")),
            .failure(.fromCommandError(code: "workspace_not_found", message: "Missing name"))
        ])
        let terminalFixture = try await makeFixture(
            store: terminalStore,
            workspaceOpenConnection: terminalConnection
        )
        await terminalFixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        await terminalFixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        let terminalCount = await terminalConnection.commandCount()
        XCTAssertEqual(terminalCount, 2, "Name-only failure is terminal for the episode")
    }

    @MainActor
    func testStaleLearnedIDSuccessfulNameRetryDoesNotLoopWhenCatalogRemainsNotOpen() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        store.learnedWorkspaceID = "deleted-workspace-id"
        let connection = WorkspaceOpenRecordingConnection(outcomes: [
            .failure(.fromCommandError(code: "workspace_not_found", message: "Deleted workspace")),
            .success
        ])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)

        let frames = await connection.frames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload?.objectValue?["workspace_id"], .string("deleted-workspace-id"))
        XCTAssertNil(frames[1].payload?.objectValue?["workspace_id"])
        guard case .error = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection()).content else {
            return XCTFail("Expected the still-not-open state to remain terminal until Retry or recovery")
        }
    }

    @MainActor
    func testLoadedCatalogClearsFailedAutoOpenEpisode() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let failure = RemoteClientError.fromCommandError(code: "unsupported_frame_type", message: "Unsupported")
        let connection = WorkspaceOpenRecordingConnection(outcomes: [.failure(failure)])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        guard case .error = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection()).content else {
            return XCTFail("Expected failed auto-open episode")
        }

        store.state = .loaded(.init(
            hostWorkspaceID: "recovered-workspace-id",
            hostWorkspaceName: "Project Alpha",
            sessions: [],
            fetchedAt: Date()
        ))
        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)

        XCTAssertEqual(
            try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection()).content,
            .sessions([])
        )
        let commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 1)
    }

    @MainActor
    func testAutoOpenEpisodeRequiresRetryOrEligibleReconnect() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let failure = RemoteClientError.fromCommandError(code: "unsupported_frame_type", message: "Unsupported")
        let connection = WorkspaceOpenRecordingConnection(outcomes: [
            .failure(failure), .failure(failure), .failure(failure)
        ])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        await fixture.viewModel.refreshRemoteWorkspaceSidebar()
        await fixture.viewModel.refreshRemoteWorkspaceSidebar()
        var commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 1)

        await fixture.coordinator.test_deliverConnectionState(
            .connected(scopes: ["sessions:observe"]),
            hostID: fixture.host.id
        )
        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 1)

        await fixture.coordinator.test_deliverConnectionState(.idle, hostID: fixture.host.id)
        await fixture.coordinator.test_deliverConnectionState(
            .connected(scopes: ["sessions:operate"]),
            hostID: fixture.host.id
        )
        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)
        commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 2)

        await fixture.viewModel.retryRemoteWorkspaceSidebar()
        commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 3)
    }

    @MainActor
    func testAutoOpenEpisodeKeyRotatesWithClientWorkspaceID() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let failure = RemoteClientError.fromCommandError(code: "unsupported_frame_type", message: "Unsupported")
        let connection = WorkspaceOpenRecordingConnection(outcomes: [.failure(failure), .failure(failure)])
        let fixture = try await makeFixture(store: store, workspaceOpenConnection: connection)

        await fixture.coordinator.autoOpenWorkspaceIfNeeded(
            hostRecord: fixture.host,
            clientWorkspaceID: fixture.workspace.id,
            workspaceName: fixture.workspace.name
        )
        await fixture.coordinator.autoOpenWorkspaceIfNeeded(
            hostRecord: fixture.host,
            clientWorkspaceID: UUID(),
            workspaceName: "Another Workspace"
        )

        let commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 2)
    }

    @MainActor
    func testAutoOpenWithoutOperateScopeKeepsExistingNotOpenFallback() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let connection = WorkspaceOpenRecordingConnection()
        let fixture = try await makeFixture(
            store: store,
            workspaceOpenConnection: connection,
            grantedScopes: ["sessions:observe"]
        )

        await fixture.viewModel.refreshRemoteWorkspaceSidebar(forceRefresh: true)

        let commandCount = await connection.commandCount()
        XCTAssertEqual(commandCount, 0)
        let section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(
            section.content,
            .workspaceNotOpen(
                "Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
            )
        )
    }

    @MainActor
    func testWorkspacePickupMaterializesFocusedUserTabOnceAndAttaches() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let fixture = try await makeFixture(store: store)
        let remoteID = UUID().uuidString
        let remote = descriptor(id: remoteID, name: "Host Session", modified: 10)
        var attachCount = 0
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { _ in
            attachCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        async let first = fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remote,
            hostRecord: fixture.host
        )
        await Task.yield()
        async let second = fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remote,
            hostRecord: fixture.host
        )
        let (firstResult, secondResult) = await (first, second)

        let materialized = try XCTUnwrap(firstResult ?? secondResult)
        XCTAssertEqual([firstResult, secondResult].compactMap(\.self).count, 1)
        XCTAssertEqual(attachCount, 1)
        XCTAssertEqual(materialized.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(materialized.remoteHost?.remoteSessionID, remoteID)
        XCTAssertEqual(materialized.origin, .user)
        XCTAssertNil(materialized.parentSessionID)
        XCTAssertEqual(fixture.workspaceManager.activeWorkspace?.activeComposeTabID, materialized.tabID)
        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: materialized.tabID), "Host Session")
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count { $0.remoteHost?.remoteSessionID == remoteID },
            1
        )
    }

    @MainActor
    func testRemoteForkMaterializesAndOpensOnceThenForceRefreshesForDuplicateDescriptor() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let fixture = try await makeFixture(store: store)
        let sourceRemoteSessionID = UUID().uuidString
        let destinationRemoteSessionID = UUID().uuidString
        let hostRowID = UUID()
        let connection = HandoffRecordingConnection(
            sourceSessionID: sourceRemoteSessionID,
            hostRowID: hostRowID,
            destinationSessionID: destinationRemoteSessionID,
            advertisedFeatures: [RemoteWireFeatures.forkSession, RemoteWireFeatures.getLogHostRowIDs]
        )
        let sourceSession = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        sourceSession.remoteHost = binding(host: fixture.host, remoteSessionID: sourceRemoteSessionID)
        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(sourceSession.remoteHost),
            connection: connection
        )
        fixture.coordinator.test_installController(controller, for: sourceSession, hostID: fixture.host.id)
        defer { fixture.coordinator.stop(tabID: sourceSession.tabID) }

        try await controller.attachAndCatchUp()
        let clientItemID = try XCTUnwrap(
            RemoteTranscriptProjector(remoteSessionID: sourceRemoteSessionID)
                .projectGetLogResponse(HandoffRecordingConnection.logPayload(
                    sourceSessionID: sourceRemoteSessionID,
                    hostRowID: hostRowID
                ))
                .items.last?.id
        )
        await waitUntil {
            fixture.coordinator.hostRowID(for: sourceSession, clientItemID: clientItemID) == hostRowID
        }
        var attachedTabIDs: [UUID] = []
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { [coordinator = fixture.coordinator, host = fixture.host] session in
            attachedTabIDs.append(session.tabID)
            // Run the real controller attach against the recording stub so the test
            // pins the wire contract (subscribe for the destination session), not just
            // the coordinator wiring.
            let destinationController = try RemoteAgentSessionController(
                binding: XCTUnwrap(session.remoteHost),
                connection: connection
            )
            coordinator.test_installController(destinationController, for: session, hostID: host.id)
            try await destinationController.attachAndCatchUp()
        }

        try await fixture.coordinator.fork(
            session: sourceSession,
            upToClientItemID: clientItemID,
            destinationAgent: AgentProviderKind.codexExec.rawValue,
            destinationModelID: "gpt-5.4",
            destinationEffort: "high"
        )
        let materialized = try XCTUnwrap(fixture.viewModel.sessions.values.first {
            $0.remoteHost?.remoteSessionID == destinationRemoteSessionID
        })
        XCTAssertEqual(materialized.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(fixture.workspaceManager.activeWorkspace?.activeComposeTabID, materialized.tabID)
        XCTAssertEqual(store.fetchForceRefreshValues, [true])
        // Fork must attach the materialized session so the client subscribes to the
        // forked session's host push events before any steer.
        XCTAssertEqual(attachedTabIDs, [materialized.tabID])
        let destinationSubscribes = await connection.subscribeBatches()
            .filter { $0 == [destinationRemoteSessionID] }
        XCTAssertEqual(destinationSubscribes.count, 1)

        try await fixture.coordinator.fork(
            session: sourceSession,
            upToClientItemID: clientItemID,
            destinationAgent: AgentProviderKind.codexExec.rawValue,
            destinationModelID: "gpt-5.4",
            destinationEffort: "high"
        )
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count { $0.remoteHost?.remoteSessionID == destinationRemoteSessionID },
            1
        )
        XCTAssertEqual(store.fetchForceRefreshValues, [true, true])
        // Duplicate descriptor: no new materialization, so no additional attach.
        XCTAssertEqual(attachedTabIDs, [materialized.tabID])
        let destinationSubscribesAfterDuplicate = await connection.subscribeBatches()
            .filter { $0 == [destinationRemoteSessionID] }
        XCTAssertEqual(destinationSubscribesAfterDuplicate.count, 1)
        let forkFrames = await connection.frames(type: "fork_session")
        XCTAssertEqual(forkFrames.count, 2)
        fixture.coordinator.stop(tabID: materialized.tabID)
    }

    @MainActor
    func testRemoteForkCapabilityAndHostRowMirrorInvalidateRunInteractionUIState() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let catalog = RemoteHostAgentCatalog(agents: [.hostDefault])
        let fixture = try await makeFixture(store: store, catalogProvider: { _ in catalog })
        let sourceRemoteSessionID = UUID().uuidString
        let hostRowID = UUID()
        let connection = HandoffRecordingConnection(
            sourceSessionID: sourceRemoteSessionID,
            hostRowID: hostRowID,
            destinationSessionID: UUID().uuidString,
            advertisedFeatures: [RemoteWireFeatures.forkSession, RemoteWireFeatures.getLogHostRowIDs]
        )
        let sourceSession = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        sourceSession.remoteHost = binding(host: fixture.host, remoteSessionID: sourceRemoteSessionID)
        fixture.viewModel.test_resetRemoteCatalogLoadState(hostID: fixture.host.id)
        XCTAssertNil(
            fixture.viewModel.cachedRemoteHostCatalog(sourceTabID: sourceSession.tabID)
        )
        XCTAssertFalse(
            fixture.viewModel.test_hasRemoteCatalogLoadTask(hostID: fixture.host.id),
            "The HUD cache-only accessor must not start a host catalog load on a miss."
        )
        let currentPresentation = fixture.viewModel.makeModelSelectionHUDPresentation(
            mode: .switchModel,
            sourceTabID: sourceSession.tabID,
            windowID: 1
        )
        XCTAssertEqual(currentPresentation.index.leaves.count, 1)
        guard case let .hostDefault(hostID)? = currentPresentation.index.leaves.first?.commitPayload else {
            return XCTFail("Current-session remote HUD should retain the host-default choice")
        }
        XCTAssertEqual(hostID, fixture.host.id)
        XCTAssertFalse(fixture.viewModel.test_hasRemoteCatalogLoadTask(hostID: fixture.host.id))

        let controller = try RemoteAgentSessionController(
            binding: XCTUnwrap(sourceSession.remoteHost),
            connection: connection
        )
        fixture.coordinator.test_installController(controller, for: sourceSession, hostID: fixture.host.id)
        defer { fixture.coordinator.stop(tabID: sourceSession.tabID) }
        let clientItemID = try XCTUnwrap(
            RemoteTranscriptProjector(remoteSessionID: sourceRemoteSessionID)
                .projectGetLogResponse(HandoffRecordingConnection.logPayload(
                    sourceSessionID: sourceRemoteSessionID,
                    hostRowID: hostRowID
                ))
                .items.last?.id
        )

        let beforeRowMirror = fixture.viewModel.test_syncRunInteractionCallCount
        try await controller.attachAndCatchUp()
        await waitUntil {
            fixture.coordinator.hostRowID(for: sourceSession, clientItemID: clientItemID) == hostRowID
        }
        XCTAssertGreaterThan(fixture.viewModel.test_syncRunInteractionCallCount, beforeRowMirror)

        await waitUntil {
            fixture.coordinator.canForkRemoteSession(session: sourceSession)
        }
        XCTAssertTrue(fixture.coordinator.canForkRemoteSession(session: sourceSession))

        let resolution = fixture.viewModel.resolveLastReplyHandoffTarget(
            sourceTabID: sourceSession.tabID
        )
        guard case let .target(target) = resolution else {
            return XCTFail("Expected VM resolver to use the coordinator's host-row mirror")
        }
        XCTAssertEqual(target.clientRowID, clientItemID)
        XCTAssertEqual(target.hostRowID, hostRowID)

        let handoffPresentation = fixture.viewModel.makeModelSelectionHUDPresentation(
            mode: .handoffLastReply,
            sourceTabID: sourceSession.tabID,
            windowID: 1
        )
        XCTAssertTrue(handoffPresentation.index.leaves.isEmpty)
        XCTAssertEqual(
            handoffPresentation.unavailableMessage,
            "This host did not expose handoff destination models."
        )
        XCTAssertFalse(
            fixture.viewModel.test_hasRemoteCatalogLoadTask(hostID: fixture.host.id),
            "Remote handoff HUD presentation must remain cache-only."
        )
    }

    @MainActor
    func testRemoteModelSelectionHUDRestoresSourceComposerFocusAndRejectsTabDrift() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let catalog = RemoteHostAgentCatalog(agents: [.hostDefault])
        let fixture = try await makeFixture(store: store, catalogProvider: { _ in catalog })
        let sourceSession = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        sourceSession.remoteHost = binding(host: fixture.host, remoteSessionID: UUID().uuidString)
        fixture.viewModel.test_resetRemoteCatalogLoadState(hostID: fixture.host.id)
        let composer = fixture.viewModel.ui.composer
        let isHostDefault: (AgentModelSelectionLeaf) -> Bool = {
            if case .hostDefault = $0.commitPayload { return true }
            return false
        }

        let hud = AgentModelSelectionHUDViewModel()
        hud.present(mode: .switchModel) {
            fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: sourceSession.tabID,
                windowID: 1
            )
        }
        XCTAssertTrue(hud.isPresented)
        XCTAssertNil(hud.unavailableMessage)
        let leaf = try XCTUnwrap(hud.filteredLeaves.first(where: isHostDefault))
        if let staleRequestID = composer.focusRequest?.id {
            composer.consumeFocusRequest(id: staleRequestID)
        }
        await hud.commit(leaf)
        XCTAssertNil(hud.errorMessage)
        XCTAssertFalse(hud.isPresented)
        XCTAssertEqual(sourceSession.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        let request = try XCTUnwrap(composer.focusRequest)
        XCTAssertEqual(request.tabID, sourceSession.tabID)
        XCTAssertEqual(request.reason, .modelSelectionCommitted)
        composer.consumeFocusRequest(id: request.id)

        let stalePresentation = fixture.viewModel.makeModelSelectionHUDPresentation(
            mode: .switchModel,
            sourceTabID: sourceSession.tabID,
            windowID: 1
        )
        let staleFocusCallback = try XCTUnwrap(stalePresentation.onSuccessfulModelSelection)
        hud.present(mode: .switchModel) { stalePresentation }
        let staleLeaf = try XCTUnwrap(hud.filteredLeaves.first(where: isHostDefault))
        fixture.viewModel.test_setCurrentTabIDOverride(UUID())
        defer { fixture.viewModel.test_setCurrentTabIDOverride(fixture.initialTabID) }
        await hud.commit(staleLeaf)
        XCTAssertTrue(hud.isPresented, "A rejected remote commit keeps the HUD open with its error.")
        XCTAssertEqual(
            hud.errorMessage,
            AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
        )
        XCTAssertNil(composer.focusRequest)
        staleFocusCallback()
        XCTAssertNil(
            composer.focusRequest,
            "A remote source-pinned callback must not focus after the current tab drifts."
        )
    }

    @MainActor
    func testCanForkCurrentSessionReflectsCapableAndLegacyHostsWithoutChangingLocalGate() async throws {
        let catalog = RemoteHostAgentCatalog.degraded
        let capableStore = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let capable = try await makeFixture(store: capableStore, catalogProvider: { _ in catalog })
        let capableSession = try await capable.viewModel.ensureSessionReady(tabID: capable.initialTabID)
        let capableConnection = HandoffRecordingConnection(
            sourceSessionID: UUID().uuidString,
            hostRowID: UUID(),
            destinationSessionID: UUID().uuidString,
            advertisedFeatures: [RemoteWireFeatures.forkSession]
        )
        capableSession.remoteHost = binding(
            host: capable.host,
            remoteSessionID: UUID().uuidString
        )
        let capableController = try RemoteAgentSessionController(
            binding: XCTUnwrap(capableSession.remoteHost),
            connection: capableConnection
        )
        capable.coordinator.test_installController(
            capableController,
            for: capableSession,
            hostID: capable.host.id
        )
        defer { capable.coordinator.stop(tabID: capableSession.tabID) }

        let beforeCapableProbe = capable.viewModel.test_syncRunInteractionCallCount
        XCTAssertFalse(capable.viewModel.canForkCurrentSession)
        await waitUntil {
            capable.viewModel.canForkCurrentSession
        }
        XCTAssertTrue(capable.viewModel.canForkCurrentSession)
        XCTAssertGreaterThan(capable.viewModel.test_syncRunInteractionCallCount, beforeCapableProbe)

        capableSession.remoteHost = nil
        capableSession.replaceItems([])
        XCTAssertFalse(capable.viewModel.canForkCurrentSession)
        capableSession.replaceItems([.user("local turn", sequenceIndex: 0)])
        XCTAssertTrue(capable.viewModel.canForkCurrentSession)

        let legacyStore = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let legacy = try await makeFixture(store: legacyStore, catalogProvider: { _ in catalog })
        let legacySession = try await legacy.viewModel.ensureSessionReady(tabID: legacy.initialTabID)
        let legacyConnection = HandoffRecordingConnection(
            sourceSessionID: UUID().uuidString,
            hostRowID: UUID(),
            destinationSessionID: UUID().uuidString,
            advertisedFeatures: []
        )
        legacySession.remoteHost = binding(
            host: legacy.host,
            remoteSessionID: UUID().uuidString
        )
        let legacyController = try RemoteAgentSessionController(
            binding: XCTUnwrap(legacySession.remoteHost),
            connection: legacyConnection
        )
        legacy.coordinator.test_installController(
            legacyController,
            for: legacySession,
            hostID: legacy.host.id
        )
        defer { legacy.coordinator.stop(tabID: legacySession.tabID) }

        let beforeLegacyProbe = legacy.viewModel.test_syncRunInteractionCallCount
        XCTAssertFalse(legacy.viewModel.canForkCurrentSession)
        await waitUntil {
            legacy.viewModel.test_syncRunInteractionCallCount > beforeLegacyProbe
        }
        XCTAssertFalse(legacy.viewModel.canForkCurrentSession)
    }

    @MainActor
    func testWorkspacePickupAttachFailureKeepsTabAndAppendsSystemMessage() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let fixture = try await makeFixture(store: store)
        let remoteID = UUID().uuidString
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { _ in
            throw WorkspacePickupTestError.attachFailed
        }

        let pickedUp = await fixture.coordinator.pickUpWorkspaceSession(
            descriptor: descriptor(id: remoteID, name: "Kept Session", modified: 1),
            hostRecord: fixture.host
        )
        let session = try XCTUnwrap(pickedUp)

        XCTAssertTrue(fixture.viewModel.sessions[session.tabID] === session)
        XCTAssertTrue(session.items.contains {
            $0.kind == .system
                && $0.text.contains("Remote workspace session attach failed")
                && $0.text.contains("attachFailed")
        })
    }

    @MainActor
    func testWorkspaceErrorsUseFriendlyWorkspaceAndHostCopy() {
        for code in ["workspace_not_open", "workspace_mismatch"] {
            let error = RemoteClientError.fromCommandError(
                code: code,
                message: code == "workspace_not_open"
                    ? "Workspace 'Project Alpha' is not open on the host."
                    : "workspace_mismatch: requested workspace differs"
            )
            XCTAssertEqual(
                RemoteAgentModeCoordinator.describe(
                    error,
                    workspaceName: "Project Alpha",
                    hostName: "Studio Mac"
                ),
                "Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
            )
        }

        let unscopedMismatch = RemoteClientError.fromCommandError(
            code: "workspace_mismatch",
            message: "workspace_mismatch: the target window's active workspace is 'Other' (id), not requested"
        )
        XCTAssertEqual(
            RemoteAgentModeCoordinator.describe(unscopedMismatch),
            "The requested workspace is not open on the host. Open it there and try again."
        )
    }

    @MainActor
    func testClosedWorkspaceSendFailureUsesSystemCopyAndResetsRunState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.runState = .running
        session.setRunningStatus("Starting on Studio Mac…", source: .transport)
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote start failed",
            error: RemoteClientError.fromCommandError(
                code: "workspace_not_open",
                message: "Workspace 'Project Alpha' is not open on the host."
            )
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.runningStatusText)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.contains(optimisticID))
        let system = try XCTUnwrap(session.items.last)
        XCTAssertEqual(system.kind, .system)
        XCTAssertEqual(
            system.text,
            "Remote start failed: Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
        )
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(tabID: session.tabID, itemID: system.id))
    }

    @MainActor
    func testTransportSendFailureOffersLocalFallbackAndSubsequentLocalSendSucceeds() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        // Failed INITIAL start: the host never adopted a session for this run,
        // so falling back locally cannot orphan a still-running host session.
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        XCTAssertNil(session.remoteHost?.normalizedRemoteSessionID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.runState = .running
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused")
        )

        let failureItem = try XCTUnwrap(session.items.last)
        XCTAssertEqual(failureItem.kind, .system)
        XCTAssertTrue(failureItem.text.contains("Remote transport failed: connection refused"))
        XCTAssertTrue(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        fixture.viewModel.runLocallyInsteadAfterRemoteFailure(tabID: session.tabID)
        XCTAssertNil(session.remoteHost)
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        let outcome = await fixture.viewModel.startAgentRun(
            tabID: session.tabID,
            initialMessage: "Run this locally",
            inputConstituents: nil
        )
        XCTAssertTrue(outcome?.didSend == true, String(describing: outcome))
        XCTAssertTrue(fixture.lifecycleRecorder.events.contains("codex:send"))
        XCTAssertNil(session.remoteHost)
    }

    @MainActor
    func testTransportSteerFailureWithAdoptedRemoteSessionDoesNotOfferLocalFallback() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        // Adopted host session (non-empty remoteSessionID): a steer transport
        // failure does not mean the host run stopped, so "Run locally instead"
        // would create a dual-execution hazard and must not be offered.
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-abc123")
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.hasSentFirstMessage = true
        session.appendItem(.user("already running on the host", sequenceIndex: 0))
        session.runState = .running
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused")
        )

        let failureItem = try XCTUnwrap(session.items.last)
        XCTAssertEqual(failureItem.kind, .system)
        XCTAssertTrue(failureItem.text.contains("Remote transport failed: connection refused"))
        XCTAssertEqual(session.runState, .failed)
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        fixture.viewModel.runLocallyInsteadAfterRemoteFailure(tabID: session.tabID)
        XCTAssertEqual(session.remoteHost?.remoteSessionID, "remote-abc123")
        XCTAssertEqual(session.remoteHost?.hostID, fixture.host.id)
    }

    @MainActor
    func testFailedAdoptedSteerLeavesOneUndeliveredUserItemAndErrorWithoutHostDelivery() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let prepared = try await prepareFailedAdoptedTurn(fixture: fixture, text: "Resend this exact turn")

        let userItems = prepared.session.items.filter { $0.kind == .user }
        XCTAssertEqual(userItems.count, 1)
        XCTAssertEqual(userItems.first?.text, "Resend this exact turn")
        XCTAssertEqual(userItems.first?.isUndeliveredRemoteSend, true)
        XCTAssertTrue(prepared.session.items.contains { $0.kind == .system || $0.kind == .error })
        let steerCount = await prepared.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 0)
        let failureItem = try XCTUnwrap(prepared.session.items.last)
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: prepared.session.tabID,
            itemID: failureItem.id
        ))
    }

    @MainActor
    func testResendUndeliveredAdoptedTurnUsesNormalSubmissionPathExactlyOnce() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let prepared = try await prepareFailedAdoptedTurn(fixture: fixture, text: "Byte-for-byte original")

        fixture.viewModel.resendUndeliveredRemoteUserTurn(
            tabID: prepared.session.tabID,
            itemID: prepared.userItemID
        )
        await waitForCommand(type: "steer", count: 1, connection: prepared.connection)

        let startCount = await prepared.connection.commandCount(type: "start")
        let steerCount = await prepared.connection.commandCount(type: "steer")
        let steerFrames = await prepared.connection.frames(type: "steer")
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(steerCount, 1)
        let steerFrame = try XCTUnwrap(steerFrames.first)
        XCTAssertEqual(steerFrame.sessionID, "remote-abc123")
        XCTAssertEqual(steerFrame.payload?.objectValue?["message"]?.stringValue, "Byte-for-byte original")
    }

    @MainActor
    func testResendFailedInitialStartDispatchesExactlyOneStart() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .failed
        var userItem = AgentChatItem.user("Retry initial start", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Retry initial start",
            wasStart: true,
            modelSelectionRaw: "codexExec:gpt-5.4",
            sessionName: "Initial retry",
            workspaceName: "Project Alpha"
        )
        let connection = ResendRecordingConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitForCommand(type: "start", count: 1, connection: connection)

        let startCount = await connection.commandCount(type: "start")
        let steerCount = await connection.commandCount(type: "steer")
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(steerCount, 0)
        let startFrames = await connection.frames(type: "start")
        XCTAssertEqual(startFrames.first?.payload?.objectValue?["message"]?.stringValue, "Retry initial start")
    }

    @MainActor
    func testResendFailedInitialStartWithAdoptedBindingClearsWithoutDispatch() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .failed
        var userItem = AgentChatItem.user("Possibly delivered", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Possibly delivered",
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-adopted-after-failure")
        let connection = ResendRecordingConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)

        let startCount = await connection.commandCount(type: "start")
        let steerCount = await connection.commandCount(type: "steer")
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(steerCount, 0)
        XCTAssertEqual(session.items.first(where: { $0.id == userItem.id })?.isUndeliveredRemoteSend, false)
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id])
        XCTAssertFalse(session.remoteResendInFlightItemIDs.contains(userItem.id))
        XCTAssertEqual(session.items.count(where: {
            $0.kind == .system && $0.text == "Remote send was already delivered."
        }), 1)
    }

    @MainActor
    func testAlreadyDeliveredResendReconcilesRunStateViaAttachCatchUp() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-adopted-catch-up")
        session.runState = .failed
        var userItem = AgentChatItem.user("Delivered before retry", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Delivered before retry",
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        let connection = ResendRecordingConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)

        XCTAssertEqual(session.runState, .failed)
        await waitForCommand(type: "get_log", count: 1, connection: connection)
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    @MainActor
    func testSuccessfulResendClearsUndeliveredState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let prepared = try await prepareFailedAdoptedTurn(fixture: fixture, text: "Deliver once")

        fixture.viewModel.resendUndeliveredRemoteUserTurn(
            tabID: prepared.session.tabID,
            itemID: prepared.userItemID
        )
        await waitForCommand(type: "steer", count: 1, connection: prepared.connection)
        await waitUntil {
            prepared.session.items.first(where: { $0.id == prepared.userItemID })?.isUndeliveredRemoteSend == false
        }

        XCTAssertEqual(prepared.session.items.count(where: { $0.id == prepared.userItemID }), 1)
        XCTAssertEqual(
            prepared.session.items.first(where: { $0.id == prepared.userItemID })?.isUndeliveredRemoteSend,
            false
        )
    }

    @MainActor
    func testUndeliveredUserBubblePresentationExposesResendAction() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-presentation")
        var undelivered = AgentChatItem.user("Failed")
        undelivered.isUndeliveredRemoteSend = true
        session.appendItem(undelivered)
        session.remoteResendPayloadsByItemID[undelivered.id] = .init(
            providerText: "Failed",
            wasStart: false,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )

        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: undelivered, tabID: session.tabID),
            .init(isUndelivered: true, resendActionLabel: "Resend")
        )
        session.remoteResendInFlightItemIDs.insert(undelivered.id)
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: undelivered, tabID: session.tabID),
            .init(isUndelivered: true, resendActionLabel: nil)
        )
        session.remoteResendInFlightItemIDs.remove(undelivered.id)
        session.remoteResendPayloadsByItemID.removeValue(forKey: undelivered.id)
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: undelivered, tabID: session.tabID),
            .init(isUndelivered: true, resendActionLabel: nil)
        )
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: .user("Delivered"), tabID: session.tabID),
            .init(isUndelivered: false, resendActionLabel: nil)
        )
        var nonUser = AgentChatItem.system("Not a user row")
        nonUser.isUndeliveredRemoteSend = true
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: nonUser, tabID: session.tabID),
            .init(isUndelivered: false, resendActionLabel: nil)
        )
    }

    @MainActor
    func testSubmitUserTurnFailureCapturesDispatchedProviderTextAndMarksUndelivered() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-real-failure")
        session.hasSentFirstMessage = true
        session.runState = .running
        let connection = ResendRecordingConnection(failingCommandTypes: ["steer"])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)
        fixture.viewModel.interviewFirst = true

        _ = fixture.viewModel.submitUserTurn(text: "Actually dispatched text", tabID: session.tabID, codexAttemptID: nil, admitted: nil)
        await waitUntil {
            session.items.contains { $0.kind == .user && $0.isUndeliveredRemoteSend }
        }

        let userItem = try XCTUnwrap(session.items.first {
            $0.kind == .user && $0.text == "Actually dispatched text"
        })
        let steerFrames = await connection.frames(type: "steer")
        let dispatchedText = try XCTUnwrap(steerFrames.first?.payload?.objectValue?["message"]?.stringValue)
        XCTAssertEqual(session.remoteResendPayloadsByItemID[userItem.id]?.providerText, dispatchedText)
        XCTAssertEqual(session.pendingRemoteOptimisticProviderTextByItemID[userItem.id], dispatchedText)
        XCTAssertNotEqual(dispatchedText, userItem.text)
        XCTAssertTrue(dispatchedText.contains("<interview_first>"))
        XCTAssertTrue(dispatchedText.hasSuffix("Actually dispatched text"))
        XCTAssertTrue(userItem.isUndeliveredRemoteSend)
        let successfulDeliveryCount = await connection.successfulDeliveryCount()
        XCTAssertEqual(successfulDeliveryCount, 0)

        let projected = AgentChatItem(
            id: UUID(),
            timestamp: userItem.timestamp.addingTimeInterval(-10),
            kind: .user,
            text: dispatchedText,
            sequenceIndex: userItem.sequenceIndex
        )
        fixture.coordinator.test_applyTranscriptRows([projected], to: session)

        let projectedUser = try XCTUnwrap(session.items.first { $0.kind == .user })
        XCTAssertEqual(session.items.count(where: { $0.kind == .user }), 1)
        XCTAssertFalse(session.items.contains { $0.id == userItem.id })
        XCTAssertEqual(projectedUser.id, projected.id)
        XCTAssertEqual(projectedUser.timestamp, userItem.timestamp)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.isEmpty)
        XCTAssertTrue(session.pendingRemoteOptimisticProviderTextByItemID.isEmpty)
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id])
    }

    @MainActor
    func testResendPickerSelectedStartPreservesStoredWindowAndWorkspaceTarget() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        let userItem = AgentChatItem.user("Retry picked target", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        let option = RemoteStartWindowOption(
            windowID: 42,
            title: "Picked Window",
            workspaceID: "workspace-picked",
            workspaceName: "Picked Workspace"
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: "Retry picked target",
            modelSelectionRaw: "codexExec:gpt-5.4",
            sessionName: "Picked retry",
            workspaceName: "Original Picked Workspace",
            optimisticUserItemID: userItem.id,
            windows: [option]
        )
        let connection = ResendRecordingConnection(
            startErrors: [.protocolViolation("synthetic picker-selected failure")]
        )
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.selectRemoteStartWindow(option)
        await waitUntil {
            session.items.first(where: { $0.id == userItem.id })?.isUndeliveredRemoteSend == true
        }
        XCTAssertEqual(session.remoteResendPayloadsByItemID[userItem.id]?.windowID, 42)
        XCTAssertEqual(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceID, "workspace-picked")

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitForCommand(type: "start", count: 2, connection: connection)

        let startFrames = await connection.frames(type: "start")
        let resendFrame = try XCTUnwrap(startFrames.last)
        XCTAssertEqual(resendFrame.payload?.objectValue?["window_id"]?.intValue, 42)
        XCTAssertEqual(resendFrame.payload?.objectValue?["workspace_id"]?.stringValue, "workspace-picked")
        XCTAssertNil(resendFrame.payload?.objectValue?["workspace_name"])
        XCTAssertEqual(session.locallyAttributedStartItemID, userItem.id)
    }

    @MainActor
    func testNonTargetFailureAfterWindowSelectionStoresPickedTargetWithNilWorkspaceName() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        let userItem = AgentChatItem.user("Retry selected target", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: userItem.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "Stale Workspace"
        )
        let option = RemoteStartWindowOption(
            windowID: 73,
            title: "Selected Window",
            workspaceID: "selected-workspace",
            workspaceName: "Selected Workspace"
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: userItem.text,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "Stale Workspace",
            optimisticUserItemID: userItem.id,
            windows: [option]
        )
        let connection = ResendRecordingConnection(
            startErrors: [.protocolViolation("synthetic non-target failure")]
        )
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.selectRemoteStartWindow(option)
        await waitUntil {
            session.items.first(where: { $0.id == userItem.id })?.isUndeliveredRemoteSend == true
        }

        XCTAssertEqual(session.remoteResendPayloadsByItemID[userItem.id]?.windowID, 73)
        XCTAssertEqual(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceID, "selected-workspace")
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceName)
    }

    @MainActor
    func testTargetFailureReopensPickerAndTerminalSelectionClearsRecoveryState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .failed
        var userItem = AgentChatItem.user("Retry target picker", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Retry target picker",
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: "Target picker",
            workspaceName: "Original Workspace",
            windowID: 7,
            workspaceID: "stale-workspace"
        )
        let pickerError = RemoteClientError.fromCommandError(
            code: "ambiguous_start_target",
            message: "Choose a window.",
            details: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(88),
                        "title": .string("Recovered Window"),
                        "workspace_id": .string("recovered-workspace"),
                        "workspace_name": .string("Recovered Workspace")
                    ])
                ])
            ])
        )
        let connection = ResendRecordingConnection(startErrors: [pickerError])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitUntil { fixture.viewModel.pendingRemoteStartWindowPicker != nil }

        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.windowID)
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceID)
        XCTAssertEqual(
            session.remoteResendPayloadsByItemID[userItem.id]?.workspaceName,
            "Original Workspace"
        )
        XCTAssertTrue(session.remoteResendInFlightItemIDs.contains(userItem.id))
        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        let startCountWhilePickerOpen = await connection.commandCount(type: "start")
        XCTAssertEqual(startCountWhilePickerOpen, 1)

        let option = try XCTUnwrap(fixture.viewModel.pendingRemoteStartWindowPicker?.windows.first)
        fixture.viewModel.selectRemoteStartWindow(option)
        await waitForCommand(type: "start", count: 2, connection: connection)
        await waitUntil {
            session.items.first(where: { $0.id == userItem.id })?.isUndeliveredRemoteSend == false
        }

        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id])
        XCTAssertFalse(session.remoteResendInFlightItemIDs.contains(userItem.id))
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.contains(userItem.id))
        XCTAssertEqual(session.locallyAttributedStartItemID, userItem.id)
    }

    @MainActor
    func testWorkspaceMismatchWithWindowCandidatesReopensPickerAndClearsStoredTarget() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .failed
        var userItem = AgentChatItem.user("Retry mismatched workspace", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Retry mismatched workspace",
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: "Workspace mismatch retry",
            workspaceName: "Original Workspace",
            windowID: 7,
            workspaceID: "stale-workspace"
        )
        let mismatchError = RemoteClientError.fromCommandError(
            code: "workspace_mismatch",
            message: "The selected workspace changed.",
            details: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(91),
                        "title": .string("Host Candidate"),
                        "workspace_id": .string("host-workspace"),
                        "workspace_name": .string("Host Workspace")
                    ])
                ])
            ])
        )
        let connection = ResendRecordingConnection(startErrors: [mismatchError])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitUntil { fixture.viewModel.pendingRemoteStartWindowPicker != nil }

        let pickerWindow = try XCTUnwrap(fixture.viewModel.pendingRemoteStartWindowPicker?.windows.first)
        XCTAssertEqual(pickerWindow.windowID, 91)
        XCTAssertEqual(pickerWindow.workspaceID, "host-workspace")
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.windowID)
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceID)
        XCTAssertEqual(
            session.remoteResendPayloadsByItemID[userItem.id]?.workspaceName,
            "Original Workspace"
        )
        XCTAssertTrue(session.remoteResendInFlightItemIDs.contains(userItem.id))
    }

    @MainActor
    func testBindingRequiredWithWindowCandidatesReopensPickerAndClearsStoredTarget() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .failed
        var userItem = AgentChatItem.user("Retry after binding failure", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: userItem.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: "Binding retry",
            workspaceName: "Original Workspace",
            windowID: 7,
            workspaceID: "stale-workspace"
        )
        let bindingError = RemoteClientError.fromCommandError(
            code: "binding_required",
            message: "Choose a window before starting.",
            details: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(92),
                        "title": .string("Binding Candidate"),
                        "workspace_id": .string("binding-workspace"),
                        "workspace_name": .string("Binding Workspace")
                    ])
                ])
            ])
        )
        let connection = ResendRecordingConnection(startErrors: [bindingError])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitUntil { fixture.viewModel.pendingRemoteStartWindowPicker != nil }

        let pickerWindow = try XCTUnwrap(fixture.viewModel.pendingRemoteStartWindowPicker?.windows.first)
        XCTAssertEqual(pickerWindow.windowID, 92)
        XCTAssertEqual(pickerWindow.workspaceID, "binding-workspace")
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.windowID)
        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id]?.workspaceID)
        XCTAssertEqual(
            session.remoteResendPayloadsByItemID[userItem.id]?.workspaceName,
            "Original Workspace"
        )
        XCTAssertTrue(session.remoteResendInFlightItemIDs.contains(userItem.id))
    }

    @MainActor
    func testResendStartAttributionMismatchSteersAdoptedSession() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-attributed")
        session.runState = .failed
        session.locallyAttributedStartItemID = UUID()
        var userItem = AgentChatItem.user("Continue original start", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Continue original start",
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        let connection = ResendRecordingConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitForCommand(type: "steer", count: 1, connection: connection)

        let startCount = await connection.commandCount(type: "start")
        let steerFrames = await connection.frames(type: "steer")
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(steerFrames.count, 1)
        XCTAssertEqual(steerFrames.first?.sessionID, "remote-attributed")
        XCTAssertEqual(
            steerFrames.first?.payload?.objectValue?["message"]?.stringValue,
            "Continue original start"
        )
        XCTAssertFalse(session.items.contains {
            $0.kind == .system && $0.text == "Remote send was already delivered."
        })
    }

    @MainActor
    func testResendFailureAfterOptimisticRemovalSilentlyDropsRecoveryState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-midflight")
        session.runState = .failed
        var userItem = AgentChatItem.user("Removed during resend", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Removed during resend",
            wasStart: false,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        let connection = BlockingFailingResendConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        // Model a previously attached session (the production resend reality) so the
        // steer observation preflight no-ops instead of attaching via the blocking
        // stub, preserving this test's original command choreography.
        await controller.test_markObservationAttached()
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await connection.waitUntilCommandStarted()
        let failureRowCount = session.items.count(where: { $0.kind == .error || $0.kind == .system })
        session.mutateItemsBatch { items in
            items.removeAll { $0.id == userItem.id }
        }
        await connection.releaseFailure()
        await waitUntil { !session.remoteResendInFlightItemIDs.contains(userItem.id) }

        XCTAssertNil(session.remoteResendPayloadsByItemID[userItem.id])
        XCTAssertFalse(session.pendingRemoteOptimisticUserItemIDs.contains(userItem.id))
        XCTAssertNil(session.pendingRemoteOptimisticProviderTextByItemID[userItem.id])
        XCTAssertNil(session.runningStatusText)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error || $0.kind == .system }), failureRowCount)
        XCTAssertEqual(session.runState, .running)
    }

    @MainActor
    func testRemoteResendFailureAfterOwnerTeardownDoesNotMutateDetachedSession() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-detached-resend")
        session.runState = .failed
        var userItem = AgentChatItem.user("Detached resend", sequenceIndex: session.nextSequenceIndex)
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: "Wrapped detached resend",
            wasStart: false,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        let connection = BlockingFailingResendConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        // Model a previously attached session (the production resend reality) so the
        // steer observation preflight no-ops instead of attaching via the blocking
        // stub, preserving this test's original command choreography.
        await controller.test_markObservationAttached()
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await connection.waitUntilCommandStarted()
        // Keep this regression scoped to detached-task liveness rather than the unrelated
        // active-run cancellation path, which owns a separate transport shutdown contract.
        session.runState = .failed
        await fixture.viewModel.handleComposeTabsWillClose([session.tabID], reason: .stash)
        let failureRowCountAfterTeardown = session.items.count {
            $0.kind == .error || $0.kind == .system
        }

        await connection.releaseFailure()
        await waitUntil { !session.remoteResendInFlightItemIDs.contains(userItem.id) }

        XCTAssertNil(fixture.viewModel.sessions[session.tabID])
        XCTAssertNil(fixture.viewModel.pendingRemoteStartWindowPicker)
        XCTAssertEqual(session.items.count {
            $0.kind == .error || $0.kind == .system
        }, failureRowCountAfterTeardown)
    }

    @MainActor
    func testRunLocallyFallbackClearsAllUndeliveredRemoteRecoveryState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.locallyAttributedStartItemID = UUID()
        session.runState = .running
        let first = AgentChatItem.user("First failed turn", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(first)
        session.pendingRemoteOptimisticUserItemIDs.insert(first.id)
        let firstPayload = AgentRemoteResendPayload(
            providerText: first.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: first.id,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused"),
            resendPayload: firstPayload
        )
        let failureItem = try XCTUnwrap(session.items.last)
        session.remoteResendInFlightItemIDs.insert(first.id)
        session.pendingRemoteOptimisticProviderTextByItemID[first.id] = firstPayload.providerText

        var second = AgentChatItem.user("Second failed turn", sequenceIndex: session.nextSequenceIndex)
        second.isUndeliveredRemoteSend = true
        session.appendItem(second)
        session.pendingRemoteOptimisticUserItemIDs.insert(second.id)
        session.remoteResendPayloadsByItemID[second.id] = .init(
            providerText: second.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        session.remoteResendInFlightItemIDs.insert(second.id)
        session.pendingRemoteOptimisticProviderTextByItemID[second.id] = second.text
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: firstPayload.providerText,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "Project Alpha",
            optimisticUserItemID: first.id,
            windows: [RemoteStartWindowOption(
                windowID: 44,
                title: "Fallback Window",
                workspaceID: "fallback-workspace",
                workspaceName: "Project Alpha"
            )]
        )

        fixture.viewModel.runLocallyInsteadAfterRemoteFailure(tabID: session.tabID)

        XCTAssertNil(session.remoteHost)
        XCTAssertNil(session.locallyAttributedStartItemID)
        XCTAssertTrue(session.items.filter { $0.kind == .user }.allSatisfy {
            !$0.isUndeliveredRemoteSend
        })
        XCTAssertTrue(session.remoteResendPayloadsByItemID.isEmpty)
        XCTAssertTrue(session.remoteResendInFlightItemIDs.isEmpty)
        XCTAssertTrue(session.pendingRemoteOptimisticProviderTextByItemID.isEmpty)
        XCTAssertNil(fixture.viewModel.pendingRemoteStartWindowPicker)
        XCTAssertFalse(session.pendingRemoteOptimisticUserItemIDs.contains(first.id))
        XCTAssertFalse(session.pendingRemoteOptimisticUserItemIDs.contains(second.id))
        XCTAssertTrue(session.items.contains { $0.id == failureItem.id })
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: first, tabID: session.tabID).resendActionLabel,
            nil
        )
    }

    @MainActor
    func testRemoteStartPickerClearsWhenOwnerIsRemovedBeforeTeardownOrSelection() async throws {
        let option = RemoteStartWindowOption(
            windowID: 99,
            title: "Removed Owner Window",
            workspaceID: "removed-owner-workspace",
            workspaceName: "Project Alpha"
        )

        let teardownFixture = try await makeFixture(
            store: StubWorkspaceSessionCatalogStore(state: .error("unused"))
        )
        let teardownSession = try await teardownFixture.viewModel.ensureSessionReady(
            tabID: teardownFixture.initialTabID
        )
        let teardownItem = AgentChatItem.user("Teardown pending start")
        teardownSession.appendItem(teardownItem)
        teardownFixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: teardownSession.tabID,
            hostName: "Studio Mac",
            message: teardownItem.text,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "Project Alpha",
            optimisticUserItemID: teardownItem.id,
            windows: [option]
        )
        let failureRowCount = teardownSession.items.count {
            $0.kind == .error || $0.kind == .system
        }

        await teardownFixture.viewModel.handleComposeTabsWillClose(
            [teardownSession.tabID],
            reason: .stash
        )

        XCTAssertNil(teardownFixture.viewModel.pendingRemoteStartWindowPicker)
        XCTAssertNil(teardownFixture.viewModel.sessions[teardownSession.tabID])
        XCTAssertEqual(teardownSession.items.count {
            $0.kind == .error || $0.kind == .system
        }, failureRowCount)

        teardownFixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: teardownSession.tabID,
            hostName: "Studio Mac",
            message: "Selection after removal",
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "Project Alpha",
            optimisticUserItemID: UUID(),
            windows: [option]
        )

        teardownFixture.viewModel.selectRemoteStartWindow(option)

        XCTAssertNil(teardownFixture.viewModel.pendingRemoteStartWindowPicker)
    }

    @MainActor
    func testV40CrossTabPickerDisplacementFailsAndReleasesDisplacedSend() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let displacedSession = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        displacedSession.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        displacedSession.runState = .waitingForUser
        var displacedItem = AgentChatItem.user("Displaced start")
        displacedItem.isUndeliveredRemoteSend = true
        displacedSession.appendItem(displacedItem)
        displacedSession.remoteResendInFlightItemIDs.insert(displacedItem.id)
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: displacedSession.tabID,
            hostName: "Studio Mac",
            message: displacedItem.text,
            modelSelectionRaw: nil,
            sessionName: "Displaced",
            workspaceName: "Project Alpha",
            optimisticUserItemID: displacedItem.id,
            windows: [RemoteStartWindowOption(
                windowID: 10,
                title: "First Window",
                workspaceID: "first-workspace",
                workspaceName: "Project Alpha"
            )]
        )
        let displacedConnection = ResendRecordingConnection(
            startErrors: [.protocolViolation("keep displaced resend undelivered")]
        )
        let displacedRemoteHost = try XCTUnwrap(displacedSession.remoteHost)
        let displacedController = RemoteAgentSessionController(
            binding: displacedRemoteHost,
            connection: displacedConnection
        )
        fixture.coordinator.test_installController(
            displacedController,
            for: displacedSession,
            hostID: fixture.host.id
        )

        let replacementSession = AgentTabSession(tabID: UUID())
        fixture.viewModel.test_installLiveSession(replacementSession)
        replacementSession.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        replacementSession.runState = .failed
        var replacementItem = AgentChatItem.user("Replacement start")
        replacementItem.isUndeliveredRemoteSend = true
        replacementSession.appendItem(replacementItem)
        replacementSession.remoteResendPayloadsByItemID[replacementItem.id] = .init(
            providerText: replacementItem.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: "Replacement",
            workspaceName: "Project Alpha"
        )
        let replacementConnection = ResendRecordingConnection(startErrors: [Self.pickerError(windowID: 20)])
        let replacementRemoteHost = try XCTUnwrap(replacementSession.remoteHost)
        let replacementController = RemoteAgentSessionController(
            binding: replacementRemoteHost,
            connection: replacementConnection
        )
        fixture.coordinator.test_installController(
            replacementController,
            for: replacementSession,
            hostID: fixture.host.id
        )

        fixture.viewModel.resendUndeliveredRemoteUserTurn(
            tabID: replacementSession.tabID,
            itemID: replacementItem.id
        )
        await waitUntil {
            fixture.viewModel.pendingRemoteStartWindowPicker?.tabID == replacementSession.tabID
        }

        XCTAssertEqual(displacedSession.runState, .failed)
        XCTAssertFalse(displacedSession.remoteResendInFlightItemIDs.contains(displacedItem.id))
        XCTAssertTrue(displacedSession.items.contains {
            $0.text.contains("Remote start superseded")
                && $0.text.contains("Send again and choose a host window to start remotely.")
        })
        let displacedPayload = try XCTUnwrap(displacedSession.remoteResendPayloadsByItemID[displacedItem.id])
        XCTAssertEqual(displacedPayload.workspaceName, "Project Alpha")
        XCTAssertNil(displacedPayload.windowID)
        XCTAssertNil(displacedPayload.workspaceID)
        XCTAssertTrue(displacedSession.items.first(where: { $0.id == displacedItem.id })?.isUndeliveredRemoteSend == true)
        let displacedFailureItem = try XCTUnwrap(displacedSession.items.last {
            $0.kind == .system || $0.kind == .error
        })
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: displacedSession.tabID,
            itemID: displacedFailureItem.id
        ))
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: displacedItem, tabID: displacedSession.tabID).resendActionLabel,
            "Resend"
        )

        fixture.viewModel.resendUndeliveredRemoteUserTurn(
            tabID: displacedSession.tabID,
            itemID: displacedItem.id
        )
        await waitForCommand(type: "start", count: 1, connection: displacedConnection)
        await waitUntil { !displacedSession.remoteResendInFlightItemIDs.contains(displacedItem.id) }
        let displacedStartFrames = await displacedConnection.frames(type: "start")
        let dispatched = try XCTUnwrap(displacedStartFrames.first)
        XCTAssertEqual(dispatched.payload?.objectValue?["workspace_name"]?.stringValue, "Project Alpha")
        XCTAssertNil(dispatched.payload?.objectValue?["window_id"])
        XCTAssertNil(dispatched.payload?.objectValue?["workspace_id"])
        XCTAssertTrue(displacedSession.items.first(where: { $0.id == displacedItem.id })?.isUndeliveredRemoteSend == true)
    }

    @MainActor
    func testV41SamePickerPairRepresentsWithoutFailureSideEffects() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .waitingForUser
        var userItem = AgentChatItem.user("Same picker pair")
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: userItem.text,
            wasStart: true,
            modelSelectionRaw: nil,
            sessionName: "Same pair",
            workspaceName: "Project Alpha"
        )
        let originalPending = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: userItem.text,
            modelSelectionRaw: nil,
            sessionName: "Same pair",
            workspaceName: "Project Alpha",
            optimisticUserItemID: userItem.id,
            windows: [RemoteStartWindowOption(
                windowID: 30,
                title: "Original Window",
                workspaceID: "original-workspace",
                workspaceName: "Project Alpha"
            )]
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = originalPending
        let connection = ResendRecordingConnection(startErrors: [Self.pickerError(windowID: 31)])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(
            binding: remoteHost,
            connection: connection
        )
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)
        let failureRowCount = session.items.count(where: { $0.kind == .error || $0.kind == .system })

        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        await waitUntil {
            fixture.viewModel.pendingRemoteStartWindowPicker != nil
                && fixture.viewModel.pendingRemoteStartWindowPicker?.id != originalPending.id
        }

        XCTAssertEqual(fixture.viewModel.pendingRemoteStartWindowPicker?.tabID, session.tabID)
        XCTAssertEqual(fixture.viewModel.pendingRemoteStartWindowPicker?.optimisticUserItemID, userItem.id)
        XCTAssertTrue(session.remoteResendInFlightItemIDs.contains(userItem.id))
        XCTAssertEqual(session.items.count(where: { $0.kind == .error || $0.kind == .system }), failureRowCount)
        XCTAssertFalse(session.items.contains { $0.text.contains("Remote start superseded") })
    }

    @MainActor
    func testPickerOpenStatePersistsIntoRecoverableColdHydration() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickerOpenRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        fixture.workspaceManager.activeWorkspace?.customStoragePath = storageDirectory

        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        let connection = ResendRecordingConnection(startErrors: [Self.pickerError(windowID: 51)])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        fixture.coordinator.test_installController(
            RemoteAgentSessionController(binding: remoteHost, connection: connection),
            for: session,
            hostID: fixture.host.id
        )

        _ = fixture.viewModel.submitUserTurn(text: "Quit while picker open", tabID: session.tabID, codexAttemptID: nil, admitted: nil)
        await waitUntil {
            guard fixture.viewModel.pendingRemoteStartWindowPicker != nil,
                  let userItem = session.items.first(where: {
                      $0.kind == .user && $0.text == "Quit while picker open"
                  })
            else { return false }
            return userItem.isUndeliveredRemoteSend
                && session.remoteResendPayloadsByItemID[userItem.id] != nil
                && session.remoteResendInFlightItemIDs.contains(userItem.id)
        }

        let userItem = try XCTUnwrap(session.items.first {
            $0.kind == .user && $0.text == "Quit while picker open"
        })
        XCTAssertTrue(userItem.isUndeliveredRemoteSend)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.contains(userItem.id))
        XCTAssertTrue(session.remoteResendInFlightItemIDs.contains(userItem.id))
        XCTAssertEqual(
            fixture.viewModel.undeliveredPresentation(for: userItem, tabID: session.tabID),
            .init(isUndelivered: true, resendActionLabel: nil)
        )
        fixture.viewModel.resendUndeliveredRemoteUserTurn(tabID: session.tabID, itemID: userItem.id)
        let startCountWhilePickerOpen = await connection.commandCount(type: "start")
        XCTAssertEqual(startCountWhilePickerOpen, 1)
        let pickerPayload = try XCTUnwrap(session.remoteResendPayloadsByItemID[userItem.id])
        XCTAssertTrue(pickerPayload.wasStart)
        XCTAssertEqual(pickerPayload.workspaceName, "Project Alpha")
        XCTAssertNil(pickerPayload.windowID)
        XCTAssertNil(pickerPayload.workspaceID)
        XCTAssertEqual(session.items.map(\.kind), [.user])

        await fixture.viewModel.flushSave(for: session.tabID)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        let workspace = try XCTUnwrap(fixture.workspaceManager.activeWorkspace)
        let service = AgentSessionDataService.shared
        let loadedSessionResult = try await service.loadAgentSession(id: sessionID, for: workspace)
        let loadedSession = try XCTUnwrap(loadedSessionResult)
        let persistedPayload = try XCTUnwrap(loadedSession.remoteResendPayloadsByItemID[userItem.id.uuidString])
        XCTAssertTrue(persistedPayload.wasStart)
        XCTAssertEqual(persistedPayload.workspaceName, "Project Alpha")
        XCTAssertNil(persistedPayload.windowID)
        XCTAssertNil(persistedPayload.workspaceID)

        let pickerHydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: session.tabID,
            sessionID: sessionID,
            resolvedDisplayName: loadedSession.name,
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let pickerPreparedResult = try await service.preparePersistedHydration(pickerHydrationRequest)
        let pickerPrepared = try XCTUnwrap(pickerPreparedResult)
        let preparedPickerItem = try XCTUnwrap(
            pickerPrepared.canonicalLiveItems.first { $0.id == userItem.id }
        )
        XCTAssertTrue(preparedPickerItem.isUndeliveredRemoteSend)
        let preparedPickerPayload = try XCTUnwrap(
            pickerPrepared.persistedSession.remoteResendPayloadsByItemID[userItem.id.uuidString]
        )
        XCTAssertTrue(preparedPickerPayload.wasStart)
        XCTAssertEqual(preparedPickerPayload.workspaceName, "Project Alpha")
        XCTAssertNil(preparedPickerPayload.windowID)
        XCTAssertNil(preparedPickerPayload.workspaceID)

        let attributedItemID = UUID()
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: pickerPayload.providerText,
            wasStart: true,
            modelSelectionRaw: pickerPayload.modelSelectionRaw,
            sessionName: pickerPayload.sessionName,
            workspaceName: "Stale Project Name",
            windowID: 61,
            workspaceID: "workspace-selected"
        )
        session.locallyAttributedStartItemID = attributedItemID
        session.runState = .running
        XCTAssertTrue(session.runState.isActive)
        session.isDirty = true
        await fixture.viewModel.flushSave(for: session.tabID)

        let selectedLoadedResult = try await service.loadAgentSession(id: sessionID, for: workspace)
        let selectedLoaded = try XCTUnwrap(selectedLoadedResult)
        let selectedPersistedPayload = try XCTUnwrap(
            selectedLoaded.remoteResendPayloadsByItemID[userItem.id.uuidString]
        )
        XCTAssertNil(selectedPersistedPayload.workspaceName)
        XCTAssertEqual(selectedPersistedPayload.windowID, 61)
        XCTAssertEqual(selectedPersistedPayload.workspaceID, "workspace-selected")
        XCTAssertEqual(selectedLoaded.locallyAttributedStartItemID, attributedItemID)
        // F-7: a same-launch read keeps the live owner's saved active run; the cold hydration below
        // restores it.
        XCTAssertEqual(selectedLoaded.lastRunState, AgentSessionRunState.running.rawValue)

        let selectedHydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: session.tabID,
            sessionID: sessionID,
            resolvedDisplayName: selectedLoaded.name,
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let selectedPreparedResult = try await service.preparePersistedHydration(selectedHydrationRequest)
        let selectedPrepared = try XCTUnwrap(selectedPreparedResult)
        let selectedPreparedItem = try XCTUnwrap(
            selectedPrepared.canonicalLiveItems.first { $0.id == userItem.id }
        )
        XCTAssertTrue(selectedPreparedItem.isUndeliveredRemoteSend)
        XCTAssertNotNil(
            selectedPrepared.persistedSession.remoteResendPayloadsByItemID[userItem.id.uuidString]
        )
        let restoredViewModel = AgentModeViewModel(
            testWindowID: 2,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        let restoredSession = AgentTabSession(tabID: session.tabID)
        restoredViewModel.test_installLiveSession(restoredSession)
        _ = restoredViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: restoredSession)
        let didHydrate = await restoredViewModel.test_applyPersistedHydration(
            pickerPrepared,
            to: restoredSession
        )
        XCTAssertTrue(didHydrate)

        let restoredItem = try XCTUnwrap(restoredSession.items.first { $0.id == userItem.id })
        XCTAssertEqual(restoredSession.runState, .idle)
        XCTAssertTrue(restoredSession.pendingRemoteOptimisticUserItemIDs.contains(userItem.id))
        XCTAssertTrue(restoredSession.remoteResendInFlightItemIDs.isEmpty)
        XCTAssertEqual(
            restoredViewModel.undeliveredPresentation(for: restoredItem, tabID: restoredSession.tabID),
            .init(isUndelivered: true, resendActionLabel: "Resend")
        )
        XCTAssertFalse(restoredSession.items.contains { $0.kind == .error })

        let resendCoordinator = RemoteAgentModeCoordinator()
        let selectedViewModel = AgentModeViewModel(
            testWindowID: 3,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            testRemoteCoordinator: resendCoordinator
        )
        let selectedSession = AgentTabSession(tabID: session.tabID)
        selectedViewModel.test_installLiveSession(selectedSession)
        _ = selectedViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: selectedSession
        )
        let didHydrateSelected = await selectedViewModel.test_applyPersistedHydration(
            selectedPrepared,
            to: selectedSession
        )
        XCTAssertTrue(didHydrateSelected)
        XCTAssertEqual(selectedSession.runState, .idle)
        XCTAssertFalse(selectedSession.runState.isActive)
        XCTAssertEqual(selectedSession.locallyAttributedStartItemID, attributedItemID)
        XCTAssertTrue(selectedSession.remoteResendInFlightItemIDs.isEmpty)

        let selectedConnection = ResendRecordingConnection()
        let selectedRemoteHost = try XCTUnwrap(selectedSession.remoteHost)
        resendCoordinator.test_installController(
            RemoteAgentSessionController(binding: selectedRemoteHost, connection: selectedConnection),
            for: selectedSession,
            hostID: fixture.host.id
        )
        selectedViewModel.resendUndeliveredRemoteUserTurn(
            tabID: selectedSession.tabID,
            itemID: userItem.id
        )
        selectedViewModel.resendUndeliveredRemoteUserTurn(
            tabID: selectedSession.tabID,
            itemID: userItem.id
        )
        await waitForCommand(type: "start", count: 1, connection: selectedConnection)

        let selectedStartFrames = await selectedConnection.frames(type: "start")
        XCTAssertEqual(selectedStartFrames.count, 1)
        XCTAssertEqual(selectedStartFrames.first?.payload?.objectValue?["window_id"]?.intValue, 61)
        XCTAssertEqual(
            selectedStartFrames.first?.payload?.objectValue?["workspace_id"]?.stringValue,
            "workspace-selected"
        )
        XCTAssertNil(selectedStartFrames.first?.payload?.objectValue?["workspace_name"])
    }

    func testRemoteStartPickerOpenableWorkspaceNameUsesTrimmedCaseInsensitiveAbsence() {
        let matching = RemoteStartWindowPickerState(
            tabID: UUID(),
            hostName: "Studio Mac",
            message: "Start",
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "  Project Alpha  ",
            optimisticUserItemID: UUID(),
            windows: [
                .init(
                    windowID: 1,
                    title: "Existing",
                    workspaceID: nil,
                    workspaceName: "\nPROJECT ALPHA "
                )
            ]
        )
        XCTAssertNil(matching.openableWorkspaceName)

        let absent = RemoteStartWindowPickerState(
            tabID: UUID(),
            hostName: "Studio Mac",
            message: "Start",
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: " Project Alpha ",
            optimisticUserItemID: UUID(),
            windows: [
                .init(
                    windowID: 2,
                    title: "Other",
                    workspaceID: nil,
                    workspaceName: "Other Workspace"
                )
            ]
        )
        XCTAssertEqual(absent.openableWorkspaceName, "Project Alpha")

        let blank = RemoteStartWindowPickerState(
            tabID: UUID(),
            hostName: "Studio Mac",
            message: "Start",
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: "   ",
            optimisticUserItemID: UUID(),
            windows: []
        )
        XCTAssertNil(blank.openableWorkspaceName)
    }

    @MainActor
    func testStartRecoveryOpensWorkspaceThenStartsNameOnlyAndClearsFailedEpisode() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let openFailure = RemoteClientError.fromCommandError(
            code: "unsupported_frame_type",
            message: "Synthetic first open failure"
        )
        let openConnection = WorkspaceOpenRecordingConnection(outcomes: [
            .failure(openFailure),
            .success
        ])
        let fixture = try await makeFixture(
            store: store,
            workspaceOpenConnection: openConnection,
            grantedScopes: ["sessions:operate"]
        )

        await fixture.coordinator.autoOpenWorkspaceIfNeeded(
            hostRecord: fixture.host,
            clientWorkspaceID: fixture.workspace.id,
            workspaceName: fixture.workspace.name
        )
        guard case .failed = fixture.coordinator.workspaceOpenEpisodeState(
            hostID: fixture.host.id,
            clientWorkspaceID: fixture.workspace.id
        ) else {
            return XCTFail("Expected a failed auto-open episode before recovery")
        }

        let prepared = try await prepareStartRecovery(fixture: fixture)
        let baselineOpenCount = await openConnection.commandCount()
        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()

        await waitForCommand(type: "start", count: 1, connection: prepared.connection)
        await waitUntil {
            !prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID)
        }

        let openFrames = await openConnection.frames()
        XCTAssertEqual(openFrames.count, baselineOpenCount + 1)
        let openFrame = try XCTUnwrap(openFrames.last)
        XCTAssertEqual(openFrame.type, "open_workspace")
        XCTAssertEqual(openFrame.payload?.objectValue?["workspace_name"], .string("Project Alpha"))
        XCTAssertNil(openFrame.payload?.objectValue?["workspace_id"])

        let startFrames = await prepared.connection.frames(type: "start")
        XCTAssertEqual(startFrames.count, 1)
        let startFrame = try XCTUnwrap(startFrames.first)
        XCTAssertEqual(startFrame.payload?.objectValue?["workspace_name"], .string("Project Alpha"))
        XCTAssertNil(startFrame.payload?.objectValue?["window_id"])
        XCTAssertNil(startFrame.payload?.objectValue?["workspace_id"])
        XCTAssertNil(fixture.viewModel.pendingRemoteStartWindowPicker)
        XCTAssertNil(prepared.session.remoteResendPayloadsByItemID[prepared.userItemID])
        XCTAssertEqual(prepared.session.locallyAttributedStartItemID, prepared.userItemID)
        XCTAssertFalse(
            try XCTUnwrap(prepared.session.items.first { $0.id == prepared.userItemID })
                .isUndeliveredRemoteSend
        )
        XCTAssertNil(fixture.coordinator.workspaceOpenEpisodeState(
            hostID: fixture.host.id,
            clientWorkspaceID: fixture.workspace.id
        ))
        XCTAssertEqual(store.invalidatedHostIDs, [fixture.host.id])
    }

    @MainActor
    func testStartRecoveryOpenFailureStopsBeforeStartAndReleasesInFlight() async throws {
        let openError = RemoteClientError.transport("Synthetic open failure")
        let openConnection = WorkspaceOpenRecordingConnection(outcomes: [.failure(openError)])
        let fixture = try await makeFixture(
            store: StubWorkspaceSessionCatalogStore(state: .error("unused")),
            workspaceOpenConnection: openConnection
        )
        let prepared = try await prepareStartRecovery(fixture: fixture)

        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()
        await waitUntil {
            !prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID)
                && prepared.session.runState == .failed
        }

        let openCount = await openConnection.commandCount()
        let startCount = await prepared.connection.commandCount(type: "start")
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(startCount, 0)
        let payload = try XCTUnwrap(prepared.session.remoteResendPayloadsByItemID[prepared.userItemID])
        XCTAssertEqual(payload.workspaceName, "Project Alpha")
        XCTAssertNil(payload.windowID)
        XCTAssertNil(payload.workspaceID)
        XCTAssertNil(fixture.viewModel.pendingRemoteStartWindowPicker)
        XCTAssertTrue(prepared.session.items.contains {
            ($0.kind == .system || $0.kind == .error)
                && $0.text.contains("Remote start failed")
        })
    }

    @MainActor
    func testStartRecoveryTargetErrorReopensPickerAndRetainsInFlight() async throws {
        let openConnection = WorkspaceOpenRecordingConnection(outcomes: [.success])
        let targetError = RemoteClientError.fromCommandError(
            code: "binding_required",
            message: "Choose a host window.",
            details: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(9),
                        "title": .string("Other Window"),
                        "workspace_name": .string("Other Workspace")
                    ])
                ])
            ])
        )
        let fixture = try await makeFixture(
            store: StubWorkspaceSessionCatalogStore(state: .error("unused")),
            workspaceOpenConnection: openConnection
        )
        let prepared = try await prepareStartRecovery(
            fixture: fixture,
            startErrors: [targetError]
        )

        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()
        await waitUntil {
            fixture.viewModel.pendingRemoteStartWindowPicker != nil
        }

        let openCount = await openConnection.commandCount()
        let startCount = await prepared.connection.commandCount(type: "start")
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(
            fixture.viewModel.pendingRemoteStartWindowPicker?.optimisticUserItemID,
            prepared.userItemID
        )
        XCTAssertEqual(
            fixture.viewModel.pendingRemoteStartWindowPicker?.openableWorkspaceName,
            "Project Alpha"
        )
        XCTAssertEqual(fixture.viewModel.pendingRemoteStartWindowPicker?.windows.map(\.windowID), [9])
        XCTAssertEqual(
            fixture.viewModel.pendingRemoteStartWindowPicker?.windows.first?.workspaceName,
            "Other Workspace"
        )
        XCTAssertTrue(prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID))
        let payload = try XCTUnwrap(prepared.session.remoteResendPayloadsByItemID[prepared.userItemID])
        XCTAssertEqual(payload.workspaceName, "Project Alpha")
        XCTAssertNil(payload.windowID)
        XCTAssertNil(payload.workspaceID)
    }

    @MainActor
    func testStartRecoveryDeduplicatesWhileOpenIsInFlight() async throws {
        let gate = WorkspaceOpenCommandGate()
        let openConnection = WorkspaceOpenRecordingConnection(outcomes: [.gatedSuccess(gate)])
        let fixture = try await makeFixture(
            store: StubWorkspaceSessionCatalogStore(state: .error("unused")),
            workspaceOpenConnection: openConnection
        )
        let prepared = try await prepareStartRecovery(fixture: fixture)

        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()
        await gate.waitUntilEntered()

        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()
        fixture.viewModel.resendUndeliveredRemoteUserTurn(
            tabID: prepared.session.tabID,
            itemID: prepared.userItemID
        )
        let inFlightOpenCount = await openConnection.commandCount()
        let inFlightStartCount = await prepared.connection.commandCount(type: "start")
        XCTAssertEqual(inFlightOpenCount, 1)
        XCTAssertEqual(inFlightStartCount, 0)
        XCTAssertTrue(prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID))

        await gate.release()
        await waitForCommand(type: "start", count: 1, connection: prepared.connection)
        await waitUntil {
            !prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID)
        }
        let finalOpenCount = await openConnection.commandCount()
        let finalStartCount = await prepared.connection.commandCount(type: "start")
        XCTAssertEqual(finalOpenCount, 1)
        XCTAssertEqual(finalStartCount, 1)
    }

    @MainActor
    func testStartRecoveryAdoptedSessionGuardSkipsDuplicateStart() async throws {
        let gate = WorkspaceOpenCommandGate()
        let openConnection = WorkspaceOpenRecordingConnection(outcomes: [.gatedSuccess(gate)])
        let fixture = try await makeFixture(
            store: StubWorkspaceSessionCatalogStore(state: .error("unused")),
            workspaceOpenConnection: openConnection
        )
        let prepared = try await prepareStartRecovery(fixture: fixture)

        fixture.viewModel.recoverRemoteStartByOpeningWorkspace()
        await gate.waitUntilEntered()

        var adoptedBinding = try XCTUnwrap(prepared.session.remoteHost)
        adoptedBinding.remoteSessionID = "adopted-during-open"
        prepared.session.remoteHost = adoptedBinding
        await gate.release()

        await waitUntil {
            !prepared.session.remoteResendInFlightItemIDs.contains(prepared.userItemID)
        }

        let openCount = await openConnection.commandCount()
        let startCount = await prepared.connection.commandCount(type: "start")
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(prepared.session.remoteResendPayloadsByItemID[prepared.userItemID])
        XCTAssertNil(prepared.session.runningStatusText)
        XCTAssertNil(prepared.session.runningStatusSource)
        XCTAssertTrue(prepared.session.pendingRemoteOptimisticUserItemIDs.contains(prepared.userItemID))
        XCTAssertFalse(
            try XCTUnwrap(prepared.session.items.first { $0.id == prepared.userItemID })
                .isUndeliveredRemoteSend
        )
        XCTAssertTrue(prepared.session.items.contains {
            $0.kind == .system && $0.text == "Remote send was already delivered."
        })
    }

    @MainActor
    func testV44PickerRecoveryRetainsOriginalWorkspaceNameWithoutMixingSelectors() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = try await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        var userItem = AgentChatItem.user("Recover workspace name")
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        let option = RemoteStartWindowOption(
            windowID: 40,
            title: "Selected Window",
            workspaceID: "selected-workspace",
            workspaceName: "Project Alpha"
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: userItem.text,
            modelSelectionRaw: nil,
            sessionName: "Recovery",
            workspaceName: "  Project Alpha  ",
            optimisticUserItemID: userItem.id,
            windows: [option]
        )

        fixture.viewModel.cancelRemoteStartWindowPicker()

        let cancelledPayload = try XCTUnwrap(session.remoteResendPayloadsByItemID[userItem.id])
        let cancellationFailureItem = try XCTUnwrap(session.items.last {
            $0.kind == .system || $0.kind == .error
        })
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: cancellationFailureItem.id
        ))
        XCTAssertEqual(cancelledPayload.workspaceName, "Project Alpha")
        XCTAssertNil(cancelledPayload.windowID)
        XCTAssertNil(cancelledPayload.workspaceID)

        let retryPending = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: userItem.text,
            modelSelectionRaw: nil,
            sessionName: "Recovery",
            workspaceName: "Project Alpha",
            optimisticUserItemID: userItem.id,
            windows: [option]
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = retryPending
        let connection = ResendRecordingConnection(startErrors: [Self.pickerError(windowID: 41)])
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(
            binding: remoteHost,
            connection: connection
        )
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.selectRemoteStartWindow(option)
        await waitUntil {
            fixture.viewModel.pendingRemoteStartWindowPicker?.id != retryPending.id
                && fixture.viewModel.pendingRemoteStartWindowPicker != nil
        }

        let targetRetryPayload = try XCTUnwrap(session.remoteResendPayloadsByItemID[userItem.id])
        XCTAssertEqual(targetRetryPayload.workspaceName, "Project Alpha")
        XCTAssertNil(targetRetryPayload.windowID)
        XCTAssertNil(targetRetryPayload.workspaceID)

        // Whitespace-only selectors normalize to nil at construction, so a blank
        // name can never round-trip into a name-shaped-but-unscoped start.
        let blankNamePending = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: "Studio Mac",
            message: userItem.text,
            modelSelectionRaw: nil,
            sessionName: "Recovery",
            workspaceName: "   ",
            optimisticUserItemID: userItem.id,
            windows: [option]
        )
        XCTAssertNil(blankNamePending.workspaceName)
    }

    @MainActor
    private func prepareStartRecovery(
        fixture: Fixture,
        startErrors: [RemoteClientError] = []
    ) async throws -> (
        session: AgentTabSession,
        userItemID: UUID,
        connection: ResendRecordingConnection
    ) {
        let session = try! await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.runState = .waitingForUser

        var userItem = AgentChatItem.user("Recover by opening workspace")
        userItem.isUndeliveredRemoteSend = true
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        session.pendingRemoteOptimisticProviderTextByItemID[userItem.id] = userItem.text
        session.remoteResendInFlightItemIDs.insert(userItem.id)
        session.remoteResendPayloadsByItemID[userItem.id] = .init(
            providerText: userItem.text,
            wasStart: true,
            modelSelectionRaw: "codexExec:gpt-5.4",
            sessionName: "Recovered start",
            workspaceName: "Project Alpha"
        )
        fixture.viewModel.pendingRemoteStartWindowPicker = RemoteStartWindowPickerState(
            tabID: session.tabID,
            hostName: fixture.host.displayName,
            message: userItem.text,
            modelSelectionRaw: "codexExec:gpt-5.4",
            sessionName: "Recovered start",
            workspaceName: "Project Alpha",
            optimisticUserItemID: userItem.id,
            windows: [
                .init(
                    windowID: 2,
                    title: "Other Window",
                    workspaceID: "other-workspace",
                    workspaceName: "Other Workspace"
                )
            ]
        )

        let connection = ResendRecordingConnection(startErrors: startErrors)
        let remoteHost = try XCTUnwrap(session.remoteHost)
        fixture.coordinator.test_installController(
            RemoteAgentSessionController(binding: remoteHost, connection: connection),
            for: session,
            hostID: fixture.host.id
        )
        return (session, userItem.id, connection)
    }

    @MainActor
    private func prepareFailedAdoptedTurn(
        fixture: Fixture,
        text: String
    ) async throws -> (session: AgentTabSession, userItemID: UUID, connection: ResendRecordingConnection) {
        let session = try! await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-abc123")
        session.hasSentFirstMessage = true
        session.runState = .running
        let userItem = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(userItem)
        session.pendingRemoteOptimisticUserItemIDs.insert(userItem.id)
        let connection = ResendRecordingConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        fixture.coordinator.test_installController(controller, for: session, hostID: fixture.host.id)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: userItem.id,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused"),
            resendPayload: .init(
                providerText: text,
                wasStart: false,
                modelSelectionRaw: nil,
                sessionName: nil,
                workspaceName: nil
            )
        )
        return (session, userItem.id, connection)
    }

    private func waitForCommand(
        type: String,
        count: Int,
        connection: ResendRecordingConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 200 {
            if await connection.commandCount(type: type) >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let finalCount = await connection.commandCount(type: type)
        XCTAssertGreaterThanOrEqual(finalCount, count, file: file, line: line)
    }

    @MainActor
    private func makeFixture(
        store: StubWorkspaceSessionCatalogStore,
        workspaceOpenConnection: (any RemoteWorkspaceSessionCatalogConnection)? = nil,
        grantedScopes: Set<String>? = nil,
        catalogProvider: (@MainActor (String) -> RemoteHostAgentCatalog?)? = nil
    ) async throws -> Fixture {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        var host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        if let grantedScopes {
            host.grantedScopes = grantedScopes
        }
        try registry.upsertHost(host)

        let initialTabID = UUID()
        let workspace = WorkspaceModel(
            name: "Project Alpha",
            repoPaths: [FileManager.default.currentDirectoryPath],
            defaultRemoteHostID: host.id,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: initialTabID, name: "Initial")],
            activeComposeTabID: initialTabID
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
        apiSettings.isCodexConnected = true
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

        let coordinator = RemoteAgentModeCoordinator(
            catalogProvider: { hostID in
                catalogProvider?(hostID) ?? RemoteHostCatalog.shared.cachedNonDegradedCatalog(for: hostID)
            },
            hostRecordProvider: { hostID in
                hostID == host.id ? host : nil
            },
            workspaceSessionCatalogStore: store,
            workspaceOpenConnectionProvider: workspaceOpenConnection.map { connection in
                { _ in connection }
            }
        )
        let lifecycleRecorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: lifecycleRecorder)
            },
            remoteHostRegistry: registry,
            testRemoteCoordinator: coordinator
        )
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: prompt,
            workspaceManager: workspaceManager
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        viewModel.test_setCurrentTabIDOverride(initialTabID)

        return Fixture(
            viewModel: viewModel,
            coordinator: coordinator,
            prompt: prompt,
            workspaceManager: workspaceManager,
            workspace: workspace,
            host: host,
            initialTabID: initialTabID,
            lifecycleRecorder: lifecycleRecorder
        )
    }

    private static func pickerError(windowID: Int) -> RemoteClientError {
        RemoteClientError.fromCommandError(
            code: "ambiguous_start_target",
            message: "Choose a window.",
            details: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(windowID),
                        "title": .string("Window \(windowID)"),
                        "workspace_id": .string("workspace-\(windowID)"),
                        "workspace_name": .string("Project Alpha")
                    ])
                ])
            ])
        )
    }

    private func descriptor(
        id: String,
        name: String,
        modified: TimeInterval
    ) -> RemoteAgentSessionDescriptor {
        RemoteAgentSessionDescriptor(
            sessionID: id,
            name: name,
            stateRaw: "running",
            agentKindRaw: AgentProviderKind.codexExec.rawValue,
            agentModelRaw: "gpt-5.4",
            parentSessionID: nil,
            lastModified: Date(timeIntervalSinceReferenceDate: modified),
            itemCount: 3,
            originSummary: "user",
            isLive: true
        )
    }

    private func binding(
        host: PairedHostRecord,
        remoteSessionID: String
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: host.id,
            hostDisplayName: host.displayName,
            remoteSessionID: remoteSessionID
        )
    }

    @MainActor
    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition", file: file, line: line)
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let coordinator: RemoteAgentModeCoordinator
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let host: PairedHostRecord
        let initialTabID: UUID
        let lifecycleRecorder: LifecycleRecorder
    }
}

@MainActor
private final class StubWorkspaceSessionCatalogStore: RemoteWorkspaceSessionCatalogStoring {
    var state: RemoteWorkspaceSessionCatalogStore.State
    var stateAfterHostInvalidation: RemoteWorkspaceSessionCatalogStore.State?
    var learnedWorkspaceID: String?
    private(set) var invalidatedWorkspaceIDs: [UUID] = []
    private(set) var invalidatedHostIDs: [String] = []
    private(set) var fetchForceRefreshValues: [Bool] = []
    private(set) var operationLog: [String] = []

    init(state: RemoteWorkspaceSessionCatalogStore.State) {
        self.state = state
    }

    func cachedState(
        hostID _: String,
        clientWorkspaceID _: UUID
    ) -> RemoteWorkspaceSessionCatalogStore.State? {
        state
    }

    func fetch(
        hostID _: String,
        clientWorkspaceID _: UUID,
        workspaceName _: String,
        forceRefresh: Bool
    ) async -> RemoteWorkspaceSessionCatalogStore.State {
        operationLog.append("fetch:\(forceRefresh)")
        fetchForceRefreshValues.append(forceRefresh)
        return state
    }

    func invalidate(hostID _: String, clientWorkspaceID: UUID) {
        operationLog.append("invalidate-workspace")
        invalidatedWorkspaceIDs.append(clientWorkspaceID)
    }

    func invalidate(hostID: String) {
        operationLog.append("invalidate-host")
        invalidatedHostIDs.append(hostID)
        if let stateAfterHostInvalidation {
            state = stateAfterHostInvalidation
        }
    }

    func learnedHostWorkspaceID(hostID _: String, clientWorkspaceID _: UUID) -> String? {
        learnedWorkspaceID
    }
}

private enum WorkspacePickupTestError: Error {
    case attachFailed
}

private actor WorkspaceOpenCommandGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func enterAndWait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor WorkspaceOpenRecordingConnection: RemoteWorkspaceSessionCatalogConnection {
    enum Outcome {
        case success
        case failure(RemoteClientError)
        case gatedSuccess(WorkspaceOpenCommandGate)
    }

    private var outcomes: [Outcome]
    private var recordedFrames: [RemoteClientFrame] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        recordedFrames.append(frame)
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            return .object(["status": .string("opened"), "window_id": .int(7)])
        case let .failure(error):
            throw error
        case let .gatedSuccess(gate):
            await gate.enterAndWait()
            return .object(["status": .string("opened"), "window_id": .int(7)])
        }
    }

    func commandCount() -> Int {
        recordedFrames.count
    }

    func frames() -> [RemoteClientFrame] {
        recordedFrames
    }
}

private actor HandoffRecordingConnection: RemoteAgentSessionConnection {
    private let sourceSessionID: String
    private let hostRowID: UUID
    private let destinationSessionID: String
    private let advertisedFeatures: Set<String>
    private var recordedFrames: [RemoteClientFrame] = []
    private var subscribedSessionIDBatches: [[String]] = []

    init(
        sourceSessionID: String,
        hostRowID: UUID,
        destinationSessionID: String,
        advertisedFeatures: Set<String>
    ) {
        self.sourceSessionID = sourceSessionID
        self.hostRowID = hostRowID
        self.destinationSessionID = destinationSessionID
        self.advertisedFeatures = advertisedFeatures
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        recordedFrames.append(frame)
        switch frame.type {
        case "poll":
            return .object([
                "status": .string("completed"),
                "session_id": .string(frame.sessionID ?? sourceSessionID)
            ])
        case "get_log":
            return Self.logPayload(sourceSessionID: sourceSessionID, hostRowID: hostRowID)
        case "fork_session":
            return .object([
                "status": .string("forked"),
                "session": .object([
                    "session_id": .string(destinationSessionID),
                    "name": .string("Forked on host"),
                    "raw_state": .string("completed"),
                    "agent": .object([
                        "id": .string(AgentProviderKind.codexExec.rawValue),
                        "model": .string("gpt-5.4")
                    ]),
                    "item_count": .int(0),
                    "origin": .string("user"),
                    "is_live": .bool(true)
                ])
            ])
        case "extract_handoff":
            return .object([
                "status": .string("ok"),
                "handoff_xml": .string("<forked_session/>")
            ])
        default:
            return .object([:])
        }
    }

    func ensureConnected() async throws {}

    func subscribe(sessionIDs: [String]) async throws {
        subscribedSessionIDBatches.append(sessionIDs)
    }

    func unsubscribe(sessionIDs _: [String]) async throws {}

    func supportsHostFeature(_ feature: String) -> Bool {
        advertisedFeatures.contains(feature)
    }

    func subscribeBatches() -> [[String]] {
        subscribedSessionIDBatches
    }

    func frames(type: String) -> [RemoteClientFrame] {
        recordedFrames.filter { $0.type == type }
    }

    nonisolated static func logPayload(sourceSessionID _: String, hostRowID: UUID) -> JSONValue {
        .object([
            "turn_offset": .int(0),
            "turn_limit": .int(20),
            "returned_turn_count": .int(1),
            "total_turns": .int(1),
            "completed_turn_count": .int(1),
            "transcript_xml": .string(
                "<user id=\"00000000-0000-0000-0000-000000000001\">Prompt</user>" +
                    "<assistant id=\"\(hostRowID.uuidString)\">Completed reply</assistant>"
            )
        ])
    }
}

private actor ResendRecordingConnection: RemoteAgentSessionConnection {
    private var recordedFrames: [RemoteClientFrame] = []
    private var successfulDeliveries = 0
    private let failingCommandTypes: Set<String>
    private var startErrors: [RemoteClientError]

    init(
        failingCommandTypes: Set<String> = [],
        startErrors: [RemoteClientError] = []
    ) {
        self.failingCommandTypes = failingCommandTypes
        self.startErrors = startErrors
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        recordedFrames.append(frame)
        if frame.type == "start", !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        if failingCommandTypes.contains(frame.type) {
            throw RemoteClientError.protocolViolation("synthetic delivery failure")
        }
        if frame.type == "start" || frame.type == "steer" {
            successfulDeliveries += 1
        }
        switch frame.type {
        case "start":
            return .object([
                "status": .string("running"),
                "session_id": .string("remote-started-by-resend")
            ])
        case "get_log":
            return .object([
                "turn_offset": .int(0),
                "turn_limit": .int(20),
                "returned_turn_count": .int(0),
                "total_turns": .int(0),
                "transcript_xml": .string("<transcript/>")
            ])
        default:
            return .object(["status": .string("running")])
        }
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func commandCount(type: String) -> Int {
        recordedFrames.count { $0.type == type }
    }

    func frames(type: String) -> [RemoteClientFrame] {
        recordedFrames.filter { $0.type == type }
    }

    func successfulDeliveryCount() -> Int {
        successfulDeliveries
    }
}

private actor BlockingFailingResendConnection: RemoteAgentSessionConnection {
    private var recordedFrames: [RemoteClientFrame] = []
    private var commandContinuation: CheckedContinuation<Void, Never>?
    private var commandStartedContinuation: CheckedContinuation<Void, Never>?
    private var commandStarted = false
    private var failureReleased = false

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        recordedFrames.append(frame)
        commandStarted = true
        commandStartedContinuation?.resume()
        commandStartedContinuation = nil
        if !failureReleased {
            await withCheckedContinuation { continuation in
                commandContinuation = continuation
            }
        }
        throw RemoteClientError.transport("synthetic mid-flight failure")
    }

    func waitUntilCommandStarted() async {
        guard !commandStarted else { return }
        await withCheckedContinuation { continuation in
            commandStartedContinuation = continuation
        }
    }

    func releaseFailure() {
        failureReleased = true
        commandContinuation?.resume()
        commandContinuation = nil
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}
}
