@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Step 1 rich-presentation authority: attempt capture, the dedicated capability's grant, and the
/// listing/direct-call policy sets (docs/context/specs/2026-11-04-rich-presentation-spec.md, A3).
@MainActor
final class RichPresentationPolicyTests: XCTestCase {
    private let toolName = AgentRichPresentationToolPolicy.toolName

    // MARK: - Captured policy

    func testCapturedPolicyKeepsOnlyCanonicalHostsSortedAndDeduplicated() {
        let workspaceID = UUID()
        let policy = AgentRichPresentationAttemptPolicy.captured(
            workspaceID: workspaceID,
            enabled: true,
            approvedImageHosts: ["images.example.com", "cdn.example.org", "images.example.com"]
        )
        XCTAssertEqual(policy.workspaceID, workspaceID)
        XCTAssertTrue(policy.enabled)
        XCTAssertTrue(policy.grantsCreation)
        XCTAssertEqual(policy.approvedImageHosts, ["cdn.example.org", "images.example.com"])
    }

    func testCapturedPolicyWithAnyNonCanonicalHostGrantsNothing() {
        let workspaceID = UUID()
        for host in ["Images.Example.com", "*.example.com", "localhost", "127.0.0.1", ""] {
            let policy = AgentRichPresentationAttemptPolicy.captured(
                workspaceID: workspaceID,
                enabled: true,
                approvedImageHosts: ["images.example.com", host]
            )
            XCTAssertEqual(policy, .disabled(workspaceID: workspaceID), host)
            XCTAssertFalse(policy.grantsCreation, host)
            XCTAssertTrue(policy.approvedImageHosts.isEmpty, host)
        }
        XCTAssertFalse(AgentRichPresentationAttemptPolicy.disabled(workspaceID: workspaceID).grantsCreation)
    }

    // MARK: - Attempt capture

    func testEachAdmittedAttemptSamplesOnceAndKeepsItsImmutableSnapshot() {
        let session = AgentTabSession(tabID: UUID())
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let workspaceID = UUID()
        var enabled = true
        var resolverCalls = 0
        session.richPresentationPolicyResolver = { _ in
            resolverCalls += 1
            return .captured(workspaceID: workspaceID, enabled: enabled, approvedImageHosts: [])
        }
        // A provider that keeps its process run ID across turns (Claude) still admits new attempts.
        session.runID = UUID()

        let first = session.beginRunAttempt(source: "test.richPresentation.first")
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(first.richPresentationPolicy?.enabled, true)
        XCTAssertEqual(first.richPresentationPolicy?.workspaceID, workspaceID)

        // A Settings change during the attempt never changes its captured policy.
        enabled = false
        XCTAssertEqual(first.richPresentationPolicy?.enabled, true)
        XCTAssertEqual(session.activeRunOwnership?.richPresentationPolicy?.enabled, true)

        let second = session.beginRunAttempt(source: "test.richPresentation.second")
        XCTAssertEqual(resolverCalls, 2, "A newly admitted attempt resamples, even on the same run ID")
        XCTAssertEqual(second.richPresentationPolicy?.enabled, false)
        XCTAssertGreaterThan(second.admissionSequence, first.admissionSequence)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(AgentRichPresentationToolPolicy.grantedTools(for: second).isEmpty)
        XCTAssertEqual(AgentRichPresentationToolPolicy.grantedTools(for: first), [toolName])
    }

    func testAttemptWithoutResolverOrBindingCapturesNoAuthority() {
        let unconfigured = AgentTabSession(tabID: UUID())
        unconfigured.testInstallPersistentSessionBinding(sessionID: UUID())
        XCTAssertNil(unconfigured.beginRunAttempt(source: "test.richPresentation.noResolver").richPresentationPolicy)

        let unbound = AgentTabSession(tabID: UUID())
        var resolverCalls = 0
        unbound.richPresentationPolicyResolver = { _ in
            resolverCalls += 1
            return .captured(workspaceID: UUID(), enabled: true, approvedImageHosts: [])
        }
        XCTAssertNil(unbound.beginRunAttempt(source: "test.richPresentation.unbound").richPresentationPolicy)
        XCTAssertEqual(resolverCalls, 0, "An unbound session is never sampled")

        let refused = AgentTabSession(tabID: UUID())
        refused.testInstallPersistentSessionBinding(sessionID: UUID())
        refused.richPresentationPolicyResolver = { _ in nil }
        let ownership = refused.beginRunAttempt(source: "test.richPresentation.refused")
        XCTAssertNil(ownership.richPresentationPolicy)
        XCTAssertTrue(AgentRichPresentationToolPolicy.grantedTools(for: ownership).isEmpty)
    }

