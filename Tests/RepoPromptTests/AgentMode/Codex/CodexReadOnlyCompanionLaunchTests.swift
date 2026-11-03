import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Plan §6 D3 Codex row: the opt-in read-only companion's launch side. The native default adds no
/// config; an enabled controller mints one credential per transport launch, registers only its
/// digest, carries the same companion entry to `thread/start` and `thread/resume`, and clears its
/// own grant on failure and shutdown. A preference change reconnects on the next send and resumes
/// the same thread. Credentials are compared without ever entering a failure message.
final class CodexReadOnlyCompanionLaunchTests: XCTestCase {
    private static let companionName = MCPCodeModeEligibility.codexReadOnlyCompanionServerName
    private static let entryKey = "mcp_servers.\(companionName)"
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Config merge

    func testMergeAddsOneCredentialedEntryAndReplacesOnlyThatServersKeys() throws {
        let server = RepoPromptMCPServerConfiguration.repoPrompt
        let key = MCPBootstrapCompanionCredential.environmentKey
        let credential = "fixture-companion-credential"
        let base: [String: Any] = [
            "mcp_servers.RepoPromptCE.enabled": true,
            "\(Self.entryKey).enabled": false,
            "\(Self.entryKey).env.STALE": "stale",
            "\(Self.entryKey)Other.enabled": true,
            "features.goals": false
        ]

        let merged = CodexOverrides.mergingReadOnlyCompanionServer(
            into: base,
            serverName: Self.companionName,
            server: server,
            credentialEnvironmentKey: key,
            credential: credential
        )

        XCTAssertNil(merged["\(Self.entryKey).enabled"])
        XCTAssertNil(merged["\(Self.entryKey).env.STALE"])
        XCTAssertEqual(merged["mcp_servers.RepoPromptCE.enabled"] as? Bool, true, "The primary entry is untouched")
        XCTAssertEqual(merged["\(Self.entryKey)Other.enabled"] as? Bool, true, "A prefix-sharing server is untouched")
        XCTAssertEqual(merged["features.goals"] as? Bool, false)
        let entry = try XCTUnwrap(merged[Self.entryKey] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, server.command)
        XCTAssertEqual(entry["args"] as? [String], server.args)
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(
            entry["tool_timeout_sec"] as? Int,
            MCPTimeoutPolicy.codexServerActiveTimeoutSeconds,
            "The companion keeps the primary entry's per-server tool timeout, never Codex's default"
        )
        XCTAssertEqual(entry["supports_parallel_tool_calls"] as? Bool, true)
        let environment = try XCTUnwrap(entry["env"] as? [String: String])
        XCTAssertTrue(environment[key] == credential, "The companion entry carries its credential")
        for (name, value) in server.environmentDictionary {
            XCTAssertEqual(environment[name], value, name)
        }

        for (label, name, value) in [("no credential", Self.companionName, nil), ("empty credential", Self.companionName, ""), ("no name", "", credential)] as [(String, String, String?)] {
            let unchanged = CodexOverrides.mergingReadOnlyCompanionServer(
                into: base,
                serverName: name,
                server: server,
                credentialEnvironmentKey: key,
                credential: value
            )
            XCTAssertEqual(Set(unchanged.keys), Set(base.keys), label)
            XCTAssertNil(unchanged[Self.entryKey], label)
        }
    }

    func testCredentialMintIsDistinctAndOnlyItsDigestIsShared() {
        let first = MCPBootstrapCompanionCredential.mint()
        let second = MCPBootstrapCompanionCredential.mint()
        XCTAssertFalse(first == second, "Each launch mints a distinct credential")
        XCTAssertGreaterThanOrEqual(first.count, 43, "256 bits, base64url")
        let digest = MCPBootstrapCompanionCredential.digest(of: first)
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(digest.contains(first), "The digest never embeds the credential")
        XCTAssertEqual(digest, MCPBootstrapCompanionCredential.digest(of: " \(first)\n"))
        XCTAssertTrue(
            MCPBootstrapCompanionCredential.credential(from: [MCPBootstrapCompanionCredential.environmentKey: " \(first) "]) == first
        )
        XCTAssertNil(MCPBootstrapCompanionCredential.credential(from: [MCPBootstrapCompanionCredential.environmentKey: "  "]))
        XCTAssertNil(MCPBootstrapCompanionCredential.credential(from: [:]))
    }

