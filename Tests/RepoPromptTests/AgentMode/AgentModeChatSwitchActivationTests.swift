import Combine
import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentModeChatSwitchActivationTests: XCTestCase {
    #if DEBUG
        override func setUp() {
            super.setUp()
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = true
        }

        override func tearDown() {
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = false
            super.tearDown()
        }
    #endif

    func testFocusedStandardSessionCreationPublishesReturnedTabRequest() async throws {
        try await withFixture { fixture in
            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                focusComposer: true
            )
            let tabID = try XCTUnwrap(returnedTabID)
            let request = try XCTUnwrap(fixture.viewModel.ui.composer.focusRequest)

            XCTAssertEqual(request.tabID, tabID)
            XCTAssertEqual(request.reason, .newSession)
        }
    }

    func testDefaultSessionCreationPublishesNoFocusRequest() async throws {
        try await withFixture { fixture in
            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab()

            XCTAssertNotNil(returnedTabID)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
        }
    }

    func testFocusedSwallowedPlaceholderPublishesReusedPriorTabRequest() async throws {
        try await withFixture { fixture in
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            session.transcript = AgentTranscript()
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                focusComposer: true
            )

            XCTAssertEqual(returnedTabID, fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.reason, .reusedPlaceholder)
        }
    }

    func testFocusedKnowledgeSessionCreationPublishesKnowledgeReason() async throws {
        try await withFixture { fixture in
            fixture.viewModel.test_setAvailableAgents([.codexExec])

            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                profile: .knowledge,
                focusComposer: true
            )
            let tabID = try XCTUnwrap(returnedTabID)

            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, tabID)
            XCTAssertEqual(
                fixture.viewModel.ui.composer.focusRequest?.reason,
                .newKnowledgeSession
            )
        }
    }

    func testFailedKnowledgeSessionCreationPublishesNoFocusRequest() async throws {
        try await withFixture { fixture in
            fixture.viewModel.test_setAvailableAgents([])

            let tabID = await fixture.viewModel.createAndActivateSessionTab(
                profile: .knowledge,
                focusComposer: true
            )

            XCTAssertNil(tabID)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
        }
    }

    func testFreshSessionCreationRetainsInitiatingSelectionAndSourceDraft() async throws {
        for profile in [AgentSessionProfile.standard, .knowledge] {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                viewModel.test_setAvailableAgents([.codexExec])
                fixture.window.apiSettingsViewModel.isCodexConnected = true
                viewModel.selectedAgent = .codexExec
                let options = viewModel.modelOptions(for: .codexExec)
                let option = try XCTUnwrap(options.first(where: { !$0.isPlaceholderDefault }) ?? options.first)
                viewModel.selectedModelRaw = option.rawValue
                viewModel.selectedReasoningEffortRaw = option.supportedReasoningEfforts.first?.rawValue
                let agent = viewModel.selectedAgent
                let modelRaw = viewModel.selectedModelRaw
                let effortRaw = viewModel.selectedReasoningEffortRaw
                let sourceAgent = fixture.sessionA.selectedAgent
                let sourceModelRaw = fixture.sessionA.selectedModelRaw
                let sourceEffortRaw = fixture.sessionA.selectedReasoningEffortRaw
                fixture.window.promptManager.promptText = "Draft A"

                let returnedTabID = await viewModel.createAndActivateSessionTab(
                    profile: profile,
                    focusComposer: true
                )
                let tabID = try XCTUnwrap(returnedTabID)
                let session = try XCTUnwrap(viewModel.sessions[tabID])

                XCTAssertEqual(session.profile, profile)
                XCTAssertEqual(session.selectedAgent, agent)
                XCTAssertEqual(session.selectedModelRaw, modelRaw)
                XCTAssertEqual(session.selectedReasoningEffortRaw, effortRaw)
                XCTAssertEqual(viewModel.selectedAgent, agent)
                XCTAssertEqual(viewModel.selectedModelRaw, modelRaw)
                XCTAssertEqual(viewModel.selectedReasoningEffortRaw, effortRaw)
                XCTAssertEqual(fixture.sessionA.selectedAgent, sourceAgent)
                XCTAssertEqual(fixture.sessionA.selectedModelRaw, sourceModelRaw)
                XCTAssertEqual(fixture.sessionA.selectedReasoningEffortRaw, sourceEffortRaw)
                XCTAssertEqual(
                    fixture.window.workspaceManager.activeWorkspace?.composeTabs
                        .first(where: { $0.id == fixture.tabAID })?.promptText,
                    "Draft A"
                )
            }
        }
    }

    func testFreshSessionCreationFirstDestinationPresentationIsBoundAndHydrated() async throws {
        let cases: [(profile: AgentSessionProfile, agent: AgentProviderKind)] = [
            (.standard, .claudeCode),
            (.standard, .codexExec),
            (.knowledge, .codexExec)
        ]
        for (profile, agent) in cases {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                viewModel.test_setAvailableAgents([.claudeCode, .codexExec])
                viewModel.selectedAgent = agent
                let modelRaw = viewModel.selectedModelRaw
                let effortRaw = viewModel.selectedReasoningEffortRaw
                let sourceTabIDs: Set<UUID> = [fixture.tabAID, fixture.tabBID]
                var presentations: [(tabID: UUID?, hydrated: Bool, profile: AgentSessionProfile?)] = []
                var loadingTabIDs: [UUID?] = []
                let presentationSink = viewModel.$activeTranscriptPresentation.dropFirst().sink { snapshot in
                    let session = snapshot.tabID.flatMap { viewModel.sessions[$0] }
                    presentations.append((snapshot.tabID, snapshot.bindingsHydrated, session?.profile))
                }
                let loadingSink = viewModel.$activeSessionLoadInProgressTabID.dropFirst().sink { tabID in
                    loadingTabIDs.append(tabID)
                }
                // Ordered Prompt cues up to the start of context application (`isSwitchingComposeTab`).
                var promptCues: [String] = []
                let promptManager = fixture.window.promptManager
                let membershipSink = promptManager.$currentComposeTabs.dropFirst().sink { tabs in
                    promptCues.append("membership:\(tabs.count)")
                }
                let activeSink = promptManager.$activeComposeTabID.dropFirst().sink { tabID in
                    promptCues.append(tabID.map(sourceTabIDs.contains) == false ? "active:new" : "active:other")
                }
                let switchingSink = promptManager.$isSwitchingComposeTab.dropFirst().sink { isSwitching in
                    if isSwitching { promptCues.append("switching") }
                }
                defer {
                    presentationSink.cancel()
                    loadingSink.cancel()
                    membershipSink.cancel()
                    activeSink.cancel()
                    switchingSink.cancel()
                }

                let returnedTabID = await viewModel.createAndActivateSessionTab(
                    profile: profile,
                    focusComposer: true
                )
                let tabID = try XCTUnwrap(returnedTabID)
                let session = try XCTUnwrap(viewModel.sessions[tabID])
                XCTAssertEqual(session.selectedAgent, agent)
                XCTAssertEqual(session.selectedModelRaw, modelRaw)
                XCTAssertEqual(session.selectedReasoningEffortRaw, effortRaw)
                XCTAssertEqual(viewModel.selectedAgent, agent)
                XCTAssertEqual(viewModel.selectedModelRaw, modelRaw)
                XCTAssertEqual(viewModel.selectedReasoningEffortRaw, effortRaw)

                XCTAssertFalse(
                    presentations.contains { $0.tabID == nil },
                    "No cleared, unbound destination is published"
                )
                XCTAssertFalse(presentations.contains { $0.tabID.map(sourceTabIDs.contains) == true })
                let first = try XCTUnwrap(presentations.first { $0.tabID == tabID })
                XCTAssertTrue(first.hydrated, "The first destination presentation is already hydrated")
                XCTAssertEqual(first.profile, profile)
                XCTAssertFalse(loadingTabIDs.contains(tabID), "No disk load starts for a fresh session")
                XCTAssertEqual(
                    Array(promptCues.prefix(3)),
                    ["membership:3", "active:new", "switching"],
                    "Membership, then the active ID, are each published once before context application"
                )
                XCTAssertEqual(promptManager.currentComposeTabs.map(\.id), [fixture.tabAID, fixture.tabBID, tabID])
                XCTAssertNil(viewModel.activeSessionLoadInProgressTabID)
                XCTAssertEqual(viewModel.currentTabID, tabID)
                XCTAssertEqual(viewModel.ui.composer.focusRequest?.tabID, tabID)
                XCTAssertTrue(viewModel.activeTranscriptPresentation.bindingsHydrated)
            }
        }
    }

    func testRefusedFreshSessionPreparationWithdrawsNeverActivatedTab() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.viewModel
            let promptManager = fixture.window.promptManager
            let tabIDsBefore = promptManager.currentComposeTabs.map(\.id)
            let sessionTabIDsBefore = Set(viewModel.sessions.keys)
            var activeTabIDs: [UUID?] = []
            let activeSink = promptManager.$activeComposeTabID.dropFirst().sink { activeTabIDs.append($0) }
            viewModel.test_refusesFreshSessionPreparation = true
            defer {
                activeSink.cancel()
                viewModel.test_refusesFreshSessionPreparation = false
            }

            let returnedTabID = await viewModel.createAndActivateSessionTab(focusComposer: true)

            XCTAssertNil(returnedTabID)
            XCTAssertTrue(activeTabIDs.isEmpty, "The refused tab is never activated")
            XCTAssertEqual(promptManager.currentComposeTabs.map(\.id), tabIDsBefore)
            XCTAssertEqual(
                fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id),
                tabIDsBefore
            )
            XCTAssertEqual(Set(viewModel.sessions.keys), sessionTabIDsBefore)
            XCTAssertEqual(viewModel.currentTabID, fixture.tabAID)
            XCTAssertNil(viewModel.ui.composer.focusRequest)
            assertPresentation(
                viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )
        }
    }

    func testFreshSessionCreationSupersededDuringContextApplyKeepsPreparedBackgroundSession() async throws {
        try await withFixture { fixture in
            let promptManager = fixture.window.promptManager
            let workspaceManager = fixture.window.workspaceManager
            let sourceTabIDs: Set<UUID> = [fixture.tabAID, fixture.tabBID]
            var didSwitchDuringCreatedApply = false
            // Creation pauses at context application of the created tab while the user switches to
            // B; B's own apply passes straight through.
            workspaceManager.composeTabApplyAfterContextHookForTesting = { tabID in
                guard !sourceTabIDs.contains(tabID), !didSwitchDuringCreatedApply else { return }
                didSwitchDuringCreatedApply = true
                await promptManager.switchComposeTab(fixture.tabBID)
            }
            defer { workspaceManager.composeTabApplyAfterContextHookForTesting = nil }

            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(focusComposer: true)

            XCTAssertTrue(didSwitchDuringCreatedApply)
            XCTAssertNil(returnedTabID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
            let createdTabID = try XCTUnwrap(
                promptManager.currentComposeTabs.map(\.id).first { !sourceTabIDs.contains($0) }
            )
            let created = try XCTUnwrap(
                fixture.viewModel.sessions[createdTabID],
                "The prepared session stays as an ordinary background tab"
            )
            XCTAssertTrue(created.hasLoadedPersistedState)
            XCTAssertNotNil(fixture.viewModel.sessions[fixture.tabAID])
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )
        }
    }

    func testSharedModelSelectionCommitPreservesInputBarOrderingAndRejectsDrift() async throws {
        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            fixture.viewModel.selectedAgent = .codexExec
            let options = fixture.viewModel.modelOptions(for: .codexExec)
            let option = try XCTUnwrap(
                options.first(where: { !$0.isPlaceholderDefault }) ?? options.first
            )
            let explicitEffort = option.supportedReasoningEfforts.first

            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .codexExec,
                rawModel: option.rawValue,
                explicitCodexEffort: explicitEffort,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(fixture.viewModel.selectedAgent, .codexExec)
            XCTAssertEqual(fixture.viewModel.selectedModelRaw, option.rawValue)
            XCTAssertEqual(session.selectedAgent, .codexExec)
            XCTAssertEqual(session.selectedModelRaw, option.rawValue)
            if let explicitEffort {
                XCTAssertEqual(
                    fixture.viewModel.selectedReasoningEffortRaw,
                    explicitEffort.rawValue
                )
                XCTAssertEqual(session.selectedReasoningEffortRaw, explicitEffort.rawValue)
            }

            let committedModel = session.selectedModelRaw
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: "not-in-the-live-catalog",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .modelUnavailable)
            }
            XCTAssertEqual(session.selectedModelRaw, committedModel)

            fixture.viewModel.test_setMCPControlledTabIDs([fixture.tabAID])
            XCTAssertEqual(
                fixture.viewModel.modelSelectionInteractivity(tabID: fixture.tabAID),
                .disabled(
                    reason: "Model and effort controls are locked while this session is controlled by an MCP agent."
                )
            )
            XCTAssertTrue(fixture.viewModel.makeComposerProps().areModelControlsDisabled)
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: option.rawValue,
                    explicitCodexEffort: explicitEffort,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                guard case .controlsDisabled = error as? AgentModelSelectionCommitError else {
                    return XCTFail("Expected MCP-only interactivity rejection, got \(error)")
                }
            }
            fixture.viewModel.test_setMCPControlledTabIDs([])

            session.hasSentFirstMessage = true
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .openCode,
                    rawModel: "irrelevant-before-family-validation",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .agentNotSelectable)
            }

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: option.rawValue,
                    explicitCodexEffort: explicitEffort,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .sourceUnavailable)
            }
            XCTAssertEqual(session.selectedModelRaw, committedModel)
        }
    }

    func testSharedModelSelectionCommitPreservesProviderRawSemantics() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer {
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }

        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCursorConnected = true
            fixture.window.apiSettingsViewModel.isOpenCodeConnected = true
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: [
                        AgentModelOption(
                            rawValue: "future-cursor-model",
                            displayName: "Future Cursor Model",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    currentModelRaw: "future-cursor-model"
                ),
                for: .cursor
            )
            let cursorRaw = "future-cursor-model[context=1m,reasoning=high,fast=false]"
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .cursor,
                rawModel: cursorRaw,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .cursor)
            XCTAssertEqual(session.selectedModelRaw, cursorRaw)

            let claudeBaseOptions = fixture.viewModel.modelOptions(
                for: .claudeCode,
                includeClaudeEffortVariants: false
            )
            let claudeBase = try XCTUnwrap(claudeBaseOptions.first { option in
                !option.isPlaceholderDefault
                    && !AgentModelCatalog.supportedClaudeEfforts(
                        forSelectedModelRaw: option.rawValue,
                        agentKind: .claudeCode
                    ).isEmpty
            })
            let claudeEffort = try XCTUnwrap(
                AgentModelCatalog.supportedClaudeEfforts(
                    forSelectedModelRaw: claudeBase.rawValue,
                    agentKind: .claudeCode
                ).first
            )
            let claudeEncodedRaw = ClaudeModelSpecifier.encodedRaw(
                baseModelRaw: claudeBase.rawValue,
                effort: claudeEffort
            )
            XCTAssertFalse(claudeBaseOptions.contains { $0.rawValue == claudeEncodedRaw })
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .claudeCode,
                rawModel: claudeEncodedRaw,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .claudeCode)
            XCTAssertEqual(session.selectedModelRaw, claudeEncodedRaw)

            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: [
                        AgentModelOption(
                            rawValue: AgentModel.defaultModel.rawValue,
                            displayName: "OpenCode Default",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    currentModelRaw: AgentModel.defaultModel.rawValue
                ),
                for: .openCode
            )
            let placeholderOptions = fixture.viewModel.modelOptions(for: .openCode)
            XCTAssertEqual(placeholderOptions.count, 1)
            XCTAssertTrue(try XCTUnwrap(placeholderOptions.first).isPlaceholderDefault)
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .openCode,
                rawModel: AgentModel.defaultModel.rawValue,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .openCode)
            XCTAssertEqual(session.selectedModelRaw, AgentModel.defaultModel.rawValue)

            // Fixture contract: the options override below is this case's only Codex catalog,
            // with no live catalog and seed-only base names. A live snapshot from the process-global polling
            // service (subscribed when the restored last-used agent is Codex) would classify the
            // static encoded option as withdrawn; that contract is covered by
            // testCodexNormalizationPreservesWithdrawnAndNormalizesPresentCapabilities.
            fixture.viewModel.updateCodexDynamicModels([])
            XCTAssertTrue(
                fixture.viewModel.codexDynamicModels.isEmpty,
                "Fixture expects seeded encoded-ID semantics, not live-catalog withdrawal."
            )
            fixture.viewModel.test_setModelOptionsOverride(
                [
                    AgentModelOption(
                        rawValue: "gpt-5.4-high",
                        displayName: "GPT-5.4 High",
                        description: nil,
                        isDefault: true
                    )
                ],
                for: .codexExec
            )
            let codexOptions = fixture.viewModel.modelOptions(for: .codexExec)
            let encodedCodexOption = try XCTUnwrap(
                codexOptions.first {
                    CodexModelSpecifier(raw: $0.rawValue, capabilities: .seedOnly).reasoningEffort != nil
                },
                "Expected an encoded dynamic Codex option; got \(codexOptions.map(\.rawValue))"
            )
            let encodedEffort = try XCTUnwrap(
                CodexModelSpecifier(raw: encodedCodexOption.rawValue, capabilities: .seedOnly).reasoningEffort
            )
            let contradictoryEffort = try XCTUnwrap(
                CodexReasoningEffort.allCases.first { $0 != encodedEffort }
            )
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .codexExec,
                rawModel: encodedCodexOption.rawValue,
                explicitCodexEffort: contradictoryEffort,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(
                session.selectedModelRaw,
                CodexModelSpecifier(raw: encodedCodexOption.rawValue, capabilities: .seedOnly).baseModel
            )
            XCTAssertEqual(
                session.selectedReasoningEffortRaw,
                encodedEffort.rawValue,
                "The encoded effort must win over a contradictory explicit effort."
            )

            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: "removed-after-menu-snapshot",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error.localizedDescription, "The selected model is no longer available.")
            }
        }
    }

    @MainActor
    func testCodexNormalizationPreservesWithdrawnAndNormalizesPresentCapabilities() async throws {
        try await withFixture { fixture in
            let session = fixture.sessionA
            let present = CodexAppServerClient.RemoteModel(
                id: "gpt-daybreak-blue-latest",
                model: "gpt-daybreak-blue-latest",
                displayName: "Daybreak",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [.init(reasoningEffort: "high", description: "")]
            )
            fixture.viewModel.updateCodexDynamicModels([present])
            fixture.viewModel.test_setModelOptionsOverride(
                [
                    AgentModelOption(
                        rawValue: "gpt-daybreak-blue-latest",
                        displayName: "Daybreak",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true,
                        supportedReasoningEfforts: [.high],
                        defaultReasoningEffort: .high
                    )
                ],
                for: .codexExec
            )
            session.selectedAgent = .codexExec

            session.selectedModelRaw = "withdrawn-model"
            session.selectedReasoningEffortRaw = CodexReasoningEffort.ultra.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertEqual(session.selectedModelRaw, "withdrawn-model")
            XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.ultra.rawValue)

            session.selectedModelRaw = "gpt-daybreak-blue-latest"
            session.selectedReasoningEffortRaw = CodexReasoningEffort.ultra.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertEqual(session.selectedModelRaw, "gpt-daybreak-blue-latest")
            XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)

            let emptyEffortModel = CodexAppServerClient.RemoteModel(
                id: "gpt-daybreak-blue-latest",
                model: "gpt-daybreak-blue-latest",
                displayName: "Daybreak",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: []
            )
            fixture.viewModel.updateCodexDynamicModels([emptyEffortModel])
            session.selectedModelRaw = "gpt-daybreak-blue-latest"
            session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertNil(session.selectedReasoningEffortRaw)
            var effective = fixture.viewModel.codexCoordinator.effectiveCodexSelection(for: session)
            XCTAssertEqual(effective.model, "gpt-daybreak-blue-latest")
            XCTAssertNil(effective.reasoningEffort)

            let unknownEffortModel = CodexAppServerClient.RemoteModel(
                id: "gpt-daybreak-blue-latest",
                model: "gpt-daybreak-blue-latest",
                displayName: "Daybreak",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [],
                hasSupportedReasoningEffortsEvidence: false
            )
            fixture.viewModel.updateCodexDynamicModels([unknownEffortModel])
            session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
            effective = fixture.viewModel.codexCoordinator.effectiveCodexSelection(for: session)
            XCTAssertEqual(effective.reasoningEffort, CodexReasoningEffort.high.rawValue)

            session.selectedModelRaw = AgentModel.defaultModel.rawValue
            session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertNil(session.selectedReasoningEffortRaw)
            effective = fixture.viewModel.codexCoordinator.effectiveCodexSelection(for: session)
            XCTAssertNil(effective.model)
            XCTAssertNil(effective.reasoningEffort)

            let shorterLiveModel = CodexAppServerClient.RemoteModel(
                id: "gpt-5.1-codex",
                model: "gpt-5.1-codex",
                displayName: "GPT-5.1 Codex",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [.init(reasoningEffort: "max", description: "")]
            )
            fixture.viewModel.updateCodexDynamicModels([shorterLiveModel])
            session.selectedModelRaw = "gpt-5.1-codex-max"
            session.selectedReasoningEffortRaw = CodexReasoningEffort.ultra.rawValue
            fixture.viewModel.codexCoordinator.normalizeCodexSelectionForSession(
                session,
                preservingExplicitEffort: true
            )
            XCTAssertEqual(session.selectedModelRaw, "gpt-5.1-codex-max")
            XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.ultra.rawValue)
            effective = fixture.viewModel.codexCoordinator.effectiveCodexSelection(for: session)
            XCTAssertEqual(effective.model, "gpt-5.1-codex-max")
            XCTAssertEqual(effective.reasoningEffort, CodexReasoningEffort.ultra.rawValue)

            let ineligible = CodexModelCapabilitySnapshot(capabilities: [
                .init(base: "gpt-daybreak-blue-latest", efforts: [.high], speedTiers: [])
            ])
            XCTAssertEqual(
                CodexAgentModeCoordinator.normalizedCodexSelectionModelRaw(
                    from: "gpt-daybreak-blue-latest-fast",
                    capabilities: ineligible
                ),
                "gpt-daybreak-blue-latest"
            )
        }
    }

    func testModelSelectionHUDCurrentPresentationCommitsAndRejectsStaleTab() async throws {
        try await withFixture { fixture in
            fixture.sessionA.hasSentFirstMessage = false
            fixture.sessionA.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)
            configureHUDCodexProvider(fixture)
            fixture.sessionA.selectedAgent = .codexExec
            fixture.sessionA.selectedModelRaw = AgentModel.defaultModel.rawValue
            fixture.sessionA.selectedReasoningEffortRaw = nil

            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            XCTAssertNil(presentation.unavailableMessage)
            let defaultLeaf = try XCTUnwrap(
                presentation.index.leaves.first {
                    if case let .local(agent: .codexExec, modelRaw, _) = $0.commitPayload {
                        return modelRaw == AgentModel.defaultModel.rawValue
                    }
                    return false
                }
            )
            XCTAssertTrue(defaultLeaf.isCurrentSelection)
            XCTAssertEqual(presentation.index.currentSelectionID, defaultLeaf.id)
            try await presentation.commit(defaultLeaf)
            XCTAssertEqual(
                fixture.sessionA.selectedModelRaw,
                AgentModel.defaultModel.rawValue
            )

            let leaf = try XCTUnwrap(
                presentation.index.leaves.first {
                    if case let .local(agent: .codexExec, modelRaw, _) = $0.commitPayload {
                        return modelRaw != fixture.viewModel.selectedModelRaw
                    }
                    return false
                }
            )

            try await presentation.commit(leaf)
            guard case let .local(agent, modelRaw, effortRaw) = leaf.commitPayload else {
                return XCTFail("Expected a local model selection")
            }
            XCTAssertEqual(agent, .codexExec)
            XCTAssertEqual(fixture.sessionA.selectedModelRaw, modelRaw)
            XCTAssertEqual(
                fixture.sessionA.selectedReasoningEffortRaw,
                CodexReasoningEffort.parse(effortRaw)?.rawValue
            )

            XCTAssertNotEqual(
                fixture.viewModel.ui.composer.focusRequest?.reason,
                .modelSelectionCommitted,
                "Calling the commit closure alone must not request composer focus."
            )

            // Through the HUD: success restores focus to the source composer.
            clearComposerFocusRequest(fixture)
            let hud = AgentModelSelectionHUDViewModel()
            hud.present(mode: .switchModel) {
                fixture.viewModel.makeModelSelectionHUDPresentation(
                    mode: .switchModel,
                    sourceTabID: fixture.tabAID,
                    windowID: fixture.window.windowID
                )
            }
            let hudLeaf = try XCTUnwrap(
                localCodexLeaf(in: hud.filteredLeaves, excludingModelRaw: fixture.sessionA.selectedModelRaw)
            )
            await hud.commit(hudLeaf)
            XCTAssertNil(hud.errorMessage)
            XCTAssertFalse(hud.isPresented)
            guard case let .local(_, hudModelRaw, _) = hudLeaf.commitPayload else {
                return XCTFail("Expected a local model selection")
            }
            XCTAssertEqual(fixture.sessionA.selectedModelRaw, hudModelRaw)
            let focusRequest = try XCTUnwrap(fixture.viewModel.ui.composer.focusRequest)
            XCTAssertEqual(focusRequest.tabID, fixture.tabAID)
            XCTAssertEqual(focusRequest.reason, .modelSelectionCommitted)

            // Through the HUD: a tab switch under an open picker rejects the commit without focus.
            let stalePresentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            XCTAssertNotNil(stalePresentation.onSuccessfulModelSelection)
            hud.present(mode: .switchModel) { stalePresentation }
            XCTAssertTrue(hud.isPresented)
            let staleLeaf = try XCTUnwrap(
                localCodexLeaf(in: hud.filteredLeaves, excludingModelRaw: fixture.sessionA.selectedModelRaw)
            )
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            clearComposerFocusRequest(fixture)
            await hud.commit(staleLeaf)
            XCTAssertTrue(hud.isPresented, "A rejected commit keeps the HUD open with its error.")
            XCTAssertEqual(
                hud.errorMessage,
                AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
            )
            XCTAssertEqual(fixture.sessionA.selectedModelRaw, hudModelRaw)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
            do {
                try await stalePresentation.commit(leaf)
                XCTFail("Expected a source-pinned presentation to reject tab drift")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
                )
            }
            hud.activeTabDidChange()
            XCTAssertFalse(hud.isPresented)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
        }
    }

    func testModelSelectionFocusCallbackRejectsSourceTabDriftAndShutdownFreeze() async throws {
        try await withFixture { fixture in
            fixture.sessionA.hasSentFirstMessage = false
            fixture.sessionA.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)
            configureHUDCodexProvider(fixture)
            fixture.sessionA.selectedAgent = .codexExec

            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            let focusCallback = try XCTUnwrap(presentation.onSuccessfulModelSelection)

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)
            clearComposerFocusRequest(fixture)
            focusCallback()
            XCTAssertNil(
                fixture.viewModel.ui.composer.focusRequest,
                "A source-pinned callback must not focus another tab's composer."
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabAID)
            clearComposerFocusRequest(fixture)
            let freezeID = UUID()
            fixture.viewModel.beginShutdownFreeze(requestID: freezeID, ownsRecoveryFreeze: false)
            XCTAssertTrue(fixture.viewModel.isShutdownFrozen)
            focusCallback()
            XCTAssertNil(
                fixture.viewModel.ui.composer.focusRequest,
                "A shutdown-frozen view model must not publish composer focus."
            )
            fixture.viewModel.endShutdownFreeze(requestID: freezeID)

            focusCallback()
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.reason, .modelSelectionCommitted)
        }
    }

    /// Lowest faithful layer for the shell receiver: the production `.activeComposeTabChanged`
    /// post drives `AgentHUDActiveTabChangeGate.handle`, the same handler the shell calls.
    /// The shell's SwiftUI `onReceive` subscription and the redraw-driven regression it replaced
    /// (the removed nested `onChange`) remain live-only; this test cannot detect either.
    func testActiveTabChangeSignalIsWindowScopedSynchronousAndAllowsFirstPressAfterSwitch() async throws {
        try await withFixture { fixture in
            configureHUDCodexProvider(fixture)
            for session in [fixture.sessionA, fixture.sessionB] {
                session.hasSentFirstMessage = false
                session.replaceItems([])
                fixture.viewModel.refreshDerivedTranscriptState(for: session)
                session.selectedAgent = .codexExec
                session.selectedModelRaw = AgentModel.defaultModel.rawValue
                session.selectedReasoningEffortRaw = nil
            }

            let windowID = fixture.window.windowID
            let promptManager = fixture.window.promptManager
            let navigationHUD = AgentNavigationHUDViewModel()
            let modelHUD = AgentModelSelectionHUDViewModel()
            let recorder = HUDActiveTabChangeRecorder()
            let observer = NotificationCenter.default.addObserver(
                forName: .activeComposeTabChanged,
                object: nil,
                queue: nil
            ) { note in
                let requestWindowID = note.userInfo?["windowID"] as? Int
                MainActor.assumeIsolated {
                    let matched = AgentHUDActiveTabChangeGate.handle(
                        requestWindowID: requestWindowID,
                        currentWindowID: windowID,
                        navigationHUD: navigationHUD,
                        modelSelectionHUD: modelHUD
                    )
                    recorder.deliveries.append(HUDActiveTabChangeRecorder.Delivery(
                        matched: matched,
                        storedActiveTabID: promptManager.activeComposeTabID,
                        navigationPresentedAfterDelivery: navigationHUD.isPresented,
                        modelPresentedAfterDelivery: modelHUD.isPresented
                    ))
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            XCTAssertFalse(AgentHUDActiveTabChangeGate.matches(requestWindowID: nil, currentWindowID: windowID))
            XCTAssertFalse(AgentHUDActiveTabChangeGate.matches(requestWindowID: windowID + 1, currentWindowID: windowID))
            XCTAssertTrue(AgentHUDActiveTabChangeGate.matches(requestWindowID: windowID, currentWindowID: windowID))

            navigationHUD.present(mode: .currentWindow, currentWindow: fixture.window)
            modelHUD.present(mode: .switchModel) {
                fixture.viewModel.makeModelSelectionHUDPresentation(
                    mode: .switchModel,
                    sourceTabID: fixture.tabAID,
                    windowID: windowID
                )
            }
            XCTAssertTrue(navigationHUD.isPresented)
            XCTAssertTrue(modelHUD.isPresented)

            // Foreign and unscoped events name the current tab so no production sink retargets.
            // No await separates these posts from the assertion, so no other fixture can interleave.
            NotificationCenter.default.post(
                name: .activeComposeTabChanged,
                object: nil,
                userInfo: ["tabID": fixture.tabAID, "windowID": windowID + 10000]
            )
            NotificationCenter.default.post(
                name: .activeComposeTabChanged,
                object: nil,
                userInfo: ["tabID": fixture.tabAID]
            )
            XCTAssertEqual(recorder.deliveries.map(\.matched), [false, false])
            XCTAssertTrue(navigationHUD.isPresented, "Another window's (or an unscoped) tab change must not dismiss.")
            XCTAssertTrue(modelHUD.isPresented, "Another window's (or an unscoped) tab change must not dismiss.")

            recorder.deliveries.removeAll()
            await promptManager.switchComposeTab(fixture.tabBID)
            // Other windows may post across the await; only this window's events count.
            XCTAssertEqual(
                recorder.deliveries.filter(\.matched),
                [HUDActiveTabChangeRecorder.Delivery(
                    matched: true,
                    storedActiveTabID: fixture.tabBID,
                    navigationPresentedAfterDelivery: false,
                    modelPresentedAfterDelivery: false
                )],
                "One window-scoped event, delivered after storage, dismisses both HUDs synchronously."
            )
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)

            // The first press after the switch presents for the new tab and commits with focus.
            clearComposerFocusRequest(fixture)
            modelHUD.present(mode: .switchModel) {
                fixture.viewModel.makeModelSelectionHUDPresentation(
                    mode: .switchModel,
                    sourceTabID: fixture.tabBID,
                    windowID: windowID
                )
            }
            XCTAssertTrue(modelHUD.isPresented, "One press after a session switch must open the picker.")
            XCTAssertNil(modelHUD.unavailableMessage)
            let leaf = try XCTUnwrap(
                localCodexLeaf(in: modelHUD.filteredLeaves, excludingModelRaw: fixture.sessionB.selectedModelRaw)
            )
            await modelHUD.commit(leaf)
            XCTAssertNil(modelHUD.errorMessage)
            XCTAssertFalse(modelHUD.isPresented)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.reason, .modelSelectionCommitted)
        }
    }

    func testModelSelectionHUDHandoffPresentationRoutesLastCompletedReply() async throws {
        try await withFixture { fixture in
            configureHUDCodexProvider(fixture)
            let expectedTargetID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )

            XCTAssertNil(presentation.unavailableMessage)
            XCTAssertTrue(presentation.noticeText?.contains("Target reply:") == true)
            XCTAssertNil(presentation.onSuccessfulModelSelection, "Handoff never restores source focus.")
            let hud = AgentModelSelectionHUDViewModel()
            hud.present(mode: .handoffLastReply) { presentation }
            let leafID = try XCTUnwrap(presentation.index.leaves.first?.id)
            let leaf = try XCTUnwrap(hud.filteredLeaves.first { $0.id == leafID })
            clearComposerFocusRequest(fixture)
            await hud.commit(leaf)
            XCTAssertNil(hud.errorMessage)
            XCTAssertFalse(hud.isPresented)
            XCTAssertNotEqual(
                fixture.viewModel.ui.composer.focusRequest?.reason,
                .modelSelectionCommitted,
                "Handoff must not publish a model-selection focus request."
            )

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            XCTAssertNotEqual(destinationTabID, fixture.tabAID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(destination.pendingHandoff.sourceItemID, expectedTargetID)
            XCTAssertEqual(destination.selectedAgent, .codexExec)
            XCTAssertEqual(destination.selectedModelRaw, AgentModel.defaultModel.rawValue)
        }
    }

    func testModelSelectionHUDHandoffPreservesOptionlessCodexSourceEffort() async throws {
        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            fixture.viewModel.test_setAvailableAgents([.codexExec])
            fixture.viewModel.test_setModelOptionsOverride(
                [
                    AgentModelOption(
                        rawValue: "gpt-5.4",
                        displayName: "GPT-5.4",
                        description: nil,
                        isDefault: false
                    )
                ],
                for: .codexExec
            )
            fixture.sessionA.selectedAgent = .codexExec
            fixture.sessionA.selectedModelRaw = "gpt-5.4"
            fixture.sessionA.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            let leaf = try XCTUnwrap(presentation.index.leaves.first)
            guard case let .local(_, _, effortRaw) = leaf.commitPayload else {
                return XCTFail("Expected a local Codex handoff leaf")
            }
            XCTAssertEqual(effortRaw, CodexReasoningEffort.high.rawValue)

            try await presentation.commit(leaf)

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(
                destination.selectedReasoningEffortRaw,
                CodexReasoningEffort.high.rawValue
            )
        }
    }

    func testModelSelectionHUDHandoffCommitFormatsStaleTargetFailure() async throws {
        try await withFixture { fixture in
            configureHUDCodexProvider(fixture)
            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            let leaf = try XCTUnwrap(presentation.index.leaves.first)

            fixture.sessionA.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "stale-hud-host",
                hostDisplayName: "Stale HUD Host",
                remoteSessionID: "stale-hud-session"
            )

            do {
                try await presentation.commit(leaf)
                XCTFail("Expected a stale handoff target to be rejected")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Handoff failed: The source session is no longer available."
                )
            }
        }
    }

    func testSourcePinnedHandoffConfigUsesOriginalTabAfterForegroundDrift() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))
            let resolved = fixture.viewModel.resolveLastReplyHandoffTarget(
                sourceTabID: fixture.tabAID
            )
            guard case let .target(target) = resolved else {
                return XCTFail("Expected the source transcript to resolve a handoff target")
            }
            XCTAssertEqual(target.clientRowID, cutoffItemID)

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: fixture.sessionA.selectedAgent,
                modelRaw: fixture.sessionA.selectedModelRaw,
                reasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )))

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            XCTAssertNotEqual(destinationTabID, fixture.tabBID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(destination.items.map(\.text), fixture.tabATexts)
            XCTAssertNotEqual(destination.items.map(\.text), fixture.tabBTexts)
            XCTAssertEqual(destination.pendingHandoff.sourceItemID, cutoffItemID)
        }
    }

    func testLocalHandoffPropagatesOMPThinkingOnlyToOMPDestinationSession() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))
            let ompModelRaw = "google-antigravity/gemini-3.7-flash"
            var thinking = OhMyPiThinkingSelections()
            thinking.setValue("high", for: ompModelRaw)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: .ohMyPi,
                modelRaw: ompModelRaw,
                reasoningEffortRaw: nil,
                ohMyPiThinkingSelections: thinking
            )))
            let ompTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let ompDestination = try XCTUnwrap(fixture.viewModel.sessions[ompTabID])
            XCTAssertEqual(ompDestination.selectedAgent, .ohMyPi)
            XCTAssertEqual(ompDestination.selectedModelRaw, ompModelRaw)
            XCTAssertEqual(ompDestination.ohMyPiThinkingSelections, thinking)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: .codexExec,
                modelRaw: "gpt-5.6-sol",
                reasoningEffortRaw: "high",
                ohMyPiThinkingSelections: thinking
            )))
            let codexTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let codexDestination = try XCTUnwrap(fixture.viewModel.sessions[codexTabID])
            XCTAssertEqual(codexDestination.selectedAgent, .codexExec)
            XCTAssertTrue(codexDestination.ohMyPiThinkingSelections.isEmpty)
        }
    }

    func testSourcePinnedHandoffConfigRejectsHostBindingDrift() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))

            fixture.sessionA.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "changed-host",
                hostDisplayName: "Changed Host",
                remoteSessionID: "changed-session"
            )
            defer { fixture.sessionA.remoteHost = nil }

            do {
                _ = try await config.buildPayloadForClipboard()
                XCTFail("Expected the pinned config to reject host drift")
            } catch AgentHandoffConfigurationError.sourceUnavailable {}
        }
    }

    func testHandoffRebindsComposerAndRejectsStaleSourceSubmitTarget() async throws {
        try await withFixture { fixture in
            let sourceTarget = try XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget)
            XCTAssertEqual(sourceTarget.tabID, fixture.tabAID)
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
            XCTAssertEqual(fixture.window.workspaceManager.activeAgentSessionID(forTabID: destinationTabID), destinationSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertTrue(destinationSession.pendingHandoff.hasPayload)
            XCTAssertEqual(destinationSession.pendingHandoff.sourceItemID, cutoffItemID)

            let composerProps = fixture.viewModel.ui.composer.props
            XCTAssertEqual(composerProps.currentTabID, destinationTabID)
            let destinationTarget = try XCTUnwrap(composerProps.submitTarget)
            XCTAssertEqual(destinationTarget.tabID, destinationTabID)
            XCTAssertEqual(destinationTarget.expectedSourceAgentSessionID, destinationSessionID)
            XCTAssertEqual(
                destinationTarget.expectedSourceTabSessionIdentity,
                ObjectIdentifier(destinationSession)
            )

            let staleAttempt = AgentComposerSubmitAttempt(
                id: UUID(),
                target: sourceTarget,
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "must not reach the source"
            )
            switch fixture.viewModel.claimComposerSubmitAttempt(staleAttempt) {
            case .claimed:
                XCTFail("The source composer target must not survive destination activation")
            case let .rejected(rejection):
                XCTAssertEqual(
                    rejection,
                    .targetRejected(reason: "inactive_composer_tab")
                )
            }
            XCTAssertNil(fixture.sessionA.activeComposerSubmitAttempt)
            XCTAssertEqual(fixture.viewModel.ui.composer.props.currentTabID, destinationTabID)

            let destinationAttempt = try AgentComposerSubmitAttempt(
                id: UUID(),
                target: XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget),
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "destination draft"
            )
            let destinationClaim: AgentModeViewModel.AgentComposerSubmitClaim
            switch fixture.viewModel.claimComposerSubmitAttempt(destinationAttempt) {
            case let .claimed(claim):
                destinationClaim = claim
            case let .rejected(rejection):
                return XCTFail("Expected destination composer recovery, got \(rejection)")
            }
            XCTAssertTrue(fixture.viewModel.releaseComposerSubmitClaim(destinationClaim))
            XCTAssertNotNil(fixture.viewModel.ui.composer.props.submitTarget)
        }
    }

    func testPrepareHandoffHeadlessKeepsForegroundTabAndStagesFullTranscriptPayload() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)

            // A pending scheduled send on the source must never travel with a handoff (plan §3.1).
            let sourceScheduleCreatedAt = Date()
            let sourceSchedule = AgentScheduledSendPersist(
                id: UUID(),
                createdAt: sourceScheduleCreatedAt,
                updatedAt: sourceScheduleCreatedAt,
                notBefore: sourceScheduleCreatedAt.addingTimeInterval(900),
                state: .scheduled,
                confirmationReason: nil,
                rawText: "scheduled on the source",
                attachments: [],
                taggedFileAttachments: [],
                workflow: nil,
                interviewFirst: false,
                isNewSessionStart: false,
                runAlongsideOtherSessions: false,
                firstEligibleAt: nil,
                attempt: nil,
                lastFailureMessage: nil
            )
            let sourceReceipt = AgentScheduledSendProvenance(
                scheduleID: UUID(),
                attemptID: UUID(),
                scheduledFor: sourceScheduleCreatedAt,
                sentAt: sourceScheduleCreatedAt
            )
            fixture.sessionA.scheduledSend = .v1(sourceSchedule)
            fixture.sessionA.lastScheduledDispatch = sourceReceipt

            let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)
            XCTAssertNotEqual(destinationTabID, fixture.tabBID)

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertNil(destinationSession.scheduledSend, "Handoff destinations never inherit a pending schedule")
            XCTAssertNil(destinationSession.lastScheduledDispatch, "Handoff destinations never inherit a dispatch receipt")
            XCTAssertNil(destinationSession.scheduledSendWorkspaceID)
            XCTAssertEqual(fixture.sessionA.scheduledSend, .v1(sourceSchedule), "The source keeps its own schedule")
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertNil(destinationSession.pendingHandoff.sourceItemID)
            let pendingPayload = try XCTUnwrap(destinationSession.pendingHandoff.payload)
            XCTAssertTrue(pendingPayload.hasPrefix("<forked_session"))

            let composed = fixture.viewModel.prependPendingHandoffIfNeeded(
                "continue from the fork",
                session: destinationSession
            )
            XCTAssertEqual(composed, pendingPayload + "\n\ncontinue from the fork")
        }
    }

    func testPrepareHandoffHeadlessPersistsDelegationParentOnlyWhenRequested() async throws {
        try await withFixture { fixture in
            let parentlessTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )
            let parentlessSession = try XCTUnwrap(fixture.viewModel.sessions[parentlessTabID])
            XCTAssertNil(parentlessSession.parentSessionID, "UI handoffs keep creating parentless destinations")

            let parentedTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw,
                delegationParentSessionID: fixture.sessionBID
            )
            let parentedSession = try XCTUnwrap(fixture.viewModel.sessions[parentedTabID])
            let parentedSessionID = try XCTUnwrap(parentedSession.activeAgentSessionID)
            XCTAssertEqual(parentedSession.parentSessionID, fixture.sessionBID)
            XCTAssertEqual(
                fixture.viewModel.mcpDelegationParentLookup(sessionID: parentedSessionID),
                .parent(fixture.sessionBID)
            )
            XCTAssertNil(fixture.sessionA.parentSessionID, "The fork source keeps its own lineage")
        }
    }

    func testPrepareHandoffHeadlessCommitCheckFailureClosesDestinationBeforeRecordingParent() async throws {
        try await withFixture { fixture in
            let workspaceTabIDsBefore = Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
            struct StaleLineage: Error {}
            var commitCheckCalls = 0
            do {
                _ = try await fixture.viewModel.prepareHandoffHeadless(
                    sourceTabID: fixture.tabAID,
                    upToItemID: nil,
                    destinationAgent: fixture.sessionA.selectedAgent,
                    destinationModelRaw: fixture.sessionA.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw,
                    delegationParentSessionID: fixture.sessionBID,
                    delegationCommitCheck: {
                        commitCheckCalls += 1
                        throw StaleLineage()
                    }
                )
                XCTFail("A failed delegation commit check must abort the fork")
            } catch is StaleLineage {}

            XCTAssertEqual(commitCheckCalls, 1)
            XCTAssertFalse(
                fixture.viewModel.sessions.values.contains { $0.parentSessionID == fixture.sessionBID },
                "No destination may be recorded under the delegation parent"
            )
            XCTAssertEqual(
                Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? []),
                workspaceTabIDsBefore,
                "The destination tab is closed when the commit check fails"
            )
        }
    }

    func testHandoffClonesOracleChatsIntoDestinationOwnershipAndPreservesFailClosedBoundaries() async throws {
        try await withFixture { fixture in
            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.id)
            let oracle = fixture.window.oracleViewModel
            let sourceRunID = UUID()
            let thirdPartySessionID = UUID()
            let primarySourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: fixture.sessionAID,
                agentModeRunID: sourceRunID,
                name: "Primary Handoff Oracle",
                messages: [
                    StoredMessage(isUser: true, rawText: "source question", sequenceIndex: 0),
                    StoredMessage(isUser: false, rawText: "source answer", sequenceIndex: 1)
                ]
            )
            let otherSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: fixture.sessionAID,
                agentModeRunID: sourceRunID,
                name: "Other Source Oracle",
                messages: [StoredMessage(isUser: false, rawText: "other source answer", sequenceIndex: 0)]
            )
            let unownedSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                name: "Unowned Source Oracle",
                messages: [
                    StoredMessage(
                        isUser: false,
                        rawText: "unowned source answer",
                        sequenceIndex: 0
                    )
                ]
            )
            let foreignSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: thirdPartySessionID,
                agentModeRunID: UUID(),
                name: "Foreign Source Oracle",
                messages: [
                    StoredMessage(
                        isUser: false,
                        rawText: "foreign source answer",
                        sequenceIndex: 0
                    )
                ]
            )
            let thirdPartyChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabBID,
                agentModeSessionID: thirdPartySessionID,
                agentModeRunID: UUID(),
                name: "Third Party Oracle",
                messages: [StoredMessage(isUser: false, rawText: "third party answer", sequenceIndex: 0)]
            )
            oracle.sessions = [
                primarySourceChat,
                otherSourceChat,
                unownedSourceChat,
                foreignSourceChat,
                thirdPartyChat
            ]
            fixture.window.workspaceManager.setActiveChatSessionID(
                primarySourceChat.id,
                forTabID: fixture.tabAID
            )

            let invocationID = UUID()
            let handoffModel = AIModel.claudeCodeSonnet
            let oracleArgs = #"{"chat_id":"\#(primarySourceChat.shortID)"}"#
            fixture.sessionA.setItemsSilently(
                [
                    .user("A user", sequenceIndex: 0),
                    .toolCall(
                        name: "ask_oracle",
                        invocationID: invocationID,
                        argsJSON: oracleArgs,
                        sequenceIndex: 1
                    ),
                    .toolResult(
                        name: "ask_oracle",
                        invocationID: invocationID,
                        argsJSON: oracleArgs,
                        resultJSON: #"{"chat_id":"\#(primarySourceChat.shortID)","model_source":"preset","ui_model_id":"\#(handoffModel.rawValue)","ui_model_name":"\#(handoffModel.displayName)","response":"source answer"}"#,
                        isError: false,
                        sequenceIndex: 2
                    ),
                    .assistant(
                        "Continue Oracle chat \(primarySourceChat.id.uuidString) from the surrounding prose.",
                        sequenceIndex: 3
                    )
                ],
                reason: .testOverride
            )
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)

            let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )
            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)

            let primaryClone = try XCTUnwrap(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID && $0.name == primarySourceChat.name
                }
            )
            let otherClone = try XCTUnwrap(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID && $0.name == otherSourceChat.name
                }
            )
            for clone in [primaryClone, otherClone] {
                XCTAssertEqual(clone.agentModeSessionID, destinationSessionID)
                XCTAssertNil(clone.agentModeRunID)
            }

            let payload = try XCTUnwrap(destinationSession.pendingHandoff.payload)
            XCTAssertTrue(
                payload.contains(
                    #"<tool_call name="ask_oracle">{"chat_id":"\#(primaryClone.shortID)"}"#
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "Continue Oracle chat \(primarySourceChat.id.uuidString) from the surrounding prose."
                )
            )
            XCTAssertTrue(payload.contains("<oracle_chat_id_mapping>"))
            XCTAssertFalse(payload.contains(handoffModel.rawValue), payload)
            XCTAssertFalse(payload.contains(handoffModel.displayName), payload)
            XCTAssertNil(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID
                        && $0.name == unownedSourceChat.name
                }
            )
            XCTAssertNil(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID
                        && $0.name == foreignSourceChat.name
                }
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(primarySourceChat.id.uuidString) | \(primaryClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(primarySourceChat.shortID) | \(primaryClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(otherSourceChat.id.uuidString) | \(otherClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(otherSourceChat.shortID) | \(otherClone.shortID) |"
                )
            )

            let destinationRunID = UUID()
            let continuedID = try await oracle.locateOrCreateChat(
                primaryClone.shortID,
                tabID: destinationTabID,
                activateInUI: false,
                agentModeSessionID: destinationSessionID,
                agentModeRunID: destinationRunID
            )
            XCTAssertEqual(continuedID, primaryClone.id)
            let continuedClone = try XCTUnwrap(
                oracle.sessions.first(where: { $0.id == primaryClone.id })
            )
            XCTAssertEqual(continuedClone.agentModeSessionID, destinationSessionID)
            XCTAssertEqual(continuedClone.agentModeRunID, destinationRunID)

            let log = try await oracle.tool_oracleChatLog(
                args: [
                    "chat_id": .string(primaryClone.shortID),
                    "include_user": .bool(true)
                ],
                tabID: destinationTabID,
                agentModeSessionID: destinationSessionID,
                agentModeRunID: destinationRunID
            )
            XCTAssertEqual(log["chat_id"]?.stringValue, primaryClone.shortID)
            let loggedTexts = log["messages"]?.arrayValue?.compactMap {
                $0.objectValue?["text"]?.stringValue
            }
            XCTAssertEqual(loggedTexts, ["source question", "source answer"])

            do {
                _ = try await oracle.locateOrCreateChat(
                    primarySourceChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected the old chat ID to remain invalid")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .invalidParams)
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(primaryClone.shortID))
            }

            do {
                _ = try await oracle.tool_oracleChatLog(
                    args: ["chat_id": .string(primarySourceChat.shortID)],
                    tabID: destinationTabID,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected oracle_chat_log to reject the old chat ID")
            } catch let error as ChatToolError {
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(primaryClone.shortID))
            }

            do {
                _ = try await oracle.locateOrCreateChat(
                    otherSourceChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected the source session's other old chat ID to remain invalid")
            } catch let error as ChatToolError {
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(otherClone.shortID))
            }

            for foreignSessionID in [fixture.sessionAID, thirdPartySessionID] {
                do {
                    _ = try await oracle.locateOrCreateChat(
                        otherClone.shortID,
                        tabID: destinationTabID,
                        activateInUI: false,
                        agentModeSessionID: foreignSessionID,
                        agentModeRunID: UUID()
                    )
                    XCTFail("Expected a foreign Agent Mode session to remain fail closed")
                } catch let error as ChatToolError {
                    XCTAssertTrue(error.message.contains("different Agent Mode owner"))
                    XCTAssertFalse(error.message.contains("was cloned during handoff"))
                }
            }

            for skippedSourceChat in [
                unownedSourceChat,
                foreignSourceChat
            ] {
                do {
                    _ = try await oracle.tool_oracleChatLog(
                        args: [
                            "chat_id": .string(skippedSourceChat.shortID),
                            "include_user": .bool(true)
                        ],
                        tabID: destinationTabID,
                        agentModeSessionID: destinationSessionID,
                        agentModeRunID: destinationRunID
                    )
                    XCTFail("Expected skipped source chat to remain unreadable")
                } catch let error as ChatToolError {
                    XCTAssertEqual(error.code, .invalidParams)
                    XCTAssertFalse(
                        error.message.contains("was cloned during handoff")
                    )
                }
            }

            do {
                _ = try await oracle.locateOrCreateChat(
                    thirdPartyChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected a third-party tab chat to remain fail closed")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .invalidParams)
                XCTAssertFalse(error.message.contains("was cloned during handoff"))
            }
        }
    }

    func testHandoffFailsAndRollsBackWhenAnyOwnedOracleCloneCannotPersist() async throws {
        try await withFixture { fixture in
            let workspaceID = try XCTUnwrap(
                fixture.window.workspaceManager.activeWorkspace?.id
            )
            let oracle = fixture.window.oracleViewModel
            let chats = ["First owned", "Second owned"].map { name in
                ChatSession(
                    workspaceID: workspaceID,
                    composeTabID: fixture.tabAID,
                    agentModeSessionID: fixture.sessionAID,
                    agentModeRunID: UUID(),
                    name: name,
                    messages: [
                        StoredMessage(
                            isUser: false,
                            rawText: "\(name) response",
                            sequenceIndex: 0
                        )
                    ]
                )
            }
            var persistedChats: [ChatSession] = []
            for var chat in chats {
                let url = try await oracle.autosaveSession(chat)
                chat.fileURL = url
                persistedChats.append(chat)
            }
            oracle.sessions = persistedChats
            var persistAttempts = 0
            oracle.setOracleCloneWillPersistObserverForTesting { _, _ in
                persistAttempts += 1
                if persistAttempts == 2 {
                    throw NSError(
                        domain: "OracleCloneFailure",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "injected clone failure"
                        ]
                    )
                }
            }
            defer {
                oracle.setOracleCloneWillPersistObserverForTesting(nil)
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffHeadless(
                    sourceTabID: fixture.tabAID,
                    upToItemID: nil,
                    destinationAgent: fixture.sessionA.selectedAgent,
                    destinationModelRaw: fixture.sessionA.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sessionA
                        .selectedReasoningEffortRaw
                )
                XCTFail("Expected handoff preparation to fail")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "no chats were cloned"
                    ),
                    error.localizedDescription
                )
            }

            XCTAssertEqual(persistAttempts, 2)
            XCTAssertEqual(Set(oracle.sessions.map(\.id)), Set(chats.map(\.id)))
            XCTAssertFalse(
                oracle.sessions.contains {
                    $0.agentModeSessionID != fixture.sessionAID
                }
            )
        }
    }

    func testColdLoadUIToolResultMergePrefersLivePayload() {
        let sharedID = UUID()
        let persistedOnlyID = UUID()
        let merged = AgentModeViewModel.mergeUIToolResultPayloads(
            live: [sharedID: "live identity"],
            persisted: [
                sharedID: "stale persisted identity",
                persistedOnlyID: "persisted identity"
            ]
        )

        XCTAssertEqual(merged[sharedID], "live identity")
        XCTAssertEqual(merged[persistedOnlyID], "persisted identity")
    }

    func testWarmSwitchPublishesDestinationTranscriptBeforeSwitchReturns() async throws {
        try await withFixture { fixture in
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testBackToBackWarmSwitchesPublishLatestDestination() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabAID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testWarmSwitchNotificationIsWindowScoped() async throws {
        try await withFixture { fixtureA in
            let initialPresentation = fixtureA.viewModel.activeTranscriptPresentation

            try await withFixture { fixtureB in
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)

                await fixtureB.window.promptManager.switchComposeTab(fixtureB.tabBID)

                XCTAssertEqual(fixtureB.window.promptManager.activeComposeTabID, fixtureB.tabBID)
                assertPresentation(
                    fixtureB.viewModel.activeTranscriptPresentation,
                    tabID: fixtureB.tabBID,
                    sessionID: fixtureB.sessionBID,
                    session: fixtureB.sessionB,
                    expectedTexts: fixtureB.tabBTexts
                )
                XCTAssertEqual(fixtureA.window.promptManager.activeComposeTabID, fixtureA.tabAID)
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)
                XCTAssertNil(fixtureA.viewModel.activeSessionLoadInProgressTabID)
            }
        }
    }

    // MARK: - D6 runtime selection (full sync reads the current owner's canonical selection)

    func testFullSyncProjectsCurrentOwnerCanonicalExplicitSlicedAndZeroSelection() async throws {
        try await withFixture { fixture in
            let explicit = StoredSelection(
                selectedPaths: ["Sources/Full.swift", "Sources/Sliced.swift"],
                slices: [
                    "Sources/Sliced.swift": [LineRange(start: 4, end: 8)],
                    "Sources/SliceOnly.swift": [LineRange(start: 1, end: 2), LineRange(start: 10, end: 12)]
                ],
                codemapAutoEnabled: false
            )
            let explicitSummary = AgentContextExportResolver.selectionSummary(for: explicit)
            XCTAssertEqual(explicitSummary.totalExplicitFileCount, 3)
            XCTAssertGreaterThan(explicitSummary.slicedFileCount, 0)

            try setCanonicalSelection(explicit, forTabID: fixture.tabAID, in: fixture)
            fixture.viewModel.syncAllActiveUIState()
            var snapshot = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot
            XCTAssertEqual(snapshot.selectionSummary, explicitSummary)
            XCTAssertEqual(snapshot.selectionFileCount, 3)

            // A canonical zero selection is a real value, not "unknown".
            try setCanonicalSelection(StoredSelection(), forTabID: fixture.tabAID, in: fixture)
            fixture.viewModel.syncAllActiveUIState()
            snapshot = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot
            XCTAssertEqual(
                snapshot.selectionSummary,
                AgentContextExportResolver.selectionSummary(for: StoredSelection())
            )
            XCTAssertEqual(snapshot.selectionFileCount, 0)
        }
    }

    func testFullSyncOwnerDisagreementAndMidSwitchSyncDoNotLeakPreviousSelection() async throws {
        try await withFixture { fixture in
            let workspaceManager = fixture.window.workspaceManager
            let selectionA = StoredSelection(
                selectedPaths: ["Sources/A0.swift", "Sources/A1.swift", "Sources/A2.swift"],
                codemapAutoEnabled: false
            )
            let summaryA = AgentContextExportResolver.selectionSummary(for: selectionA)
            try setCanonicalSelection(selectionA, forTabID: fixture.tabAID, in: fixture)
            fixture.viewModel.syncAllActiveUIState()
            XCTAssertEqual(fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.selectionSummary, summaryA)

            // Workspace explicit active tab disagrees with the Agent owner: no canonical A summary.
            let workspaceIndex = try XCTUnwrap(
                workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceManager.activeWorkspace?.id })
            )
            workspaceManager.workspaces[workspaceIndex].activeComposeTabID = fixture.tabBID
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabAID)
            fixture.viewModel.syncAllActiveUIState()
            var snapshot = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot
            XCTAssertNil(snapshot.selectionSummary)
            // This fixture has no tool-derived selection metrics; those may legitimately supply
            // a count when the live canonical summary is unavailable.
            XCTAssertNil(snapshot.selectionFileCount)
            workspaceManager.workspaces[workspaceIndex].activeComposeTabID = fixture.tabAID

            // Real A→B switch: a full sync mid-apply and the final sync never surface A's counts.
            try setCanonicalSelection(
                StoredSelection(selectedPaths: ["Sources/B0.swift"], codemapAutoEnabled: false),
                forTabID: fixture.tabBID,
                in: fixture
            )
            var midApplySummaries: [AgentContextSelectionSummary?] = []
            workspaceManager.composeTabApplyAfterContextHookForTesting = { tabID in
                guard tabID == fixture.tabBID else { return }
                fixture.viewModel.syncAllActiveUIState()
                midApplySummaries.append(fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.selectionSummary)
            }
            defer { workspaceManager.composeTabApplyAfterContextHookForTesting = nil }

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            XCTAssertEqual(midApplySummaries.count, 1)
            XCTAssertNotEqual(midApplySummaries.first ?? nil, summaryA)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)
            let workspaceID = try XCTUnwrap(workspaceManager.activeWorkspace?.id)
            let canonicalB = try XCTUnwrap(
                workspaceManager.composeTab(
                    for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabBID)
                )
            ).selection
            snapshot = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot
            XCTAssertNotEqual(snapshot.selectionSummary, summaryA)
            XCTAssertEqual(snapshot.selectionSummary, AgentContextExportResolver.selectionSummary(for: canonicalB))
        }
    }

    private func setCanonicalSelection(_ selection: StoredSelection, forTabID tabID: UUID, in fixture: Fixture) throws {
        let workspaceManager = fixture.window.workspaceManager
        let workspaceIndex = try XCTUnwrap(
            workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceManager.activeWorkspace?.id })
        )
        let tabIndex = try XCTUnwrap(
            workspaceManager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tabID })
        )
        workspaceManager.workspaces[workspaceIndex].composeTabs[tabIndex].selection = selection
    }

    // MARK: - D6 cold activation provider stamp (real store, foreground switch)

    #if DEBUG
        /// A foreground cold activation of a persisted completed OpenCode session, from an unseeded
        /// placeholder holding the warm tab's different provider, stamps hydration with the normalized
        /// persisted provider. The activation catch-up then sees only the run-state delta and takes the
        /// guarded run-state-only final-turn import, installing output equal to a full cold reference.
        /// Hydration is held until the switch's own save flush has run, as in the persisted-run-state
        /// variants, so that save always follows the observation; a save that lands first is covered by
        /// `testSaveBeforeActivationCatchUpReconcilesOnlyGeneratedToolSummaries`.
        func testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let observed = try await observeColdActivationCatchUp(
                    persistedRunState: .completed,
                    in: fixture,
                    holdsHydrationUntilSwitchSettles: true
                )
                let session = observed.session
                XCTAssertEqual(observed.persisted.agentKind, AgentProviderKind.openCode.rawValue)
                XCTAssertEqual(observed.persisted.lastRunState, AgentSessionRunState.completed.rawValue)
                XCTAssertEqual(session.persistedLoadDisposition, .applied)

                XCTAssertEqual(observed.catchUps.count, 1)
                let catchUp = try XCTUnwrap(observed.catchUps.first)
                XCTAssertEqual(catchUp.reason, AgentDerivedTranscriptRefreshReason.liveMutation.rawValue)
                XCTAssertEqual(catchUp.stamp?.selectedAgent, .openCode, "Hydration stamps the normalized persisted provider")
                XCTAssertEqual(catchUp.stamp?.runState, .idle, "Run state is still installed after the stamp")
                XCTAssertEqual(catchUp.delta, "syncDelta.run")
                XCTAssertEqual(catchUp.path, "incremental-success:no-frontier")
                XCTAssertEqual(session.transcriptPerformanceSnapshot.incrementalImportAttemptCount - catchUp.attempts, 1)
                XCTAssertEqual(session.transcriptPerformanceSnapshot.incrementalImportSuccessCount - catchUp.successes, 1)

                // Sync: the catch-up leaves a reusable stamp for the completed state.
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.runState, .completed)
                XCTAssertEqual(session.derivedTranscriptSyncState, coldCatchUpSyncState(of: session, in: viewModel))
                let protection = viewModel.transcriptProjectionProtection(for: session, transcript: session.transcript)
                XCTAssertTrue(viewModel.canReuseDerivedTranscriptForSave(for: session, projectionProtection: protection))

                // Integrity: the hydrated items are the stored record; output equals a cold full reference.
                XCTAssertEqual(session.items, observed.persistedItems)
                let reference = observed.reference
                XCTAssertEqual(session.transcript, reference.transcript)
                XCTAssertEqual(session.baseTranscriptProjection, reference.baseProjection)
                XCTAssertEqual(session.fullTranscriptProjection, reference.fullProjection)
                XCTAssertEqual(session.workingTranscriptProjection, reference.workingProjection)
                XCTAssertEqual(session.transcriptProjectionCounts, reference.projectionCounts)
                XCTAssertEqual(session.transcriptCanonicalVisibleRowCount, reference.canonicalVisibleRowCount)
                XCTAssertEqual(session.transcriptAnalyticsSnapshot, reference.analyticsSnapshot)

                // The hydrated state the catch-up replaced already equaled that reference.
                XCTAssertEqual(observed.transcriptBeforeCatchUp, reference.transcript)
                XCTAssertEqual(observed.baseProjectionBeforeCatchUp, reference.baseProjection)
            }
        }

        /// A foreground save that runs after real persisted hydration but before the activation
        /// catch-up (the race the observation tests hold off) reconciles working items from the
        /// sanitized presentation. Judged against the original stored record: IDs, order, kinds,
        /// user/assistant text, and tool associations are unchanged, the only in-memory difference is
        /// dropping storage-generated `"<tool> • <status>"` summary text from summary-only bash
        /// payloads, and the written file restores it, so the durable items equal the input. A later
        /// activation then installs output equal to a cold reference built from the original input.
        func testSaveBeforeActivationCatchUpReconcilesOnlyGeneratedToolSummaries() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let window = fixture.window
                let storageURL = fixture.rootURL.appendingPathComponent("SessionStore", isDirectory: true)
                try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
                var storeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                storeWorkspace.customStoragePath = storageURL
                viewModel.test_persistenceWorkspaceOverride = storeWorkspace
                // Automatic debounce and maximum-wait saves stay held; only the explicit save runs.
                // Every held sleep is ended explicitly when the test finishes, after its timer task is
                // cancelled, so no held debounce save runs late.
                let heldSaveTimers = HeldSaveTimers()
                viewModel.test_saveTimerSleepOverride = { _, _ in try await heldSaveTimers.sleep() }
                defer {
                    for owner in viewModel.sessions.values {
                        viewModel.cancelTranscriptSaveTimers(owner)
                    }
                    heldSaveTimers.cancelAll()
                    viewModel.test_persistenceWorkspaceOverride = nil
                    viewModel.test_saveTimerSleepOverride = nil
                    viewModel.test_saveSessionBeforeWriteHook = nil
                    viewModel.test_setCurrentTabIDOverride(nil)
                }

                // The same multi-turn completed OpenCode record the observation tests use.
                let writer = AgentModeViewModel(
                    testWindowID: 4492,
                    testWorkspacePath: storageURL.path,
                    testWorkspaceDirectory: storageURL,
                    codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
                )
                writer.test_establishPersistenceWorkspace(storeWorkspace)
                // The writer's automatic saves are held too; only its explicit flush writes the record.
                writer.test_saveTimerSleepOverride = { _, _ in try await heldSaveTimers.sleep() }
                let writerTabID = UUID()
                writer.test_setCurrentTabIDOverride(writerTabID)
                let written = try await writer.ensureSessionReady(tabID: writerTabID)
                written.selectedAgent = .openCode
                for turn in 0 ..< 3 {
                    let invocation = UUID()
                    written.appendItem(.user("Turn \(turn) request"))
                    written.appendItem(.toolCall(name: "bash", invocationID: invocation, argsJSON: "{\"command\":\"echo \(turn)\"}"))
                    written.appendItem(.toolResult(name: "bash", invocationID: invocation, resultJSON: "{\"output\":\"\(turn)\"}"))
                    written.appendItem(.assistant("Turn \(turn) reply"))
                }
                written.runState = .completed
                let saved = await writer.flushSave(for: writerTabID)
                XCTAssertTrue(saved)
                let sessionID = try XCTUnwrap(written.activeAgentSessionID)
                await writer.prepareForWindowClose()
                // Window close keeps a pending debounce; retire the writer's timers so none can write
                // the file under test later (its held sleeps end with the others at cleanup).
                for owner in writer.sessions.values {
                    writer.cancelTranscriptSaveTimers(owner)
                }
                XCTAssertTrue(writer.sessions.values.allSatisfy { $0.saveDebounceTask == nil && $0.transcriptSaveMaxWaitTask == nil })
                writer.test_saveTimerSleepOverride = nil
                let loadedInput = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: storeWorkspace)
                let input = try XCTUnwrap(loadedInput)
                let inputItems = try AgentTranscriptIO.workingSourceItems(from: XCTUnwrap(input.transcript))
                let fileURL = try XCTUnwrap(input.fileURL)

                // Real persisted hydration of a background-materialized tab, without activation.
                let tabID = UUID()
                let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == storeWorkspace.id })
                window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                    ComposeTabState(id: tabID, name: "Cold", activeAgentSessionID: sessionID)
                )
                window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex])
                let session = try materializeUnpresentable(tabID, in: fixture)
                let request = AgentSessionHydrationRequest(
                    workspace: storeWorkspace,
                    tabID: tabID,
                    sessionID: sessionID,
                    resolvedDisplayName: "Cold",
                    hasPendingQuestionUI: false,
                    transcriptViewportState: .liveBottom,
                    isCompressedHistoryRevealed: false,
                    initialPerformanceSnapshot: .empty
                )
                let preparedPayload = try await viewModel.test_dataService.preparePersistedHydration(request)
                let payload = try XCTUnwrap(preparedPayload)
                let didHydrate = await viewModel.test_applyPersistedHydration(payload, to: session)
                XCTAssertTrue(didHydrate)
                // Foreground ownership only: no switch, presentation, or catch-up.
                viewModel.test_setCurrentTabIDOverride(tabID)

                // Precondition: hydrated items are the stored record, and the catch-up is still owed.
                XCTAssertEqual(session.items, inputItems)
                XCTAssertNotEqual(session.derivedTranscriptSyncState, coldCatchUpSyncState(of: session, in: viewModel))

                let revisionBeforeSave = session.sourceItemsRevision
                var itemsAtWrite: [AgentChatItem]?
                var revisionAtWrite: Int?
                viewModel.test_saveSessionBeforeWriteHook = { saving in
                    guard saving === session else { return }
                    itemsAtWrite = saving.items
                    revisionAtWrite = saving.sourceItemsRevision
                }
                session.isDirty = true
                let outcome = await viewModel.flushSaveDetailed(for: tabID)
                guard case .written = outcome else {
                    return XCTFail("The foreground save must write, got \(outcome)")
                }
                let memoryItems = try XCTUnwrap(itemsAtWrite)
                XCTAssertGreaterThan(try XCTUnwrap(revisionAtWrite), revisionBeforeSave, "The save reconciled working items before writing")

                // Memory: only generated summaries of summary-only tool payloads may differ.
                let memoryDifferences = Self.itemDifferencesBeyondGeneratedToolSummaries(from: inputItems, to: memoryItems)
                XCTAssertEqual(memoryDifferences, [], memoryDifferences.joined(separator: "\n"))
                XCTAssertEqual(session.items, memoryItems)

                // Durable: the written record, decoded read-only, restores the original items exactly.
                let durable = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: fileURL))
                XCTAssertEqual(durable.id, sessionID)
                XCTAssertEqual(durable.lastRunState, AgentSessionRunState.completed.rawValue)
                let durableItems = try AgentTranscriptIO.workingSourceItems(from: XCTUnwrap(durable.transcript))
                let durableDifferences = Self.itemDifferencesBeyondGeneratedToolSummaries(from: inputItems, to: durableItems, allowGeneratedSummaryRemoval: false)
                XCTAssertEqual(durableDifferences, [], durableDifferences.joined(separator: "\n"))

                // Activation after the save: the real foreground switch catches the tab up, and its
                // output equals a cold reference built from the ORIGINAL stored items.
                viewModel.test_setCurrentTabIDOverride(nil)
                XCTAssertNotEqual(viewModel.currentTabID, tabID)
                await window.promptManager.switchComposeTab(tabID)
                try await Self.waitUntil {
                    viewModel.currentTabID == tabID && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()
                XCTAssertTrue(viewModel.sessions[tabID] === session, "Activation reuses the hydrated owner")
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.runState, .completed)
                XCTAssertEqual(session.derivedTranscriptSyncState, coldCatchUpSyncState(of: session, in: viewModel))
                XCTAssertEqual(session.items, memoryItems, "Activation does not change the reconciled items")
                let protection = viewModel.transcriptProjectionProtection(for: session, transcript: session.transcript)
                let rebuiltFromInput = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: AgentTranscript(),
                    workingItems: inputItems,
                    terminalState: .completed,
                    nextSequenceIndex: session.nextSequenceIndex,
                    policy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI),
                    protection: protection
                )
                let reference = AgentModeViewModel.buildTranscriptPresentation(
                    from: rebuiltFromInput,
                    sourceItems: inputItems,
                    selectedAgent: .openCode,
                    previousPerformanceSnapshot: .empty,
                    projectionProtection: protection,
                    isColdLoad: true
                )
                XCTAssertEqual(session.transcript, reference.transcript)
                XCTAssertEqual(session.baseTranscriptProjection, reference.baseProjection)
                XCTAssertEqual(session.fullTranscriptProjection, reference.fullProjection)
                XCTAssertEqual(session.workingTranscriptProjection, reference.workingProjection)
                XCTAssertEqual(session.transcriptProjectionCounts, reference.projectionCounts)
                XCTAssertEqual(session.transcriptCanonicalVisibleRowCount, reference.canonicalVisibleRowCount)
                XCTAssertEqual(session.transcriptAnalyticsSnapshot, reference.analyticsSnapshot)
            }
        }

        /// Exact per-field differences between two item lists over their Codable encoding. When
        /// `allowGeneratedSummaryRemoval` is set, a JSON-object field may differ only by dropping a
        /// `summary_text` equal to the storage-generated `"<toolName> • <status>"` string.
        private static func itemDifferencesBeyondGeneratedToolSummaries(
            from input: [AgentChatItem],
            to output: [AgentChatItem],
            allowGeneratedSummaryRemoval: Bool = true
        ) -> [String] {
            var differences: [String] = []
            if input.map(\.id) != output.map(\.id) {
                differences.append("ids/order: \(input.map(\.id)) => \(output.map(\.id))")
                return differences
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for (before, after) in zip(input, output) {
                guard let beforeData = try? encoder.encode(before), let afterData = try? encoder.encode(after),
                      let beforeObject = (try? JSONSerialization.jsonObject(with: beforeData)) as? [String: Any],
                      let afterObject = (try? JSONSerialization.jsonObject(with: afterData)) as? [String: Any]
                else {
                    differences.append("\(before.id): not encodable")
                    continue
                }
                for key in Set(beforeObject.keys).union(afterObject.keys).sorted() {
                    let beforeValue = beforeObject[key]
                    let afterValue = afterObject[key]
                    if let beforeValue, let afterValue, (beforeValue as AnyObject).isEqual(afterValue) { continue }
                    if allowGeneratedSummaryRemoval,
                       isGeneratedSummaryRemoval(beforeValue, afterValue, toolName: before.toolName)
                    {
                        continue
                    }
                    differences.append("\(before.id) \(before.kind) .\(key): \(String(describing: beforeValue)) => \(String(describing: afterValue))")
                }
            }
            return differences
        }

        private static func isGeneratedSummaryRemoval(_ before: Any?, _ after: Any?, toolName: String?) -> Bool {
            guard let toolName,
                  let beforeText = before as? String, let afterText = after as? String,
                  var beforeObject = (try? JSONSerialization.jsonObject(with: Data(beforeText.utf8))) as? [String: Any],
                  let afterObject = (try? JSONSerialization.jsonObject(with: Data(afterText.utf8))) as? [String: Any],
                  beforeObject["summary_only"] as? Bool == true,
                  let status = beforeObject["status"] as? String,
                  beforeObject["summary_text"] as? String == "\(toolName) • \(status)",
                  afterObject["summary_text"] == nil
            else { return false }
            beforeObject.removeValue(forKey: "summary_text")
            return NSDictionary(dictionary: beforeObject).isEqual(to: afterObject)
        }

        /// These cancelled/failed fixtures take one run-state-only catch-up. It leaves the hydrated
        /// transcript and base projection unchanged but is not a no-op: it reconciles the hydrated source
        /// items to the sanitized transcript's working items. The active-state fixture is saved with run
        /// state running while its final turn's last tool call has no result (interrupted mid-tool). Cold
        /// activation preserves its cancelled turn/span, unlike a fresh import at the restored idle state,
        /// and so does the reload-migration save that follows it, whose pending-tool repair turns that call
        /// row into a result in place: in memory, in the saved bytes, and after a reload. The target's hydration is held
        /// until the switch's own save flush has run, so that save always follows the observation, and
        /// the test then flushes it explicitly.
        func testColdActivationCatchUpAcrossPersistedRunStates() async throws {
            for persistedRunState in [AgentSessionRunState.cancelled, .failed, .running] {
                try await withFixture { fixture in
                    let viewModel = fixture.viewModel
                    defer { viewModel.test_persistenceWorkspaceOverride = nil }
                    let observed = try await observeColdActivationCatchUp(
                        persistedRunState: persistedRunState,
                        in: fixture,
                        holdsHydrationUntilSwitchSettles: true,
                        endsWithUnmatchedToolCall: persistedRunState.isActive
                    )
                    let session = observed.session
                    let label = persistedRunState.rawValue
                    XCTAssertEqual(session.persistedLoadDisposition, .applied, label)
                    XCTAssertEqual(session.derivedTranscriptSyncState, coldCatchUpSyncState(of: session, in: viewModel), label)
                    if persistedRunState.isActive {
                        // F-7: the writer's same-launch read keeps the saved active run; the cold
                        // activation below still loads it as idle.
                        XCTAssertEqual(observed.persisted.lastRunState, persistedRunState.rawValue, "\(label): a same-launch read keeps the saved run")
                        XCTAssertEqual(session.runState, .idle, label)
                        XCTAssertTrue(observed.catchUps.isEmpty, "\(label): no observed run-state catch-up")
                        XCTAssertNil(session.derivedTranscriptRefreshTask, label)
                        XCTAssertNil(session.pendingDerivedTranscriptRefreshReason, label)
                        XCTAssertNotEqual(session.transcript, observed.reference.transcript, "\(label): an idle rebuild is not an integrity reference for cold cancellation")
                        let lastTurn = try XCTUnwrap(session.transcript.turns.last)
                        XCTAssertEqual(lastTurn.terminalState, .cancelled, "\(label): the interrupted turn stays cancelled")
                        XCTAssertEqual(lastTurn.responseSpans.map(\.lifecycle), [.cancelled], label)
                        try await assertColdCancelledTurnSurvivesReloadMigrationSave(
                            observed,
                            cancelledTurnID: lastTurn.id,
                            viewModel: viewModel,
                            label: label
                        )
                    } else {
                        XCTAssertEqual(observed.persisted.lastRunState, persistedRunState.rawValue, label)
                        XCTAssertEqual(session.runState, persistedRunState, label)
                        // Hydration installs the load-normalized record's items; the catch-up then reconciles them to
                        // the working items of the sanitized transcript (`.retentionCompaction`), changing only
                        // tool-result rows. Completed sessions are excluded from that reconciliation.
                        XCTAssertEqual(observed.itemsBeforeCatchUp, observed.persistedItems, "\(label): hydrated items are the load-normalized record")
                        XCTAssertEqual(session.items.map(\.id), observed.persistedItems.map(\.id), label)
                        XCTAssertEqual(session.items, AgentTranscriptIO.workingSourceItems(from: session.transcript), label)
                        let reconciled = zip(observed.persistedItems, session.items).filter { $0 != $1 }
                        XCTAssertFalse(reconciled.isEmpty, "\(label): catch-up reconciles hydrated source items")
                        XCTAssertTrue(reconciled.allSatisfy { $0.0.kind == .toolResult }, label)
                        XCTAssertEqual(observed.catchUps.map(\.reason), [AgentDerivedTranscriptRefreshReason.liveMutation.rawValue], label)
                        XCTAssertEqual(observed.catchUps.first?.stamp?.selectedAgent, .openCode, label)
                        XCTAssertEqual(observed.catchUps.first?.stamp?.runState, .idle, label)
                        XCTAssertEqual(session.baseTranscriptProjection, observed.reference.baseProjection, label)
                        XCTAssertEqual(session.fullTranscriptProjection, observed.reference.fullProjection, label)
                        XCTAssertEqual(observed.catchUps.map(\.delta), ["syncDelta.run"], label)
                        XCTAssertEqual(observed.catchUps.map(\.path), ["incremental-success:no-frontier"], label)
                        XCTAssertEqual(observed.transcriptBeforeCatchUp, observed.reference.transcript, "\(label): hydrated transcript already final")
                        XCTAssertEqual(observed.baseProjectionBeforeCatchUp, observed.reference.baseProjection, label)
                        XCTAssertEqual(session.transcript, observed.reference.transcript, label)
                        await viewModel.flushSave(for: session.tabID)
                        XCTAssertEqual(session.transcript, observed.reference.transcript, "\(label): unchanged by a save")
                    }
                }
            }
        }

        /// Flushes the cold target's pending reload-migration save, then asserts that the cancelled turn
        /// and span survive in memory, in the saved file's bytes, and through a reload.
        private func assertColdCancelledTurnSurvivesReloadMigrationSave(
            _ observed: ColdActivationCatchUpObservation,
            cancelledTurnID: UUID,
            viewModel: AgentModeViewModel,
            label: String
        ) async throws {
            let session = observed.session
            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            XCTAssertTrue(session.isDirty, "\(label): the reload-migration save is pending, not yet run")
            let unmatchedCall = try XCTUnwrap(session.items.last, label)
            XCTAssertEqual(unmatchedCall.kind, .toolCall, "\(label): the turn still ends in the unmatched call before the save")
            // The cold load's own normalizing write may still be in flight (F-7: the writer's
            // same-launch read no longer pre-normalizes the file); settle it so this explicit flush is
            // not deferred behind it.
            await viewModel.awaitInFlightSave(sessionID: sessionID)
            let outcome = await viewModel.flushSaveDetailed(for: session.tabID)
            await viewModel.awaitInFlightSave(sessionID: sessionID)
            XCTAssertTrue(outcome.isCleanSuccess, "\(label): the reload-migration save wrote (\(outcome))")
            XCTAssertFalse(session.isDirty, label)
            XCTAssertEqual(session.runState, .idle, label)
            let repairedCall = try XCTUnwrap(session.items.last, label)
            XCTAssertEqual(repairedCall.id, unmatchedCall.id, label)
            XCTAssertEqual(repairedCall.kind, .toolResult, "\(label): the save's pending-tool repair converted the call in place")

            func assertCancelled(_ transcript: AgentTranscript?, _ stage: String) throws {
                let turn = try XCTUnwrap(transcript?.turns.last, "\(label) \(stage)")
                XCTAssertEqual(turn.id, cancelledTurnID, "\(label) \(stage)")
                XCTAssertEqual(turn.terminalState, .cancelled, "\(label) \(stage): the interrupted turn stays cancelled")
                XCTAssertEqual(turn.responseSpans.map(\.lifecycle), [.cancelled], "\(label) \(stage)")
            }
            try assertCancelled(session.transcript, "in memory after save")

            let fileURL = try XCTUnwrap(observed.persisted.fileURL)
            let savedSession = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(savedSession.id, sessionID, label)
            XCTAssertEqual(savedSession.lastRunState, AgentSessionRunState.idle.rawValue, label)
            try assertCancelled(savedSession.transcript, "saved bytes")

            let workspace = try XCTUnwrap(viewModel.test_persistenceWorkspaceOverride)
            let reloaded = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace)
            XCTAssertEqual(reloaded?.lastRunState, AgentSessionRunState.idle.rawValue, label)
            try assertCancelled(reloaded?.transcript, "reloaded")
        }

        private struct ColdActivationCatchUpAttempt {
            let reason: String
            let path: String
            let stamp: AgentDerivedTranscriptSyncState?
            let delta: String
            let attempts: Int
            let successes: Int
        }

        private struct ColdActivationCatchUpObservation {
            let session: AgentTabSession
            let persisted: AgentSession
            let persistedItems: [AgentChatItem]
            let catchUps: [ColdActivationCatchUpAttempt]
            /// The target's hydrated state while the (last) catch-up import is computed but not installed.
            let transcriptBeforeCatchUp: AgentTranscript?
            let baseProjectionBeforeCatchUp: AgentTranscriptProjection?
            let itemsBeforeCatchUp: [AgentChatItem]?
            /// Reimports final items at the restored run state. This is not an integrity reference
            /// for cold-cancelled turns whose session-level run state has normalized to idle.
            let reference: AgentBuiltTranscriptPresentation
        }

        private func coldCatchUpSyncState(
            of session: AgentTabSession,
            in viewModel: AgentModeViewModel
        ) -> AgentDerivedTranscriptSyncState {
            AgentDerivedTranscriptSyncState(
                sourceItemsRevision: session.sourceItemsRevision,
                nextSequenceIndex: session.nextSequenceIndex,
                runState: session.runState,
                selectedAgent: session.selectedAgent,
                hidePendingQuestionToolCall: session.hasPendingQuestionUI,
                projectionProtection: viewModel.transcriptProjectionProtection(for: session, transcript: session.transcript)
            )
        }

        /// Persists a multi-turn OpenCode session at `persistedRunState` through a separate writer to
        /// the real store, then cold-activates it in a new unseeded tab whose placeholder holds the warm
        /// tab's different provider. Sets `test_persistenceWorkspaceOverride`; callers reset it.
        private func observeColdActivationCatchUp(
            persistedRunState: AgentSessionRunState,
            in fixture: Fixture,
            holdsHydrationUntilSwitchSettles: Bool = false,
            endsWithUnmatchedToolCall: Bool = false
        ) async throws -> ColdActivationCatchUpObservation {
            let viewModel = fixture.viewModel
            let window = fixture.window
            let storageURL = fixture.rootURL.appendingPathComponent("SessionStore", isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            var storeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            storeWorkspace.customStoragePath = storageURL
            viewModel.test_persistenceWorkspaceOverride = storeWorkspace
            do {
                // A separate writer persists the multi-turn OpenCode session to the real store.
                let writer = AgentModeViewModel(
                    testWindowID: 4490,
                    testWorkspacePath: storageURL.path,
                    testWorkspaceDirectory: storageURL,
                    codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
                )
                writer.test_establishPersistenceWorkspace(storeWorkspace)
                let writerTabID = UUID()
                writer.test_setCurrentTabIDOverride(writerTabID)
                let written = try await writer.ensureSessionReady(tabID: writerTabID)
                written.selectedAgent = .openCode
                for turn in 0 ..< 3 {
                    let invocation = UUID()
                    written.appendItem(.user("Turn \(turn) request"))
                    written.appendItem(.toolCall(name: "bash", invocationID: invocation, argsJSON: "{\"command\":\"echo \(turn)\"}"))
                    written.appendItem(.toolResult(name: "bash", invocationID: invocation, resultJSON: "{\"output\":\"\(turn)\"}"))
                    written.appendItem(.assistant("Turn \(turn) reply"))
                }
                if endsWithUnmatchedToolCall {
                    // Interrupted mid-tool: the final turn's last call has no result.
                    written.appendItem(.toolCall(name: "bash", invocationID: UUID(), argsJSON: "{\"command\":\"sleep 60\"}"))
                }
                written.runState = persistedRunState
                let saved = await writer.flushSave(for: writerTabID)
                XCTAssertTrue(saved)
                let sessionID = try XCTUnwrap(written.activeAgentSessionID)
                let loaded = try await writer.test_dataService.loadAgentSession(id: sessionID, for: storeWorkspace)
                let persisted = try XCTUnwrap(loaded)
                let persistedItems = try AgentTranscriptIO.workingSourceItems(from: XCTUnwrap(persisted.transcript))
                XCTAssertEqual(persistedItems.map(\.id), written.items.map(\.id))

                // Unseeded cold target; its placeholder inherits the warm tab's different provider.
                let tabID = UUID()
                let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == storeWorkspace.id })
                window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                    ComposeTabState(id: tabID, name: "Cold", activeAgentSessionID: sessionID)
                )
                window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex])
                XCTAssertNotEqual(viewModel.selectedAgent, .openCode)
                XCTAssertNil(viewModel.ownerValidatedSessionIndex[sessionID])
                XCTAssertNil(viewModel.sessions[tabID])

                // Read-only: the target's state while the catch-up import is computed but not installed.
                var catchUps: [ColdActivationCatchUpAttempt] = []
                var hydratedTranscriptBeforeCatchUp: AgentTranscript?
                var hydratedBaseProjectionBeforeCatchUp: AgentTranscriptProjection?
                var hydratedItemsBeforeCatchUp: [AgentChatItem]?
                AgentTranscriptDebugInstrumentation.reset()
                AgentTranscriptDebugInstrumentation.isEnabled = true
                AgentTranscriptDebugInstrumentation.refreshAttemptHandler = { metrics in
                    MainActor.assumeIsolated {
                        guard viewModel.currentTabID == tabID, let target = viewModel.sessions[tabID],
                              target.sourceItemsRevision == metrics.sourceItemsRevision
                        else { return }
                        hydratedTranscriptBeforeCatchUp = target.transcript
                        hydratedBaseProjectionBeforeCatchUp = target.baseTranscriptProjection
                        hydratedItemsBeforeCatchUp = target.items
                        let stamp = target.derivedTranscriptSyncState
                        let delta = AgentDerivedTranscriptSyncState.diagnosticDeltaLabel(
                            from: stamp,
                            to: self.coldCatchUpSyncState(of: target, in: viewModel)
                        )
                        let performance = target.transcriptPerformanceSnapshot
                        catchUps.append(.init(
                            reason: metrics.reason,
                            path: metrics.incrementalPath,
                            stamp: stamp,
                            delta: delta,
                            attempts: performance.incrementalImportAttemptCount,
                            successes: performance.incrementalImportSuccessCount
                        ))
                    }
                }
                defer { AgentTranscriptDebugInstrumentation.reset() }

                // Optionally holds the prepared payload before install until the switch's workspace
                // save has flushed the (still unloaded) target, so that flush cannot save the target.
                let hydrationGate = ColdLoadGate()
                defer { hydrationGate.release() }
                if holdsHydrationUntilSwitchSettles {
                    viewModel.test_persistedLoadPrepareHook = { held in
                        guard held.tabID == tabID else { return }
                        await hydrationGate.waitForRelease()
                    }
                }
                defer { viewModel.test_persistedLoadPrepareHook = nil }

                await window.promptManager.switchComposeTab(tabID)
                if holdsHydrationUntilSwitchSettles {
                    try await Self.waitUntil { hydrationGate.isWaiting }
                    await Self.drainMainQueue()
                    XCTAssertFalse(try XCTUnwrap(viewModel.sessions[tabID]).hasLoadedPersistedState)
                    hydrationGate.release()
                }
                let session = try XCTUnwrap(viewModel.sessions[tabID])
                let deadline = Date().addingTimeInterval(20)
                while viewModel.activeSessionLoadInProgressTabID != nil || !session.hasLoadedPersistedState, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                await Self.drainMainQueue()

                let protection = viewModel.transcriptProjectionProtection(for: session, transcript: session.transcript)
                let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: AgentTranscript(),
                    workingItems: session.items,
                    terminalState: session.runState,
                    nextSequenceIndex: session.nextSequenceIndex,
                    policy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI),
                    protection: protection
                )
                let reference = AgentModeViewModel.buildTranscriptPresentation(
                    from: rebuilt,
                    sourceItems: session.items,
                    selectedAgent: .openCode,
                    previousPerformanceSnapshot: .empty,
                    projectionProtection: protection,
                    isColdLoad: true
                )
                return ColdActivationCatchUpObservation(
                    session: session,
                    persisted: persisted,
                    persistedItems: persistedItems,
                    catchUps: catchUps,
                    transcriptBeforeCatchUp: hydratedTranscriptBeforeCatchUp,
                    baseProjectionBeforeCatchUp: hydratedBaseProjectionBeforeCatchUp,
                    itemsBeforeCatchUp: hydratedItemsBeforeCatchUp,
                    reference: reference
                )
            }
        }

        // MARK: - D6 cold-loading UI publication

        /// A foreground switch from a hydrated tab to an already-materialized, unpresentable persisted
        /// tab publishes exactly one target loading snapshot to the transcript UI store before the
        /// persisted load completes, then the hydrated target.
        func testColdActivationPublishesOneLoadingSnapshotBeforeHydration() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)
                XCTAssertEqual(viewModel.currentTabID, fixture.tabAID)
                XCTAssertTrue(viewModel.ui.transcript.snapshot.isHydrated)
                let previousRevision = viewModel.activeTranscriptPresentation.revision

                let gate = ColdLoadGate()
                defer { gate.release() }
                viewModel.test_persistedLoadBeforePrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    await gate.waitForRelease()
                }
                defer { viewModel.test_persistedLoadBeforePrepareHook = nil }
                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                await Self.drainMainQueue()
                XCTAssertTrue(viewModel.sessions[cold.tabID] === session)
                XCTAssertFalse(session.hasLoadedPersistedState)

                let loading = emissions.filter { $0.currentTabID == cold.tabID }
                XCTAssertEqual(loading.count, 1, "One target loading publication before the persisted load completes")
                let snapshot = try XCTUnwrap(loading.first)
                XCTAssertEqual(snapshot.presentation.tabID, cold.tabID)
                XCTAssertFalse(snapshot.isHydrated)
                XCTAssertFalse(snapshot.presentation.bindingsHydrated)
                XCTAssertEqual(snapshot.presentationRevision, previousRevision &+ 1)
                XCTAssertEqual(snapshot.activeSessionLoadInProgressTabID, cold.tabID)
                XCTAssertTrue(snapshot.presentation.visibleRows.isEmpty)
                XCTAssertTrue(snapshot.presentation.workingRows.isEmpty)
                XCTAssertEqual(viewModel.ui.transcript.snapshot, snapshot)
                assertDefaultFollowAndQuietViewNormalization(
                    snapshot,
                    tabID: cold.tabID,
                    viewModel: viewModel,
                    emissionCount: { emissions.count }
                )

                gate.release()
                try await Self.waitUntil {
                    session.hasLoadedPersistedState && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()
                XCTAssertEqual(session.persistedLoadDisposition, .applied)
                let hydrated = viewModel.ui.transcript.snapshot
                XCTAssertEqual(hydrated.currentTabID, cold.tabID)
                XCTAssertTrue(hydrated.isHydrated)
                XCTAssertNil(hydrated.activeSessionLoadInProgressTabID)
                assertPresentation(
                    hydrated.presentation,
                    tabID: cold.tabID,
                    sessionID: cold.sessionID,
                    session: session,
                    expectedTexts: cold.texts
                )
                XCTAssertFalse(emissions.contains { snapshot in
                    snapshot.currentTabID == cold.tabID
                        && snapshot.presentation.visibleRows.contains { fixture.tabATexts.contains($0.text) }
                }, "The target never shows the previous tab's rows")
            }
        }

        /// A pre-materialized cold destination with a non-default (detached, disarmed) follow state
        /// carries that exact state in its single loading snapshot; the view's legitimate activation
        /// reset to live-bottom/armed still mutates the session and publishes, without hydrating.
        func testColdActivationLoadingSnapshotCarriesDetachedFollowAndViewResetPublishes() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)
                viewModel.setTranscriptDetachedFromLiveBottom(
                    tabID: cold.tabID,
                    isDetached: true,
                    armingState: .disarmedAfterManualDetach
                )
                let detached = AgentModeViewModel.ActiveTranscriptFollowBindingState(
                    tabID: cold.tabID,
                    viewportState: session.transcriptViewportState,
                    armingState: session.transcriptAutoFollowArmingState
                )
                XCTAssertTrue(detached.viewportState.isDetachedFromLiveBottom)
                XCTAssertEqual(detached.armingState, .disarmedAfterManualDetach)
                XCTAssertEqual(viewModel.ui.transcript.snapshot.currentTabID, fixture.tabAID)

                let gate = ColdLoadGate()
                defer { gate.release() }
                viewModel.test_persistedLoadBeforePrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    await gate.waitForRelease()
                }
                defer { viewModel.test_persistedLoadBeforePrepareHook = nil }
                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                await Self.drainMainQueue()
                let loading = emissions.filter { $0.currentTabID == cold.tabID }
                XCTAssertEqual(loading.count, 1)
                let snapshot = try XCTUnwrap(loading.first)
                XCTAssertFalse(snapshot.isHydrated)
                XCTAssertEqual(snapshot.followBindingState, detached, "The loading snapshot preserves the destination's follow state")

                let beforeReset = emissions.count
                viewModel.normalizeTranscriptFollowStateForViewActivation(tabID: cold.tabID)
                XCTAssertEqual(session.transcriptViewportState, .liveBottom)
                XCTAssertEqual(session.transcriptAutoFollowArmingState, .armed)
                XCTAssertEqual(emissions.count, beforeReset + 1, "The legitimate view reset publishes once")
                let reset = viewModel.ui.transcript.snapshot
                XCTAssertEqual(
                    reset.followBindingState,
                    AgentModeViewModel.ActiveTranscriptFollowBindingState(tabID: cold.tabID, viewportState: .liveBottom, armingState: .armed)
                )
                XCTAssertFalse(reset.isHydrated, "Follow alignment is not hydration")

                gate.release()
                try await Self.waitUntil {
                    session.hasLoadedPersistedState && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()
                let hydrated = viewModel.ui.transcript.snapshot
                XCTAssertTrue(hydrated.isHydrated)
                XCTAssertEqual(
                    hydrated.followBindingState,
                    AgentModeViewModel.ActiveTranscriptFollowBindingState(tabID: cold.tabID, viewportState: .liveBottom, armingState: .armed)
                )
                assertPresentation(
                    hydrated.presentation,
                    tabID: cold.tabID,
                    sessionID: cold.sessionID,
                    session: session,
                    expectedTexts: cold.texts
                )
            }
        }

        /// The DEBUG cold-timing markers follow the activation/prepare boundaries: outer task markers
        /// appear while the before-prepare gate is held, and after release the will-await, service
        /// entry, successful payload, and did-resume markers appear in order before the after-prepare hook.
        func testColdActivationTimingMarkersFollowGateOrder() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)
                let previousOverride = WorkspaceRestorePerfLog.debugProcessOverrideEnabled
                WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(true)
                defer { WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(previousOverride) }
                // The metrics buffer is process-global with no restore API: clear it for this test and
                // filter by this test's cold tab ID.
                WorkspaceRestorePerfLog.clearRecentMetricLines()

                let markerNames = [
                    "agentMode.activation.coldTaskWillCreate",
                    "agentMode.activation.coldTaskEntered",
                    "agentSessionHydration.prepareWillAwait",
                    "agentSessionHydration.prepareEntered",
                    "agentSessionHydration.prepare",
                    "agentSessionHydration.prepareDidResume"
                ]
                let tabField = "tabID=\(WorkspaceRestorePerfLog.shortID(cold.tabID))"
                func coldEvents() -> [(name: String, fields: [String: String])] {
                    WorkspaceRestorePerfLog.recentMetricLinesSnapshot(limit: 2000).compactMap { line in
                        let tokens = line.split(separator: " ").map(String.init)
                        guard tokens.count > 1, markerNames.contains(tokens[1]), tokens.contains(tabField) else {
                            return nil
                        }
                        var fields: [String: String] = [:]
                        for token in tokens.dropFirst(2) {
                            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                            if pair.count == 2 { fields[pair[0]] = pair[1] }
                        }
                        return (tokens[1], fields)
                    }
                }
                func coldMarkers() -> [String] {
                    coldEvents().map { event in
                        event.name == "agentSessionHydration.prepare"
                            ? "\(event.name):outcome=\(event.fields["outcome"] ?? "")"
                            : event.name
                    }
                }

                let gate = ColdLoadGate()
                defer { gate.release() }
                viewModel.test_persistedLoadBeforePrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    await gate.waitForRelease()
                }
                defer { viewModel.test_persistedLoadBeforePrepareHook = nil }
                var markersAtAfterHook: [String]?
                viewModel.test_persistedLoadPrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    markersAtAfterHook = coldMarkers()
                }
                defer { viewModel.test_persistedLoadPrepareHook = nil }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                await Self.drainMainQueue()
                XCTAssertEqual(
                    coldMarkers(),
                    ["agentMode.activation.coldTaskWillCreate", "agentMode.activation.coldTaskEntered"],
                    "Outer markers only while the before-prepare gate is held"
                )

                gate.release()
                try await Self.waitUntil {
                    session.hasLoadedPersistedState && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()
                let expected = [
                    "agentMode.activation.coldTaskWillCreate",
                    "agentMode.activation.coldTaskEntered",
                    "agentSessionHydration.prepareWillAwait",
                    "agentSessionHydration.prepareEntered",
                    "agentSessionHydration.prepare:outcome=payload",
                    "agentSessionHydration.prepareDidResume"
                ]
                XCTAssertEqual(markersAtAfterHook, expected, "did-resume precedes the after-prepare hook")
                XCTAssertEqual(coldMarkers(), expected)
                XCTAssertTrue(viewModel.ui.transcript.snapshot.isHydrated)

                let events = coldEvents()
                XCTAssertEqual(events.count, expected.count)
                func fields(_ name: String) -> [String: String] {
                    events.first { $0.name == name }?.fields ?? [:]
                }
                let willCreate = fields("agentMode.activation.coldTaskWillCreate")
                let entered = fields("agentMode.activation.coldTaskEntered")
                let willAwait = fields("agentSessionHydration.prepareWillAwait")
                let didResume = fields("agentSessionHydration.prepareDidResume")
                let activationGeneration = try XCTUnwrap(willCreate["activationGeneration"])
                XCTAssertFalse(activationGeneration.isEmpty)
                XCTAssertEqual(entered["activationGeneration"], activationGeneration, "Outer events share the captured generation")
                let loadAttemptID = try XCTUnwrap(willAwait["loadAttemptID"])
                XCTAssertFalse(loadAttemptID.isEmpty)
                XCTAssertNotEqual(loadAttemptID, "nil")
                XCTAssertEqual(didResume["loadAttemptID"], loadAttemptID, "Await/resume share the load attempt")
                let transitionGeneration = try XCTUnwrap(willAwait["transitionGeneration"])
                XCTAssertFalse(transitionGeneration.isEmpty)
                XCTAssertEqual(didResume["transitionGeneration"], transitionGeneration)
                XCTAssertEqual(didResume["payload"], "present")
                let targetSessionID = WorkspaceRestorePerfLog.shortID(cold.sessionID)
                for event in events {
                    XCTAssertEqual(event.fields["sessionID"], targetSessionID, "\(event.name) carries the target session")
                }
            }
        }

        /// A foreground switch to an unseeded persisted tab materializes and binds its session during
        /// activation; the binding notification and sidebar publication land before the transcript UI
        /// store publishes exactly one target loading snapshot, followed by the hydrated target.
        func testUnseededColdActivationPublishesOneLoadingSnapshotAfterMaterialization() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let previousRevision = viewModel.activeTranscriptPresentation.revision

                let gate = ColdLoadGate()
                defer { gate.release() }
                viewModel.test_persistedLoadBeforePrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    await gate.waitForRelease()
                }
                defer { viewModel.test_persistedLoadBeforePrepareHook = nil }
                var events: [String] = []
                var emissions: [AgentTranscriptUISnapshot] = []
                let transcriptSubscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated {
                        emissions.append(snapshot)
                        if snapshot.currentTabID == cold.tabID { events.append("transcript") }
                    }
                }
                let sidebarSubscription = viewModel.ui.sessionSidebar.$snapshot.dropFirst().sink { _ in
                    // The sidebar snapshot carries no binding fields; only publications observed
                    // after the VM registered the cold tab bound to the cold session count.
                    MainActor.assumeIsolated {
                        if viewModel.sessions[cold.tabID]?.activeAgentSessionID == cold.sessionID {
                            events.append("sidebar")
                        }
                    }
                }
                let bindingSubscription = NotificationCenter.default
                    .publisher(for: .agentSessionBindingDidChange, object: viewModel)
                    .sink { notification in
                        let tabID = notification.userInfo?["tabID"] as? UUID
                        let sessionID = notification.userInfo?["sessionID"] as? UUID
                        MainActor.assumeIsolated {
                            if tabID == cold.tabID, sessionID == cold.sessionID { events.append("binding") }
                        }
                    }
                defer {
                    transcriptSubscription.cancel()
                    sidebarSubscription.cancel()
                    bindingSubscription.cancel()
                }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                await Self.drainMainQueue()
                let session = try XCTUnwrap(viewModel.sessions[cold.tabID], "Activation materializes the target")
                XCTAssertEqual(session.activeAgentSessionID, cold.sessionID)
                XCTAssertFalse(session.hasLoadedPersistedState)

                XCTAssertEqual(events.count { $0 == "transcript" }, 1, "One target loading publication before the persisted load completes")
                let flushIndex = try XCTUnwrap(events.firstIndex(of: "transcript"))
                XCTAssertTrue(events[..<flushIndex].contains("binding"), "Binding installed before the transcript publication")
                XCTAssertTrue(events[..<flushIndex].contains("sidebar"), "Sidebar publication after bound-session registration, before the transcript publication")
                let snapshot = try XCTUnwrap(emissions.first { $0.currentTabID == cold.tabID })
                XCTAssertEqual(snapshot.presentation.tabID, cold.tabID)
                XCTAssertFalse(snapshot.isHydrated)
                XCTAssertFalse(snapshot.presentation.bindingsHydrated)
                XCTAssertEqual(snapshot.presentationRevision, previousRevision &+ 1)
                XCTAssertEqual(snapshot.activeSessionLoadInProgressTabID, cold.tabID)
                XCTAssertTrue(snapshot.presentation.visibleRows.isEmpty)
                XCTAssertTrue(snapshot.presentation.workingRows.isEmpty)
                XCTAssertEqual(viewModel.ui.transcript.snapshot, snapshot)
                assertDefaultFollowAndQuietViewNormalization(
                    snapshot,
                    tabID: cold.tabID,
                    viewModel: viewModel,
                    emissionCount: { emissions.count }
                )

                gate.release()
                try await Self.waitUntil {
                    session.hasLoadedPersistedState && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()
                XCTAssertEqual(session.persistedLoadDisposition, .applied)
                let hydrated = viewModel.ui.transcript.snapshot
                XCTAssertEqual(hydrated.currentTabID, cold.tabID)
                XCTAssertTrue(hydrated.isHydrated)
                XCTAssertNil(hydrated.activeSessionLoadInProgressTabID)
                assertPresentation(
                    hydrated.presentation,
                    tabID: cold.tabID,
                    sessionID: cold.sessionID,
                    session: session,
                    expectedTexts: cold.texts
                )
                XCTAssertFalse(emissions.contains { snapshot in
                    snapshot.currentTabID == cold.tabID
                        && snapshot.presentation.visibleRows.contains { fixture.tabATexts.contains($0.text) }
                }, "The target never shows the previous tab's rows")
            }
        }

        /// After a rapid switch away from a still-loading unseeded cold target, the target's delayed
        /// load never republishes its loading or hydrated state over the newer destination.
        func testColdActivationStaleLoadCannotRepublishAfterRapidSwitch() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }

                let gate = ColdLoadGate()
                defer { gate.release() }
                viewModel.test_persistedLoadBeforePrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    await gate.waitForRelease()
                }
                defer { viewModel.test_persistedLoadBeforePrepareHook = nil }
                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                let session = try XCTUnwrap(viewModel.sessions[cold.tabID])
                XCTAssertEqual(emissions.count { $0.currentTabID == cold.tabID }, 1)

                await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
                let destinationStart = emissions.count
                // The inactive cold tab's normalization neither mutates nor publishes.
                viewModel.normalizeTranscriptFollowStateForViewActivation(tabID: cold.tabID)
                XCTAssertEqual(emissions.count, destinationStart)
                gate.release()
                try await Self.waitUntil { session.hasLoadedPersistedState }
                await Self.drainMainQueue()

                XCTAssertEqual(session.persistedLoadDisposition, .applied)
                XCTAssertFalse(emissions[destinationStart...].contains { snapshot in
                    snapshot.currentTabID == cold.tabID
                        || snapshot.presentation.tabID == cold.tabID
                        || snapshot.activeSessionLoadInProgressTabID == cold.tabID
                        || snapshot.followBindingState.tabID == cold.tabID
                }, "The stale cold load never republishes after the newer switch")
                let destination = viewModel.ui.transcript.snapshot
                XCTAssertEqual(destination.currentTabID, fixture.tabBID)
                XCTAssertEqual(
                    destination.followBindingState,
                    AgentModeViewModel.ActiveTranscriptFollowBindingState(
                        tabID: fixture.tabBID,
                        viewportState: fixture.sessionB.transcriptViewportState,
                        armingState: fixture.sessionB.transcriptAutoFollowArmingState
                    ),
                    "The warm destination's follow state survives the late cold completion"
                )
                XCTAssertTrue(destination.isHydrated)
                XCTAssertNil(destination.activeSessionLoadInProgressTabID)
                assertPresentation(
                    destination.presentation,
                    tabID: fixture.tabBID,
                    sessionID: fixture.sessionBID,
                    session: fixture.sessionB,
                    expectedTexts: fixture.tabBTexts
                )
            }
        }

        /// Without the before-prepare seam, cold activation requests its preparation from the
        /// synchronous load start (before the activation task hop). The owning operation adopts that
        /// one prepare: exactly one service entry and payload for the attempt, the outer activation
        /// task awaits the same operation, and the hydrated target is identical to the ordinary path.
        func testColdActivationEarlyPrepareIsAdoptedOnceByOwningOperation() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)
                let previousOverride = WorkspaceRestorePerfLog.debugProcessOverrideEnabled
                WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(true)
                defer { WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(previousOverride) }
                WorkspaceRestorePerfLog.clearRecentMetricLines()
                XCTAssertNil(viewModel.test_persistedLoadBeforePrepareHook)

                var afterHookCount = 0
                viewModel.test_persistedLoadPrepareHook = { held in
                    guard held.tabID == cold.tabID else { return }
                    afterHookCount += 1
                }
                defer { viewModel.test_persistedLoadPrepareHook = nil }
                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil {
                    session.hasLoadedPersistedState && viewModel.activeSessionLoadInProgressTabID == nil
                }
                await Self.drainMainQueue()

                // The early start leaves activation publication unchanged: exactly one destination
                // loading snapshot precedes the hydrated destination.
                let destinationEmissions = emissions.filter { $0.currentTabID == cold.tabID }
                let firstHydratedIndex = try XCTUnwrap(
                    destinationEmissions.firstIndex { $0.isHydrated },
                    "The destination publishes its hydrated snapshot"
                )
                let loadingEmissions = destinationEmissions[..<firstHydratedIndex]
                XCTAssertEqual(loadingEmissions.count, 1, "One destination loading publication before hydration")
                let loading = try XCTUnwrap(loadingEmissions.first)
                XCTAssertFalse(loading.isHydrated)
                XCTAssertFalse(loading.presentation.bindingsHydrated)
                XCTAssertEqual(loading.presentation.tabID, cold.tabID)
                XCTAssertEqual(loading.activeSessionLoadInProgressTabID, cold.tabID)
                XCTAssertTrue(loading.presentation.visibleRows.isEmpty)
                XCTAssertTrue(loading.presentation.workingRows.isEmpty)

                let events = Self.coldHydrationEvents(tabID: cold.tabID)
                let names = events.map(\.name)
                for name in [
                    "agentMode.activation.coldTaskWillCreate",
                    "agentMode.activation.coldTaskEntered",
                    "agentSessionHydration.prepareWillAwait",
                    "agentSessionHydration.prepareEntered",
                    "agentSessionHydration.prepare",
                    "agentSessionHydration.prepareDidResume"
                ] {
                    XCTAssertEqual(names.count { $0 == name }, 1, "\(name) occurs once for the single load operation")
                }
                func index(_ name: String) throws -> Int {
                    try XCTUnwrap(names.firstIndex(of: name), name)
                }
                XCTAssertLessThan(try index("agentMode.activation.coldTaskWillCreate"), try index("agentSessionHydration.prepareEntered"))
                XCTAssertLessThan(try index("agentMode.activation.coldTaskWillCreate"), try index("agentMode.activation.coldTaskEntered"))
                XCTAssertLessThan(try index("agentSessionHydration.prepareEntered"), try index("agentSessionHydration.prepare"))
                XCTAssertLessThan(try index("agentSessionHydration.prepare"), try index("agentSessionHydration.prepareDidResume"))
                XCTAssertLessThan(try index("agentSessionHydration.prepareWillAwait"), try index("agentSessionHydration.prepareDidResume"))
                let prepare = try XCTUnwrap(events.first { $0.name == "agentSessionHydration.prepare" })
                XCTAssertEqual(prepare.fields["outcome"], "payload")
                let willAwait = try XCTUnwrap(events.first { $0.name == "agentSessionHydration.prepareWillAwait" })
                XCTAssertEqual(willAwait.fields["earlyPrepare"], "adopted", "The operation adopts the early prepare")
                let didResume = try XCTUnwrap(events.first { $0.name == "agentSessionHydration.prepareDidResume" })
                XCTAssertEqual(didResume.fields["loadAttemptID"], willAwait.fields["loadAttemptID"])
                XCTAssertEqual(didResume.fields["payload"], "present")

                XCTAssertEqual(afterHookCount, 1, "One prepared payload reaches the operation's post-prepare fences")
                XCTAssertEqual(session.persistedLoadDisposition, .applied)
                XCTAssertNil(session.persistedLoadTask, "The creating activation task cleared its own handle")
                let hydrated = viewModel.ui.transcript.snapshot
                XCTAssertEqual(hydrated.currentTabID, cold.tabID)
                XCTAssertTrue(hydrated.isHydrated)
                assertPresentation(
                    hydrated.presentation,
                    tabID: cold.tabID,
                    sessionID: cold.sessionID,
                    session: session,
                    expectedTexts: cold.texts
                )
            }
        }

        /// Persisted adoption makes the destination presentable before its activation commits the
        /// binding. An urgent session refresh landing in that window (the apply-edits approval
        /// stream's path) keeps the destination's loading presentation; the authoritative commit
        /// then publishes hydrated rows with the latest approval state, and refreshes after that
        /// commit apply even while the load marker is still set.
        func testColdLoadUrgentRefreshBeforeBindingCommitKeepsLoadingPresentation() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let session = fixture.sessionA
                let tabID = fixture.tabAID
                await Self.drainMainQueue()
                XCTAssertEqual(viewModel.currentTabID, tabID)
                viewModel.applySessionToBindings(session)
                viewModel.test_setActiveSessionLoadInProgressTabID(nil)
                assertPresentation(
                    viewModel.ui.transcript.snapshot.presentation,
                    tabID: tabID,
                    sessionID: fixture.sessionAID,
                    session: session,
                    expectedTexts: fixture.tabATexts
                )

                // The post-adoption, pre-commit state of a cold activation: the session is loaded
                // and presentable, its binding is not marked hydrated, and the destination shows
                // its loading presentation under the load marker.
                session.clearCurrentBindingHydration()
                viewModel.test_setActiveSessionLoadInProgressTabID(tabID)
                viewModel.test_publishLoadingTranscriptPresentation(tabID: tabID)
                XCTAssertTrue(session.hasLoadedPersistedState)
                XCTAssertTrue(session.isPresentableForOwner)
                XCTAssertNil(session.authoritativeHydratedBindingTransitionGeneration)
                XCTAssertTrue(viewModel.canBuildOrPublishActiveTranscriptBindings(for: session))
                let loading = viewModel.ui.transcript.snapshot
                XCTAssertEqual(loading.currentTabID, tabID)
                XCTAssertEqual(loading.activeSessionLoadInProgressTabID, tabID)
                XCTAssertFalse(loading.isHydrated)
                XCTAssertTrue(loading.presentation.visibleRows.isEmpty)

                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                // An approval model update (auto-edit plus a pending review and its reconciled wait
                // state, as the approval stream applies them) followed by its urgent refresh.
                let heldAutoEdit = !session.autoEditEnabled
                session.autoEditEnabled = heldAutoEdit
                let heldReview = PendingApplyEditsReview(
                    scope: viewModel.applyEditsScope(for: tabID),
                    path: "held.swift",
                    unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
                )
                session.pendingApplyEditsReview = heldReview
                defer {
                    session.pendingApplyEditsReview = nil
                    session.runState = .idle
                }
                viewModel.reconcileInteractiveRunState(session)
                XCTAssertEqual(session.runState, .waitingForApproval)
                let updateCountBeforeHeldRefresh = viewModel.test_updateBindingsCallCount
                viewModel.requestUIRefresh(tabID: tabID, urgent: true)
                XCTAssertEqual(
                    viewModel.test_updateBindingsCallCount,
                    updateCountBeforeHeldRefresh + 1,
                    "The urgent refresh reaches the session binding update"
                )
                XCTAssertFalse(
                    emissions.contains { !$0.presentation.visibleRows.isEmpty || !$0.presentation.workingRows.isEmpty },
                    "No destination rows are published before the binding commit"
                )
                let held = viewModel.ui.transcript.snapshot
                XCTAssertEqual(held.currentTabID, tabID)
                XCTAssertFalse(held.isHydrated)
                XCTAssertFalse(held.presentation.bindingsHydrated)
                XCTAssertTrue(held.presentation.visibleRows.isEmpty)
                XCTAssertTrue(held.presentation.workingRows.isEmpty)
                XCTAssertEqual(session.autoEditEnabled, heldAutoEdit, "The session keeps the approval update")
                XCTAssertEqual(session.pendingApplyEditsReview, heldReview)
                XCTAssertNil(viewModel.ui.runInteraction.snapshot.pendingApplyEditsReview, "The held refresh publishes no review")
                XCTAssertNotEqual(viewModel.ui.runInteraction.snapshot.runState, .waitingForApproval)

                // The authoritative commit, in the cold activation's order: bindings, then marker.
                viewModel.applySessionToBindings(session)
                let committed = viewModel.ui.transcript.snapshot
                XCTAssertTrue(committed.isHydrated)
                assertPresentation(
                    committed.presentation,
                    tabID: tabID,
                    sessionID: fixture.sessionAID,
                    session: session,
                    expectedTexts: fixture.tabATexts
                )
                XCTAssertEqual(viewModel.autoEditEnabled, heldAutoEdit, "The commit consumes the held approval state")
                XCTAssertEqual(viewModel.pendingApplyEditsReview, heldReview)
                XCTAssertEqual(viewModel.runState, .waitingForApproval)
                XCTAssertEqual(viewModel.ui.runInteraction.snapshot.pendingApplyEditsReview, heldReview)
                XCTAssertEqual(viewModel.ui.runInteraction.snapshot.runState, .waitingForApproval)
                let firstRowsIndex = try XCTUnwrap(emissions.firstIndex { !$0.presentation.visibleRows.isEmpty })
                XCTAssertTrue(emissions[firstRowsIndex].isHydrated, "The first row-bearing destination snapshot is hydrated")

                // A refresh after the commit applies even while the marker is still set.
                let postCommitAutoEdit = !heldAutoEdit
                session.autoEditEnabled = postCommitAutoEdit
                let updateCountBeforePostCommitRefresh = viewModel.test_updateBindingsCallCount
                viewModel.requestUIRefresh(tabID: tabID, urgent: true)
                XCTAssertEqual(viewModel.test_updateBindingsCallCount, updateCountBeforePostCommitRefresh + 1)
                XCTAssertEqual(viewModel.autoEditEnabled, postCommitAutoEdit, "Post-commit refreshes are not held")
                XCTAssertTrue(viewModel.ui.transcript.snapshot.isHydrated)
                viewModel.test_setActiveSessionLoadInProgressTabID(nil)
                assertPresentation(
                    viewModel.ui.transcript.snapshot.presentation,
                    tabID: tabID,
                    sessionID: fixture.sessionAID,
                    session: session,
                    expectedTexts: fixture.tabATexts
                )
            }
        }

        /// A duplicate `.activeComposeTabChanged` for the tab whose cold activation is already in
        /// flight is a no-op: the in-flight activation stays the owner, commits the hydrated
        /// binding, clears the load marker, and later session refreshes reach the bindings.
        func testDuplicateSameTabActivationNotificationKeepsColdActivationOwner() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)

                let gate = ColdLoadGate()
                defer { gate.release() }
                var heldLoadResumed = false
                viewModel.test_persistedLoadPrepareHook = { held in
                    guard held.tabID == cold.tabID, !heldLoadResumed else { return }
                    await gate.waitForRelease()
                    heldLoadResumed = true
                }
                defer { viewModel.test_persistedLoadPrepareHook = nil }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                XCTAssertEqual(viewModel.activeSessionLoadInProgressTabID, cold.tabID)

                // Post the same active tab again through the production notification sink.
                NotificationCenter.default.post(
                    name: .activeComposeTabChanged,
                    object: nil,
                    userInfo: ["tabID": cold.tabID, "windowID": fixture.window.windowID]
                )
                gate.release()
                try await Self.waitUntil { heldLoadResumed && session.hasLoadedPersistedState }
                try await Self.waitUntil { viewModel.activeSessionLoadInProgressTabID == nil }
                await Self.drainMainQueue()

                XCTAssertEqual(session.persistedLoadDisposition, .applied)
                let hydrated = viewModel.ui.transcript.snapshot
                XCTAssertEqual(hydrated.currentTabID, cold.tabID)
                XCTAssertTrue(hydrated.isHydrated)
                assertPresentation(
                    hydrated.presentation,
                    tabID: cold.tabID,
                    sessionID: cold.sessionID,
                    session: session,
                    expectedTexts: cold.texts
                )

                let nextAutoEdit = !session.autoEditEnabled
                session.autoEditEnabled = nextAutoEdit
                viewModel.requestUIRefresh(tabID: cold.tabID, urgent: true)
                XCTAssertEqual(viewModel.autoEditEnabled, nextAutoEdit, "Session refreshes reach the bindings")
            }
        }

        /// An early-prepared cold load held after its prepare keeps every existing fence: a switch
        /// away plus cancellation of the attempt means its late payload is neither applied nor
        /// published over the newer destination, and an ordinary reload still recovers the session.
        func testColdActivationEarlyPrepareKeepsAttemptAndDestinationFences() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let cold = try await persistColdTarget(in: fixture)
                defer { viewModel.test_persistenceWorkspaceOverride = nil }
                let session = try materializeUnpresentable(cold.tabID, in: fixture)
                let previousOverride = WorkspaceRestorePerfLog.debugProcessOverrideEnabled
                WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(true)
                defer { WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(previousOverride) }
                WorkspaceRestorePerfLog.clearRecentMetricLines()

                let gate = ColdLoadGate()
                defer { gate.release() }
                var heldLoadResumed = false
                viewModel.test_persistedLoadPrepareHook = { held in
                    guard held.tabID == cold.tabID, !heldLoadResumed else { return }
                    await gate.waitForRelease()
                    heldLoadResumed = true
                }
                defer { viewModel.test_persistedLoadPrepareHook = nil }
                var emissions: [AgentTranscriptUISnapshot] = []
                let subscription = viewModel.ui.transcript.$snapshot.dropFirst().sink { snapshot in
                    MainActor.assumeIsolated { emissions.append(snapshot) }
                }
                defer { subscription.cancel() }

                await fixture.window.promptManager.switchComposeTab(cold.tabID)
                try await Self.waitUntil { gate.isWaiting }
                let willAwait = try XCTUnwrap(Self.coldHydrationEvents(tabID: cold.tabID).first {
                    $0.name == "agentSessionHydration.prepareWillAwait"
                })
                XCTAssertEqual(willAwait.fields["earlyPrepare"], "adopted")

                await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
                viewModel.cancelPersistedLoad(for: session)
                let destinationStart = emissions.count
                gate.release()
                try await Self.waitUntil { heldLoadResumed }
                await Self.drainMainQueue()

                XCTAssertFalse(session.hasLoadedPersistedState, "A cancelled attempt's payload is never applied")
                XCTAssertNotEqual(session.persistedLoadDisposition, .applied)
                XCTAssertNil(session.persistedLoadTask)
                XCTAssertFalse(emissions[destinationStart...].contains { snapshot in
                    snapshot.currentTabID == cold.tabID
                        || snapshot.presentation.tabID == cold.tabID
                        || snapshot.activeSessionLoadInProgressTabID == cold.tabID
                }, "The stale early-prepared load never republishes after the newer switch")
                let destination = viewModel.ui.transcript.snapshot
                XCTAssertEqual(destination.currentTabID, fixture.tabBID)
                XCTAssertTrue(destination.isHydrated)

                let outcome = await viewModel.loadSessionFromDisk(for: session)
                XCTAssertEqual(outcome.disposition, .applied, "An ordinary reload recovers the cancelled cold session")
                XCTAssertTrue(session.hasLoadedPersistedState)
                XCTAssertEqual(session.items.map(\.text), cold.texts)
                XCTAssertEqual(viewModel.ui.transcript.snapshot.currentTabID, fixture.tabBID)
            }
        }

        /// Parsed DEBUG cold-hydration events for one tab, in emission order.
        private static func coldHydrationEvents(tabID: UUID) -> [(name: String, fields: [String: String])] {
            let markerNames = Set([
                "agentMode.activation.coldTaskWillCreate",
                "agentMode.activation.coldTaskEntered",
                "agentSessionHydration.prepareWillAwait",
                "agentSessionHydration.prepareEntered",
                "agentSessionHydration.prepare",
                "agentSessionHydration.prepareDidResume"
            ])
            let tabField = "tabID=\(WorkspaceRestorePerfLog.shortID(tabID))"
            return WorkspaceRestorePerfLog.recentMetricLinesSnapshot(limit: 2000).compactMap { line in
                let tokens = line.split(separator: " ").map(String.init)
                guard tokens.count > 1, markerNames.contains(tokens[1]), tokens.contains(tabField) else {
                    return nil
                }
                var fields: [String: String] = [:]
                for token in tokens.dropFirst(2) {
                    let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 { fields[pair[0]] = pair[1] }
                }
                return (tokens[1], fields)
            }
        }

        /// Activations that end without a cold load (no bound session; warm session) leave transcript UI
        /// publication immediate: a later loading-flag update reaches the store synchronously.
        func testEarlyExitAndWarmActivationsLeaveTranscriptPublicationImmediate() async throws {
            try await withFixture { fixture in
                let viewModel = fixture.viewModel
                let window = fixture.window
                let unboundTabID = UUID()
                let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                    ComposeTabState(id: unboundTabID, name: "Unbound", activeAgentSessionID: nil)
                )
                window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex])

                @MainActor func assertLaterUpdatePublishesImmediately(_ label: String) {
                    let marker = UUID()
                    viewModel.test_setActiveSessionLoadInProgressTabID(marker)
                    XCTAssertEqual(viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID, marker, label)
                    viewModel.test_setActiveSessionLoadInProgressTabID(nil)
                    XCTAssertNil(viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID, label)
                }

                // Early exit: the tab has no session at activation, so activation clears the bindings
                // (an unbound placeholder created afterwards is never bound by this activation).
                XCTAssertNil(viewModel.sessions[unboundTabID])
                await window.promptManager.switchComposeTab(unboundTabID)
                XCTAssertNil(viewModel.sessions[unboundTabID]?.activeAgentSessionID)
                let cleared = viewModel.ui.transcript.snapshot
                XCTAssertEqual(cleared.currentTabID, unboundTabID)
                XCTAssertFalse(cleared.isHydrated)
                XCTAssertNil(cleared.activeSessionLoadInProgressTabID)
                assertLaterUpdatePublishesImmediately("after unbound early exit")

                // Warm: the destination is presentable and publishes before the switch returns.
                await window.promptManager.switchComposeTab(fixture.tabBID)
                let warm = viewModel.ui.transcript.snapshot
                XCTAssertEqual(warm.currentTabID, fixture.tabBID)
                XCTAssertTrue(warm.isHydrated)
                XCTAssertNil(warm.activeSessionLoadInProgressTabID)
                assertPresentation(
                    warm.presentation,
                    tabID: fixture.tabBID,
                    sessionID: fixture.sessionBID,
                    session: fixture.sessionB,
                    expectedTexts: fixture.tabBTexts
                )
                assertLaterUpdatePublishesImmediately("after warm activation")
            }
        }

        /// Persists a completed two-row session to a real temporary store and adds an unseeded
        /// compose tab bound to it; the view model reads that store until the caller resets the override.
        private func persistColdTarget(in fixture: Fixture) async throws -> (tabID: UUID, sessionID: UUID, texts: [String]) {
            let window = fixture.window
            let storageURL = fixture.rootURL.appendingPathComponent("SessionStore", isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            var storeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            storeWorkspace.customStoragePath = storageURL
            fixture.viewModel.test_persistenceWorkspaceOverride = storeWorkspace

            let writer = AgentModeViewModel(
                testWindowID: 4491,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
            )
            writer.test_establishPersistenceWorkspace(storeWorkspace)
            let writerTabID = UUID()
            writer.test_setCurrentTabIDOverride(writerTabID)
            let written = try await writer.ensureSessionReady(tabID: writerTabID)
            let texts = ["Cold user", "Cold assistant"]
            written.appendItem(.user(texts[0]))
            written.appendItem(.assistant(texts[1]))
            written.runState = .completed
            let saved = await writer.flushSave(for: writerTabID)
            XCTAssertTrue(saved)
            let sessionID = try XCTUnwrap(written.activeAgentSessionID)
            // Ordinary close of the headless writer; the persisted record stays in the store.
            await writer.prepareForWindowClose()

            let tabID = UUID()
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == storeWorkspace.id })
            window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                ComposeTabState(id: tabID, name: "Cold", activeAgentSessionID: sessionID)
            )
            window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex])
            XCTAssertNil(fixture.viewModel.sessions[tabID])
            return (tabID, sessionID, texts)
        }

        /// Materializes the cold tab's session in the background (while another tab is current), so
        /// activation takes the ordinary unpresentable-session path rather than materializing it.
        private func materializeUnpresentable(_ tabID: UUID, in fixture: Fixture) throws -> AgentTabSession {
            let viewModel = fixture.viewModel
            let before = viewModel.ui.transcript.snapshot
            let session = try XCTUnwrap(viewModel.session(for: tabID, createIfNeeded: false))
            XCTAssertFalse(session.isPresentableForOwner)
            XCTAssertFalse(session.hasLoadedPersistedState)
            XCTAssertEqual(viewModel.ui.transcript.snapshot, before, "Background materialization does not publish")
            return session
        }

        /// The first loading snapshot carries the destination's default follow state, and the view's
        /// real activation normalization while the load is held publishes nothing further.
        private func assertDefaultFollowAndQuietViewNormalization(
            _ snapshot: AgentTranscriptUISnapshot,
            tabID: UUID,
            viewModel: AgentModeViewModel,
            emissionCount: () -> Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                snapshot.followBindingState,
                AgentModeViewModel.ActiveTranscriptFollowBindingState(tabID: tabID, viewportState: .liveBottom, armingState: .armed),
                "The loading snapshot carries the destination's follow state",
                file: file,
                line: line
            )
            let before = emissionCount()
            viewModel.normalizeTranscriptFollowStateForViewActivation(tabID: tabID)
            XCTAssertEqual(emissionCount(), before, "Default follow normalization adds no store publication", file: file, line: line)
            XCTAssertFalse(viewModel.ui.transcript.snapshot.isHydrated, file: file, line: line)
        }

        private static func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                guard Date() < deadline else {
                    XCTFail("Timed out waiting for condition")
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        /// Save-timer sleeps that never complete on their own; `cancelAll()` ends every one (and any
        /// started later) with `CancellationError`.
        @MainActor
        private final class HeldSaveTimers {
            private var continuations: [CheckedContinuation<Void, Error>] = []
            private var isClosed = false

            func sleep() async throws {
                if isClosed {
                    throw CancellationError()
                }
                try await withCheckedThrowingContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func cancelAll() {
                isClosed = true
                let pending = continuations
                continuations.removeAll()
                for continuation in pending {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        @MainActor
        private final class ColdLoadGate {
            private var continuation: CheckedContinuation<Void, Never>?
            private var released = false
            private(set) var isWaiting = false

            func waitForRelease() async {
                if released { return }
                isWaiting = true
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }

            func release() {
                released = true
                continuation?.resume()
                continuation = nil
            }
        }
    #endif

    // MARK: - D0 interaction-latency attribution (real PromptViewModel → notification → VM path)

    #if DEBUG
        func testInteractionLatencySupersededClickSwitchNeitherRetargetsNorAdvancesNewerClick() async throws {
            try await withFixture { fixture in
                let recorder = LatencyEventRecorder()
                defer { recorder.tearDown() }
                let windowID = fixture.window.windowID
                let older = AgentInteractionLatencyProbe.beginTabActivation(
                    tabID: fixture.tabBID,
                    windowID: windowID,
                    source: "sidebarRow"
                )
                let newer = AgentInteractionLatencyProbe.beginTabActivation(
                    tabID: fixture.tabAID,
                    windowID: windowID,
                    source: "sidebarRow"
                )

                // The older click's switch runs late under its own task-local action.
                await Self.switchTab(fixture, to: fixture.tabBID, as: older)
                await Self.drainMainQueue()
                XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
                XCTAssertEqual(recorder.names(for: newer), ["tabActivation.begin"])
                XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)

                await Self.switchTab(fixture, to: fixture.tabAID, as: newer)
                XCTAssertEqual(
                    Array(recorder.names(for: newer).prefix(3)),
                    ["tabActivation.begin", "tabActivation.handlerEntered", "tabActivation.firstPublish"]
                )
                // The real switch reports scheduling wait separately from work start.
                let fields = try XCTUnwrap(recorder.fields(of: "tabActivation.firstPublish", for: newer))
                let queueWait = try XCTUnwrap(fields["queueWaitMS"].flatMap(Double.init))
                let clickToWorkStart = try XCTUnwrap(fields["clickToWorkStartMS"].flatMap(Double.init))
                XCTAssertLessThanOrEqual(queueWait, clickToWorkStart)
                XCTAssertNotNil(fields["handlerToWorkStartMS"])
                XCTAssertTrue(["applyBindings", "none"].contains(fields["refreshPath"] ?? ""), "\(fields)")
            }
        }

        func testInteractionLatencyRapidSameTargetClicksIgnoreSupersededSwitchWork() async throws {
            try await withFixture { fixture in
                let recorder = LatencyEventRecorder()
                defer { recorder.tearDown() }
                let windowID = fixture.window.windowID
                let older = AgentInteractionLatencyProbe.beginTabActivation(
                    tabID: fixture.tabBID,
                    windowID: windowID,
                    source: "sidebarRow"
                )
                let newer = AgentInteractionLatencyProbe.beginTabActivation(
                    tabID: fixture.tabBID,
                    windowID: windowID,
                    source: "sidebarRow"
                )

                // The superseded click performs the real handler, refresh and publish for the
                // shared target; none of it may stamp the newer click.
                await Self.switchTab(fixture, to: fixture.tabBID, as: older)
                await Self.drainMainQueue()
                XCTAssertEqual(fixture.viewModel.activeTranscriptPresentation.tabID, fixture.tabBID)
                XCTAssertEqual(recorder.names(for: newer), ["tabActivation.begin"])

                // The newer click's own switch is a no-op: the tab is already active.
                await Self.switchTab(fixture, to: fixture.tabBID, as: newer)
                await Self.drainMainQueue()
                XCTAssertEqual(recorder.names(for: newer), ["tabActivation.begin"])
                XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)

                // An unrelated streaming mutation (no task-local action) refreshes and publishes the
                // target tab; without its own handler the newer click must not be stamped or done.
                let revisionBeforeStreaming = fixture.viewModel.activeTranscriptPresentation.revision
                fixture.sessionB.appendItem(.assistant("Streaming update", sequenceIndex: 2))
                await Self.drainMainQueue()
                let streamedPresentation = fixture.viewModel.activeTranscriptPresentation
                XCTAssertEqual(streamedPresentation.tabID, fixture.tabBID)
                XCTAssertGreaterThan(streamedPresentation.revision, revisionBeforeStreaming)
                AgentInteractionLatencyProbe.transcriptPresentationObservedBySwiftUI(
                    tabID: streamedPresentation.tabID,
                    windowID: windowID,
                    revision: streamedPresentation.revision
                )
                XCTAssertEqual(recorder.names(for: newer), ["tabActivation.begin"])
                XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)
            }
        }

        func testInteractionLatencyOtherWindowSwitchDoesNotCancelActivation() async throws {
            try await withFixture { fixtureA in
                try await withFixture { fixtureB in
                    let recorder = LatencyEventRecorder()
                    defer { recorder.tearDown() }
                    XCTAssertNotEqual(fixtureA.window.windowID, fixtureB.window.windowID)
                    let action = AgentInteractionLatencyProbe.beginTabActivation(
                        tabID: fixtureA.tabBID,
                        windowID: fixtureA.window.windowID,
                        source: "sidebarRow"
                    )

                    // Window B's unrelated switch reaches every VM's notification sink.
                    await fixtureB.window.promptManager.switchComposeTab(fixtureB.tabBID)
                    await Self.drainMainQueue()
                    XCTAssertEqual(fixtureB.window.promptManager.activeComposeTabID, fixtureB.tabBID)
                    XCTAssertEqual(recorder.names(for: action), ["tabActivation.begin"])
                    XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)

                    // The owning window's handler still advances it.
                    AgentInteractionLatencyAction.$current.withValue(action) {
                        AgentInteractionLatencyProbe.tabActivationHandlerEntered(
                            tabID: fixtureA.tabBID,
                            windowID: fixtureA.window.windowID
                        )
                    }
                    XCTAssertEqual(recorder.names(for: action), ["tabActivation.begin", "tabActivation.handlerEntered"])
                }
            }
        }

        func testInteractionLatencyOlderNewSessionFocusRequestDoesNotCompleteNewerAction() async throws {
            try await withFixture { fixture in
                let recorder = LatencyEventRecorder()
                defer { recorder.tearDown() }
                let windowID = fixture.window.windowID
                let older = AgentInteractionLatencyProbe.beginNewSession(windowID: windowID, source: "globalShortcut")
                let newer = AgentInteractionLatencyProbe.beginNewSession(windowID: windowID, source: "globalShortcut")

                await Task {
                    await AgentInteractionLatencyProbe.run(as: older) {
                        await fixture.viewModel.createAndActivateSessionTab(focusComposer: true)
                    }
                }.value
                // Focus behavior is unchanged; only attribution is withheld.
                let olderRequest = try XCTUnwrap(fixture.viewModel.ui.composer.focusRequest)
                AgentInteractionLatencyProbe.composerFocusAcknowledged(token: olderRequest.id, via: "tokenAttempt")
                XCTAssertEqual(recorder.names(for: newer), ["newSession.begin"])
                XCTAssertFalse(AgentInteractionLatencyProbe.isAwaitingComposerFocus)

                await Task {
                    await AgentInteractionLatencyProbe.run(as: newer) {
                        await fixture.viewModel.createAndActivateSessionTab(focusComposer: true)
                    }
                }.value
                let newerRequest = try XCTUnwrap(fixture.viewModel.ui.composer.focusRequest)
                XCTAssertNotEqual(newerRequest.id, olderRequest.id)
                AgentInteractionLatencyProbe.composerFocusAcknowledged(token: newerRequest.id, via: "tokenAttempt")
                XCTAssertEqual(
                    recorder.names(for: newer),
                    ["newSession.begin", "newSession.focusRequested", "newSession.composerReady"]
                )
            }
        }

        private static func switchTab(
            _ fixture: Fixture,
            to tabID: UUID,
            as action: AgentInteractionLatencyAction?
        ) async {
            await Task {
                await AgentInteractionLatencyProbe.run(as: action) {
                    await fixture.window.promptManager.switchComposeTab(tabID)
                }
            }.value
        }

        /// Lets main-queue callbacks and spawned main-actor Tasks from a switch run.
        private static func drainMainQueue() async {
            for _ in 0 ..< 5 {
                await Task.yield()
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }

        @MainActor
        private final class LatencyEventRecorder {
            private(set) var events: [AgentInteractionLatencyLedger.Event] = []

            init() {
                AgentInteractionLatencyProbe.resetForTesting()
                AgentInteractionLatencyProbe.enabledOverrideForTesting = true
                AgentInteractionLatencyProbe.eventSinkForTesting = { [weak self] event in
                    self?.events.append(event)
                }
            }

            func names(for action: AgentInteractionLatencyAction?) -> [String] {
                guard let id = action?.id else { return [] }
                return events.filter { $0.interactionID == id }.map(\.name)
            }

            func fields(of name: String, for action: AgentInteractionLatencyAction?) -> [String: String]? {
                guard let id = action?.id else { return nil }
                return events.first { $0.interactionID == id && $0.name == name }?.fields
            }

            func tearDown() {
                AgentInteractionLatencyProbe.resetForTesting()
            }
        }
    #endif

    private func clearComposerFocusRequest(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let requestID = fixture.viewModel.ui.composer.focusRequest?.id {
            fixture.viewModel.ui.composer.consumeFocusRequest(id: requestID)
        }
        XCTAssertNil(fixture.viewModel.ui.composer.focusRequest, file: file, line: line)
    }

    private func localCodexLeaf(
        in leaves: [AgentModelSelectionLeaf],
        excludingModelRaw: String?
    ) -> AgentModelSelectionLeaf? {
        leaves.first {
            if case let .local(agent: .codexExec, modelRaw, _) = $0.commitPayload {
                return modelRaw != excludingModelRaw
            }
            return false
        }
    }

    private func configureHUDCodexProvider(_ fixture: Fixture) {
        fixture.window.apiSettingsViewModel.isCodexConnected = true
        fixture.viewModel.test_setAvailableAgents([.codexExec])
        fixture.viewModel.test_setModelOptionsOverride(
            [
                AgentModelOption(
                    rawValue: AgentModel.defaultModel.rawValue,
                    displayName: "Default",
                    description: nil,
                    isPlaceholderDefault: true,
                    isProviderDefault: false
                ),
                AgentModelOption(
                    rawValue: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Deterministic HUD test option",
                    isDefault: false,
                    supportedReasoningEfforts: [.low, .high],
                    defaultReasoningEffort: .high
                ),
                AgentModelOption(
                    rawValue: "gpt-5.3",
                    displayName: "GPT-5.3",
                    description: "Alternate HUD test option",
                    isDefault: false,
                    supportedReasoningEfforts: [.medium, .high],
                    defaultReasoningEffort: .medium
                )
            ],
            for: .codexExec
        )
        fixture.viewModel.selectedAgent = .codexExec
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentModeChatSwitchActivationTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "A", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "B", activeAgentSessionID: sessionBID)

            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = try XCTUnwrap(viewModel.session(for: tabAID, createIfNeeded: true))
            let sessionB = try XCTUnwrap(viewModel.session(for: tabBID, createIfNeeded: true))
            XCTAssertEqual(sessionA.activeAgentSessionID, sessionAID)
            XCTAssertEqual(sessionB.activeAgentSessionID, sessionBID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabAID), sessionAID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabBID), sessionBID)

            let tabATexts = ["A user", "A assistant"]
            let tabBTexts = ["B user", "B assistant"]
            sessionA.hasLoadedPersistedState = true
            sessionA.setItemsSilently(
                [
                    .user(tabATexts[0], sequenceIndex: 0),
                    .assistant(tabATexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionA)

            sessionB.hasLoadedPersistedState = true
            sessionB.setItemsSilently(
                [
                    .user(tabBTexts[0], sequenceIndex: 0),
                    .assistant(tabBTexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionB)

            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionBID: sessionBID,
                sessionA: sessionA,
                sessionB: sessionB,
                tabATexts: tabATexts,
                tabBTexts: tabBTexts
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func assertPresentation(
        _ presentation: AgentTranscriptPresentationSnapshot,
        tabID: UUID,
        sessionID: UUID,
        session: AgentTabSession,
        expectedTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.tabID, tabID, file: file, line: line)
        XCTAssertTrue(presentation.bindingsHydrated, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.tabID, tabID, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(
            presentation.hydratedBindingTransitionGeneration,
            session.bindingTransitionGeneration,
            file: file,
            line: line
        )
        XCTAssertEqual(presentation.visibleRows.map(\.text), expectedTexts, file: file, line: line)
        XCTAssertEqual(presentation.workingRows.map(\.text), expectedTexts, file: file, line: line)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionBID: UUID
        let sessionA: AgentTabSession
        let sessionB: AgentTabSession
        let tabATexts: [String]
        let tabBTexts: [String]
    }
}

@MainActor
private final class HUDActiveTabChangeRecorder {
    struct Delivery: Equatable {
        let matched: Bool
        let storedActiveTabID: UUID?
        let navigationPresentedAfterDelivery: Bool
        let modelPresentedAfterDelivery: Bool
    }

    var deliveries: [Delivery] = []
}
