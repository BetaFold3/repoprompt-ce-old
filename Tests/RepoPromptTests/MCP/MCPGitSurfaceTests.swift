import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Code-mode readiness D2: `git_review_snapshot` is a fixed-argument diff publication surface
/// that stays available when an Agent Mode run with a native shell hides `git`. Knowledge and
/// discovery surfaces never gain it. Wire-level `tools/list` and `tools/call` evidence lives in
/// `MCPAskOracleWorktreeTests`: the native-shell scenario with structured results off and on, and
/// `testDiscoveryExploreAndKnowledgeLeasesKeepTheReviewSnapshotOffTheirSurfaces`.
@MainActor
final class MCPGitSurfaceTests: XCTestCase {
    // MARK: - Fixed-argument surface

    func testInvocationKindsShareTheImplementationUnderTheirOwnToolNames() {
        XCTAssertEqual(MCPGitToolInvocationKind.full.toolName, MCPWindowToolName.git)
        XCTAssertEqual(MCPGitToolInvocationKind.reviewSnapshot.toolName, MCPWindowToolName.gitReviewSnapshot)
        XCTAssertEqual(MCPWindowToolName.gitReviewSnapshot, "git_review_snapshot")
        XCTAssertEqual(
            MCPGitToolInvocationKind.reviewSnapshotAcceptedArguments,
            [
                "compare", "scope", "mode",
                "repo_root", "repo_roots", "repo_key",
                "path", "paths", "context_lines", "detect_renames"
            ]
        )
    }

    func testReviewSnapshotPinsDiffArtifactsSummaryAndKeepsAcceptedArguments() throws {
        let accepted: [String: Value] = [
            "compare": .string("main"),
            "scope": .string("selected"),
            "mode": .string("deep"),
            "repo_root": .string("@main"),
            "paths": .array([.string("Sources/A.swift")]),
            "context_lines": .int(5),
            "detect_renames": .bool(true)
        ]
        let normalized = try MCPGitToolInvocationKind.reviewSnapshot.normalizedArguments(accepted)
        XCTAssertEqual(normalized["op"], .string("diff"))
        XCTAssertEqual(normalized["artifacts"], .bool(true))
        XCTAssertEqual(normalized["detail"], .string("summary"))
        for (key, value) in accepted {
            XCTAssertEqual(normalized[key], value, key)
        }
        XCTAssertEqual(normalized.count, accepted.count + 3)

        let empty = try MCPGitToolInvocationKind.reviewSnapshot.normalizedArguments([:])
        XCTAssertEqual(
            empty,
            ["op": .string("diff"), "artifacts": .bool(true), "detail": .string("summary")]
        )
    }

    func testReviewSnapshotRejectsEveryArgumentOutsideItsFixedSurface() {
        let forbidden = ["op", "artifacts", "detail", "inline", "ref", "count", "lines", "snapshot_id", "future_option"]
        for key in forbidden {
            XCTAssertThrowsError(
                try MCPGitToolInvocationKind.reviewSnapshot.normalizedArguments([
                    "scope": .string("selected"),
                    key: .string("x")
                ]),
                key
            ) { error in
                guard case let MCPError.invalidParams(message) = error else {
                    return XCTFail("\(key): expected invalidParams, got \(error)")
                }
                XCTAssertTrue(
                    message?.contains("git_review_snapshot does not accept: \(key).") == true,
                    "\(key): \(message ?? "nil")"
                )
            }
        }

        XCTAssertThrowsError(
            try MCPGitToolInvocationKind.reviewSnapshot.normalizedArguments([
                "op": .string("status"),
                "detail": .string("patches")
            ])
        ) { error in
            guard case let MCPError.invalidParams(message) = error else {
                return XCTFail("expected invalidParams, got \(error)")
            }
            XCTAssertTrue(message?.contains("does not accept: detail, op.") == true, message ?? "nil")
        }
    }

    func testFullGitKindPassesArgumentsThroughUnchanged() throws {
        let args: [String: Value] = ["op": .string("log"), "count": .int(3), "inline": .object([:])]
        XCTAssertEqual(try MCPGitToolInvocationKind.full.normalizedArguments(args), args)
    }

    func testWindowCatalogAdvertisesSnapshotWithFixedSchemaAndWritingAnnotations() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let names = tools.map(\.name)
        let gitIndex = try XCTUnwrap(names.firstIndex(of: MCPWindowToolName.git))
        XCTAssertEqual(names[gitIndex + 1], MCPWindowToolName.gitReviewSnapshot)