    // MARK: - Eligibility gate

    @MainActor
    func testGateAndLeaseEligibilityKeepKnowledgeAndMCPSafeSessionsNative() {
        XCTAssertTrue(CodexAgentModeCoordinator.codexReadOnlyCompanionAllowed(sessionProfile: .standard, permissionProfile: .userConfigured))
        XCTAssertFalse(CodexAgentModeCoordinator.codexReadOnlyCompanionAllowed(sessionProfile: .knowledge, permissionProfile: .userConfigured))
        XCTAssertFalse(CodexAgentModeCoordinator.codexReadOnlyCompanionAllowed(sessionProfile: .standard, permissionProfile: .mcpSafeDefaults))

        XCTAssertEqual(CodexAgentModeCoordinator.codexCodeModeEligibility(companionServerName: nil), .native)
        let companion = CodexAgentModeCoordinator.codexCodeModeEligibility(companionServerName: Self.companionName)
        XCTAssertEqual(companion, .codexReadOnlyCompanion(serverName: Self.companionName))
        for profile in [AgentSessionProfile.standard, .knowledge] {
            let spec = MCPBootstrapLeaseSpec.agentMode(
                tabID: UUID(),
                runID: UUID(),
                gateID: UUID(),
                windowID: 1,
                agent: .codexExec,
                sessionProfile: profile,
                codeModeEligibility: companion
            )
            XCTAssertEqual(spec.codeModeEligibility, profile == .standard ? companion : .native, "\(profile)")
            XCTAssertEqual(spec.clientName, AgentProviderKind.codexExec.mcpClientNameHint, "The primary policy keeps its client name")
        }
    }

    // MARK: - Controller launch

