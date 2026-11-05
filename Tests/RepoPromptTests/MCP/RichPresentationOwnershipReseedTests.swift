import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Step 4 Package A: the routing reseeds of a run's cached policy (`installTabContextFromPolicy`,
/// the run-tab rebind) keep attempt ownership only for a proven same-binding refresh. A changed or
/// unprovable binding clears the ownership and exactly the rich-presentation grant, and raises the
/// run's revocation watermark to the cleared admission, so neither advertisement nor a direct call
/// regains authority through any writer (seed, install, pending application, refresh, rollback,
/// cleanup); a delayed predecessor never grants. Admission sequences here are explicit stand-ins
/// for the process-wide `AgentRunAdmissionSequence` ordinals.
@MainActor
final class RichPresentationOwnershipReseedTests: XCTestCase {
    private let toolName = AgentRichPresentationToolPolicy.toolName

    func testSameBindingReseedRetainsOwnershipAndGrant() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let ownership = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: ownership)
            let installed = await manager.debugRunPolicyState(for: fixture.runID)
            let toolsBefore = try XCTUnwrap(installed?.additionalTools)
            XCTAssertTrue(toolsBefore.contains(toolName))

            // No workspace cached yet: the attempt's captured policy proves the resolved workspace.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.workspaceID, fixture.workspaceID)
            XCTAssertEqual(state.additionalTools, toolsBefore)
            var kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(kept, ownership)

            // A reconnect within the same binding (cached workspace equal) is a no-op for authority.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, toolsBefore)
            kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(kept, ownership)

            // The reconnecting connection is advertised the grant and carries the same attempt to
            // the resolver, which proceeds past its ownership checks to the session check.
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertTrue(effective.additionalTools.contains(toolName))
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, ownership)
            let resolution = await resolve(routing, fixture)
            XCTAssertEqual(resolution.windowReads, 1, "Ownership reached the session check")

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testReseedAfterANewAttemptUnderAReusedRunIDCarriesOnlyThatAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false, workspaceID: fixture.workspaceID)
            let second = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            let third = Self.ownership(tabID: fixture.tabID, sequence: 3, enabled: false, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: first)
            // A refresh stamps its state up to 1 ms ahead, so each reseed carries a controlled later date.
            let start = Date()

            // The retained process admits a new attempt: the existing refresh contract resamples.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: second)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID,
                updatedAt: start.addingTimeInterval(1)
            )
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.workspaceID, fixture.workspaceID, "The reseed landed")
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)
            var kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(kept, second)

            // A later disabled attempt removes the grant; the reseed neither restores nor resamples it.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: third)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID,
                updatedAt: start.addingTimeInterval(2)
            )
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)
            kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(kept, third)

            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, third)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testDelayedPredecessorSeedNeverGrantsFromTheOlderAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let newer = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: false, workspaceID: fixture.workspaceID)
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: newer)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            // The predecessor's install arrives late, even with a caller-supplied grant.
            let forged = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec).union([toolName])
            await install(fixture, ownership: older, additionalTools: forged)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )

            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)
            let kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(kept, newer)

            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            let effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertFalse(effective.additionalTools.contains(toolName))
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, newer)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testChangedOrUnprovenBindingDropsOwnershipAndOnlyTheRichGrant() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            enum Change: String, CaseIterable {
                case workspaceChanged = "cached workspace replaced by another"
                case workspaceUnproven = "no cached workspace and the attempt names another"
                case tabChanged = "another tab"
                case windowChanged = "another window"
            }
            for change in Change.allCases {
                let label = change.rawValue
                let fixture = Fixture()
                let ownership = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
                await install(fixture, ownership: ownership)
                if change == .workspaceChanged {
                    await manager.debugReseedRunPolicyRouting(
                        runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
                    )
                }
                let before = await manager.debugRunPolicyState(for: fixture.runID)
                let stateBefore = try XCTUnwrap(before, label)
                let toolsBefore = try XCTUnwrap(stateBefore.additionalTools, label)
                XCTAssertTrue(toolsBefore.contains(toolName), label)

                let otherWindowID = fixture.windowID + 1000
                let otherTabID = UUID()
                await manager.debugReseedRunPolicyRouting(
                    runID: fixture.runID,
                    windowID: change == .windowChanged ? otherWindowID : fixture.windowID,
                    workspaceID: change == .workspaceChanged || change == .workspaceUnproven ? UUID() : fixture.workspaceID,
                    tabID: change == .tabChanged ? otherTabID : fixture.tabID
                )

                let after = await manager.debugRunPolicyState(for: fixture.runID)
                let stateAfter = try XCTUnwrap(after, label)
                XCTAssertEqual(stateAfter.additionalTools, toolsBefore.subtracting([toolName]), "Only the rich grant goes: \(label)")
                XCTAssertEqual(stateAfter.restrictedTools, stateBefore.restrictedTools, label)
                XCTAssertEqual(stateAfter.purpose, stateBefore.purpose, label)
                let cleared = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertNil(cleared, label)
                let revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
                XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1, label)
                XCTAssertEqual(revocation?.isRevocationOnly, false, label)

                // Advertisement: a connection admitted from the reseeded state lacks the grant.
                await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
                let effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
                XCTAssertFalse(effective.additionalTools.contains(toolName), label)
                // Direct call: no applied ownership, so the resolver refuses before any session read.
                let routing = await manager.requestRoutingContext(for: fixture.connectionID)
                XCTAssertNil(routing.appliedRunOwnership, label)
                let resolution = await resolve(routing, fixture)
                XCTAssertEqual(
                    resolution.result,
                    .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage),
                    label
                )
                XCTAssertEqual(resolution.windowReads, 0, label)

                // A same-binding reseed afterwards never resurrects the cleared authority.
                let latest = await manager.debugRunPolicyState(for: fixture.runID)
                let latestState = try XCTUnwrap(latest, label)
                if let workspaceID = latestState.workspaceID {
                    await manager.debugReseedRunPolicyRouting(
                        runID: fixture.runID,
                        windowID: latestState.windowID,
                        workspaceID: workspaceID,
                        tabID: change == .tabChanged ? otherTabID : fixture.tabID
                    )
                }
                let resurrected = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertNil(resurrected, label)

                await cleanUp(fixture)
            }
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testLateRefreshAfterABindingChangeNeverRestoresTheClearedAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            enum Change: String, CaseIterable {
                case workspaceChanged = "cached workspace replaced by another"
                case windowChanged = "another window"
            }
            for change in Change.allCases {
                let label = change.rawValue
                let fixture = Fixture()
                let newWorkspaceID = change == .workspaceChanged ? UUID() : fixture.workspaceID
                let newWindowID = change == .windowChanged ? fixture.windowID + 1000 : fixture.windowID
                let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
                let cleared = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
                let foreign = Self.ownership(tabID: fixture.tabID, sequence: 3, enabled: true, workspaceID: UUID())
                // A new binding admitted by a re-created owner of the tab: its local counter
                // restarted, but its process-wide admission is later than every predecessor's.
                let admitted = Self.ownership(tabID: fixture.tabID, sequence: 4, enabled: true, workspaceID: newWorkspaceID)
                await install(fixture, ownership: cleared)
                await manager.debugReseedRunPolicyRouting(
                    runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
                )
                await manager.debugReseedRunPolicyRouting(
                    runID: fixture.runID, windowID: newWindowID, workspaceID: newWorkspaceID, tabID: fixture.tabID
                )
                var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertNil(ownership, label)

                // Late refreshes arrive while no ownership is installed: the cleared attempt and an
                // older one never individually cleared are at or below the watermark (even when only
                // the window changed and the workspace is the same), and another workspace's later
                // attempt conflicts with the run's workspace. All are refused.
                for late in [cleared, older, foreign] {
                    await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: late)
                    ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
                    XCTAssertNil(ownership, label)
                    let read = await manager.debugRunPolicyState(for: fixture.runID)
                    let state = try XCTUnwrap(read, label)
                    XCTAssertEqual(state.additionalTools?.contains(toolName), false, label)
                }
                await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
                var effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
                XCTAssertFalse(effective.additionalTools.contains(toolName), label)
                var routing = await manager.requestRoutingContext(for: fixture.connectionID)
                XCTAssertNil(routing.appliedRunOwnership, label)

                // A genuinely newer admission for the run's current workspace takes the run without
                // any installed ownership to replace, with its grant.
                await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: admitted)
                ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertEqual(ownership, admitted, label)
                let read = await manager.debugRunPolicyState(for: fixture.runID)
                let state = try XCTUnwrap(read, label)
                XCTAssertEqual(state.additionalTools?.contains(toolName), true, label)
                await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
                effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
                XCTAssertTrue(effective.additionalTools.contains(toolName), label)
                routing = await manager.requestRoutingContext(for: fixture.connectionID)
                XCTAssertEqual(routing.appliedRunOwnership?.ownership, admitted, label)

                // The cleared attempt still cannot come back after the successor.
                await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: cleared)
                ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertEqual(ownership, admitted, label)

                await cleanUp(fixture)
            }
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testFirstAdmissionRefreshWithoutInstalledOwnershipStillGrants() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let admitted = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            // A run policy without attempt ownership (no revocation, no resolved workspace yet).
            await install(fixture, ownership: nil)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)

            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: admitted)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, admitted)
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testPendingPolicyQueuedBeforeAClearIsAppliedWithoutTheClearedAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let newWorkspaceID = UUID()
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            let admitted = Self.ownership(tabID: fixture.tabID, sequence: 3, enabled: true, workspaceID: newWorkspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: cleared)
                .subtracting([toolName])
            // The install queues a one-shot policy carrying the attempt; the binding then changes.
            await install(fixture, ownership: cleared)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: newWorkspaceID, tabID: fixture.tabID
            )

            let applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.additionalTools, otherTools, "Only the rich grant is withheld")
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            let resolution = await resolve(routing, fixture)
            XCTAssertEqual(resolution.result, .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage))
            XCTAssertEqual(resolution.windowReads, 0)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)

            // A fresh admission for the current binding still takes the run with its grant.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: admitted)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, admitted)
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, admitted)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testLateInstallOfAClearedOrOlderAttemptCarriesNoOwnership() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let secondConnectionID = UUID()
            let newWorkspaceID = UUID()
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            let admitted = Self.ownership(tabID: fixture.tabID, sequence: 3, enabled: true, workspaceID: newWorkspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: cleared)
                .subtracting([toolName])
            await install(fixture, ownership: cleared)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: newWorkspaceID, tabID: fixture.tabID
            )

            // Late installs of the cleared attempt and of an older one (each with the grant its
            // installer derives) carry no ownership into the run state or the queued policy.
            for late in [cleared, older] {
                await install(fixture, ownership: late)
                let ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
                XCTAssertNil(ownership)
                let read = await manager.debugRunPolicyState(for: fixture.runID)
                let state = try XCTUnwrap(read)
                XCTAssertEqual(state.additionalTools, otherTools)
            }
            var applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.additionalTools, otherTools)
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)

            // A fresh admission's install for the current binding is accepted with its grant.
            await install(fixture, ownership: admitted)
            let ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, admitted)
            applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: secondConnectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.additionalTools, otherTools.union([toolName]))
            routing = await manager.requestRoutingContext(for: secondConnectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, admitted)

            await manager.removeConnection(secondConnectionID)
            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testClearRevokesTheAttemptFromALiveConnectionAndNotifiesOnce() async throws {
        #if DEBUG
            let manager = ServerNetworkManager()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rich-reseed-terminal-records-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            await manager.debugSetTerminalRecordsDirectoryOverride(directory)

            let fixture = Fixture()
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: cleared, on: manager)
            let connection = ReseedFixtureConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: fixture.connectionID,
                connection: connection,
                clientName: fixture.clientName,
                sessionToken: "rich-reseed-\(UUID().uuidString)"
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
            let toolsBefore = effective.additionalTools
            XCTAssertTrue(toolsBefore.contains(toolName))
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, cleared)
            let baseline = await connection.toolListChangedCount

            // Same binding: nothing changes, no notification.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            var count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, cleared)

            // Changed binding: the live connection loses the attempt and exactly its grant.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: UUID(), tabID: fixture.tabID
            )
            effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertEqual(effective.additionalTools, toolsBefore.subtracting([toolName]))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            count = await connection.toolListChangedCount
            XCTAssertEqual(count, baseline + 1)

            await cleanUp(fixture, on: manager)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testReseedOfARemovedRunDoesNotRecreateItsState() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            XCTAssertNil(read)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: - Watermark authority

    func testRevocationLandsEvenWhenTheReseedIsSkippedByItsTimestamp() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let ownership = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: ownership)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, ownership)
            let before = await manager.debugRunPolicyState(for: fixture.runID)
            let toolsBefore = try XCTUnwrap(before?.additionalTools)
            XCTAssertTrue(toolsBefore.contains(toolName))

            // A stale reseed (older than the stored state) discovers a changed binding.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: UUID(), tabID: fixture.tabID,
                updatedAt: .distantPast
            )
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.workspaceID, fixture.workspaceID, "The stale reseed overwrites no routing field")
            XCTAssertEqual(state.additionalTools, toolsBefore.subtracting([toolName]), "Only the rich grant goes")
            let kept = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(kept)
            let revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            // The live connection loses the attempt and its grant too.
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            let effective = await manager.debugEffectivePolicyState(for: fixture.connectionID)
            XCTAssertEqual(effective.additionalTools, toolsBefore.subtracting([toolName]))

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testTheSameOrdinalWithADifferentOwnershipNeverReplacesTheInstalledAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let installed = Self.ownership(tabID: fixture.tabID, sequence: 5, enabled: false, workspaceID: fixture.workspaceID)
            let twin = Self.ownership(tabID: fixture.tabID, sequence: 5, enabled: true, workspaceID: fixture.workspaceID)
            XCTAssertNotEqual(installed, twin)
            await install(fixture, ownership: installed)

            // Not a reconnect: neither a refresh nor an install of the twin takes the run.
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: twin)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, installed)
            await install(fixture, ownership: twin)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, installed)
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)

            let applied = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertFalse(applied.additionalTools.contains(toolName))
            let routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, installed)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testNoStateRollbackKeepsTheWatermarkAndOnlyAFreshAdmissionGrants() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let admitted = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: cleared)
            // The run's usable state goes (no watermark yet); its one-shot policy stays queued.
            await manager.cleanupRunRoutingState(for: fixture.runID)
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertNil(revocation)

            // The application recreates the run state, then suspends; meanwhile a routing reseed
            // clears the attempt for another workspace. The route then fails (no window): rollback
            // to a restore point that holds no run state.
            await manager.debugSuspendNextPendingPolicyRouteInstallation()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: fixture.clientName,
                    connectionID: fixture.connectionID,
                    requireRunRouting: true
                )
            }
            let suspended = await waitForSuspendedRouteInstallation(manager)
            XCTAssertTrue(suspended)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, cleared)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: UUID(), tabID: fixture.tabID
            )
            await manager.debugResumePendingPolicyRouteInstallation()
            let rolledBack = await application.value
            XCTAssertEqual(rolledBack.outcome, "rejected:route_mapping_failed")

            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            XCTAssertEqual(revocation?.isRevocationOnly, true)
            let inert = await manager.debugRunPolicyState(for: fixture.runID)
            XCTAssertNil(inert, "A revocation-only entry is no usable policy")
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)

            // The requeued policy's late application carries no authority, and activates the run's
            // policy with the watermark kept.
            let retried = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(retried.outcome, "applied")
            XCTAssertFalse(retried.additionalTools.contains(toolName))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            XCTAssertEqual(revocation?.isRevocationOnly, false)

            // A fresh admission takes the run with its grant.
            await install(fixture, ownership: admitted)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, admitted)
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testRollbackNeverReplacesAnIndependentlyAdmittedSuccessor() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let first = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: false, workspaceID: fixture.workspaceID)
            let successor = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: first)

            await manager.debugSuspendNextPendingPolicyRouteInstallation()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: fixture.clientName,
                    connectionID: fixture.connectionID,
                    requireRunRouting: true
                )
            }
            let suspended = await waitForSuspendedRouteInstallation(manager)
            XCTAssertTrue(suspended)
            await manager.refreshRunAttemptRichPresentation(for: fixture.clientName, runID: fixture.runID, runOwnership: successor)
            await manager.debugResumePendingPolicyRouteInstallation()
            let rolledBack = await application.value
            XCTAssertEqual(rolledBack.outcome, "rejected:route_mapping_failed")

            let ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, successor, "The restore point's older state is not put back")
            let read = await manager.debugRunPolicyState(for: fixture.runID)
            let state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    /// Oracle rollback cases 1 and 2: a failed route installation rolls back only that connection's
    /// application and requeues the same policy; with no revocation recorded (zero floor) the
    /// restore point's absent run state is removed, and the retry admits the identical attempt.
    func testRoutingFailureRollbackLeavesTheSameAttemptEligibleForItsRetry() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let attempt = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: attempt)
                .subtracting([toolName])
            await install(fixture, ownership: attempt)
            // The restore point holds no run state and the run has no watermark.
            await manager.cleanupRunRoutingState(for: fixture.runID)
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertNil(revocation)

            let failed = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: true
            )
            XCTAssertEqual(failed.outcome, "rejected:route_mapping_failed")
            XCTAssertEqual(failed.additionalTools, [])
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertNil(revocation, "A retryable rollback records no revocation")
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            let pending = await manager.debugPendingPolicySnapshot(for: fixture.clientName)
            XCTAssertTrue(pending.contains { $0.runID == fixture.runID }, "The same policy is requeued")

            let retried = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(retried.outcome, "applied")
            XCTAssertEqual(retried.additionalTools, otherTools.union([toolName]))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, attempt)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership.admissionSequence, 1)
            let ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, attempt)
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 0)
            XCTAssertEqual(revocation?.isRevocationOnly, false)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    /// Oracle rollback cases 5 and 1: a failed application over an eligible restore-point owner
    /// puts that owner back, in the run state and on the connection, with its grant and without
    /// advancing the floor; the requeued retry carries the identical attempt.
    func testRollbackOverAnEligibleRestorePointRestoresItsOwnerWithoutAFloor() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let attempt = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: attempt)
                .subtracting([toolName])
            await install(fixture, ownership: attempt)
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, attempt)

            let failed = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: true
            )
            XCTAssertEqual(failed.outcome, "rejected:route_mapping_failed")
            XCTAssertEqual(failed.additionalTools, otherTools.union([toolName]), "The connection's grant is restored")
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, attempt)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, attempt)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools.union([toolName]))
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 0)

            let retried = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(retried.outcome, "applied")
            XCTAssertEqual(retried.additionalTools, otherTools.union([toolName]))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, attempt)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, attempt)
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools.union([toolName]))
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 0)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    /// Oracle rollback case 3 against a restore point that held the attempt (run state and the
    /// connection's applied ownership): a binding invalidation during the suspended application
    /// survives both restore scopes, and the requeued retry is admitted without authority.
    func testRevocationDuringASuspendedApplicationSurvivesARestorePointThatHeldTheAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: cleared)
                .subtracting([toolName])
            await install(fixture, ownership: cleared)
            await manager.debugApplyRunPolicyState(runID: fixture.runID, connectionID: fixture.connectionID)
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, cleared)

            await manager.debugSuspendNextPendingPolicyRouteInstallation()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: fixture.clientName,
                    connectionID: fixture.connectionID,
                    requireRunRouting: true
                )
            }
            let suspended = await waitForSuspendedRouteInstallation(manager)
            XCTAssertTrue(suspended)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: UUID(), tabID: fixture.tabID
            )
            await manager.debugResumePendingPolicyRouteInstallation()
            let rolledBack = await application.value
            XCTAssertEqual(rolledBack.outcome, "rejected:route_mapping_failed")

            // Connection scope: the restore point's applied attempt and its grant stay revoked.
            XCTAssertEqual(rolledBack.additionalTools, otherTools)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            // Run scope: the restored state keeps the floor and drops the attempt and its grant.
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools)
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            XCTAssertEqual(revocation?.isRevocationOnly, false)

            let retried = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(retried.outcome, "applied")
            XCTAssertEqual(retried.additionalTools, otherTools)
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)
            let resolution = await resolve(routing, fixture)
            XCTAssertEqual(resolution.result, .invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage))
            XCTAssertEqual(resolution.windowReads, 0)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools)
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    /// Oracle rollback case 7: an older attempt's queued policy is staged with the newer installed
    /// attempt; its failed application revokes neither, and the retry carries the newer attempt.
    func testFailedApplicationOfAnOlderQueuedPolicyRevokesNeitherAttempt() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let otherClientName = "codex-rich-reseed-other-\(UUID().uuidString)"
            let older = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let newer = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            let otherTools = AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: newer)
                .subtracting([toolName])
            // The older attempt's policy stays queued for this client; another client's install
            // admits the newer attempt into the run state without touching that queue.
            await install(fixture, ownership: older)
            await install(fixture, ownership: newer, clientName: otherClientName)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, newer)

            let failed = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: true
            )
            XCTAssertEqual(failed.outcome, "rejected:route_mapping_failed")
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, newer)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools.union([toolName]))
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 0, "Neither attempt is revoked")
            var routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertNil(routing.appliedRunOwnership)

            let retried = await manager.debugApplyPendingPolicy(
                clientName: fixture.clientName,
                connectionID: fixture.connectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(retried.outcome, "applied")
            XCTAssertEqual(retried.additionalTools, otherTools.union([toolName]))
            routing = await manager.requestRoutingContext(for: fixture.connectionID)
            XCTAssertEqual(routing.appliedRunOwnership?.ownership, newer)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, newer)
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools, otherTools.union([toolName]))
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 0)

            await manager.clearClientConnectionPolicy(for: otherClientName, windowID: fixture.windowID, runID: fixture.runID)
            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testCleanupDemotesAWatermarkBearingStateAndALateInstallStaysUnauthorized() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let fixture = Fixture()
            let cleared = Self.ownership(tabID: fixture.tabID, sequence: 1, enabled: true, workspaceID: fixture.workspaceID)
            let admitted = Self.ownership(tabID: fixture.tabID, sequence: 2, enabled: true, workspaceID: fixture.workspaceID)
            await install(fixture, ownership: cleared)
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: UUID(), tabID: fixture.tabID
            )
            await manager.cleanupRunRoutingState(for: fixture.runID)
            var revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            XCTAssertEqual(revocation?.isRevocationOnly, true)
            // A routing reseed never revives the inert entry.
            await manager.debugReseedRunPolicyRouting(
                runID: fixture.runID, windowID: fixture.windowID, workspaceID: fixture.workspaceID, tabID: fixture.tabID
            )
            let inert = await manager.debugRunPolicyState(for: fixture.runID)
            XCTAssertNil(inert)

            // A late install of the cleared attempt activates the run's policy without its authority.
            await install(fixture, ownership: cleared)
            var ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertNil(ownership)
            var read = await manager.debugRunPolicyState(for: fixture.runID)
            var state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), false)
            revocation = await manager.debugRunPolicyRevocation(for: fixture.runID)
            XCTAssertEqual(revocation?.maxRevokedAdmissionSequence, 1)
            XCTAssertEqual(revocation?.isRevocationOnly, false)

            // A fresh admission's install takes the run with its grant.
            await install(fixture, ownership: admitted)
            ownership = await manager.debugRunPolicyOwnership(for: fixture.runID)
            XCTAssertEqual(ownership, admitted)
            read = await manager.debugRunPolicyState(for: fixture.runID)
            state = try XCTUnwrap(read)
            XCTAssertEqual(state.additionalTools?.contains(toolName), true)

            await cleanUp(fixture)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: - Helpers

    #if DEBUG
        /// Waits, by yielding (no timed sleep), until a pending application parks at its route
        /// installation (`debugSuspendNextPendingPolicyRouteInstallation`).
        private func waitForSuspendedRouteInstallation(_ manager: ServerNetworkManager) async -> Bool {
            for _ in 0 ..< 10000 {
                if await manager.debugIsPendingPolicyRouteInstallationSuspended() {
                    return true
                }
                await Task.yield()
            }
            return false
        }
    #endif

    private struct Fixture {
        let clientName = "codex-rich-reseed-\(UUID().uuidString)"
        let runID = UUID()
        let tabID = UUID()
        let workspaceID = UUID()
        let connectionID = UUID()
        let windowID = Int.random(in: 61000 ..< 62000)
    }

    private func install(
        _ fixture: Fixture,
        ownership: AgentRunOwnership?,
        additionalTools: Set<String>? = nil,
        clientName: String? = nil,
        on manager: ServerNetworkManager = .shared
    ) async {
        await manager.installClientConnectionPolicy(
            for: clientName ?? fixture.clientName,
            windowID: fixture.windowID,
            restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
            oneShot: true,
            reason: "rich presentation ownership reseed test",
            ttl: 10,
            tabID: fixture.tabID,
            runID: fixture.runID,
            additionalTools: additionalTools
                ?? AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec, runOwnership: ownership),
            allowedToolsOverride: nil,
            sessionProfile: .standard,
            purpose: .agentModeRun,
            runOwnership: ownership
        )
    }

    /// Resolves request metadata captured from `routing` with no windows, counting window reads.
    private func resolve(
        _ routing: ServerNetworkManager.RequestRoutingContext,
        _ fixture: Fixture
    ) async -> (result: RichPresentationMCPAuthorityResolver.Denial?, windowReads: Int) {
        var windowReads = 0
        let resolver = RichPresentationMCPAuthorityResolver(
            isGatewayPrincipalConnection: { _ in false },
            windows: {
                windowReads += 1
                return []
            }
        )
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: fixture.connectionID,
            clientName: fixture.clientName,
            windowID: fixture.windowID,
            runPurpose: routing.runPurpose,
            actorRoutedRunTab: routing.actorRoutedRunTab,
            appliedRunOwnership: routing.appliedRunOwnership
        )
        let result = await resolver.resolve(metadata: metadata)
        if case let .failure(denial) = result {
            return (denial, windowReads)
        }
        return (nil, windowReads)
    }

    private func cleanUp(_ fixture: Fixture, on manager: ServerNetworkManager = .shared) async {
        await manager.clearClientConnectionPolicy(for: fixture.clientName, windowID: fixture.windowID, runID: fixture.runID)
        await manager.removeConnection(fixture.connectionID)
        await manager.cleanupRunRoutingState(for: fixture.runID)
    }

    private static func ownership(
        tabID: UUID,
        sequence: UInt64,
        enabled: Bool,
        workspaceID: UUID
    ) -> AgentRunOwnership {
        AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: tabID, persistentSessionID: UUID()),
            richPresentationPolicy: .captured(workspaceID: workspaceID, enabled: enabled, approvedImageHosts: []),
            admissionSequence: sequence
        )
    }
}

/// An in-memory routed connection that counts `tools/list_changed` deliveries (no socket).
private actor ReseedFixtureConnection: MCPServerConnection {
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