    // MARK: - View-model binding (review F5)

    func testViewModelSessionCapturesItsActiveWorkspaceEntryAndFailsClosedOtherwise() throws {
        let vm = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Rich Presentation",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Root", activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )
        let owner = vm.test_receiveWorkspaceSwitchNotification(workspace)
        vm.test_installSessionIndexSnapshot([:], owner: owner, latestOwner: owner, activeWorkspace: workspace)
        var stored: WorkspaceRichPresentationSettings? = WorkspaceRichPresentationSettings(
            enabled: true,
            approvedImageHosts: ["images.example.com"]
        )
        var readWorkspaceIDs: [UUID] = []
        vm.richPresentationSettingsRead = { workspaceID in
            readWorkspaceIDs.append(workspaceID)
            return stored
        }
        let session = try XCTUnwrap(vm.session(for: tabID, createIfNeeded: true))
        session.testInstallPersistentSessionBinding(sessionID: sessionID)

        // The session the view model created carries its resolver: the attempt captures the
        // active workspace's entry, read once per admission.
        let enabled = session.beginRunAttempt(source: "test.richPresentation.vm.enabled")
        XCTAssertEqual(
            enabled.richPresentationPolicy,
            .captured(workspaceID: workspace.id, enabled: true, approvedImageHosts: ["images.example.com"])
        )
        XCTAssertEqual(readWorkspaceIDs, [workspace.id])

        // An unreadable or future settings file (nil read) captures no authority; the admitted
        // attempt keeps its snapshot.
        stored = nil
        XCTAssertNil(session.beginRunAttempt(source: "test.richPresentation.vm.unreadable").richPresentationPolicy)
        XCTAssertEqual(enabled.richPresentationPolicy?.enabled, true)