    func testNativeLaunchAddsNoCompanionEntryKeyOrCredential() async throws {
        let options = Self.options(readOnlyCompanion: nil)
        let (controller, recordURL) = try await makeController(options: options)
        XCTAssertNil(controller.readOnlyCompanionServerName)
        _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        await controller.shutdown()

        let config = try XCTUnwrap(recordedParams(for: "thread/start", at: recordURL)["config"] as? [String: Any])
        XCTAssertFalse(config.keys.contains { $0 == Self.entryKey || $0.hasPrefix(Self.entryKey + ".") }, "\(config.keys.sorted())")
        XCTAssertNil(config[CodexOverrides.directOnlyToolNamespacesKey])
        let serialized = try String(decoding: JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        XCTAssertFalse(serialized.contains(MCPBootstrapCompanionCredential.environmentKey))
        XCTAssertFalse(try recordedProcessArguments(at: recordURL).contains { $0.contains(MCPBootstrapCompanionCredential.environmentKey) })
    }

    func testCompanionLaunchRegistersOneGrantPerTransportAndCarriesTheSameEntryToStartAndResume() async throws {
        let grants = CompanionGrantRecorder()
        let startRunID = UUID()
        let (startController, startRecordURL) = try await makeController(
            options: Self.options(readOnlyCompanion: grants.launch()),
            runID: startRunID
        )
        XCTAssertEqual(startController.readOnlyCompanionServerName, Self.companionName)
        _ = try await startController.startOrResume(existing: nil, baseInstructions: "Agent")
        let startConfig = try XCTUnwrap(recordedParams(for: "thread/start", at: startRecordURL)["config"] as? [String: Any])
        let startEntry = try Self.companionEntry(in: startConfig)
        let startCredential = try Self.credential(in: startEntry)
        let startDigest = MCPBootstrapCompanionCredential.digest(of: startCredential)
        var registered = await grants.registered
        XCTAssertEqual(registered.map(\.runID), [startRunID], "One grant for the transport launch")
        XCTAssertEqual(registered.map(\.digest), [startDigest], "Only the digest crosses to the host")
        XCTAssertEqual(
            startConfig[CodexOverrides.directOnlyToolNamespacesKey] as? [String],
            ["mcp__RepoPromptCE_Direct"],
            "Only the companion namespace is direct-only"
        )
        XCTAssertNil(startConfig["\(Self.entryKey).enabled"])
        XCTAssertFalse(
            try recordedProcessArguments(at: startRecordURL).contains { $0.contains(MCPBootstrapCompanionCredential.environmentKey) },
            "The credential never reaches process arguments"
        )
        let clearedBeforeShutdown = await grants.cleared
        XCTAssertTrue(clearedBeforeShutdown.isEmpty, "A live launch keeps its grant")

        await startController.shutdown()
        var cleared = await grants.cleared
        XCTAssertEqual(cleared.map(\.runID), [startRunID])
        XCTAssertEqual(cleared.map(\.digest), [startDigest], "Shutdown clears only its own grant")

        // A reconnect is a new controller and transport: a fresh credential, the same entry shape.
        let resumeRunID = UUID()
        let (resumeController, resumeRecordURL) = try await makeController(
            options: Self.options(readOnlyCompanion: grants.launch()),
            runID: resumeRunID
        )
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "fresh-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
        _ = try await resumeController.startOrResume(existing: existing, baseInstructions: "Agent")
        let resumeParams = try recordedParams(for: "thread/resume", at: resumeRecordURL)
        XCTAssertEqual(resumeParams["threadId"] as? String, "fresh-thread", "The same thread resumes")
        let resumeConfig = try XCTUnwrap(resumeParams["config"] as? [String: Any])
        let resumeEntry = try Self.companionEntry(in: resumeConfig)
        let resumeCredential = try Self.credential(in: resumeEntry)
        XCTAssertFalse(resumeCredential == startCredential, "A new transport never reuses the old credential")
        XCTAssertEqual(resumeEntry["command"] as? String, startEntry["command"] as? String)
        XCTAssertEqual(resumeEntry["args"] as? [String], startEntry["args"] as? [String])
        XCTAssertEqual(resumeEntry["enabled"] as? Bool, true)
        XCTAssertEqual(
            try XCTUnwrap(resumeEntry["env"] as? [String: String]).keys.sorted(),
            try XCTUnwrap(startEntry["env"] as? [String: String]).keys.sorted()
        )
        XCTAssertEqual(
            resumeConfig[CodexOverrides.directOnlyToolNamespacesKey] as? [String],
            startConfig[CodexOverrides.directOnlyToolNamespacesKey] as? [String]
        )
        let resumeDigest = MCPBootstrapCompanionCredential.digest(of: resumeCredential)
        registered = await grants.registered
        XCTAssertEqual(registered.map(\.digest), [startDigest, resumeDigest])
        XCTAssertEqual(registered.map(\.runID), [startRunID, resumeRunID])

        await resumeController.shutdown()
        cleared = await grants.cleared
        XCTAssertEqual(cleared.map(\.digest), [startDigest, resumeDigest])
    }

    func testFailedStartClearsItsGrantAndARetryMintsAFreshCredential() async throws {
        let grants = CompanionGrantRecorder()
        let runID = UUID()
        let (controller, _) = try await makeController(
            options: Self.options(readOnlyCompanion: grants.launch()),
            runID: runID,
            failThreadStart: true
        )
        for _ in 0 ..< 2 {
            do {
                _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
                XCTFail("The fixture app-server rejects thread/start")
            } catch {}
        }
        let registered = await grants.registered
        let cleared = await grants.cleared
        XCTAssertEqual(registered.count, 2)
        XCTAssertEqual(Set(registered.map(\.digest)).count, 2, "A retry never reuses a cleared credential")
        XCTAssertEqual(cleared.map(\.digest), registered.map { Optional($0.digest) }, "Each failed attempt clears its own grant")
        XCTAssertEqual(Set(cleared.map(\.runID)), [runID])

        await controller.shutdown()
        let clearedAfterShutdown = await grants.cleared
        XCTAssertEqual(clearedAfterShutdown.count, 2, "Nothing is left to clear")
    }

    func testShutdownDuringAPendingGrantRegistrationLeavesNoGrantAndSendsNoThreadRequest() async throws {
        let grants = CompanionGrantRecorder()
        await grants.holdTheNextRegistration()
        let runID = UUID()
        let (controller, recordURL) = try await makeController(
            options: Self.options(readOnlyCompanion: grants.launch()),
            runID: runID
        )
        let start = Task { try await controller.startOrResume(existing: nil, baseInstructions: "Agent") }
        try await AsyncTestWait.waitUntil("grant registration in flight", timeout: 15) {
            await grants.heldRegistrationEntered
        }

        // Shutdown settles while the registration is still suspended (no await deadlock): it owns
        // the published pending credential and clears its digest before the grant even lands.
        await controller.shutdown()
        let clearedByShutdown = await grants.cleared
        XCTAssertEqual(clearedByShutdown.map(\.runID), [runID])

        // The registration lands after shutdown: the controller clears that exact digest and
        // aborts the start before any thread request.
        await grants.releaseHeldRegistration()
        do {
            _ = try await start.value
            XCTFail("A start interrupted by shutdown never binds a thread")
        } catch {}
        let registered = await grants.registered
        let cleared = await grants.cleared
        let live = await grants.live
        XCTAssertEqual(registered.count, 1)
        XCTAssertNil(live[runID], "No grant outlives shutdown")
        XCTAssertTrue(cleared.allSatisfy { $0.digest == registered.first?.digest }, "Only its own digest is cleared")
        let threadRequests = try recordedRequests(at: recordURL).compactMap { $0["method"] as? String }
            .filter { $0 == "thread/start" || $0 == "thread/resume" }
        XCTAssertTrue(threadRequests.isEmpty, "\(threadRequests)")
    }

    // MARK: - Coordinator: next-send preference and second send

    @MainActor
    func testSecondSendKeepsTheControllerAndATogglePlusResumeSameThreadInBothDirections() async {
        let recorder = LifecycleRecorder()
        let preference = CompanionPreferenceBox()
        var created: [LifecycleNoopCodexController] = []
        let host = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                XCTFail("The companion-aware factory is used")
                return LifecycleNoopCodexController(recorder: recorder)
            },
            codexControllerFactoryWithComputerUse: { _, _, _, _, permissionProfile, sessionProfile, _, _ in
                let controller = LifecycleNoopCodexController(recorder: recorder, startedConversationID: "companion-thread")
                // Production Agent Mode controllers are runtime-registered (R6): a toggle's replaced
                // controller's shutdown is retained and joined before the successor starts.
                controller.joinsRetirementBeforeSuccessor = true
                // Mirrors the production factory: the same gate and preference, read at creation.
                if CodexAgentModeCoordinator.codexReadOnlyCompanionAllowed(
                    sessionProfile: sessionProfile,
                    permissionProfile: permissionProfile
                ), preference.enabled {
                    controller.readOnlyCompanionServerName = Self.companionName
                }
                created.append(controller)
                return controller
            },
            testCodexReadOnlyCompanionEnabled: { preference.enabled }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec

        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created[0].readOnlyCompanionServerName, "Native by default")
        XCTAssertEqual(session.codexControllerFeatureState?.readOnlyCompanionEnabled, false)
        XCTAssertEqual(session.codexConversationID, "companion-thread")

