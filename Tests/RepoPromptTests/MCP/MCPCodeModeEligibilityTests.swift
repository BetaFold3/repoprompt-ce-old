import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Plan §6 D3 Step 5: production Claude eligibility, policy install/cache normalization, flat
/// `code_mode` child-card provenance, and legacy transcript round-trips.
@MainActor
final class MCPCodeModeEligibilityTests: XCTestCase {
    private typealias LaunchSettings = ClaudeAgentModeCoordinator.ControllerLaunchSettings

    private static func launchSettings(
        runtimeVariant: ClaudeCodeRuntimeVariant = .standard,
        sessionProfile: AgentSessionProfile = .standard
    ) -> LaunchSettings {
        LaunchSettings(
            runtimeVariant: runtimeVariant,
            workspacePath: nil,
            permissionMode: nil,
            allowNativeBashTool: nil,
            mcpStrictMode: nil,
            sessionProfile: sessionProfile,
            toolSearchEnabled: nil
        )
    }

    private static func eligibility(
        toolsMode: RepoPromptToolsMode = .directCodeMode,
        agentKind: AgentProviderKind = .claudeCode,
        sessionProfile: AgentSessionProfile = .standard,
        permissionProfile: AgentProviderPermissionProfile = .userConfigured,
        model: String = "opus",
        live: LaunchSettings?? = .none
    ) -> MCPCodeModeEligibility {
        ClaudeAgentModeCoordinator.codeModeEligibility(
            toolsMode: toolsMode,
            agentKind: agentKind,
            sessionProfile: sessionProfile,
            permissionProfile: permissionProfile,
            selectedModelRaw: model,
            liveControllerLaunchSettings: live
        )
    }

    // MARK: - Production eligibility

    func testDirectCodeModeOnAnOfficialClaudeStandardLaunchIsEligible() {
        XCTAssertEqual(Self.eligibility(), .directTools)
        for model in ["sonnet", "opus[1m]", "claude-opus-5-5", "sonnet:high", AgentModel.defaultModel.rawValue] {
            XCTAssertEqual(Self.eligibility(model: model), .directTools, model)
        }
        XCTAssertEqual(Self.eligibility(live: .some(Self.launchSettings())), .directTools)
    }

    func testEveryOtherLaunchFactFailsClosedToNative() {
        XCTAssertEqual(Self.eligibility(toolsMode: .native), .native)
        for agent in AgentProviderKind.allCases where agent != .claudeCode {
            XCTAssertEqual(Self.eligibility(agentKind: agent), .native, agent.rawValue)
        }
        XCTAssertEqual(Self.eligibility(sessionProfile: .knowledge), .native)
        XCTAssertEqual(Self.eligibility(permissionProfile: .mcpSafeDefaults), .native)
        for model in ["", "custom-model", "gpt-5", "glm-4.7"] {
            XCTAssertEqual(Self.eligibility(model: model), .native, model)
        }
        // A live controller with unknown, compatible-backend, or Knowledge launch settings.
        XCTAssertEqual(Self.eligibility(live: .some(nil)), .native)
        XCTAssertEqual(Self.eligibility(live: .some(Self.launchSettings(runtimeVariant: .glm))), .native)
        XCTAssertEqual(
            Self.eligibility(live: .some(Self.launchSettings(runtimeVariant: .customCompatible))),
            .native
        )
        XCTAssertEqual(Self.eligibility(live: .some(Self.launchSettings(sessionProfile: .knowledge))), .native)
    }