        // A malformed stored entry captures as disabled for the workspace.
        stored = try JSONDecoder().decode(WorkspaceRichPresentationSettings.self, from: Data(#"{"enabled":"yes"}"#.utf8))
        XCTAssertEqual(stored?.storedEntryWasInvalid, true)
        XCTAssertEqual(
            session.beginRunAttempt(source: "test.richPresentation.vm.invalid").richPresentationPolicy,
            .disabled(workspaceID: workspace.id)
        )

        // A session this view model doesn't own is never sampled.
        stored = WorkspaceRichPresentationSettings(enabled: true)
        let readsBeforeRefusals = readWorkspaceIDs.count
        let foreign = AgentTabSession(tabID: tabID)
        foreign.testInstallPersistentSessionBinding(sessionID: sessionID)
        XCTAssertNil(vm.richPresentationAttemptPolicy(for: foreign))

        // Nor is a session whose index owner is no longer the active workspace.
        vm.test_setActiveWorkspaceIDForSessionIndex(UUID())
        XCTAssertNil(session.beginRunAttempt(source: "test.richPresentation.vm.mismatch").richPresentationPolicy)
        XCTAssertEqual(readWorkspaceIDs.count, readsBeforeRefusals, "Refused callers never read settings")
    }

    // MARK: - Grants

    func testEveryProviderIsGrantedOnlyByAnEnabledAttempt() {
        let tabID = UUID()
        let enabled = Self.ownership(tabID: tabID, policy: .captured(workspaceID: UUID(), enabled: true, approvedImageHosts: []))
        let disabled = Self.ownership(tabID: tabID, policy: .disabled(workspaceID: UUID()))
        let unauthorized = Self.ownership(tabID: tabID, policy: nil)

        for agent in AgentProviderKind.allCases {
            for profile in [AgentSessionProfile.standard, .knowledge] {
                let label = "\(agent.rawValue) \(profile)"
                XCTAssertTrue(
                    AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile, runOwnership: enabled)
                        .contains(toolName),
                    label
                )
                for ownership in [disabled, unauthorized] {
                    XCTAssertFalse(
                        AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile, runOwnership: ownership)
                            .contains(toolName),
                        label
                    )
                }
                XCTAssertFalse(
                    AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile).contains(toolName),
                    "\(label): no attempt ownership grants nothing"
                )
                // The rich grant only adds its own capability to the profile's own base grants
                // (compared with the base policy itself, so a profile mix-up can't cancel out).
                let base = AgentModeMCPToolPolicy.grantedTools(forAgent: agent, sessionProfile: profile)
                XCTAssertEqual(
                    AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile, runOwnership: enabled)
                        .subtracting([toolName]),
                    base,
                    label
                )
                XCTAssertEqual(
                    AgentModeMCPPolicyInstaller.additionalTools(for: agent, sessionProfile: profile, runOwnership: disabled),
                    base,
                    label
                )
            }
        }
        XCTAssertFalse(AgentModeMCPToolPolicy.restrictedTools.contains(toolName))
    }

    func testKnowledgeCeilingAdmitsTheCapabilityWithoutGrantingIt() {
        XCTAssertTrue(KnowledgeSessionPolicy.allowedMCPToolNames.contains(toolName))
        XCTAssertTrue(AgentModeMCPToolPolicy.knowledgeAllowedTools.contains(toolName))
        XCTAssertFalse(
            AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, sessionProfile: .knowledge).contains(toolName)
        )
    }

    func testListingAndDirectCallPolicySets() {
        XCTAssertEqual(MCPToolCapabilities.toolNames(for: [.richPresentation]), [toolName])
        XCTAssertEqual(MCPToolCapabilities.capabilities(for: toolName), [.richPresentation])
        // Hidden and uncallable for every connection without an explicit grant.
        XCTAssertTrue(MCPPolicyGatedTools.names.contains(toolName))
        // Context Builder runs are restricted.
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains(toolName))
        XCTAssertFalse(DiscoverMCPToolPolicy.grantedTools.contains(toolName))
        // Explore and other roles advertise it (the grant, not advertisement, authorizes).
        for role in [AgentModelCatalog.TaskLabelKind.explore, .engineer, .pair, .design] {
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: toolName, taskLabelKind: role),
                "\(role)"
            )
        }
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: toolName, taskLabelKind: nil))
    }

    // MARK: - Lease input

    func testAgentModeLeaseSpecCarriesTheAttemptAndRestrictionsWin() {
        let tabID = UUID()
        let ownership = Self.ownership(
            tabID: tabID,
            policy: .captured(workspaceID: UUID(), enabled: true, approvedImageHosts: [])
        )
        let spec = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID,
            runID: UUID(),
            gateID: UUID(),
            windowID: 1,
            agent: .codexExec,
            runOwnership: ownership
        )
        XCTAssertEqual(spec.runOwnership, ownership)
        XCTAssertEqual(spec.additionalTools?.contains(toolName), true)
        XCTAssertFalse(spec.restrictedTools.contains(toolName))

        let restricted = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID,
            runID: UUID(),
            gateID: UUID(),
            windowID: 1,
            agent: .codexExec,
            additionalRestrictedTools: [toolName],
            runOwnership: ownership
        )
        XCTAssertTrue(restricted.restrictedTools.contains(toolName), "Restrictions are unioned, so they win over grants")

        let legacy = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID,
            runID: UUID(),
            gateID: UUID(),
            windowID: 1,
            agent: .codexExec
        )
        XCTAssertNil(legacy.runOwnership)
        XCTAssertEqual(legacy.additionalTools?.contains(toolName), false)
    }

    // MARK: - Registered (Step 4) and policy-gated

    /// Step 4 registers the tool in every window catalog; it stays hidden and uncallable unless an
    /// attempt's grant adds it, runs under the ordinary bounded contract, and is admitted on the
    /// control lane (no window-wide mutation lease; B-S4-02, main-approved).
    func testPresentRichIsRegisteredPolicyGatedBoundedAndControlLane() {
        XCTAssertEqual(MCPWindowToolName.presentRich, toolName)
        XCTAssertEqual(MCPWindowToolGroup.orderedToolNames.filter { $0 == toolName }, [toolName])
        XCTAssertEqual(MCPWindowToolGroup.richPresentation.orderedToolNames, [toolName])
        XCTAssertTrue(MCPPolicyGatedTools.names.contains(toolName))
        XCTAssertEqual(AgentRichPresentationToolPolicy.capabilityToolNames, [toolName])
        guard case let .bounded(deadline, grace) = MCPToolExecutionContractCatalog.contract(for: toolName) else {
            return XCTFail("present_rich must run under the bounded execution contract")
        }
        XCTAssertEqual(deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline)
        XCTAssertEqual(grace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
        XCTAssertEqual(MCPToolAdmissionPolicy.classification(forCanonicalToolName: toolName), .control)
    }

    // MARK: - Helpers

    static func ownership(
        tabID: UUID,
        sequence: UInt64 = 1,
        policy: AgentRichPresentationAttemptPolicy?
    ) -> AgentRunOwnership {
        AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: tabID, persistentSessionID: UUID()),
            richPresentationPolicy: policy,
            admissionSequence: sequence
        )
    }
}