        // Second send on the same thread: no reconnect, no new transport, no new grant.
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].startReferences.count, 1)

        // Enabling applies from the next send: reconnect and resume the same thread.
        preference.enabled = true
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].readOnlyCompanionServerName, Self.companionName)
        XCTAssertEqual(created[1].startReferences.first??.conversationID, "companion-thread")
        XCTAssertEqual(session.codexControllerFeatureState?.readOnlyCompanionEnabled, true)
        XCTAssertTrue(recorder.events.contains("codex:shutdown"), "The native controller is shut down")

        // Second send with the companion: the same controller (and grant) stays.
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].startReferences.count, 1)

        // Disabling reconnects back to native on the same thread.
        preference.enabled = false
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, 3)
        XCTAssertNil(created[2].readOnlyCompanionServerName)
        XCTAssertEqual(created[2].startReferences.first??.conversationID, "companion-thread")
        XCTAssertEqual(session.codexControllerFeatureState?.readOnlyCompanionEnabled, false)

        // MCP-safe sessions stay native even when the preference is on, without reconnect churn.
        preference.enabled = true
        session.permissionProfile = .mcpSafeDefaults
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        let mcpSafeCount = created.count
        XCTAssertNil(created.last?.readOnlyCompanionServerName)
        await host.test_codexCoordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(created.count, mcpSafeCount, "A matching native launch never reconnects again")

        await host.prepareForWindowClose()
    }

    // MARK: - Coordinator: managed MCP policy lifecycle

    #if DEBUG
        /// Managed Codex tooling (the production policy path): the first send installs one run policy
        /// whose eligibility is `.codexReadOnlyCompanion` exactly when the controller launched the
        /// companion; the lease routes and its ordinary release keeps that policy. Production installer
        /// and lease, fake controller; the route is a stand-in `registerRunIDMapping`, not a primary
        /// connection initializing. A warm second send
        /// reuses the same controller, run ID and installed policy without reinstalling. A toggle (both
        /// directions) or a lost primary route starts a new controller and run whose policy carries
        /// the matching eligibility, resuming the same thread.
        @MainActor
        func testManagedSendsInstallOnePolicyPerTransportStartWithTheLaunchedEligibility() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let mcpServer = fixture.contextA.window.mcpServer
                let windowID = fixture.contextA.window.windowID
                let policies = ManagedPolicyRecorder()
                let recorder = LifecycleRecorder()
                let preference = CompanionPreferenceBox()
                preference.enabled = true
                var created: [LifecycleNoopCodexController] = []
                let host = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: FileManager.default.currentDirectoryPath,
                    shouldManageCodexTooling: true,
                    codexControllerFactory: { _, _, _, _, _, _ in
                        XCTFail("The companion-aware factory is used")
                        return LifecycleNoopCodexController(recorder: recorder)
                    },
                    codexControllerFactoryWithComputerUse: { _, _, _, _, permissionProfile, sessionProfile, _, _ in
                        let controller = LifecycleNoopCodexController(recorder: recorder, startedConversationID: "managed-thread")
                        if CodexAgentModeCoordinator.codexReadOnlyCompanionAllowed(
                            sessionProfile: sessionProfile,
                            permissionProfile: permissionProfile
                        ), preference.enabled {
                            controller.readOnlyCompanionServerName = Self.companionName
                        }
                        created.append(controller)
                        return controller
                    },
                    connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, allowedToolsOverride, sessionProfile, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID, codeModeEligibility in
                        // The production install (so the lease's expected-PID armer finds its pending
                        // policy), then a stand-in primary initializing routes the run.
                        await ServerNetworkManager.shared.installClientConnectionPolicy(
                            for: clientName,
                            windowID: windowID,
                            restrictedTools: restrictedTools,
                            oneShot: oneShot,
                            reason: reason,
                            ttl: ttl,
                            tabID: tabID,
                            runID: runID,
                            additionalTools: additionalTools,
                            allowedToolsOverride: allowedToolsOverride,
                            sessionProfile: sessionProfile,
                            purpose: purpose,
                            taskLabelKind: taskLabelKind,
                            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                            requiresExpectedAgentPID: requiresExpectedAgentPID,
                            codeModeEligibility: codeModeEligibility
                        )
                        await policies.install(
                            clientName: clientName,
                            runID: runID,
                            eligibility: codeModeEligibility,
                            windowID: windowID,
                            mcpServer: mcpServer
                        )
                    },
                    mcpRunRoutingCleaner: { runID, _, reason in
                        await policies.recordRoutingCleanup(runID: runID, reason: reason)
                    },
                    testMCPServer: mcpServer,
                    testCodexLeaseRoutingTimeoutMs: 5000,
                    testCodexReadOnlyCompanionEnabled: { preference.enabled }
                )
                let session = AgentTabSession(tabID: UUID())
                session.selectedAgent = .codexExec
                let companion = MCPCodeModeEligibility.codexReadOnlyCompanion(serverName: Self.companionName)

                // First send: one transport start, one policy with the companion eligibility.
                await host.test_codexCoordinator.ensureCodexNativeSession(session: session, semanticRunState: .running)
                let firstRunID = try XCTUnwrap(session.runID)
                XCTAssertEqual(created.count, 1)
                XCTAssertEqual(created.last?.readOnlyCompanionServerName, Self.companionName)
                XCTAssertEqual(policies.installs.map(\.runID), [firstRunID])
                XCTAssertEqual(policies.installs.map(\.eligibility), [companion])
                XCTAssertTrue(mcpServer.hasLiveRunID(firstRunID), "The lease routed the primary")
                XCTAssertTrue(policies.routingCleanups.isEmpty, "Ordinary lease release never cleans run routing or policy")

                // Turn ends; warm second send on the same thread: same controller, run and policy.
                await host.test_codexCoordinator.ensureCodexNativeSession(session: session, semanticRunState: .running)
                XCTAssertEqual(created.count, 1)
                XCTAssertEqual(created[0].startReferences.count, 1)
                XCTAssertEqual(session.runID, firstRunID)
                XCTAssertEqual(policies.installs.count, 1, "A warm send never reinstalls the policy")

                // Toggle off: next send reconnects natively under a new run, same thread.
                preference.enabled = false
                await host.test_codexCoordinator.ensureCodexNativeSession(session: session, semanticRunState: .running)
                let nativeRunID = try XCTUnwrap(session.runID)
                XCTAssertNotEqual(nativeRunID, firstRunID)
                XCTAssertEqual(created.count, 2)
                XCTAssertNil(created[1].readOnlyCompanionServerName)
                XCTAssertEqual(created[1].startReferences.first??.conversationID, "managed-thread")
                XCTAssertEqual(policies.installs.map(\.runID), [firstRunID, nativeRunID])
                XCTAssertEqual(policies.installs.last?.eligibility, .native)

                // Toggle on: the companion eligibility returns with the new launch.
                preference.enabled = true
                await host.test_codexCoordinator.ensureCodexNativeSession(session: session, semanticRunState: .running)
                let companionRunID = try XCTUnwrap(session.runID)
                XCTAssertEqual(created.count, 3)
                XCTAssertEqual(created[2].readOnlyCompanionServerName, Self.companionName)
                XCTAssertEqual(policies.installs.last?.runID, companionRunID)
                XCTAssertEqual(policies.installs.last?.eligibility, companion)

                // A lost primary route forces a new controller (and grant) on the next send.
                policies.dropRoute(runID: companionRunID, mcpServer: mcpServer)
                await host.test_codexCoordinator.ensureCodexNativeSession(session: session, semanticRunState: .running)
                let recoveredRunID = try XCTUnwrap(session.runID)
                XCTAssertNotEqual(recoveredRunID, companionRunID)
                XCTAssertEqual(created.count, 4)
                XCTAssertEqual(created[3].readOnlyCompanionServerName, Self.companionName)
                XCTAssertEqual(created[3].startReferences.first??.conversationID, "managed-thread")
                XCTAssertEqual(policies.installs.last?.runID, recoveredRunID)
                XCTAssertEqual(policies.installs.last?.eligibility, companion)

                await host.prepareForWindowClose()
                policies.dropAllRoutes(mcpServer: mcpServer)
                for install in policies.installs {
                    await ServerNetworkManager.shared.clearClientConnectionPolicy(
                        for: install.clientName,
                        windowID: windowID,
                        runID: install.runID
                    )
                    // The routing cleaner is overridden above, so clear each installed run's shared
                    // run-policy state here; the shared manager keeps none of this test's runs.
                    if let runID = install.runID {
                        await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowID)
                        let leftover = await ServerNetworkManager.shared.hasCachedRunPolicyState(for: runID)
                        XCTAssertFalse(leftover, "No shared run policy outlives the test")
                    }
                }
                await fixture.cleanup()
            }
        }
    #endif

    // MARK: - Helpers

    private static func options(
        readOnlyCompanion: CodexNativeSessionController.ReadOnlyCompanionLaunch?
    ) -> CodexNativeSessionController.Options {
        .agentModeDefault(
            forceExperimentalSteering: false,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            goalSupportEnabledProvider: { false },
            readOnlyCompanion: readOnlyCompanion
        )
    }

    private static func companionEntry(in config: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(config[entryKey] as? [String: Any], "missing companion entry; keys: \(config.keys.sorted())")
    }

    /// Returns the entry's credential without letting it reach a failure message.
    private static func credential(in entry: [String: Any]) throws -> String {
        let environment = try XCTUnwrap(entry["env"] as? [String: String], "missing companion env")
        guard let credential = environment[MCPBootstrapCompanionCredential.environmentKey], !credential.isEmpty else {
            XCTFail("missing companion credential")
            throw CompanionLaunchTestError.missingCredential
        }
        return credential
    }

    private func makeController(
        options: CodexNativeSessionController.Options,
        runID: UUID = UUID(),
        failThreadStart: Bool = false
    ) async throws -> (CodexNativeSessionController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReadOnlyCompanionLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL, failThreadStart: failThreadStart)
        let client = CodexAppServerClient(mcpHost: ServerNetworkManager.shared)
        await client.updateConfig(
            CodexAppServerClient.Config(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                workingDirectory: directory.path
            )
        )
        let controller = CodexNativeSessionController(
            client: client,
            runID: runID,
            tabID: UUID(),
            windowID: 0,
            workspacePath: directory.path,
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        return (controller, recordURL)
    }

    private func makeFakeCodexAppServer(in directory: URL, recordURL: URL, failThreadStart: Bool) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import sys

        record_path = \(String(reflecting: recordURL.path))
        fail_thread_start = \(failThreadStart ? "True" : "False")

        with open(record_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"method": "__process_args", "argv": sys.argv[1:]}) + "\\n")

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\\n")
            if "id" not in request:
                continue
            if method == "thread/start" and fail_thread_start:
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32000, "message": "fixture start failure"}}), flush=True)
            elif method == "thread/start":
                respond(request["id"], {"thread": {"id": "fresh-thread", "status": "idle", "turns": []}})
            elif method == "thread/resume":
                respond(request["id"], {"thread": {"id": params.get("threadId", "resumed-thread"), "status": "idle", "turns": []}})
            else:
                respond(request["id"], {})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func recordedParams(for method: String, at recordURL: URL) throws -> [String: Any] {
        let request = try XCTUnwrap(recordedRequests(at: recordURL).first { $0["method"] as? String == method }, "No \(method) request")
        return try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func recordedProcessArguments(at recordURL: URL) throws -> [String] {
        let request = try XCTUnwrap(recordedRequests(at: recordURL).first { $0["method"] as? String == "__process_args" })
        return try XCTUnwrap(request["argv"] as? [String])
    }

    private func recordedRequests(at recordURL: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: recordURL, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
}

private enum CompanionLaunchTestError: Error {
    case missingCredential
}

@MainActor
private final class CompanionPreferenceBox {
    var enabled = false
}

/// Records managed Codex policy installs and routes each run to a stand-in primary connection.
@MainActor
private final class ManagedPolicyRecorder {
    struct Install {
        let clientName: String
        let runID: UUID?
        let eligibility: MCPCodeModeEligibility
    }

    private(set) var installs: [Install] = []
    private(set) var routingCleanups: [(runID: UUID, reason: String)] = []
    private var connectionIDByRunID: [UUID: UUID] = [:]

    func install(clientName: String, runID: UUID?, eligibility: MCPCodeModeEligibility, windowID: Int, mcpServer: MCPServerViewModel) {
        installs.append(Install(clientName: clientName, runID: runID, eligibility: eligibility))
        guard let runID else { return }
        let connectionID = UUID()
        connectionIDByRunID[runID] = connectionID
        mcpServer.registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: windowID)
    }

    func recordRoutingCleanup(runID: UUID, reason: String) {
        routingCleanups.append((runID, reason))
    }

    func dropRoute(runID: UUID, mcpServer: MCPServerViewModel) {
        guard let connectionID = connectionIDByRunID.removeValue(forKey: runID) else { return }
        mcpServer.cleanupRunIDMapping(runID: runID, connectionID: connectionID, signalRoutingFailure: false)
    }

    func dropAllRoutes(mcpServer: MCPServerViewModel) {
        for runID in Array(connectionIDByRunID.keys) {
            dropRoute(runID: runID, mcpServer: mcpServer)
        }
    }
}