    /// Launch validation accepts strict-grammar dynamic family point releases without a static
    /// `AgentModel` case; eligibility must read the same authority as the same-family aliases.
    func testDynamicFamilyPointReleasesShareStaticAliasEligibility() {
        let staticAliases = ["sonnet", "sonnet:medium", "opus", "opus:medium", "opus[1m]"]
        let dynamicReleases = [
            "claude-sonnet-5-1", "claude-sonnet-5-1:medium", "claude-sonnet-5-1-20261015", "claude-sonnet-5-1[1m]",
            "claude-opus-5-7", "claude-opus-5-7:xhigh", "claude-opus-5-7-20261101", "claude-opus-5-7[1m]:medium"
        ]
        for model in dynamicReleases {
            XCTAssertNil(AgentModel.resolvedModel(forRaw: model, agentKind: .claudeCode), "\(model) must miss the enum")
        }
        for model in staticAliases + dynamicReleases {
            XCTAssertEqual(Self.eligibility(model: model), .directTools, model)
            XCTAssertEqual(Self.eligibility(model: model, live: .some(Self.launchSettings())), .directTools, model)
        }
    }

    func testDynamicPointReleasesKeepEveryOtherGateAndNonFamilyIDsStayNative() {
        let dynamic = "claude-sonnet-5-1:medium"
        XCTAssertEqual(Self.eligibility(toolsMode: .native, model: dynamic), .native)
        for agent in AgentProviderKind.allCases where agent != .claudeCode {
            XCTAssertEqual(Self.eligibility(agentKind: agent, model: dynamic), .native, agent.rawValue)
        }
        XCTAssertEqual(Self.eligibility(sessionProfile: .knowledge, model: dynamic), .native)
        XCTAssertEqual(Self.eligibility(permissionProfile: .mcpSafeDefaults, model: dynamic), .native)
        let nativeLive: [LaunchSettings?] = [
            nil,
            Self.launchSettings(runtimeVariant: .glm),
            Self.launchSettings(runtimeVariant: .customCompatible),
            Self.launchSettings(sessionProfile: .knowledge)
        ]
        for live in nativeLive {
            XCTAssertEqual(Self.eligibility(model: dynamic, live: .some(live)), .native)
        }
        // Unknown family, new major, malformed minor/date/qualifier, unparseable effort, custom prefix.
        for model in [
            "claude-haiku-5-1", "claude-sonnet-6-1", "claude-opus-6-0:medium", "claude-sonnet-5-x",
            "claude-sonnet-5-1-2026", "claude-sonnet-5-1-20261015-2", "claude-sonnet-5-1[2m]",
            "claude-sonnet-5-1:ultra", "acme-claude-sonnet-5-1"
        ] {
            XCTAssertEqual(Self.eligibility(model: model), .native, model)
        }
    }