        let snapshot = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.gitReviewSnapshot })
        let schema = try XCTUnwrap(Value(snapshot.inputSchema).objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(Set(properties.keys), MCPGitToolInvocationKind.reviewSnapshotAcceptedArguments)
        XCTAssertEqual(schema["required"]?.arrayValue ?? [], [])
        // Only the snapshot declares the Git DTO shape; the legacy `git` tool stays schema-less.
        XCTAssertEqual(snapshot.outputSchema, MCPToolOutputSchemas.gitReviewSnapshot)
        // It writes snapshot files and the tab selection, so it is never advertised as read-only.
        XCTAssertEqual(snapshot.annotations.readOnlyHint, false)
        XCTAssertEqual(snapshot.annotations.destructiveHint, false)
        XCTAssertEqual(snapshot.annotations.openWorldHint, false)
        XCTAssertTrue(snapshot.description.contains("ask_oracle"))

        let git = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.git })
        XCTAssertEqual(git.annotations.readOnlyHint, true)
        XCTAssertNil(git.outputSchema)
    }

    // MARK: - Capability, admission, and execution contract

    func testSnapshotHasItsOwnCapabilityAndSharesGitAdmissionAndLifecycleContract() {
        XCTAssertEqual(
            MCPToolCapabilities.capabilities(for: MCPWindowToolName.gitReviewSnapshot),
            [.gitReviewSnapshot]
        )
        XCTAssertEqual(MCPToolCapabilities.toolNames(for: [.gitRead]), [MCPWindowToolName.git])
        XCTAssertEqual(
            MCPToolCapabilities.toolNames(for: [.gitReviewSnapshot]),
            [MCPWindowToolName.gitReviewSnapshot]
        )
        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.gitReviewSnapshot)?.kind,
            .workspaceLifecycleCancellable
        )
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: MCPWindowToolName.gitReviewSnapshot))
        XCTAssertTrue(MCPIntegrationHelper.repoPromptToolNames.contains(MCPWindowToolName.gitReviewSnapshot))
    }

    // MARK: - Lease, Knowledge, and discovery surfaces

    func testNativeShellLeaseHidesOnlyGitAndKeepsReviewSnapshot() {
        func spec(shell: Bool, profile: AgentSessionProfile = .standard) -> MCPBootstrapLeaseSpec {
            MCPBootstrapLeaseSpec.agentMode(
                tabID: UUID(),
                runID: UUID(),
                gateID: UUID(),
                windowID: 1,
                agent: .claudeCode,
                sessionProfile: profile,
                runHasNativeShell: shell
            )
        }

        let withoutShell = spec(shell: false)
        XCTAssertEqual(withoutShell.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
        XCTAssertFalse(withoutShell.restrictedTools.contains(MCPWindowToolName.git))
        XCTAssertFalse(withoutShell.restrictedTools.contains(MCPWindowToolName.gitReviewSnapshot))

        let withShell = spec(shell: true)
        XCTAssertEqual(
            withShell.restrictedTools,
            AgentModeMCPToolPolicy.restrictedTools.union([MCPWindowToolName.git])
        )
        XCTAssertFalse(withShell.restrictedTools.contains(MCPWindowToolName.gitReviewSnapshot))
        XCTAssertNil(withShell.allowedToolsOverride)

        // Knowledge keeps its closed allowlist, which admits neither Git tool.
        for shell in [false, true] {
            let knowledge = spec(shell: shell, profile: .knowledge)
            XCTAssertEqual(knowledge.allowedToolsOverride, AgentModeMCPToolPolicy.knowledgeAllowedTools)
            for tool in [MCPWindowToolName.git, MCPWindowToolName.gitReviewSnapshot] {
                XCTAssertFalse(
                    ServerNetworkManager.isAllowedByPositiveToolCeiling(
                        canonicalToolName: tool,
                        allowedToolsOverride: knowledge.allowedToolsOverride
                    ),
                    "Knowledge must not list or call \(tool)"
                )
                XCTAssertNotNil(
                    ServerNetworkManager.positiveToolCeilingDenialMessage(
                        forCanonicalToolName: tool,
                        allowedToolsOverride: knowledge.allowedToolsOverride
                    ),
                    tool
                )
            }
        }
    }

    func testDiscoveryAndExploreSurfacesNeverGainTheSnapshot() {
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.gitReviewSnapshot))
        XCTAssertFalse(DiscoverMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.git))
        XCTAssertFalse(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.gitReviewSnapshot,
                taskLabelKind: .explore
            )
        )
        XCTAssertTrue(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.git,
                taskLabelKind: .explore
            )
        )
        for role: AgentModelCatalog.TaskLabelKind? in [nil, .engineer, .pair, .design] {
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.gitReviewSnapshot,
                    taskLabelKind: role
                ),
                "\(String(describing: role))"
            )
        }
    }

    // MARK: - Native-shell signal sources

    func testOpenCodeShellSignalFollowsTheRequestedManagedSessionMode() {
        XCTAssertTrue(OpenCodeAgentConfig.sessionModeHasNativeShell(OpenCodeAgentConfig.managedSessionModeID))
        XCTAssertTrue(OpenCodeAgentConfig.sessionModeHasNativeShell(OpenCodeAgentConfig.managedFullAccessSessionModeID))
        XCTAssertFalse(OpenCodeAgentConfig.sessionModeHasNativeShell(OpenCodeAgentConfig.managedHeadlessSessionModeID))
        XCTAssertFalse(OpenCodeAgentConfig.sessionModeHasNativeShell(OpenCodeAgentConfig.managedNoToolsSessionModeID))
        XCTAssertFalse(OpenCodeAgentConfig.sessionModeHasNativeShell(nil))
        XCTAssertFalse(OpenCodeAgentConfig.sessionModeHasNativeShell("custom"))
    }

    func testCodexControllerOptionsCarryTheCapturedShellLaunchValue() {
        for value: Bool? in [true, false, nil] {
            let options = CodexNativeSessionController.Options.agentModeDefault(
                forceExperimentalSteering: false,
                shellToolEnabled: value,
                goalSupportEnabledProvider: { false }
            )
            XCTAssertEqual(options.shellToolEnabled, value)
        }
    }

    func testClaudeShellSignalIsFalseForKnowledgeAndSafeDefaultSessions() {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )

        guard let safeDefaults = viewModel.session(for: UUID(), createIfNeeded: true),
              let knowledge = viewModel.session(for: UUID(), createIfNeeded: true)
        else {
            return XCTFail("Test sessions were not created")
        }
        safeDefaults.permissionProfile = .mcpSafeDefaults
        XCTAssertFalse(viewModel.claudeCoordinator.runHasNativeShell(for: safeDefaults))

        knowledge.testInstallPersistentSessionBinding(sessionID: UUID())
        knowledge.hasLoadedPersistedState = true
        XCTAssertTrue(knowledge.adoptSessionProfile(.knowledge))
        XCTAssertEqual(knowledge.profile, .knowledge)
        XCTAssertFalse(viewModel.claudeCoordinator.runHasNativeShell(for: knowledge))
    }

    /// The signal is true only when both the pending launch and any live controller's recorded
    /// launch settings keep RepoPrompt's Bash enabled; a recycle can be deferred mid-turn.
    func testClaudeShellSignalRequiresBashInThePendingAndLiveLaunchSettings() {
        func live(_ bash: Bool?, _ profile: AgentSessionProfile = .standard) -> ClaudeAgentModeCoordinator.ControllerLaunchSettings {
            ClaudeAgentModeCoordinator.ControllerLaunchSettings(
                runtimeVariant: .standard,
                workspacePath: "/workspace",
                permissionMode: "default",
                allowNativeBashTool: bash,
                mcpStrictMode: true,
                sessionProfile: profile,
                toolSearchEnabled: nil
            )
        }
        func signal(
            pending: Bool?,
            profile: AgentSessionProfile = .standard,
            live: ClaudeAgentModeCoordinator.ControllerLaunchSettings??
        ) -> Bool {
            ClaudeAgentModeCoordinator.runHasNativeShell(
                pendingAllowNativeBashTool: pending,
                sessionProfile: profile,
                liveControllerLaunchSettings: live
            )
        }

        XCTAssertTrue(signal(pending: true, live: .none), "next launch enables Bash")
        XCTAssertTrue(signal(pending: true, live: .some(live(true))))
        XCTAssertFalse(signal(pending: true, live: .some(live(false))), "live process launched without Bash")
        XCTAssertFalse(signal(pending: true, live: .some(live(nil))), "live process launched with unresolved Bash")
        XCTAssertFalse(signal(pending: true, live: .some(nil)), "live process with unknown launch settings")
        XCTAssertFalse(signal(pending: true, live: .some(live(true, .knowledge))))
        XCTAssertFalse(signal(pending: false, live: .some(live(true))), "pending launch disables Bash")
        XCTAssertFalse(signal(pending: nil, live: .none), "unresolved pending preference")
        XCTAssertFalse(signal(pending: true, profile: .knowledge, live: .none))
    }

    // MARK: - Prompts

    func testAgentModePromptsRouteReviewPublicationToTheSnapshotAndInspectionToTheShell() {
        let roles: [AgentModelCatalog.TaskLabelKind?] = [nil, .engineer, .pair, .design]
        for agentKind in [AgentProviderKind.claudeCode, .codexExec] {
            for role in roles {
                let label = "\(agentKind) \(role.map { "\($0)" } ?? "default")"
                let prompt = SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: role)
                XCTAssertEqual(
                    prompt.components(separatedBy: "**Git review context**").count - 1,
                    1,
                    "\(label): the shared fragment appears exactly once"
                )
                XCTAssertTrue(prompt.contains("git_review_snapshot"), label)
                let inspection = AgentModePrompts.Fragments.gitInspectionGuidance
                XCTAssertTrue(
                    prompt.contains(inspection)
                        || prompt.contains(AgentModePrompts.Fragments.codexQualifiedToolReferences(inspection, agentKind: agentKind)),
                    label
                )
            }
        }

        for agentKind in [AgentProviderKind.claudeCode, .codexExec] {
            // Explore runs with a native shell also lose `git`, so they get the inspection line only.
            let explore = SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: .explore)
            XCTAssertFalse(explore.contains("git_review_snapshot"), "\(agentKind) explore")
            XCTAssertTrue(
                explore.contains(AgentModePrompts.Fragments.codexQualifiedToolReferences(
                    AgentModePrompts.Fragments.gitInspectionGuidance,
                    agentKind: agentKind
                )),
                "\(agentKind) explore"
            )
            let knowledge = SystemPromptService.agentModePrompt(agentKind: agentKind, sessionProfile: .knowledge)
            XCTAssertFalse(knowledge.contains("git_review_snapshot"), "\(agentKind) knowledge")
        }
    }

    func testWorkflowPromptsNameTheSnapshotAndShellInspection() {
        let note = RepoPromptWorkflowPrompts.nativeShellGitInspectionNote
        // Installed MCP skills also load inside Agent Mode runs, so every non-CLI variant names the
        // native-shell case; the CLI variant has no MCP `git` tool to hide.
        for variant in [WorkflowPromptVariant.mcp, .agent] {
            let reminder = RepoPromptWorkflowPrompts.rpReminder(variant: variant)
            XCTAssertTrue(reminder.contains("| Publish a diff for Oracle review | `git_review_snapshot` |"), "\(variant)")
            XCTAssertTrue(reminder.contains("shelling out while `git` is in your tool list"), "\(variant)")
            XCTAssertTrue(reminder.contains(note), "\(variant)")
            XCTAssertTrue(RepoPromptWorkflowPrompts.rpReviewCore(variant: variant).contains(note), "\(variant)")
            XCTAssertTrue(RepoPromptWorkflowPrompts.rpOracleExport(variant: variant).contains(note), "\(variant)")
        }

        let reminderCLI = RepoPromptWorkflowPrompts.rpReminder(variant: .cli)
        XCTAssertTrue(reminderCLI.contains("shelling out for analysis"))
        XCTAssertFalse(reminderCLI.contains("git_review_snapshot"))
        XCTAssertFalse(reminderCLI.contains(note))
        XCTAssertFalse(RepoPromptWorkflowPrompts.rpReviewCore(variant: .cli).contains(note))
        XCTAssertFalse(RepoPromptWorkflowPrompts.rpOracleExport(variant: .cli).contains(note))
    }

    func testOracleToolDescriptionsNameTheSnapshotForReviewPublication() async {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        for name in [MCPWindowToolName.askOracle, MCPWindowToolName.oracleSend] {
            guard let tool = tools.first(where: { $0.name == name }) else {
                XCTFail("\(name) is not in the window catalog")
                continue
            }
            XCTAssertTrue(tool.description.contains("publish the diff with `git_review_snapshot`"), name)
        }
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