/// Records grant registration and clearing by digest; never sees a credential.
private actor CompanionGrantRecorder {
    struct Registration {
        let runID: UUID
        let digest: String
    }

    struct Clearing {
        let runID: UUID
        let digest: String?
    }

    private(set) var registered: [Registration] = []
    private(set) var cleared: [Clearing] = []
    /// Host-like grant liveness: registration installs the digest, a digest-matched clear removes it.
    private(set) var live: [UUID: String] = [:]
    private(set) var heldRegistrationEntered = false
    private var holdNextRegistration = false
    private var heldRegistration: CheckedContinuation<Void, Never>?

    /// Suspends the next registration before it lands, until `releaseHeldRegistration()`.
    func holdTheNextRegistration() {
        holdNextRegistration = true
    }

    func releaseHeldRegistration() {
        heldRegistration?.resume()
        heldRegistration = nil
    }

    nonisolated func launch() -> CodexNativeSessionController.ReadOnlyCompanionLaunch {
        CodexNativeSessionController.ReadOnlyCompanionLaunch(
            serverName: MCPCodeModeEligibility.codexReadOnlyCompanionServerName,
            server: .repoPrompt,
            registerGrant: { [self] runID, digest in await recordRegister(runID: runID, digest: digest) },
            clearGrant: { [self] runID, digest in await recordClear(runID: runID, digest: digest) }
        )
    }

    private func recordRegister(runID: UUID, digest: String) async {
        if holdNextRegistration {
            holdNextRegistration = false
            heldRegistrationEntered = true
            await withCheckedContinuation { heldRegistration = $0 }
        }
        registered.append(Registration(runID: runID, digest: digest))
        live[runID] = digest
    }

    private func recordClear(runID: UUID, digest: String?) {
        cleared.append(Clearing(runID: runID, digest: digest))
        if digest == nil || live[runID] == digest {
            live.removeValue(forKey: runID)
        }
    }
}