    func testRepoPromptToolsSettingDefaultsNativeAndUnknownValuesReadNative() throws {
        let suiteName = "MCPCodeModeEligibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .native)
        ClaudeAgentToolPreferences.setRepoPromptToolsMode(.directCodeMode, defaults: defaults)
        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .directCodeMode)
        defaults.set("direct_plus_code_mode", forKey: "claudeCodeRepoPromptToolsMode")
        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .native)
        defaults.set(true, forKey: "claudeCodeRepoPromptToolsMode")
        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .native)
    }

    func testAppSettingsExposesTheClaudeRepoPromptToolsMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCodeModeEligibilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "MCPCodeModeEligibilityTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.claude_repoprompt_tools"

        let initial = try await service.handleForTesting(["op": .string("get"), "key": .string(key)])
        XCTAssertEqual(initial.objectValue?["values"]?.objectValue?[key]?.stringValue, "native")

        let set = try await service.handleForTesting([
            "op": .string("set"), "key": .string(key), "value": .string("direct_code_mode")
        ])
        XCTAssertEqual(set.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .directCodeMode)

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"), "key": .string(key), "value": .string("code_mode_only")
            ])
            XCTFail("An unsupported mode must be rejected")
        } catch {}
        XCTAssertEqual(ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults), .directCodeMode)
    }

    #if DEBUG

        // MARK: - Policy install and run cache

        func testInstalledPolicyNormalizesAndCachesEligibilityPerRun() async {
            let manager = ServerNetworkManager.shared
            let cases: [(String, MCPRunPurpose, AgentSessionProfile, MCPCodeModeEligibility, MCPCodeModeEligibility)] = [
                ("standard agent run", .agentModeRun, .standard, .directTools, .directTools),
                ("default install", .agentModeRun, .standard, .native, .native),
                ("knowledge", .agentModeRun, .knowledge, .directTools, .native),
                ("discovery", .discoverRun, .standard, .directTools, .native),
                ("unknown purpose", .unknown, .standard, .directTools, .native)
            ]
            for (label, purpose, profile, requested, expected) in cases {
                let runID = UUID()
                let clientName = "code-mode-eligibility-\(UUID().uuidString)"
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: 1,
                    restrictedTools: [],
                    runID: runID,
                    sessionProfile: profile,
                    purpose: purpose,
                    codeModeEligibility: requested
                )
                let cached = await manager.debugRunCodeModeEligibility(for: runID)
                XCTAssertEqual(cached, expected, label)
                await manager.clearClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: 1)
                let cleaned = await manager.debugRunCodeModeEligibility(for: runID)
                XCTAssertNil(cleaned, label)
            }

            // The protocol-facing install (direct installs, Codex) never carries eligibility.
            let runID = UUID()
            let clientName = "code-mode-eligibility-legacy-\(UUID().uuidString)"
            await manager.installClientConnectionPolicy(
                for: clientName, windowID: 1, restrictedTools: [], runID: runID, purpose: .agentModeRun
            )
            let legacy = await manager.debugRunCodeModeEligibility(for: runID)
            XCTAssertEqual(legacy, .native)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: 1)

            // A seeded run cache normalizes the same way (rehydration copies this value verbatim).
            let seededRunID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: seededRunID, restrictedTools: [], additionalTools: nil,
                sessionProfile: .knowledge, purpose: .agentModeRun, codeModeEligibility: .directTools
            )
            let seeded = await manager.debugRunCodeModeEligibility(for: seededRunID)
            XCTAssertEqual(seeded, .native)
            await manager.cleanupRunRoutingState(for: seededRunID, windowID: 1)
        }

        // MARK: - Child cards

        func testCodeModeChildEventsAppendFlatLinkedCardsWithoutHijackingParentCorrelation() {
            let handler = ClaudeAgentToolTrackingHandler(mcpHost: ServerNetworkManager.shared)
            let session = AgentTabSession(tabID: UUID())
            let parentInvocationID = UUID()
            let childInvocationID = UUID()
            let args: [String: Value] = ["path": .string("Sources/A.swift")]
            session.setItemsSilently([
                .user("go", sequenceIndex: 0),
                .toolCall(name: "code_mode", invocationID: parentInvocationID, argsJSON: "{}", sequenceIndex: 1)
            ], reason: .testOverride)
            session.runState = .running

            let linkage = AgentToolEventLinkage(codeModeParentInvocationID: parentInvocationID)
            AgentToolEventLinkage.$current.withValue(linkage) {
                handler.handleTrackerToolCall(
                    invocationID: childInvocationID, toolName: "read_file", args: args, session: session
                )
            }
            XCTAssertEqual(session.items.count, 3)
            let childCall = session.items[2]
            XCTAssertEqual(childCall.kind, .toolCall)
            XCTAssertEqual(childCall.toolInvocationID, childInvocationID)
            XCTAssertEqual(childCall.codeModeParentInvocationID, parentInvocationID)
            XCTAssertEqual(ToolCardRouter.codeModeChildMarker(for: childCall), "via code_mode")
            XCTAssertNil(ToolCardRouter.codeModeChildMarker(for: session.items[1]))

            // A direct call with the same signature never adopts the child card.
            let directInvocationID = UUID()
            handler.handleTrackerToolCall(
                invocationID: directInvocationID, toolName: "read_file", args: args, session: session
            )
            XCTAssertEqual(session.items.count, 4)
            XCTAssertEqual(session.items[3].toolInvocationID, directInvocationID)
            XCTAssertNil(session.items[3].codeModeParentInvocationID)
            XCTAssertEqual(session.items[2].toolInvocationID, childInvocationID)

            AgentToolEventLinkage.$current.withValue(linkage) {
                handler.handleTrackerToolResult(
                    invocationID: childInvocationID, toolName: "read_file", args: args,
                    resultJSON: #"{"content":"child"}"#, isError: false, session: session
                )
            }
            XCTAssertEqual(session.items[2].kind, .toolResult)
            XCTAssertEqual(session.items[2].toolResultJSON, #"{"content":"child"}"#)
            XCTAssertEqual(session.items[2].codeModeParentInvocationID, parentInvocationID)
            XCTAssertEqual(session.items[3].kind, .toolCall, "The direct call stays pending")
            XCTAssertEqual(session.items[1].kind, .toolCall, "The parent card is untouched by its child")
            session.testAssertSourceItemDerivedStateIsConsistent()
        }
    #endif

    // MARK: - Persistence

    func testChildLinkageRoundTripsAndLegacyItemsDecodeWithoutIt() throws {
        let parentInvocationID = UUID()
        let fixedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var child = AgentChatItem.toolResult(
            name: "read_file", invocationID: UUID(), resultJSON: #"{"content":"x"}"#, isError: false, sequenceIndex: 3
        ).replacingTimestamp(fixedTimestamp)
        child.codeModeParentInvocationID = parentInvocationID

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decodedChild = try decoder.decode(AgentChatItem.self, from: encoder.encode(child))
        XCTAssertEqual(decodedChild, child)
        XCTAssertEqual(AgentChatItemPersist(from: child).toItem().codeModeParentInvocationID, parentInvocationID)
        let persisted = try decoder.decode(AgentChatItemPersist.self, from: encoder.encode(AgentChatItemPersist(from: child)))
        XCTAssertEqual(persisted.codeModeParentInvocationID, parentInvocationID)
        XCTAssertEqual(child.replacingTimestamp(Date(timeIntervalSince1970: 1)).codeModeParentInvocationID, parentInvocationID)

        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: child))
        XCTAssertEqual(execution.codeModeParentInvocationID, parentInvocationID)
        let activity = AgentTranscriptActivity(from: child, toolExecution: execution)
        let decodedActivity = try decoder.decode(AgentTranscriptActivity.self, from: encoder.encode(activity))
        XCTAssertEqual(decodedActivity.toItem().codeModeParentInvocationID, parentInvocationID)

        // Legacy: an ordinary item never writes the key, and pre-Step-5 payloads decode unchanged.
        let ordinary = AgentChatItem.toolResult(name: "read_file", invocationID: UUID(), resultJSON: "{}", sequenceIndex: 1)
            .replacingTimestamp(fixedTimestamp)
        let ordinaryJSON = try XCTUnwrap(String(data: encoder.encode(ordinary), encoding: .utf8))
        XCTAssertFalse(ordinaryJSON.contains("codeModeParentInvocationID"), ordinaryJSON)
        let persistedOrdinaryJSON = try XCTUnwrap(
            String(data: encoder.encode(AgentChatItemPersist(from: ordinary)), encoding: .utf8)
        )
        XCTAssertFalse(persistedOrdinaryJSON.contains("codeModeParentInvocationID"), persistedOrdinaryJSON)
        let legacyItem = try decoder.decode(AgentChatItem.self, from: Data(ordinaryJSON.utf8))
        XCTAssertEqual(legacyItem, ordinary)
        XCTAssertNil(legacyItem.codeModeParentInvocationID)
        let legacyPersist = try decoder.decode(AgentChatItemPersist.self, from: Data(persistedOrdinaryJSON.utf8))
        XCTAssertNil(legacyPersist.toItem().codeModeParentInvocationID)
        let ordinaryExecution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: ordinary))
        let ordinaryExecutionJSON = try XCTUnwrap(String(data: encoder.encode(ordinaryExecution), encoding: .utf8))
        XCTAssertFalse(ordinaryExecutionJSON.contains("codeModeParentInvocationID"), ordinaryExecutionJSON)
        XCTAssertEqual(
            try decoder.decode(AgentTranscriptToolExecution.self, from: Data(ordinaryExecutionJSON.utf8)),
            ordinaryExecution
        )
    }
}
