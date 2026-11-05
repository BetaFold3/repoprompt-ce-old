import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Step 1 rich-presentation authority in the connection manager and the App authority resolver:
/// ownership travels with the run policy to the routed connection, retained refresh delivers a
/// newer attempt without a controller restart, and unproven callers fail closed.
@MainActor
final class RichPresentationAuthorityTests: XCTestCase {
    private let toolName = AgentRichPresentationToolPolicy.toolName

    func testInstalledOwnershipReachesTheRoutedConnectionWithItsGrant() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let ownership = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true)
            await install(fixture, ownership: ownership)

            let installed = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(installed)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)

            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertTrue(effective.additionalTools.contains(toolName))
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.runID, fixture.runID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, ownership)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testAttemptRefreshPreservesCodeModeEligibilityAlongsideRichOwnership() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true)
            let second = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: false)
            let spec = MCPBootstrapLeaseSpec.agentMode(
                tabID: fixture.tabID, runID: fixture.runID, gateID: UUID(),
                windowID: fixture.windowID, agent: .claudeCode,
                codeModeEligibility: .directTools, runOwnership: first
            )
            XCTAssertEqual(spec.codeModeEligibility, .directTools)
            XCTAssertEqual(spec.runOwnership, first)
            await manager.installClientConnectionPolicy(
                for: fixture.clientName, windowID: fixture.windowID,
                restrictedTools: spec.restrictedTools,
                tabID: fixture.tabID, runID: fixture.runID,
                additionalTools: spec.additionalTools, purpose: .agentModeRun,
                codeModeEligibility: spec.codeModeEligibility, runOwnership: spec.runOwnership
            )
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let initialEligibility = await manager.debugStagedCodeModeEligibility(for: fixture.connectionID)
            let initialRouting = await manager.requestRoutingContext(for: fixture.connectionID)
            let initialPolicy = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertEqual(initialEligibility, .directTools)
            XCTAssertEqual(initialRouting.appliedRunOwnership?.ownership, first)
            XCTAssertTrue(initialPolicy.additionalTools.contains(toolName))

            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName, runID: fixture.runID, runOwnership: second
            )
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let refreshedEligibility = await manager.debugStagedCodeModeEligibility(for: fixture.connectionID)
            let refreshedRouting = await manager.requestRoutingContext(for: fixture.connectionID)
            let refreshedPolicy = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertEqual(refreshedEligibility, .directTools)
            XCTAssertEqual(refreshedRouting.appliedRunOwnership?.ownership, second)
            XCTAssertFalse(refreshedPolicy.additionalTools.contains(toolName))
            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testOwnershipIsDroppedOutsideAgentModeRuns() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let ownership = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true)
            await install(fixture, ownership: ownership, purpose: .discoverRun)

            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testRefreshDeliversANewerAttemptAndRefusesOlderOrForeignOnes() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            let second = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            await install(fixture, ownership: first)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)
            let toolsWithoutGrant = try XCTUnwrap(state.additionalTools)

            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName,
                runID: fixture.runID,
                runOwnership: second
            )
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, toolsWithoutGrant.union([toolName]))

            // Idempotent.
            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName,
                runID: fixture.runID,
                runOwnership: second
            )
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, toolsWithoutGrant.union([toolName]))

            // A delayed predecessor and another tab's attempt never replace the installed attempt.
            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName,
                runID: fixture.runID,
                runOwnership: first
            )
            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName,
                runID: fixture.runID,
                runOwnership: Self.ownership(tabID: UUID(), sequence: 9, enabled: false)
            )
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, toolsWithoutGrant.union([toolName]))

            // A connection admitted from the run's state after the refresh carries the new attempt.
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, second)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testOlderAttemptInstallKeepsTheNewerAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let newer = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            await install(fixture, ownership: newer)
            await install(fixture, ownership: older)

            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, newer)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: - Queued-policy application (review R2, F7)

    func testDelayedPredecessorInstallDoesNotDowngradeTheAppliedPendingPolicy() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let newer = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            await install(fixture, ownership: newer)
            // The predecessor's install arrives late and collapses the successor's queued entry.
            await install(fixture, ownership: older)

            let applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.runID, fixture.runID)
            XCTAssertTrue(applied.additionalTools.contains(toolName), "The newer attempt's grant is applied")
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, newer)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testOlderQueuedPolicyTakesTheNewerRunOwnershipAtApplication() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let otherClient = "codex-rich-authority-other-\(UUID().uuidString)"
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            let newer = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            await install(fixture, ownership: older)
            // A newer attempt of the run's tab installs under another client: the older policy
            // stays queued for the first client while the run's state holds the newer attempt.
            await install(fixture, ownership: newer, clientName: otherClient)

            let applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertTrue(applied.additionalTools.contains(toolName), "The stale queued policy takes the newer grant")
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, newer)
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true, "Application never caches the older grant")

            await manager.clearClientConnectionPolicy(for: otherClient, windowID: fixture.windowID, runID: fixture.runID)
            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testInstallWithoutMatchingOwnershipStripsACallerSuppliedGrant() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let forged = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec).union([toolName])
            let cases: [(String, AgentRunOwnership?, MCPRunPurpose)] = [
                ("no ownership", nil, .agentModeRun),
                ("another tab's ownership", Self.ownership(tabID: UUID(), sequence: 1, enabled: true), .agentModeRun),
                ("not an Agent Mode run", nil, .discoverRun)
            ]
            for (label, ownership, purpose) in cases {
                let fixture = Fixture()
                // Outside Agent Mode, even the run tab's own enabled attempt carries no authority.
                let ownTab = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true)
                let candidate = purpose == .discoverRun ? ownTab : ownership
                await install(fixture, ownership: candidate, purpose: purpose, additionalTools: forged)

                let read = await manager.debugRunPolicyState(for: fixture.runID)
                let state = try XCTUnwrap(read, label)
                XCTAssertEqual(state.additionalTools?.contains(toolName), false, label)
                let applied = await manager.debugApplyPendingPolicy(
                    clientName: fixture.clientName,
                    connectionID: fixture.connectionID,
                    requireRunRouting: false
                )
                XCTAssertEqual(applied.outcome, "applied", label)
                XCTAssertFalse(applied.additionalTools.contains(toolName), label)
                let routing = await manager.requestRoutingContext(for: fixture.connectionID)
                XCTAssertNil(routing.appliedRunOwnership, label)

                await cleanUp(fixture)
            }
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: - Live connection refresh (review F4)

    func testRefreshReachesALiveRoutedConnectionAndNotifiesOnlyWhenItsToolsChange() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rich-authority-terminal-records-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            await manager.debugSetTerminalRecordsDirectoryOverride(directory)

            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            let second = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            let third = Self.ownership(tabID: fixture.tabID, sequence: 3, enabled: true)
            await install(fixture, ownership: first, on: manager)

            let connection = RichAuthorityFixtureConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: fixture.connectionID,
                connection: connection,
                clientName: fixture.clientName,
                sessionToken: "rich-authority-\(UUID().uuidString)"
            )
            await manager.debugSetAdmittedClientIDForTesting(connectionID: fixture.connectionID, clientID: fixture.clientName)
            await manager.debugSeedConnectionRunRouting(
                connectionID: fixture.connectionID,
                runID: fixture.runID,
                purpose: .agentModeRun,
                windowID: fixture.windowID
            )
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            var effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertFalse(effective.additionalTools.contains(toolName))
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, first)
            let baseline = await connection.toolListChangedCount

            // A newer enabled attempt reaches the live connection with its grant and one notification.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: second)
            effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertTrue(effective.additionalTools.contains(toolName))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, second)
            var count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline + 1)

            // Identical refresh: nothing changes, no notification.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: second)
            count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline + 1)

            // A newer attempt with the same grant: ownership moves, the tool list does not.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: third)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, third)
            count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline + 1)

            // A delayed predecessor is refused.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: first)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, third)
            effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertTrue(effective.additionalTools.contains(toolName))
            count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline + 1)

            await cleanUp(fixture, on: manager)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testRichOnlyRefreshDoesNotFingerprintUnappliedCodeModeEligibility() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false)
            let second = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true)
            await install(fixture, ownership: first, on: manager)
            let connection = RichAuthorityFixtureConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: fixture.connectionID, connection: connection,
                clientName: fixture.clientName, sessionToken: "rich-code-mode-\(UUID().uuidString)"
            )
            await manager.debugSetAdmittedClientIDForTesting(connectionID: fixture.connectionID, clientID: fixture.clientName)
            await manager.debugSeedConnectionRunRouting(
                connectionID: fixture.connectionID, runID: fixture.runID,
                purpose: .agentModeRun, windowID: fixture.windowID
            )
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)

            // A new full policy is cached, but the retained connection still has native eligibility.
            await manager.installClientConnectionPolicy(
                for: fixture.clientName, windowID: fixture.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                tabID: fixture.tabID, runID: fixture.runID,
                additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: second),
                purpose: .agentModeRun, codeModeEligibility: .directTools, runOwnership: second
            )
            await manager.refreshRunAttemptRichPresentation(
                for: fixture.clientName, runID: fixture.runID, runOwnership: second
            )
            let partialEligibility = await manager.debugStagedCodeModeEligibility(for: fixture.connectionID)
            let partialMatches = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: fixture.connectionID, runID: fixture.runID
            )
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, second)
            XCTAssertEqual(partialEligibility, .native)
            XCTAssertEqual(partialMatches, false, "Rich-only refresh must not claim the new full policy was applied")

            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let fullEligibility = await manager.debugStagedCodeModeEligibility(for: fixture.connectionID)
            let fullMatches = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: fixture.connectionID, runID: fixture.runID
            )
            XCTAssertEqual(fullEligibility, .directTools)
            XCTAssertEqual(fullMatches, true)
            await cleanUp(fixture, on: manager)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: - Resolver

    func testResolverRefusesGatewayAndUnboundCallersBeforeAnySessionCheck() async {
        let tabID = UUID()
        let runID = UUID()
        let workspaceID = UUID()
        let ownership = Self.ownership(tabID: tabID, sequence: 1, enabled: true, workspaceID: workspaceID)
        let route = ServerNetworkManager.RunPolicyTab(runID: runID, windowID: 1, workspaceID: workspaceID, tabID: tabID)
        let applied = ServerNetworkManager.AppliedRunOwnership(runID: runID, ownership: ownership)
        var windowReads = 0
        let gateway = RichPresentationMCPAuthorityResolver(
            isGatewayPrincipalConnection: { _ in true },
            windows: {
                windowReads += 1
                return []
            }
        )
        let local = RichPresentationMCPAuthorityResolver(
            isGatewayPrincipalConnection: { _ in false },
            windows: {
                windowReads += 1
                return []
            }
        )

        let routed = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "codex",
            windowID: 1,
            runPurpose: .agentModeRun,
            actorRoutedRunTab: route,
            appliedRunOwnership: applied
        )
        let gatewayResult = await gateway.resolve(metadata: routed)
        XCTAssertEqual(
            gatewayResult.failureValue,
            .invalidContext(RichPresentationMCPAuthorityResolver.gatewayRefusalMessage)
        )
        let paired = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "codex",
            windowID: 1,
            runPurpose: .agentModeRun,
            actorRoutedRunTab: route,
            gatewayRemoteDeviceID: "remote:abcd1234",
            appliedRunOwnership: applied
        )
        let pairedResult = await local.resolve(metadata: paired)
        XCTAssertEqual(
            pairedResult.failureValue,
            .invalidContext(RichPresentationMCPAuthorityResolver.gatewayRefusalMessage)
        )
        XCTAssertEqual(windowReads, 0)

        let unbound = [
            // External or unrouted client.
            MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "external", windowID: 1, actorRoutedRunTab: nil),
            // Context Builder / non-Agent-Mode purpose.
            MCPServerViewModel.RequestMetadata(
                connectionID: UUID(), clientName: "codex", windowID: 1,
                runPurpose: .discoverRun, actorRoutedRunTab: route, appliedRunOwnership: applied
            ),
            // Routed run with no applied attempt ownership.
            MCPServerViewModel.RequestMetadata(
                connectionID: UUID(), clientName: "codex", windowID: 1,
                runPurpose: .agentModeRun, actorRoutedRunTab: route
            ),
            // Ownership applied for another run than the route.
            MCPServerViewModel.RequestMetadata(
                connectionID: UUID(), clientName: "codex", windowID: 1,
                runPurpose: .agentModeRun, actorRoutedRunTab: route,
                appliedRunOwnership: .init(runID: UUID(), ownership: ownership)
            )
        ]
        for metadata in unbound {
            let result = await local.resolve(metadata: metadata)
            XCTAssertEqual(
                result.failureValue,
                .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage)
            )
        }
        XCTAssertEqual(windowReads, 0)

        // A valid-looking route whose window no longer exists fails closed.
        let missingWindowResult = await local.resolve(metadata: routed)
        XCTAssertEqual(
            missingWindowResult.failureValue,
            .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage)
        )
        XCTAssertEqual(windowReads, 1)
        XCTAssertTrue(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage.contains("Start a new agent run."))
    }

    func testResolverRefusesAWorkspaceMismatchWithoutReadingWindows() async {
        let tabID = UUID()
        let runID = UUID()
        let ownership = Self.ownership(tabID: tabID, sequence: 1, enabled: true, workspaceID: UUID())
        var windowReads = 0
        let resolver = RichPresentationMCPAuthorityResolver(
            isGatewayPrincipalConnection: { _ in false },
            windows: {
                windowReads += 1
                return []
            }
        )
        for routeWorkspaceID in [UUID(), nil] as [UUID?] {
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: UUID(),
                clientName: "codex",
                windowID: 1,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: .init(runID: runID, windowID: 1, workspaceID: routeWorkspaceID, tabID: tabID),
                appliedRunOwnership: .init(runID: runID, ownership: ownership)
            )
            let result = await resolver.resolve(metadata: metadata)
            XCTAssertEqual(
                result.failureValue,
                .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage)
            )
        }
        XCTAssertEqual(windowReads, 0)
    }

    // MARK: - Helpers

    private struct Fixture {
        let clientName = "codex-rich-authority-\(UUID().uuidString)"
        let runID = UUID()
        let tabID = UUID()
        let connectionID = UUID()
        let windowID = Int.random(in: 63000 ..< 64000)
    }

    private func install(
        _ fixture: Fixture,
        ownership: AgentRunOwnership?,
        purpose: MCPRunPurpose = .agentModeRun,
        additionalTools: Set<String>? = nil,
        clientName: String? = nil,
        on manager: ServerNetworkManager = .shared
    ) async {
        await manager.installClientConnectionPolicy(
            for: clientName ?? fixture.clientName,
            windowID: fixture.windowID,
            restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
            oneShot: true,
            reason: "rich presentation authority test",
            ttl: 10,
            tabID: fixture.tabID,
            runID: fixture.runID,
            additionalTools: additionalTools
                ?? AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: ownership),
            allowedToolsOverride: nil,
            sessionProfile: .standard,
            purpose: purpose,
            runOwnership: ownership
        )
    }

    private func cleanUp(_ fixture: Fixture, on manager: ServerNetworkManager = .shared) async {
        await manager.clearClientConnectionPolicy(for: fixture.clientName, windowID: fixture.windowID, runID: fixture.runID)
        await manager.removeConnection(fixture.connectionID)
        await manager.cleanupRunRoutingState(for: fixture.runID, windowID: fixture.windowID)
    }

    private static func ownership(
        tabID: UUID,
        sequence: UInt64,
        enabled: Bool,
        workspaceID: UUID = UUID()
    ) -> AgentRunOwnership {
        AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: tabID, persistentSessionID: UUID()),
            richPresentationPolicy: .captured(workspaceID: workspaceID, enabled: enabled, approvedImageHosts: []),
            admissionSequence: sequence
        )
    }
}

/// An in-memory routed connection that counts `tools/list_changed` deliveries (no socket).
private actor RichAuthorityFixtureConnection: MCPServerConnection {
    private(set) var toolListChangedCount = 0

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        nil
    }

    func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
    func stop() async {}
    func abortForExecutionWatchdog() async {}
    func notifyToolListChanged() async {
        toolListChangedCount += 1
    }

    func connectionState() -> ConnectionStateSnapshot {
        .ready
    }

    func isViableForRetention() -> Bool {
        true
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        0
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func terminate(reason _: TerminationReason, message _: String?) async {}
    func sendProgress(
        tool _: String,
        kind _: RepoPromptProgressKind,
        stage _: String,
        message _: String
    ) async {}
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}
