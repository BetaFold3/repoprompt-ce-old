import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
import XCTest

#if DEBUG
    /// Later turns on a long-lived agent process: each turn's bootstrap lease revokes its unused
    /// pending policy when no new helper connection arrives. `revokeClientConnectionPolicy` keeps
    /// the run's routing while a live, ancestry-proven helper of the run (admitted for the client)
    /// remains, so its later loss is still observed, and prunes the run's unproven routes; without
    /// such a helper it clears routing as before. A turn's installed run policy reaches a retained
    /// helper at turn start when its applied projection differs, and a later turn whose launch's
    /// helper is already routed releases its lease without the routing wait. Uses private managers,
    /// in-memory fixture connections and a fake process table (no socket, helper or agent process),
    /// plus a real registered window where the window-side mapping matters.
    final class MCPRunRouteRetentionTests: XCTestCase {
        private actor FixtureConnection: MCPServerConnection {
            private(set) var toolListChangedCount = 0
            /// Awaited inside each `tools/list_changed` delivery, after it was counted.
            private var notificationHook: (@Sendable () async -> Void)?

            func setNotificationHook(_ hook: (@Sendable () async -> Void)?) {
                notificationHook = hook
            }

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
                if let notificationHook {
                    await notificationHook()
                }
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

        /// A mutable fake process table; unknown PIDs are absent.
        private final class FakeProcessTable: MCPProcessTableReading, @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [pid_t: MCPProcessTableEntry] = [:]

            @discardableResult
            func spawn(_ pid: pid_t, parent: pid_t, start: Int64) -> MCPHelperProcessIdentity {
                let identity = MCPHelperProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0)
                set(pid, .present(identity: identity, parentPID: parent, isZombie: false))
                return identity
            }

            func set(_ pid: pid_t, _ entry: MCPProcessTableEntry) {
                lock.withLock { entries[pid] = entry }
            }

            func entry(for pid: pid_t) -> MCPProcessTableEntry {
                lock.withLock { entries[pid] ?? .absent }
            }
        }

        /// Claims once across concurrent callers (the refresh suspension hook runs per connection).
        private final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false

            func claim() -> Bool {
                lock.withLock {
                    defer { claimed = true }
                    return !claimed
                }
            }
        }

        /// A value written from a `@Sendable` hook and read by the test afterwards.
        private final class LockedValue<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Value

            init(_ value: Value) {
                self.value = value
            }

            func set(_ newValue: Value) {
                lock.withLock { value = newValue }
            }

            func get() -> Value {
                lock.withLock { value }
            }
        }

        private struct FixtureError: Error {
            let message: String
        }

        private actor LossRecorder {
            private(set) var losses: [AgentMCPRunConnectionLoss] = []

            func record(_ loss: AgentMCPRunConnectionLoss) {
                losses.append(loss)
            }

            /// Bounded: fails the test instead of hanging when the losses never arrive.
            func waitForCount(
                _ count: Int,
                timeout: Duration = .seconds(10),
                file: StaticString = #filePath,
                line: UInt = #line
            ) async {
                let deadline = ContinuousClock.now.advanced(by: timeout)
                while losses.count < count {
                    guard ContinuousClock.now < deadline else {
                        XCTFail("timed out waiting for \(count) loss(es); got \(losses.count)", file: file, line: line)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }

        // Process tree: shell 3000 → agent 4000 → helper 5000; restarted agent 4100 → helper 5100.
        private let clientName = AgentProviderKind.claudeMCPClientID
        private let shellPID: pid_t = 3000
        private let agentPID: pid_t = 4000
        private let otherAgentPID: pid_t = 4100
        private let helperPID: pid_t = 5000
        private let otherHelperPID: pid_t = 5100
        private let agentStart: Int64 = 400
        private let windowID = 62001

        private func makeManager(table: FakeProcessTable) async -> ServerNetworkManager {
            let manager = ServerNetworkManager()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("route-retention-terminal-records-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            await manager.debugSetTerminalRecordsDirectoryOverride(directory)
            await manager.debugSetHelperProcessTableReader(table)
            await manager.debugSetHelperExitWatchManualTicks(true)
            return manager
        }

        private func makeTable() -> FakeProcessTable {
            let table = FakeProcessTable()
            table.spawn(shellPID, parent: 1, start: 300)
            table.spawn(agentPID, parent: shellPID, start: agentStart)
            table.spawn(otherAgentPID, parent: shellPID, start: 410)
            table.spawn(helperPID, parent: agentPID, start: 500)
            table.spawn(otherHelperPID, parent: otherAgentPID, start: 510)
            return table
        }

        /// A registered bootstrap helper connection (admission snapshot captured from the table)
        /// routed to `runID` actor-side, with the run's policy state seeded as an installed turn
        /// policy leaves it. The connection is bound to the run policy's window (the fixture's
        /// window when this call seeds the policy), as a production route is; a proven route needs
        /// that binding.
        @discardableResult
        private func routedHelper(
            on manager: ServerNetworkManager,
            runID: UUID,
            helperPID: pid_t,
            connection: FixtureConnection = FixtureConnection(),
            sessionToken: String = "route-retention-\(UUID().uuidString)",
            clientName overrideClientName: String? = nil,
            seedsWindow: Bool = true
        ) async -> UUID {
            let clientName = overrideClientName ?? clientName
            let connectionID = UUID()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: clientName,
                sessionToken: sessionToken
            )
            await manager.debugSetAdmittedClientIDForTesting(connectionID: connectionID, clientID: clientName)
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: helperPID)
            let policyWindowID = await manager.debugRunPolicyState(for: runID)?.windowID ?? windowID
            await manager.debugSeedConnectionRunRouting(
                connectionID: connectionID,
                runID: runID,
                purpose: .agentModeRun,
                windowID: seedsWindow ? policyWindowID : nil
            )
            if await manager.debugRunPolicyState(for: runID) == nil {
                await manager.debugSeedRunPolicyState(
                    runID: runID,
                    windowID: windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    additionalTools: nil,
                    purpose: .agentModeRun
                )
            }
            return connectionID
        }

        private func revoke(_ manager: ServerNetworkManager, runID: UUID) async {
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
        }

        private func launch(_ pid: pid_t) -> AgentMCPRunLaunchIdentity {
            AgentMCPRunLaunchIdentity(token: UUID(), agentProcessID: pid)
        }

        private func observe(
            _ manager: ServerNetworkManager,
            runID: UUID,
            launch: AgentMCPRunLaunchIdentity,
            recorder: LossRecorder
        ) async {
            await manager.registerRunConnectionLossObserver(for: runID, launch: launch) { loss in
                await recorder.record(loss)
            }
        }

        /// The fields of every recorded routing event of the run named `event`, oldest first.
        private func routingEvents(
            _ manager: ServerNetworkManager,
            runID: UUID,
            named event: String
        ) async -> [[String: String]] {
            let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 1000)
            let events = payload["events"] as? [[String: Any]] ?? []
            return events
                .filter { $0["event"] as? String == event }
                .map { $0["fields"] as? [String: String] ?? [:] }
        }

        private func lastPolicyRevokedFields(
            _ manager: ServerNetworkManager,
            runID: UUID
        ) async -> [String: String]? {
            await routingEvents(manager, runID: runID, named: "policy_revoked").last
        }

        /// Installs a later turn's run policy as its bootstrap lease does: the install, then (after
        /// the lease released the global gate) the turn-start refresh of retained helpers.
        private func installTurnPolicy(
            _ manager: ServerNetworkManager,
            runID: UUID,
            windowID: Int? = nil,
            restrictedTools: Set<String> = AgentModeMCPToolPolicy.restrictedTools,
            allowedToolsOverride: Set<String>? = nil,
            taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
            allowsAgentExternalControlTools: Bool = false
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID ?? self.windowID,
                restrictedTools: restrictedTools,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                runID: runID,
                allowedToolsOverride: allowedToolsOverride,
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: true
            )
            await manager.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: runID)
        }

        // MARK: - Preservation and fail-closed cleanup (actor routing state)

        func testRevocationKeepsTheRouteOfALiveAncestryProvenHelper() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            // A later turn's lease installs its policy and an application is past reservation.
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            await manager.debugBeginPendingPolicyApplicationForTesting(runID: runID)

            await revoke(manager, runID: runID)

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID }, "the turn's pending policy is revoked")
            let applicationID = await manager.debugPendingPolicyApplicationID(runID: runID)
            XCTAssertNil(applicationID, "an application past reservation is invalidated")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID, "the live proven helper keeps its run route")
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy)
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertEqual(runWindow, windowID)
            let preservations = await manager.debugRoutingPreservingPolicyRevocationCount
            XCTAssertEqual(preservations, 1)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "true")
            XCTAssertEqual(fields["preserved_connection_count"], "1")
            XCTAssertEqual(fields["pruned_connection_count"], "0")
        }

        private enum FailClosedCase: CaseIterable {
            case agentPIDReused
            case agentAbsent
            case agentZombie
            case agentUnreadable
            case expectedPIDNotRegistered
            case expectedPIDRegisteredUnderAnotherRun
            case connectionBeingRemoved
            case connectionTerminalClaimed
            case connectionWatchdogTerminal
            case admittedForAnotherClient
        }

        func testRevocationWithoutLiveAncestryProofClearsRunRouting() async {
            for failCase in FailClosedCase.allCases {
                let label = "\(failCase)"
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                switch failCase {
                case .expectedPIDNotRegistered:
                    break
                case .expectedPIDRegisteredUnderAnotherRun:
                    await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: UUID())
                default:
                    await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                }
                let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
                switch failCase {
                case .agentPIDReused:
                    table.spawn(agentPID, parent: shellPID, start: 900)
                case .agentAbsent:
                    table.set(agentPID, .absent)
                case .agentZombie:
                    table.set(agentPID, .present(
                        identity: MCPHelperProcessIdentity(pid: agentPID, startSeconds: agentStart, startMicroseconds: 0),
                        parentPID: shellPID,
                        isZombie: true
                    ))
                case .agentUnreadable:
                    table.set(agentPID, .unreadable)
                case .connectionBeingRemoved:
                    await manager.debugMarkConnectionBeingRemovedForTesting(connectionID, true)
                case .connectionTerminalClaimed:
                    await manager.debugCommitTerminalRecordForTesting(connectionID: connectionID, reason: "peer_eof")
                case .connectionWatchdogTerminal:
                    await manager.debugAbortConnectionForExecutionWatchdog(connectionID: connectionID, toolName: "slow_tool")
                case .admittedForAnotherClient:
                    await manager.debugSetAdmittedClientIDForTesting(connectionID: connectionID, clientID: "codex-cli")
                case .expectedPIDNotRegistered, .expectedPIDRegisteredUnderAnotherRun:
                    break
                }

                await revoke(manager, runID: runID)

                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(route, label)
                let runPolicy = await manager.debugRunPolicyState(for: runID)
                XCTAssertNil(runPolicy, label)
                let runWindow = await manager.debugWindowIDForRunID(runID)
                XCTAssertNil(runWindow, label)
                let preservations = await manager.debugRoutingPreservingPolicyRevocationCount
                XCTAssertEqual(preservations, 0, label)
                let fields = await lastPolicyRevokedFields(manager, runID: runID)
                XCTAssertEqual(fields?["routing_preserved"], "false", label)
                XCTAssertEqual(fields?["preserved_connection_count"], "0", label)
                if failCase == .connectionBeingRemoved {
                    await manager.debugMarkConnectionBeingRemovedForTesting(connectionID, false)
                }
            }
        }

        /// Without an admission snapshot (the peer could not be read at admission) nothing proves
        /// the helper's agent instance: a PID-only ancestry walk cannot tell a reused PID from the
        /// original. Revocation fails closed even when the expected PID really is an ancestor.
        func testWithoutAnAdmissionSnapshotRevocationFailsClosed() async throws {
            let ownPID = getpid()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            defer {
                child.terminate()
                child.waitUntilExit()
            }
            let unrelatedPID = child.processIdentifier

            for expectedPID in [ownPID, unrelatedPID] {
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                await manager.registerExpectedAgentPID(expectedPID, for: clientName, runID: runID)
                // The fake table does not know the test process, so admission captures no snapshot.
                let connectionID = await routedHelper(on: manager, runID: runID, helperPID: ownPID)
                let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
                XCTAssertNil(snapshot)

                await revoke(manager, runID: runID)

                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(route, "expected pid \(expectedPID)")
                let runPolicy = await manager.debugRunPolicyState(for: runID)
                XCTAssertNil(runPolicy, "expected pid \(expectedPID)")
                let fields = await lastPolicyRevokedFields(manager, runID: runID)
                XCTAssertEqual(fields?["routing_preserved"], "false", "expected pid \(expectedPID)")
            }
        }

        /// A snapshot that stops short of the agent (an unreadable ancestor at admission) proves
        /// nothing: ownership is decided by the admission snapshot alone, with no live re-capture,
        /// even once the agent reads back as the registered instance and the helper is unchanged.
        func testSnapshotLackingTheAgentFailsClosedWithoutALiveFallback() async {
            for helperRecycled in [false, true] {
                let label = "helper recycled: \(helperRecycled)"
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                table.set(agentPID, .unreadable)
                let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
                let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
                XCTAssertEqual(snapshot?.ancestorPIDs, [], label)
                table.spawn(agentPID, parent: shellPID, start: agentStart)
                if helperRecycled {
                    table.spawn(helperPID, parent: agentPID, start: 950)
                }

                await revoke(manager, runID: runID)

                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(route, label)
                let runPolicy = await manager.debugRunPolicyState(for: runID)
                XCTAssertNil(runPolicy, label)
                let fields = await lastPolicyRevokedFields(manager, runID: runID)
                XCTAssertEqual(fields?["routing_preserved"], "false", label)
            }
        }

        /// The agent was unreadable when its PID was registered (no registered instance), then
        /// readable when the helper was admitted (the snapshot holds it): nothing binds the
        /// snapshot's instance to the registration, so revocation fails closed.
        func testUnreadableRegistrationThenReadableAdmissionFailsClosed() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            table.set(agentPID, .unreadable)
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let identityRecorded = await manager.debugHasExpectedAgentIdentityEntry(runID: runID)
            XCTAssertFalse(identityRecorded, "an unreadable registration records no instance (and no empty map)")
            table.spawn(agentPID, parent: shellPID, start: agentStart)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
            XCTAssertEqual(snapshot?.ancestorPIDs.contains(agentPID), true, "fixture: admission saw the agent")

            await revoke(manager, runID: runID)

            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy)
            let fields = await lastPolicyRevokedFields(manager, runID: runID)
            XCTAssertEqual(fields?["routing_preserved"], "false")
        }

        /// Production order: the launch's loss observer registers first (reading the agent's
        /// instance), then the expected PID. When only the expected-PID registration read the agent
        /// as unreadable, the observer's earlier read is the registered instance and the helper is
        /// owned; when the agent was unreadable at both, nothing is registered and revocation fails
        /// closed.
        func testObserverReadBeforeAnUnreadableRegistrationIsTheRegisteredInstance() async {
            for observerReadable in [true, false] {
                let label = "agent readable at observer registration: \(observerReadable)"
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                if !observerReadable {
                    table.set(agentPID, .unreadable)
                }
                await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
                table.set(agentPID, .unreadable)
                await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                let identityRecorded = await manager.debugHasExpectedAgentIdentityEntry(runID: runID)
                XCTAssertFalse(identityRecorded, "\(label): the unreadable registration records no instance")
                table.spawn(agentPID, parent: shellPID, start: agentStart)
                let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)

                await revoke(manager, runID: runID)

                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertEqual(route, observerReadable ? runID : nil, label)
                let fields = await lastPolicyRevokedFields(manager, runID: runID)
                XCTAssertEqual(fields?["routing_preserved"], observerReadable ? "true" : "false", label)
                await manager.removeConnection(connectionID)
            }
        }

        /// The registered agent exited and another process reused its PID before the helper was
        /// admitted: the snapshot holds the PID with another start time, which is not the
        /// registered instance, so revocation fails closed.
        func testAgentPIDReusedBetweenRegistrationAndAdmissionFailsClosed() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            table.spawn(agentPID, parent: shellPID, start: 777)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
            XCTAssertEqual(snapshot?.chainIdentity(of: agentPID)?.startSeconds, 777, "fixture: admission saw the reused PID")

            await revoke(manager, runID: runID)

            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy)
            let fields = await lastPolicyRevokedFields(manager, runID: runID)
            XCTAssertEqual(fields?["routing_preserved"], "false")
        }

        /// A revocation while a restart has both launches' PIDs registered (the old one not yet
        /// cleared): each helper is owned by a registered, live agent instance, so both routes are
        /// kept and nothing is pruned. Launch-bound evidence still tells them apart.
        func testRevocationWithBothLaunchPIDsRegisteredKeepsBothOwnedRoutes() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let oldConnectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let newConnectionID = await routedHelper(on: manager, runID: runID, helperPID: otherHelperPID)

            await revoke(manager, runID: runID)

            let oldRoute = await manager.debugCachedRunID(for: oldConnectionID)
            XCTAssertEqual(oldRoute, runID, "the old launch's helper is owned by a registered instance")
            let newRoute = await manager.debugCachedRunID(for: newConnectionID)
            XCTAssertEqual(newRoute, runID)
            let pruned = await manager.debugPrunedUnprovenRunRouteCount
            XCTAssertEqual(pruned, 0)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "true")
            XCTAssertEqual(fields["preserved_connection_count"], "2")
            XCTAssertEqual(fields["pruned_connection_count"], "0")

            // Once the old launch's PID is cleared, its helper proves nothing.
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let oldProven = await manager.debugAncestryProvesExpectedAgent(connectionID: oldConnectionID, runID: runID)
            XCTAssertFalse(oldProven)
            let newProven = await manager.debugAncestryProvesExpectedAgent(connectionID: newConnectionID, runID: runID)
            XCTAssertTrue(newProven)
        }

        /// Run-route retention is Claude-only: a Codex or OMP client with a live helper that is
        /// ancestry-proven exactly as a Claude one would be still gets the full cleanup on
        /// revocation, no turn-start refresh, and no early release.
        func testNonClaudeClientsKeepTheFullCleanupOnRevocation() async throws {
            for client in [AgentProviderKind.codexMCPClientID, AgentProviderKind.ohMyPiMCPClientID] {
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                await manager.registerExpectedAgentPID(agentPID, for: client, runID: runID)
                let connection = FixtureConnection()
                let connectionID = await routedHelper(
                    on: manager, runID: runID, helperPID: helperPID, connection: connection, clientName: client
                )
                await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionID)
                let baseline = await connection.toolListChangedCount
                let proven = await manager.debugAncestryProvesExpectedAgent(connectionID: connectionID, runID: runID)
                try require(proven, "fixture (\(client)): the helper is ancestry-proven")

                var changed = AgentModeMCPToolPolicy.restrictedTools
                changed.insert("route_retention_probe_tool")
                await manager.installClientConnectionPolicy(
                    for: client,
                    windowID: windowID,
                    restrictedTools: changed,
                    oneShot: true,
                    reason: "later turn",
                    ttl: 10,
                    runID: runID,
                    purpose: .agentModeRun,
                    requiresExpectedAgentPID: true
                )
                await manager.refreshRetainedRunPolicyForTurnStart(for: client, runID: runID)
                let afterRefresh = await connection.toolListChangedCount
                XCTAssertEqual(afterRefresh, baseline, "\(client): no turn-start refresh")
                let released = await manager.releasePendingRunPolicyForProvenRoute(
                    for: client, windowID: windowID, runID: runID, agentPID: agentPID
                )
                XCTAssertFalse(released, "\(client): no early release")

                await manager.revokeClientConnectionPolicy(for: client, windowID: windowID, runID: runID)

                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(route, client)
                let runPolicy = await manager.debugRunPolicyState(for: runID)
                XCTAssertNil(runPolicy, client)
                let runWindow = await manager.debugWindowIDForRunID(runID)
                XCTAssertNil(runWindow, client)
                let fields = await lastPolicyRevokedFields(manager, runID: runID)
                XCTAssertEqual(fields?["routing_preserved"], "false", client)
                let refreshes = await manager.debugRetainedRunPolicyRefreshCount
                XCTAssertEqual(refreshes, 0, client)
            }
        }

        // MARK: - Loss observation after a later turn's revocation

        /// The later-turn regression: turn 2's routing wait times out and revokes its policy, then
        /// the retained helper dies. The helper-exit watch still opens and reports to the launch.
        func testHelperExitAfterALaterTurnRevocationStillReportsTheLoss() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)

            await revoke(manager, runID: runID)
            await manager.removeConnection(
                connectionID,
                context: MCPConnectionCloseContext(reason: "peer_eof", initiator: .peer)
            )
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 1, "the retained route opens the helper-exit watch")

            table.set(helperPID, .absent)
            await manager.debugAdvanceHelperExitWatchClock(by: .seconds(2))
            let delivered = await manager.debugRunHelperExitWatchTick()
            XCTAssertEqual(delivered, 1)
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .helperExited)
            XCTAssertEqual(loss.connectionID, connectionID)
            XCTAssertEqual(loss.agentProcessID, agentPID)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
        }

        func testWatchdogAbortAfterALaterTurnRevocationReportsWithoutACallTimeRunID() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)

            await revoke(manager, runID: runID)
            await manager.debugAbortConnectionForExecutionWatchdog(
                connectionID: connectionID,
                toolName: "slow_tool",
                callTimeRunID: nil
            )
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .toolExecutionWatchdog)
            XCTAssertEqual(loss.toolName, "slow_tool")
            XCTAssertEqual(loss.agentProcessID, agentPID)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
        }

        /// A restart within the run: the old agent's PID is cleared and the new agent's helper is
        /// routed. Clearing the old PID unroutes the old helper (route and affinity) at that
        /// moment, leaving run-level state; the new helper proves the run's current agent and
        /// keeps its route and affinity through the later revocation, which has nothing to prune.
        func testRestartOverlapKeepsTheNewLaunchHelperRoute() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let oldToken = "route-retention-old-\(UUID().uuidString)"
            let newToken = "route-retention-new-\(UUID().uuidString)"
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let oldConnectionID = await routedHelper(
                on: manager, runID: runID, helperPID: helperPID, sessionToken: oldToken
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: oldConnectionID)
            let oldAffinityBefore = await manager.debugLiveRunAffinityRunID(sessionKey: oldToken)
            XCTAssertEqual(oldAffinityBefore, runID, "fixture: the old helper's session has run affinity")
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let oldRouteAtClear = await manager.debugCachedRunID(for: oldConnectionID)
            XCTAssertNil(oldRouteAtClear, "clearing the old PID unroutes its helper at once")
            let oldAffinityAtClear = await manager.debugLiveRunAffinityRunID(sessionKey: oldToken)
            XCTAssertNil(oldAffinityAtClear)
            let runPolicyAtClear = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicyAtClear, "the registration hook never clears run-level state")
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let newConnectionID = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, sessionToken: newToken
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: newConnectionID)

            let oldProven = await manager.debugAncestryProvesExpectedAgent(connectionID: oldConnectionID, runID: runID)
            XCTAssertFalse(oldProven, "the old launch's helper proves nothing about the restarted agent")
            let newProven = await manager.debugAncestryProvesExpectedAgent(connectionID: newConnectionID, runID: runID)
            XCTAssertTrue(newProven)

            await revoke(manager, runID: runID)

            let newRoute = await manager.debugCachedRunID(for: newConnectionID)
            XCTAssertEqual(newRoute, runID)
            let oldRoute = await manager.debugCachedRunID(for: oldConnectionID)
            XCTAssertNil(oldRoute, "the unproven old helper is unrouted")
            let oldAffinity = await manager.debugLiveRunAffinityRunID(sessionKey: oldToken)
            XCTAssertNil(oldAffinity, "the unproven old helper's affinity is gone")
            let newAffinity = await manager.debugLiveRunAffinityRunID(sessionKey: newToken)
            XCTAssertEqual(newAffinity, runID)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy, "run-level state stays")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertEqual(runWindow, windowID)
            let pruned = await manager.debugPrunedUnprovenRunRouteCount
            XCTAssertEqual(pruned, 1, "one unroute in total: the old helper's, at the clear")
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["preserved_connection_count"], "1")
            XCTAssertEqual(fields["pruned_connection_count"], "0", "nothing unproven was left to prune")
        }

        /// The kept helper closes during the prune's MainActor hop: the revocation re-checks after
        /// the hop, finds no proven route left, and falls back to the full cleanup.
        func testKeptHelperClosingDuringThePruneHopFallsBackToTheFullCleanup() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let keptConnectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            // An unproven second route of the run (no admission snapshot: the test process peer).
            let unprovenConnectionID = await routedHelper(on: manager, runID: runID, helperPID: getpid())
            let once = OnceFlag()
            await manager.debugSetAfterRevocationPruneSuspension {
                guard once.claim() else { return }
                await manager.removeConnection(
                    keptConnectionID,
                    context: MCPConnectionCloseContext(reason: "peer_eof", initiator: .peer)
                )
            }

            await revoke(manager, runID: runID)
            await manager.debugSetAfterRevocationPruneSuspension(nil)

            let pruned = await manager.debugPrunedUnprovenRunRouteCount
            XCTAssertEqual(pruned, 1, "the unproven route was pruned before the hop")
            let unprovenRoute = await manager.debugCachedRunID(for: unprovenConnectionID)
            XCTAssertNil(unprovenRoute)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, "nothing proven after the hop: the run's routing state is cleared")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertNil(runWindow)
            let preservations = await manager.debugRoutingPreservingPolicyRevocationCount
            XCTAssertEqual(preservations, 0)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "false")
            XCTAssertEqual(fields["pruned_connection_count"], "1")
            await manager.removeConnection(unprovenConnectionID)
        }

        /// Two proven helpers (both launches' PIDs registered) and an unproven route, whose
        /// window-side cleanup is the revocation's one suspension. During that hop the first
        /// launch's PID is cleared: the clear itself unroutes its helper actor-side (route and
        /// affinity, in the same synchronous step), and the other proven helper stays.
        func testAKeptHelperLosingItsProofDuringTheWindowCleanupHopIsUnrouted() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let firstToken = "route-retention-first-\(UUID().uuidString)"
            let secondToken = "route-retention-second-\(UUID().uuidString)"
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let firstConnectionID = await routedHelper(
                on: manager, runID: runID, helperPID: helperPID, sessionToken: firstToken
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: firstConnectionID)
            let secondConnectionID = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, sessionToken: secondToken
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: secondConnectionID)
            // An unproven third route (no admission snapshot: the test process peer).
            let unprovenConnectionID = await routedHelper(on: manager, runID: runID, helperPID: getpid())
            let firstAffinityBefore = await manager.debugLiveRunAffinityRunID(sessionKey: firstToken)
            try require(firstAffinityBefore == runID, "fixture: the first helper's session has run affinity")
            let once = OnceFlag()
            let clientName = clientName
            let agentPID = agentPID
            let routeRightAfterClear = LockedValue<UUID?>(UUID())
            await manager.debugSetAfterRevocationPruneSuspension {
                guard once.claim() else { return }
                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
                await routeRightAfterClear.set(manager.debugCachedRunID(for: firstConnectionID))
            }

            await revoke(manager, runID: runID)
            await manager.debugSetAfterRevocationPruneSuspension(nil)
            await manager.debugAwaitScheduledRunWindowCleanups()

            XCTAssertNil(routeRightAfterClear.get(), "unrouted by the clear itself, while the revocation is suspended")
            let firstRoute = await manager.debugCachedRunID(for: firstConnectionID)
            XCTAssertNil(firstRoute, "the helper that lost its proof during the hop is unrouted")
            let firstAffinity = await manager.debugLiveRunAffinityRunID(sessionKey: firstToken)
            XCTAssertNil(firstAffinity, "and its affinity is gone")
            let secondRoute = await manager.debugCachedRunID(for: secondConnectionID)
            XCTAssertEqual(secondRoute, runID)
            let secondAffinity = await manager.debugLiveRunAffinityRunID(sessionKey: secondToken)
            XCTAssertEqual(secondAffinity, runID)
            let unprovenRoute = await manager.debugCachedRunID(for: unprovenConnectionID)
            XCTAssertNil(unprovenRoute)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy, "a proven helper remains: run-level state stays")
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "true")
            XCTAssertEqual(fields["preserved_connection_count"], "1")
            XCTAssertEqual(fields["pruned_connection_count"], "1", "the revocation pruned the unproven route")
            let unrouted = await manager.debugPrunedUnprovenRunRouteCount
            XCTAssertEqual(unrouted, 2, "plus the clear's unroute of the first helper")
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.map { $0["unrouted_connection_count"] }, ["1"])
            XCTAssertEqual(proofLost.map { $0["cause"] }, ["expected_pid_cleared"])
            await manager.removeConnection(unprovenConnectionID)
        }

        /// The reviewer's interleaving: proven helpers A and B and an unproven route C. During C's
        /// window-cleanup hop (the revocation's prune) A's registration is cleared, which unroutes A
        /// at once and schedules A's own window cleanup; during A's hop B's registration is cleared
        /// too. No stale partition keeps B: the final check finds nothing proven and the run's
        /// routing state (routes, affinity, run state) is fully cleaned up.
        func testProofLostDuringASecondCleanupHopLeavesNothingAndFullyCleansUp() async throws {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let tokenA = "route-retention-a-\(UUID().uuidString)"
            let tokenB = "route-retention-b-\(UUID().uuidString)"
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let connectionIDA = await routedHelper(on: manager, runID: runID, helperPID: helperPID, sessionToken: tokenA)
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionIDA)
            let connectionIDB = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, sessionToken: tokenB
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionIDB)
            // An unproven third route (no admission snapshot: the test process peer).
            let connectionIDC = await routedHelper(on: manager, runID: runID, helperPID: getpid())
            let affinityBBefore = await manager.debugLiveRunAffinityRunID(sessionKey: tokenB)
            try require(affinityBBefore == runID, "fixture: B's session has run affinity")
            let clientName = clientName
            let agentPID = agentPID
            let otherAgentPID = otherAgentPID
            let hops = LockedValue<[[UUID]]>([])
            await manager.debugSetBeforeRunWindowCleanupHop { connectionIDs in
                hops.set(hops.get() + [connectionIDs])
                if connectionIDs == [connectionIDC] {
                    // C's hop: A loses its registration; stay in this hop until A's own hop ran.
                    await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while await manager.debugExpectedAgentPIDs(runID: runID).contains(otherAgentPID),
                          ContinuousClock.now < deadline
                    {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                } else if connectionIDs == [connectionIDA] {
                    // A's hop: B loses its registration too.
                    await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
                }
            }

            await revoke(manager, runID: runID)
            await manager.debugAwaitScheduledRunWindowCleanups()
            await manager.debugSetBeforeRunWindowCleanupHop(nil)

            let recordedHops = hops.get()
            XCTAssertEqual(Array(recordedHops.prefix(2)), [[connectionIDC], [connectionIDA]], "fixture: C's hop, then A's")
            XCTAssertTrue(recordedHops.contains([connectionIDB]), "B's own window cleanup ran")
            for (label, connectionID) in [("A", connectionIDA), ("B", connectionIDB), ("C", connectionIDC)] {
                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertNil(route, "\(label) is unrouted")
            }
            let affinityA = await manager.debugLiveRunAffinityRunID(sessionKey: tokenA)
            XCTAssertNil(affinityA)
            let affinityB = await manager.debugLiveRunAffinityRunID(sessionKey: tokenB)
            XCTAssertNil(affinityB, "no stale partition keeps B's affinity")
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, "nothing proven is left: the run's routing state is cleared")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertNil(runWindow)
            let preservations = await manager.debugRoutingPreservingPolicyRevocationCount
            XCTAssertEqual(preservations, 0)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "false")
            XCTAssertEqual(fields["preserved_connection_count"], "0")
            XCTAssertEqual(fields["pruned_connection_count"], "1")
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.count, 2, "A's and B's unroutes, one per clear")
            for connectionID in [connectionIDA, connectionIDB, connectionIDC] {
                await manager.removeConnection(connectionID)
            }
        }

        /// The last proven helper loses its registration while the revocation's backstop refresh
        /// is suspended in its `tools/list_changed`: the clear unroutes it, and the final check
        /// finds no proven route, so route, affinity and run state are all cleaned up.
        func testLastProvenHelperLosingItsRegistrationDuringTheRevokeRefreshIsFullyCleanedUp() async throws {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let token = "route-retention-last-\(UUID().uuidString)"
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connection = FixtureConnection()
            let connectionID = await routedHelper(
                on: manager, runID: runID, helperPID: helperPID, connection: connection, sessionToken: token
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionID)
            // A changed policy installed without its turn-start refresh: only the revocation's
            // backstop refresh delivers it.
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: changed,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            let baseline = await connection.toolListChangedCount
            let once = OnceFlag()
            let clientName = clientName
            let agentPID = agentPID
            await connection.setNotificationHook {
                guard once.claim() else { return }
                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            }

            await revoke(manager, runID: runID)
            await manager.debugAwaitScheduledRunWindowCleanups()

            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, baseline + 1, "fixture: the backstop refresh announced the policy")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            let affinity = await manager.debugLiveRunAffinityRunID(sessionKey: token)
            XCTAssertNil(affinity)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, "no proven route at the final check: the run state is cleared")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertNil(runWindow)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "false")
            XCTAssertEqual(fields["preserved_connection_count"], "0")
            await manager.removeConnection(connectionID)
        }

        /// The round-5 interleaving: proven helpers A and B, and while the revocation's backstop
        /// refresh is suspended in B's `tools/list_changed`, A's agent exits and only then is A's
        /// registration cleared. A held no live proof at the clear (its agent was already gone), so
        /// the hook finds it from the released registration and its admission ancestry, not from
        /// liveness: A's route, fingerprint, affinity and window mapping all go, while B, its
        /// affinity and the run's seeded policy stay.
        @MainActor
        func testAHelperWhoseAgentAlreadyExitedIsUnroutedWhenItsRegistrationIsClearedDuringARefresh() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let tokenA = "route-retention-dead-a-\(UUID().uuidString)"
            let tokenB = "route-retention-dead-b-\(UUID().uuidString)"
            let (connectionIDA, _) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, sessionToken: tokenA
            )
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let connectionB = FixtureConnection()
            let connectionIDB = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, connection: connectionB, sessionToken: tokenB
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionIDB)
            // A changed policy installed without its turn-start refresh: the revocation's backstop
            // refresh announces it to A and B.
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: changed,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            for (label, connectionID) in [("A", connectionIDA), ("B", connectionIDB)] {
                let proven = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: connectionID, runID: runID, clientName: clientName
                )
                try require(proven, "fixture: \(label) holds a proven route")
            }
            try require(window.mcpServer.connectionIDByRunID[runID] == connectionIDA, "fixture: the window maps the run to A")
            let affinityABefore = await manager.debugLiveRunAffinityRunID(sessionKey: tokenA)
            try require(affinityABefore == runID, "fixture: A's session has run affinity")
            let once = OnceFlag()
            let provenAtClear = LockedValue<Bool?>(nil)
            let clientName = clientName
            let agentPID = agentPID
            await connectionB.setNotificationHook {
                guard once.claim() else { return }
                table.set(agentPID, .absent)
                let provenBeforeClear = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: connectionIDA, runID: runID, clientName: clientName
                )
                provenAtClear.set(provenBeforeClear)
                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            }

            await revoke(manager, runID: runID)
            await manager.debugAwaitScheduledRunWindowCleanups()

            XCTAssertEqual(provenAtClear.get(), false, "fixture: A's agent was gone before its registration was cleared")
            let routeA = await manager.debugCachedRunID(for: connectionIDA)
            XCTAssertNil(routeA, "A is unrouted although it held no live proof at the clear")
            let fingerprintA = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionIDA, runID: runID
            )
            XCTAssertNil(fingerprintA, "A's fingerprint goes with its route")
            let affinityA = await manager.debugLiveRunAffinityRunID(sessionKey: tokenA)
            XCTAssertNil(affinityA, "A's affinity goes with its route")
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID], "A's window mapping is cleaned up, not re-pointed")
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionIDA])
            let routeB = await manager.debugCachedRunID(for: connectionIDB)
            XCTAssertEqual(routeB, runID, "B is still proven: kept")
            let affinityB = await manager.debugLiveRunAffinityRunID(sessionKey: tokenB)
            XCTAssertEqual(affinityB, runID)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertEqual(runPolicy?.restrictedTools, changed, "the run's seeded policy stays")
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "true")
            XCTAssertEqual(fields["preserved_connection_count"], "1")
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.count, 1)
            XCTAssertEqual(proofLost.first?["cause"], "expected_pid_cleared")
            XCTAssertEqual(proofLost.first?["unrouted_connection_count"], "1")
            XCTAssertEqual(proofLost.first?["window_mapping_removed"], "true")

            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            for connectionID in [connectionIDA, connectionIDB] {
                await manager.removeConnection(connectionID)
            }
        }

        /// Window binding is part of the proof: a later turn that installs the run's policy for
        /// another window leaves the helper bound to the old window unproven, so the turn-start
        /// refresh skips it (never moving it into the new window) and the revocation finds nothing
        /// proven and fully cleans the run up. The same turn in the helper's own window keeps it.
        func testALaterTurnInstallingTheRunsPolicyForAnotherWindowIsFullyCleanedUpOnRevoke() async throws {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            await installTurnPolicy(manager, runID: runID)
            await revoke(manager, runID: runID)
            let keptRoute = await manager.debugCachedRunID(for: connectionID)
            try require(keptRoute == runID, "control: a turn in the helper's own window keeps the route")
            let notifiedBefore = await connection.toolListChangedCount

            let otherWindowID = windowID + 1
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_other_window_tool")
            await installTurnPolicy(manager, runID: runID, windowID: otherWindowID, restrictedTools: changed)
            let provenAfterInstall = await manager.debugConnectionHoldsProvenRunRoute(
                connectionID: connectionID, runID: runID, clientName: clientName
            )
            XCTAssertFalse(provenAfterInstall, "bound to the old window: no proven route")
            let ancestryStillProves = await manager.debugAncestryProvesExpectedAgent(connectionID: connectionID, runID: runID)
            XCTAssertTrue(ancestryStillProves, "only the window binding fails")
            let notifiedAfterInstall = await connection.toolListChangedCount
            XCTAssertEqual(notifiedAfterInstall, notifiedBefore, "the turn-start refresh skips the unproven helper")
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: otherWindowID, runID: runID)

            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route, "the full cleanup unroutes it")
            let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertNil(fingerprint)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, "nothing proven: the run's routing state is cleared")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertNil(runWindow)
            let affinity = await manager.debugLiveRunAffinityRunIDs()
            XCTAssertFalse(affinity.contains(runID))
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "false")
            XCTAssertEqual(fields["preserved_connection_count"], "0")
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.removeConnection(connectionID)
        }

        /// Every removal of a run's expected PIDs drops its registered identities with them.
        func testClearingTheRunsExpectedPIDsDropsTheirRegisteredIdentities() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let registered = await manager.debugHasExpectedAgentIdentityEntry(runID: runID)
            XCTAssertTrue(registered)

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let afterOne = await manager.debugHasExpectedAgentIdentityEntry(runID: runID)
            XCTAssertTrue(afterOne, "one PID remains")
            // The clear-by-client path (no run given) walks every run.
            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName)
            let pids = await manager.debugExpectedAgentPIDs(runID: runID)
            XCTAssertTrue(pids.isEmpty)
            let afterAll = await manager.debugHasExpectedAgentIdentityEntry(runID: runID)
            XCTAssertFalse(afterAll, "no identity outlives the run's PID set")
        }

        // MARK: - Policy refresh for the retained helper

        /// A retained helper of the run with its run policy applied (its projection fingerprint
        /// recorded), as a turn-1 admission leaves it.
        private func retainedHelperWithAppliedPolicy(
            on manager: ServerNetworkManager,
            runID: UUID
        ) async -> (connectionID: UUID, connection: FixtureConnection) {
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connection = FixtureConnection()
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID, connection: connection)
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionID)
            return (connectionID, connection)
        }

        /// Turn start delivers a changed restricted set with one notification before any revocation;
        /// the revoke-time backstop and an unchanged policy add none.
        func testTurnStartRefreshDeliversAChangedPolicyOnceAndAnUnchangedOneNotAtAll() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount

            // Unchanged policy: nothing to deliver at turn start or at revocation.
            await installTurnPolicy(manager, runID: runID)
            let afterUnchangedInstall = await connection.toolListChangedCount
            XCTAssertEqual(afterUnchangedInstall, baseline)
            await revoke(manager, runID: runID)
            let afterUnchangedRevoke = await connection.toolListChangedCount
            XCTAssertEqual(afterUnchangedRevoke, baseline)

            // A changed restricted set reaches the retained connection at turn start, once.
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")
            await installTurnPolicy(manager, runID: runID, restrictedTools: changed)
            let afterChangedInstall = await connection.toolListChangedCount
            XCTAssertEqual(afterChangedInstall, baseline + 1, "delivered at turn start, before any revocation")
            let state = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(state.restrictedTools, changed)
            await revoke(manager, runID: runID)
            let afterChangedRevoke = await connection.toolListChangedCount
            XCTAssertEqual(afterChangedRevoke, baseline + 1, "the revoke-time backstop finds nothing left to deliver")
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 1)
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID)
        }

        func testAllowedToolsOverrideChangesRefreshOncePerChange() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount
            let override: Set = ["read_file", "file_search"]

            await installTurnPolicy(manager, runID: runID, allowedToolsOverride: override)
            let afterSet = await connection.toolListChangedCount
            XCTAssertEqual(afterSet, baseline + 1, "nil → set")
            let setState = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(setState.allowedToolsOverride, override)

            await installTurnPolicy(manager, runID: runID, allowedToolsOverride: override)
            let afterRepeat = await connection.toolListChangedCount
            XCTAssertEqual(afterRepeat, baseline + 1, "set → same set")

            await installTurnPolicy(manager, runID: runID, allowedToolsOverride: nil)
            let afterClear = await connection.toolListChangedCount
            XCTAssertEqual(afterClear, baseline + 2, "set → nil")
            let clearedState = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertNil(clearedState.allowedToolsOverride)
        }

        func testTaskLabelKindOnlyChangeRefreshesOnce() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (_, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount

            await installTurnPolicy(manager, runID: runID, taskLabelKind: .explore)
            let afterChange = await connection.toolListChangedCount
            XCTAssertEqual(afterChange, baseline + 1)
            await installTurnPolicy(manager, runID: runID, taskLabelKind: .explore)
            await revoke(manager, runID: runID)
            let afterRepeat = await connection.toolListChangedCount
            XCTAssertEqual(afterRepeat, baseline + 1)
        }

        func testExternalControlOnlyChangeRefreshesOnce() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (_, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount

            await installTurnPolicy(manager, runID: runID, allowsAgentExternalControlTools: true)
            let afterChange = await connection.toolListChangedCount
            XCTAssertEqual(afterChange, baseline + 1)
            await installTurnPolicy(manager, runID: runID, allowsAgentExternalControlTools: true)
            await revoke(manager, runID: runID)
            let afterRepeat = await connection.toolListChangedCount
            XCTAssertEqual(afterRepeat, baseline + 1)
        }

        /// A refresh suspended before applying policy A resumes after policy B was installed (and
        /// delivered by B's own turn-start refresh): A never overwrites B.
        func testAnOlderSuspendedRefreshNeverOverwritesANewerPolicy() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount
            var policyA = AgentModeMCPToolPolicy.restrictedTools
            policyA.insert("route_retention_policy_a")
            var policyB = AgentModeMCPToolPolicy.restrictedTools
            policyB.insert("route_retention_policy_b")
            let newerPolicy = policyB
            let once = OnceFlag()
            let clientName = clientName
            let windowID = windowID
            await manager.debugSetRetainedRunPolicyRefreshSuspension { _ in
                guard once.claim() else { return }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: windowID,
                    restrictedTools: newerPolicy,
                    oneShot: true,
                    reason: "newer turn",
                    ttl: 10,
                    runID: runID,
                    purpose: .agentModeRun,
                    requiresExpectedAgentPID: true
                )
                // The newer turn's lease delivers its own policy at its turn start.
                await manager.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: runID)
            }

            await installTurnPolicy(manager, runID: runID, restrictedTools: policyA)
            await manager.debugSetRetainedRunPolicyRefreshSuspension(nil)

            let state = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(state.restrictedTools, policyB, "the newer policy stays applied")
            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, baseline + 1, "only the newer policy was announced")
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 1)
        }

        /// The retained connection is removed while its refresh is suspended: the refresh skips it
        /// and never routes it again.
        func testRemovingTheRetainedConnectionDuringASuspendedRefreshNeverReroutesIt() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let baseline = await connection.toolListChangedCount
            let once = OnceFlag()
            await manager.debugSetRetainedRunPolicyRefreshSuspension { suspendedConnectionID in
                guard once.claim() else { return }
                await manager.removeConnection(
                    suspendedConnectionID,
                    context: MCPConnectionCloseContext(reason: "peer_eof", initiator: .peer)
                )
            }
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")

            await installTurnPolicy(manager, runID: runID, restrictedTools: changed)
            await manager.debugSetRetainedRunPolicyRefreshSuspension(nil)

            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route, "a removed connection is never re-routed")
            let registered = await manager.debugConnectionIsRegistered(connectionID: connectionID)
            XCTAssertFalse(registered)
            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, baseline)
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 0)

            await revoke(manager, runID: runID)
            let routeAfterRevoke = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(routeAfterRevoke)
            let fields = await lastPolicyRevokedFields(manager, runID: runID)
            XCTAssertEqual(fields?["routing_preserved"], "false")
        }

        /// Two retained helpers of different registered launches; while the first one's
        /// `tools/list_changed` is suspended, the other launch's PID is cleared. The refresh proves
        /// each connection again right before its apply, so the second is never refreshed.
        func testRefreshReprovesEachConnectionBeforeItsApply() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let connectionA = FixtureConnection()
            let connectionIDA = await routedHelper(on: manager, runID: runID, helperPID: helperPID, connection: connectionA)
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionIDA)
            let connectionB = FixtureConnection()
            let connectionIDB = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, connection: connectionB
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: connectionIDB)
            let baselineA = await connectionA.toolListChangedCount
            let baselineB = await connectionB.toolListChangedCount
            // Whichever connection is refreshed first clears the other launch's PID.
            let once = OnceFlag()
            let clientName = clientName
            let agentPID = agentPID
            let otherAgentPID = otherAgentPID
            await connectionA.setNotificationHook {
                guard once.claim() else { return }
                await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            }
            await connectionB.setNotificationHook {
                guard once.claim() else { return }
                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            }
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")

            await installTurnPolicy(manager, runID: runID, restrictedTools: changed)

            let notifiedA = await connectionA.toolListChangedCount - baselineA
            let notifiedB = await connectionB.toolListChangedCount - baselineB
            XCTAssertEqual(notifiedA + notifiedB, 1, "only the first connection is refreshed")
            let stateA = await manager.debugConnectionPolicyState(for: connectionIDA)
            let stateB = await manager.debugConnectionPolicyState(for: connectionIDB)
            let (refreshed, skipped) = notifiedA == 1 ? (stateA, stateB) : (stateB, stateA)
            XCTAssertEqual(refreshed.restrictedTools, changed)
            XCTAssertEqual(skipped.restrictedTools, AgentModeMCPToolPolicy.restrictedTools, "the unproven connection keeps its policy")
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 1)
        }

        // MARK: - Per-connection restriction APIs

        /// The run policy alone owns a run-routed connection's restricted set: `set`, `add` and
        /// `clear` change and announce nothing, both with its fingerprint and after the fingerprint
        /// was dropped (still routed), so they never lift a run restriction, overlap included; a
        /// changed run policy's refresh still writes exactly the run's set.
        func testRestrictionAPIsDoNothingOnARunOwnedConnection() async {
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            let (connectionID, connection) = await retainedHelperWithAppliedPolicy(on: manager, runID: runID)
            let runSet = AgentModeMCPToolPolicy.restrictedTools
            guard let overlap = runSet.sorted().first else {
                return XCTFail("fixture: the run policy restricts at least one tool")
            }
            let notifiedBefore = await connection.toolListChangedCount
            for fingerprinted in [true, false] {
                let label = fingerprinted ? "with its fingerprint" : "after its fingerprint was dropped"
                if !fingerprinted {
                    await manager.debugDropRunPolicyFingerprint(connectionID: connectionID)
                }
                await manager.setRestrictedTools(for: connectionID, tools: ["route_retention_explicit_tool"])
                await manager.addRestrictedTools(for: connectionID, names: ["route_retention_added_tool"])
                await manager.setRestrictedTools(for: connectionID, tools: [overlap])
                await manager.clearRestrictedTools(for: connectionID)
                let state = await manager.debugConnectionPolicyState(for: connectionID)
                XCTAssertEqual(state.restrictedTools, runSet, "\(label): the run's set is untouched")
                let notified = await connection.toolListChangedCount
                XCTAssertEqual(notified, notifiedBefore, "\(label): nothing is announced")
                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertEqual(route, runID, label)
            }

            var changed = runSet
            changed.insert("route_retention_probe_tool")
            await installTurnPolicy(manager, runID: runID, restrictedTools: changed)
            await manager.clearRestrictedTools(for: connectionID)
            await manager.setRestrictedTools(for: connectionID, tools: [])
            let refreshed = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(refreshed.restrictedTools, changed, "the refresh writes exactly the run's set; the APIs never lift it")
            let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertEqual(fingerprint, true)
            let notifiedAfter = await connection.toolListChangedCount
            XCTAssertEqual(notifiedAfter, notifiedBefore + 1, "only the refresh announces")
            await manager.removeConnection(connectionID)
        }

        /// Off a run (no run route, no fingerprint) the APIs keep their original behaviour: `set`
        /// replaces the set, `add` extends it, `clear` removes it, each announcing the change.
        func testRestrictionAPIsKeepTheirOriginalBehaviourOffARun() async {
            let manager = await makeManager(table: makeTable())
            let connectionID = UUID()
            let connection = FixtureConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: clientName,
                sessionToken: "route-retention-restrictions-\(UUID().uuidString)"
            )
            let notifiedBefore = await connection.toolListChangedCount
            await manager.setRestrictedTools(for: connectionID, tools: ["route_retention_a"])
            let afterA = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(afterA.restrictedTools, ["route_retention_a"])
            await manager.setRestrictedTools(for: connectionID, tools: ["route_retention_b"])
            let afterB = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(afterB.restrictedTools, ["route_retention_b"], "set replaces")
            await manager.addRestrictedTools(for: connectionID, names: ["route_retention_c"])
            let afterAdd = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(afterAdd.restrictedTools, ["route_retention_b", "route_retention_c"], "add extends")
            await manager.clearRestrictedTools(for: connectionID)
            let cleared = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertTrue(cleared.restrictedTools.isEmpty, "clear removes")
            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, notifiedBefore + 4, "each change is announced")
            await manager.removeConnection(connectionID)
        }

        // MARK: - Registration hooks with an agent that already exited

        /// The re-registration and loss-observer-unregistration hooks find a dependent whose agent
        /// already exited (no live proof at the change) from the released registration and its
        /// admission ancestry: it is unrouted (route and fingerprint), a helper proven by another
        /// registered PID is kept, and the run's state stays.
        func testReRegistrationAndObserverUnregistrationUnrouteADependentWhoseAgentAlreadyExited() async throws {
            for cause in ["expected_pid_reregistered", "loss_observer_unregistered"] {
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                var observerToken: UUID?
                if cause == "loss_observer_unregistered" {
                    // The observer's read is the PID's registered instance: the expected-PID
                    // registration found the agent unreadable.
                    observerToken = await manager.registerRunConnectionLossObserver(for: runID, launch: launch(agentPID)) { _ in }
                    table.set(agentPID, .unreadable)
                    await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                    table.spawn(agentPID, parent: shellPID, start: agentStart)
                } else {
                    await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                }
                let dependentID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
                await manager.debugApplyRunPolicyState(runID: runID, connectionID: dependentID)
                await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
                let otherID = await routedHelper(on: manager, runID: runID, helperPID: otherHelperPID)
                let provenBefore = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: dependentID, runID: runID, clientName: clientName
                )
                try require(provenBefore, "\(cause): fixture: the dependent is proven")
                table.set(agentPID, .absent)
                let provenAfterExit = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: dependentID, runID: runID, clientName: clientName
                )
                try require(!provenAfterExit, "\(cause): fixture: the agent exited, so the dependent holds no live proof")
                let routeAfterExit = await manager.debugCachedRunID(for: dependentID)
                try require(routeAfterExit == runID, "\(cause): fixture: an exit alone unroutes nothing")

                if let observerToken {
                    await manager.unregisterRunConnectionLossObserver(for: runID, token: observerToken)
                } else {
                    // Re-registered while the agent is gone: the PID's registered instance is dropped.
                    await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                }

                let route = await manager.debugCachedRunID(for: dependentID)
                XCTAssertNil(route, "\(cause): the dependent is unrouted")
                let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                    connectionID: dependentID, runID: runID
                )
                XCTAssertNil(fingerprint, "\(cause): its fingerprint goes with its route")
                let otherRoute = await manager.debugCachedRunID(for: otherID)
                XCTAssertEqual(otherRoute, runID, "\(cause): proven by another registered PID: kept")
                let runPolicy = await manager.debugRunPolicyState(for: runID)
                XCTAssertNotNil(runPolicy, "\(cause): the hook never clears run-level state")
                await manager.debugAwaitScheduledRunWindowCleanups()
                let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
                XCTAssertEqual(proofLost.count, 1, cause)
                XCTAssertEqual(proofLost.first?["cause"], cause)
                XCTAssertEqual(proofLost.first?["unrouted_connection_count"], "1", cause)
                for connectionID in [dependentID, otherID] {
                    await manager.removeConnection(connectionID)
                }
            }
        }

        /// Loss observers of one PID that read different instances (a reused PID while an earlier
        /// launch's observer is still registered) register none: the observer fallback fails
        /// closed, and the registration that made them disagree unroutes the helper that the
        /// first instance proved. An observer agreeing on the same instance changes nothing, and
        /// unregistering the disagreeing one makes the fallback the one instance again.
        func testLossObserversDisagreeingOnAPIDsInstanceRegisterNone() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: launch(agentPID)) { _ in }
            table.set(agentPID, .unreadable)
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            table.spawn(agentPID, parent: shellPID, start: agentStart)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            let provenBefore = await manager.debugConnectionHoldsProvenRunRoute(
                connectionID: connectionID, runID: runID, clientName: clientName
            )
            try require(provenBefore, "fixture: the observer's instance proves the helper")

            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: launch(agentPID)) { _ in }
            let provenAfterAgreeing = await manager.debugConnectionHoldsProvenRunRoute(
                connectionID: connectionID, runID: runID, clientName: clientName
            )
            XCTAssertTrue(provenAfterAgreeing, "an observer agreeing on the instance keeps the proof")
            let agreedIdentity = await manager.debugRegisteredAgentIdentity(runID: runID, pid: agentPID)
            XCTAssertEqual(agreedIdentity?.startSeconds, agentStart)

            // A third observer reads another instance under the PID; the original instance is
            // live again afterwards, so only the disagreement decides.
            table.spawn(agentPID, parent: shellPID, start: 999)
            let disagreeingToken = await manager.registerRunConnectionLossObserver(for: runID, launch: launch(agentPID)) { _ in }
            table.spawn(agentPID, parent: shellPID, start: agentStart)
            let ancestryAfterDisagreement = await manager.debugAncestryProvesExpectedAgent(connectionID: connectionID, runID: runID)
            XCTAssertFalse(ancestryAfterDisagreement, "disagreeing observers register no instance")
            let disagreedIdentity = await manager.debugRegisteredAgentIdentity(runID: runID, pid: agentPID)
            XCTAssertNil(disagreedIdentity, "neither observer's read is picked")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route, "the disagreeing registration unroutes the helper its released instance proved")
            // The event is recorded by the scheduled window-side cleanup.
            await manager.debugAwaitScheduledRunWindowCleanups()
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.map { $0["cause"] }, ["loss_observer_registered"])

            await manager.unregisterRunConnectionLossObserver(for: runID, token: disagreeingToken)
            let ancestryAfterUnregister = await manager.debugAncestryProvesExpectedAgent(connectionID: connectionID, runID: runID)
            XCTAssertTrue(ancestryAfterUnregister, "the agreeing observers' instance is the fallback again")
            let restoredIdentity = await manager.debugRegisteredAgentIdentity(runID: runID, pid: agentPID)
            XCTAssertEqual(restoredIdentity?.startSeconds, agentStart)
            await manager.removeConnection(connectionID)
        }

        // MARK: - Production routing through a registered window

        @MainActor
        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        /// Fails the test and stops the caller when a fixture precondition does not hold.
        private func require(
            _ condition: Bool,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            guard condition else {
                XCTFail(message, file: file, line: line)
                throw FixtureError(message: message)
            }
        }

        /// Routes a helper (fake-table peer = the test process under `agent`, default `agentPID`)
        /// through the production pending-policy application into `window`, as turn 1 does, then
        /// registers the Claude agent instance `agent` as the run's expected agent.
        @MainActor
        private func productionRoutedHelper(
            on manager: ServerNetworkManager,
            table: FakeProcessTable,
            window: WindowState,
            runID: UUID,
            underAgent agent: pid_t? = nil,
            peerStart: Int64 = 520,
            taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
            connectionID: UUID = UUID(),
            sessionToken: String = "route-retention-\(UUID().uuidString)",
            beforeAdmission: (@Sendable () async -> Void)? = nil
        ) async throws -> (connectionID: UUID, connection: FixtureConnection) {
            let agent = agent ?? agentPID
            let ownPID = getpid()
            let fixturePIDs: Set<pid_t> = [shellPID, agentPID, otherAgentPID, helperPID, otherHelperPID]
            try require(!fixturePIDs.contains(ownPID), "the test process PID must not collide with a fixture PID")
            table.spawn(ownPID, parent: agent, start: peerStart)
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "turn 1",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                requiresExpectedAgentPID: true
            )
            await beforeAdmission?()
            // Pending-policy admission walks the real process table, so the test process stands in.
            await manager.registerExpectedAgentPID(ownPID, for: clientName, runID: runID)
            let connection = FixtureConnection()
            let token = sessionToken
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: clientName,
                sessionToken: token
            )
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: ownPID)
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(ownPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: token,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            try require(result.outcome == "applied", "pending-policy application outcome: \(result.outcome)")
            await manager.debugSetAdmittedClientIDForTesting(connectionID: connectionID, clientID: clientName)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            // The agent is registered before the stand-in PID is cleared: the route (whose
            // admission chain contains `agent`) stays proven throughout, so clearing the stand-in
            // never unroutes it.
            await manager.registerExpectedAgentPID(agent, for: clientName, runID: runID)
            await manager.clearExpectedAgentPID(ownPID, for: clientName, runID: runID)
            try require(
                window.mcpServer.liveConnectionID(forRunID: runID) == connectionID,
                "the production route did not reach the window"
            )
            return (connectionID, connection)
        }

        /// Adds a workspace with one compose tab to `window` and activates it, so a run policy that
        /// names the tab can bind it window-side. With `activeDecoyTab`, a second compose tab is the
        /// active one, so a resolution that reaches the run tab is never active-tab compatibility.
        @MainActor
        private func addRunTab(
            to window: WindowState,
            activeDecoyTab: Bool = false
        ) async throws -> (tabID: UUID, workspaceID: UUID) {
            let tabID = UUID()
            let decoyTabID = UUID()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Route retention run tab \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switched = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "routeRetentionRunTab"
            )
            try require(switched == .switched, "fixture: the workspace switch returned \(switched)")
            guard let index = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
                throw FixtureError(message: "fixture: the workspace is not loaded")
            }
            window.workspaceManager.workspaces[index].composeTabs = activeDecoyTab
                ? [ComposeTabState(id: tabID, name: "Run"), ComposeTabState(id: decoyTabID, name: "Active")]
                : [ComposeTabState(id: tabID, name: "Run")]
            window.workspaceManager.workspaces[index].activeComposeTabID = activeDecoyTab ? decoyTabID : tabID
            let reloaded = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[index],
                reason: "routeRetentionRunTabs"
            )
            try require(reloaded == .switched, "fixture: the tab reload returned \(reloaded)")
            if let active = window.workspaceManager.activeWorkspace {
                window.promptManager.loadComposeTabsFromWorkspace(active, syncPromptText: true)
            }
            return (tabID, workspace.id)
        }

        /// A soft disconnect, then the same helper reconnecting with the same session token and no
        /// pending policy queued: the production fallback restores its route from the live-run
        /// affinity (`applyRoutingFallback` -> `applyLiveRunAffinity`) and binds it to the run
        /// policy's window, so it holds a proven route again and the next turn's revoke keeps it.
        @MainActor
        func testASameTokenReconnectThroughTheLiveRunAffinityKeepsRetention() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let token = "route-retention-reconnect-\(UUID().uuidString)"
            let (oldConnectionID, _) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, sessionToken: token
            )
            await manager.removeConnection(oldConnectionID)
            let affinity = await manager.debugLiveRunAffinityRunID(sessionKey: token)
            try require(affinity == runID, "fixture: the helper session keeps its run affinity across the disconnect")
            let queued = await manager.debugPendingPolicySnapshot(for: clientName)
            try require(!queued.contains { $0.runID == runID }, "fixture: no pending policy is queued for the run")

            let connectionID = UUID()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: FixtureConnection(),
                clientName: clientName,
                sessionToken: token
            )
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: getpid())
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: token,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            await manager.debugSetAdmittedClientIDForTesting(connectionID: connectionID, clientID: clientName)
            XCTAssertEqual(result.outcome, "fallback", "routed by the live-run affinity, not a pending policy")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID, "the live-run affinity restores the route")
            let restoredEvents = await routingEvents(manager, runID: runID, named: "live_affinity_route_restored")
            XCTAssertEqual(
                restoredEvents.map { $0["path"] },
                ["routing_fallback:session-token"],
                "the restore is recorded as a route assignment"
            )
            let runPolicyWindowID = await manager.debugRunPolicyState(for: runID)?.windowID
            XCTAssertEqual(runPolicyWindowID, window.windowID)
            XCTAssertEqual(result.windowID, runPolicyWindowID, "bound to the run policy's window")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], connectionID)
            let proven = await manager.debugConnectionHoldsProvenRunRoute(
                connectionID: connectionID, runID: runID, clientName: clientName
            )
            XCTAssertTrue(proven, "the reconnected helper holds a proven route")

            await installTurnPolicy(manager, runID: runID, windowID: window.windowID)
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)

            let routeAfterRevoke = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(routeAfterRevoke, runID, "the next turn's revoke keeps the reconnected route")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], connectionID)
            let revokedFields = await lastPolicyRevokedFields(manager, runID: runID)
            let fields = try XCTUnwrap(revokedFields)
            XCTAssertEqual(fields["routing_preserved"], "true")
            XCTAssertEqual(fields["preserved_connection_count"], "1")

            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.removeConnection(connectionID)
        }

        /// A restart overlap with a real window and run tab: the window maps the run to A, whose
        /// run tab is bound, and a changed policy refreshes both launches' proven helpers. The
        /// refresh writes the policy only: the window's run mapping and tab bindings stay where
        /// they were (re-binding the run tab for B would register the mapping for B and schedule
        /// A's replacement).
        @MainActor
        func testARefreshOfBothLaunchesHelpersNeverMovesTheWindowsRunMapping() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let (tabID, workspaceID) = try await addRunTab(to: window)
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: runID,
                windowID: window.windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun
            )
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connectionA = FixtureConnection()
            let connectionIDA = await routedHelper(on: manager, runID: runID, helperPID: helperPID, connection: connectionA)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let connectionB = FixtureConnection()
            let connectionIDB = await routedHelper(on: manager, runID: runID, helperPID: otherHelperPID, connection: connectionB)
            // A's routing left the window's run mapping and the run tab bound to A.
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionIDA,
                clientName: clientName,
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: runID,
                explicitlyBound: false
            )
            try require(window.mcpServer.connectionIDByRunID[runID] == connectionIDA, "fixture: the window maps the run to A")
            for (label, connectionID) in [("A", connectionIDA), ("B", connectionIDB)] {
                let proven = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: connectionID, runID: runID, clientName: clientName
                )
                try require(proven, "fixture: \(label) holds a proven route")
            }
            let notifiedA = await connectionA.toolListChangedCount
            let notifiedB = await connectionB.toolListChangedCount
            // The window's run mapping as each refreshed helper is announced: a transient move (one
            // helper's rebind undone by the other's) would still schedule a replacement.
            let windowID = window.windowID
            let mappingAtNotifications = LockedValue<[UUID?]>([])
            for connection in [connectionA, connectionB] {
                await connection.setNotificationHook {
                    let mapped = await MainActor.run {
                        WindowStatesManager.shared.window(withID: windowID)?.mcpServer.connectionIDByRunID[runID]
                    }
                    mappingAtNotifications.set(mappingAtNotifications.get() + [mapped])
                }
            }

            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_both_launches_tool")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: changed,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            await manager.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: runID)

            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 2, "both launches' helpers are refreshed")
            for (label, connectionID, connection, before) in [
                ("A", connectionIDA, connectionA, notifiedA),
                ("B", connectionIDB, connectionB, notifiedB)
            ] {
                let state = await manager.debugConnectionPolicyState(for: connectionID)
                XCTAssertEqual(state.restrictedTools, changed, "\(label) carries the changed policy")
                let notified = await connection.toolListChangedCount
                XCTAssertEqual(notified, before + 1, "\(label) is announced once")
                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertEqual(route, runID, label)
            }
            XCTAssertEqual(
                mappingAtNotifications.get(),
                [connectionIDA, connectionIDA],
                "the window maps the run to A at every refresh, never transiently to B"
            )
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], connectionIDA, "the refresh never moves the window's run mapping")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[connectionIDA], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionIDB], "B is never registered window-side")
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: connectionIDA), tabID)
            XCTAssertNil(window.mcpServer.boundTabID(forConnection: connectionIDB), "the refresh binds no run tab for B")
            // The later turn's policy-only install keeps the source workspace the run tab's admission
            // established, for the bound helper (A) and the one routed only actor-side (B).
            let expectedRunTab = ServerNetworkManager.RunPolicyTab(
                runID: runID, windowID: window.windowID, workspaceID: workspaceID, tabID: tabID
            )
            for (label, connectionID) in [("A", connectionIDA), ("B", connectionIDB)] {
                let runTab = await manager.actorRoutedRunPolicyTab(for: connectionID)
                XCTAssertEqual(runTab, expectedRunTab, "\(label) keeps the run tab's workspace after the later turn")
            }

            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            for connectionID in [connectionIDA, connectionIDB] {
                await manager.removeConnection(connectionID)
            }
        }

        /// A later turn whose policy leaves the tool projection unchanged (the retained refresh has
        /// nothing to announce) keeps the run tab's workspace on the helper's actor-side route:
        /// nothing rebinds the tab to rediscover it, so the policy install must not erase it.
        @MainActor
        func testAnUnchangedLaterTurnPolicyKeepsTheRunTabsWorkspace() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let (tabID, workspaceID) = try await addRunTab(to: window)
            let manager = await makeManager(table: makeTable())
            let runID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: runID,
                windowID: window.windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun
            )
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let connectionID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: runID,
                explicitlyBound: false
            )
            let expectedRunTab = ServerNetworkManager.RunPolicyTab(
                runID: runID, windowID: window.windowID, workspaceID: workspaceID, tabID: tabID
            )
            let seededRunTab = await manager.actorRoutedRunPolicyTab(for: connectionID)
            try require(seededRunTab == expectedRunTab, "fixture: the route names the run tab's workspace")

            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "later turn",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            await manager.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: runID)

            let runTab = await manager.actorRoutedRunPolicyTab(for: connectionID)
            XCTAssertEqual(runTab, expectedRunTab, "the unchanged later turn keeps the run tab's workspace")
            let cachedWorkspaceID = await manager.debugRunPolicyState(for: runID)?.workspaceID
            XCTAssertEqual(cachedWorkspaceID, workspaceID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: connectionID), tabID)
            // `workspace_steer` resolves its caller from the same request routing context: the later
            // turn's call is not refused for a missing source workspace. (`grantStore` is never read
            // by caller resolution.)
            let routing = await manager.requestRoutingContext(for: connectionID)
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: clientName,
                windowID: window.windowID,
                runPurpose: routing.runPurpose,
                actorRoutedRunTab: routing.actorRoutedRunTab,
                gatewayRemoteDeviceID: routing.gatewayRemoteDeviceID
            )
            let steering = WorkspaceSteeringMCPToolService(
                captureRequestMetadata: { metadata },
                isGatewayPrincipalConnection: { await manager.isGatewayPrincipalConnection($0) },
                windows: { [window] },
                grantStore: { .shared }
            )
            let caller = try await steering.resolveCaller(metadata: metadata)
            XCTAssertEqual(caller.sourceWorkspaceID, workspaceID, "the later turn's steering caller keeps its source workspace")
            XCTAssertEqual(caller.runID, runID)
            XCTAssertEqual(caller.windowID, window.windowID)
            XCTAssertEqual(caller.tabID, tabID)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        /// A policy-only install keeps a known workspace only for the same run, window, nonnil tab,
        /// and purpose; any other identity, a replacement seed, or a cleaned-up run stays unknown, and
        /// the accepted policy's tools always replace the old ones.
        func testAPolicyOnlyInstallKeepsTheWorkspaceOnlyForTheSameRunTabIdentity() async {
            let manager = await makeManager(table: makeTable())
            let knownWorkspaceID = UUID()
            let tabID = UUID()
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_workspace_identity_tool")

            struct Case {
                let label: String
                var seededTabID: UUID?
                var installedWindowOffset = 0
                var installedTabID: UUID?
                var installedPurpose: MCPRunPurpose = .agentModeRun
                var cleansUpFirst = false
                let expectsWorkspace: Bool
            }
            let cases = [
                Case(label: "same identity", seededTabID: tabID, installedTabID: tabID, expectsWorkspace: true),
                Case(label: "changed window", seededTabID: tabID, installedWindowOffset: 1, installedTabID: tabID, expectsWorkspace: false),
                Case(label: "changed tab", seededTabID: tabID, installedTabID: UUID(), expectsWorkspace: false),
                Case(label: "changed purpose", seededTabID: tabID, installedTabID: tabID, installedPurpose: .discoverRun, expectsWorkspace: false),
                Case(label: "no incoming tab", seededTabID: tabID, installedTabID: nil, expectsWorkspace: false),
                Case(label: "no existing tab", seededTabID: nil, installedTabID: tabID, expectsWorkspace: false),
                Case(label: "no tab on either side", seededTabID: nil, installedTabID: nil, expectsWorkspace: false),
                Case(label: "cleaned-up run", seededTabID: tabID, installedTabID: tabID, cleansUpFirst: true, expectsWorkspace: false)
            ]
            for testCase in cases {
                let runID = UUID()
                let installedWindowID = windowID + testCase.installedWindowOffset
                await manager.debugSeedRunPolicyState(
                    runID: runID,
                    windowID: windowID,
                    workspaceID: knownWorkspaceID,
                    tabID: testCase.seededTabID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    additionalTools: nil,
                    purpose: .agentModeRun,
                    updatedAt: Date(timeIntervalSinceNow: -60)
                )
                if testCase.cleansUpFirst {
                    await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: installedWindowID,
                    restrictedTools: changed,
                    oneShot: true,
                    reason: "later turn",
                    ttl: 10,
                    tabID: testCase.installedTabID,
                    runID: runID,
                    purpose: testCase.installedPurpose
                )
                let state = await manager.debugRunPolicyState(for: runID)
                XCTAssertEqual(
                    state?.workspaceID,
                    testCase.expectsWorkspace ? knownWorkspaceID : nil,
                    "\(testCase.label): workspace"
                )
                XCTAssertEqual(state?.restrictedTools, changed, "\(testCase.label): the accepted policy's tools replace the old ones")
                XCTAssertEqual(state?.windowID, installedWindowID, "\(testCase.label): window")
                XCTAssertEqual(state?.purpose, testCase.installedPurpose, "\(testCase.label): purpose")
                await manager.clearClientConnectionPolicy(for: clientName, windowID: installedWindowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: installedWindowID)
            }

            // A replacement seed (preservation off) with no workspace still clears a known one.
            let replacedRunID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: replacedRunID,
                windowID: windowID,
                workspaceID: knownWorkspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun,
                updatedAt: Date(timeIntervalSinceNow: -60)
            )
            await manager.debugSeedRunPolicyState(
                runID: replacedRunID,
                windowID: windowID,
                workspaceID: nil,
                tabID: tabID,
                restrictedTools: changed,
                additionalTools: nil,
                purpose: .agentModeRun
            )
            let replaced = await manager.debugRunPolicyState(for: replacedRunID)
            XCTAssertNil(replaced?.workspaceID, "a replacement seed keeps its clearing semantics")
            await manager.cleanupRunRoutingState(for: replacedRunID, windowID: windowID)

            // A stale install (older than the cached state) changes nothing.
            let staleRunID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: staleRunID,
                windowID: windowID,
                workspaceID: knownWorkspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun,
                updatedAt: Date(timeIntervalSinceNow: 3600)
            )
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: changed,
                oneShot: true,
                reason: "stale turn",
                ttl: 10,
                tabID: UUID(),
                runID: staleRunID,
                purpose: .agentModeRun
            )
            let stale = await manager.debugRunPolicyState(for: staleRunID)
            XCTAssertEqual(stale?.workspaceID, knownWorkspaceID, "a stale install leaves the cached state")
            XCTAssertEqual(stale?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: staleRunID)
            await manager.cleanupRunRoutingState(for: staleRunID, windowID: windowID)
        }

        // MARK: - Request-originated window-route mutations (window-route holder)

        private struct TwoHelperRunTabFixture {
            let window: WindowState
            let manager: ServerNetworkManager
            let runID: UUID
            let tabID: UUID
            let workspaceID: UUID
            /// The old launch's helper (agent 4000).
            let olderID: UUID
            /// The new launch's helper (agent 4100).
            let newerID: UUID
        }

        /// A real window and run tab, with two live connections routed to the run: the old launch's
        /// helper (under agent 4000) and the new launch's (under agent 4100), both admitted for
        /// `clientName` (Claude native unless overridden). Neither is bound window-side yet.
        @MainActor
        private func twoRoutedHelpersWithRunTab(
            on sharedManager: ServerNetworkManager? = nil,
            activeDecoyTab: Bool = false,
            clientName overrideClientName: String? = nil
        ) async throws -> TwoHelperRunTabFixture {
            let window = makeWindow()
            // Registered as soon as installed, so a failing precondition below never leaks the
            // window or the shared manager's fake process table into later tests.
            addTeardownBlock { @MainActor in
                if WindowStatesManager.shared.allWindows.contains(where: { $0 === window }) {
                    WindowStatesManager.shared.unregisterWindowState(window)
                }
            }
            let (tabID, workspaceID) = try await addRunTab(to: window, activeDecoyTab: activeDecoyTab)
            let manager: ServerNetworkManager
            let table = makeTable()
            if let sharedManager {
                manager = sharedManager
                await manager.debugSetHelperProcessTableReader(table)
                addTeardownBlock {
                    await sharedManager.debugSetHelperProcessTableReader(MCPSystemProcessTableReader())
                }
            } else {
                manager = await makeManager(table: table)
            }
            let runID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: runID,
                windowID: window.windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun
            )
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let olderID = await routedHelper(on: manager, runID: runID, helperPID: helperPID, clientName: overrideClientName)
            let newerID = await routedHelper(on: manager, runID: runID, helperPID: otherHelperPID, clientName: overrideClientName)
            for connectionID in [olderID, newerID] {
                let route = await manager.debugCachedRunID(for: connectionID)
                try require(route == runID, "fixture: both helpers are routed to the run actor-side")
            }
            try require(window.mcpServer.connectionIDByRunID[runID] == nil, "fixture: nothing holds the window's run mapping yet")
            return TwoHelperRunTabFixture(
                window: window,
                manager: manager,
                runID: runID,
                tabID: tabID,
                workspaceID: workspaceID,
                olderID: olderID,
                newerID: newerID
            )
        }

        /// Binds the run tab for `connectionID` window-side, as its admission did.
        @MainActor
        private func bindRunTab(_ fixture: TwoHelperRunTabFixture, for connectionID: UUID) throws {
            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: fixture.tabID,
                workspaceID: fixture.workspaceID,
                windowID: fixture.window.windowID,
                runID: fixture.runID,
                explicitlyBound: false
            )
        }

        @MainActor
        private func tearDownRunTabFixture(_ fixture: TwoHelperRunTabFixture) async {
            await fixture.manager.debugSetRequestWindowRouteHook(nil)
            await fixture.manager.cleanupRunRoutingState(for: fixture.runID, windowID: fixture.window.windowID)
            for connectionID in [fixture.olderID, fixture.newerID] {
                await fixture.manager.removeConnection(connectionID)
            }
            for pid in [agentPID, otherAgentPID] {
                await fixture.manager.clearExpectedAgentPID(pid, for: clientName, runID: fixture.runID)
            }
            // The shared manager's process-table restore is a teardown block of the fixture.
            WindowStatesManager.shared.unregisterWindowState(fixture.window)
        }

        /// The window never displaced `holder` for the run: checked synchronously at the window's
        /// registration (`registerRunIDMapping`, the pending-policy mapping), where a replacement
        /// is decided before any is scheduled, and on the shared manager's replacement record.
        @MainActor
        private func assertNeverDisplaced(
            _ holder: UUID,
            runID: UUID,
            _ message: String = "the holder is never displaced",
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            XCTAssertEqual(MCPServerViewModel.debugRunMappingDisplacementCount(existing: holder, runID: runID), 0, message, file: file, line: line)
            let scheduled = await ServerNetworkManager.shared.debugConnectionReplacementCount(existing: holder, runID: runID)
            XCTAssertEqual(scheduled, 0, "\(message): no replacement is scheduled", file: file, line: line)
        }

        /// The yield events of the run (`tab_rebind_yielded_to_holder`, then
        /// `run_mapping_yielded_to_holder`).
        private func yieldEvents(_ manager: ServerNetworkManager, runID: UUID) async -> [[String: String]] {
            await routingEvents(manager, runID: runID, named: "tab_rebind_yielded_to_holder")
                + routingEvents(manager, runID: runID, named: "run_mapping_yielded_to_holder")
        }

        /// The run's `run_tab_rebound_empty_slot` events: a request path taking the empty slot.
        private func emptySlotFills(_ manager: ServerNetworkManager, runID: UUID) async -> [[String: String]] {
            await routingEvents(manager, runID: runID, named: "run_tab_rebound_empty_slot")
        }

        /// A reconnect of a helper whose earlier connection is gone: a fresh connection with the
        /// helper's session token and admission ancestry (`helperPID`), no run route and no policy
        /// yet, whose session holds the run's live run affinity (as its earlier connection's policy
        /// application left it).
        @MainActor
        private func policylessReconnect(
            on manager: ServerNetworkManager,
            runID: UUID,
            window: WindowState,
            helperPID: pid_t
        ) async -> UUID {
            let connectionID = UUID()
            let token = "route-retention-reconnect-\(UUID().uuidString)"
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: FixtureConnection(),
                clientName: clientName,
                sessionToken: token
            )
            await manager.debugSetAdmittedClientIDForTesting(connectionID: connectionID, clientID: clientName)
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: helperPID)
            await manager.debugSeedLiveRunAffinity(
                clientName: clientName,
                sessionKey: token,
                runID: runID,
                windowID: window.windowID,
                purpose: .agentModeRun
            )
            return connectionID
        }

        /// Polls `condition` until it holds or `timeout` elapses (for a replacement the window side
        /// schedules on the shared manager).
        private func eventually(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await condition()
        }

        @MainActor
        private func window(_ fixture: TwoHelperRunTabFixture) -> WindowState {
            fixture.window
        }

        /// Both launches' helpers live and routed, the window mapping the run to the newer one: a
        /// late tool call of the older helper runs the per-call rebind, which yields (an explicit
        /// outcome, recorded) and changes nothing window-side. The newer helper keeps the mapping,
        /// its tab and its connection, and the older one's call proceeds with its actor routing.
        @MainActor
        func testALateToolCallOfTheOlderHelperNeverDisplacesTheNewerLiveHolder() async throws {
            let fixture = try await twoRoutedHelpersWithRunTab()
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            try bindRunTab(fixture, for: fixture.newerID)
            try require(window.mcpServer.connectionIDByRunID[runID] == fixture.newerID, "fixture: the window maps the run to the newer helper")
            let olderPolicyBefore = await manager.debugConnectionPolicyState(for: fixture.olderID)

            let outcome = await manager.debugRunScopedTabRebindFallbackForToolCall(
                connectionID: fixture.olderID,
                runID: runID,
                windowID: window.windowID
            )

            XCTAssertEqual(outcome, .yieldedToHolder(holder: fixture.newerID))
            XCTAssertFalse(outcome.keepsRunTabBinding)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, "the newer holder keeps the window's run mapping")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[fixture.newerID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID, "the newer holder keeps its run tab")
            XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.olderID], "the older helper is not registered window-side")
            XCTAssertNil(window.mcpServer.boundTabID(forConnection: fixture.olderID), "no run tab is bound for the older helper")
            // The older helper's call proceeds with its unchanged actor-side routing and policy.
            let olderRoute = await manager.debugCachedRunID(for: fixture.olderID)
            XCTAssertEqual(olderRoute, runID)
            let olderPolicyAfter = await manager.debugConnectionPolicyState(for: fixture.olderID)
            XCTAssertEqual(olderPolicyAfter.restrictedTools, olderPolicyBefore.restrictedTools)
            XCTAssertEqual(olderPolicyAfter.windowID, olderPolicyBefore.windowID)
            let yields = await routingEvents(manager, runID: runID, named: "tab_rebind_yielded_to_holder")
            XCTAssertEqual(yields.count, 1)
            XCTAssertEqual(yields.first?["holder_connection_id"], fixture.newerID.uuidString)
            XCTAssertEqual(yields.first?["reason"], "different_holder")
            XCTAssertEqual(yields.first?["source"], "tool_call")
            // No replacement (soft disconnect or hard termination) is ever decided for the holder.
            await assertNeverDisplaced(fixture.newerID, runID: runID)
            let newerStillRegistered = await manager.debugContainsConnection(fixture.newerID)
            XCTAssertTrue(newerStillRegistered)

            await tearDownRunTabFixture(fixture)
        }

        /// The request-originated rehydrate (agent_run / agent_explore spawn source, launch purpose,
        /// ask_user) of the older helper, with the newer live helper holding the window's run
        /// mapping: it applies the run policy but yields the run-tab bind (once, recorded). The
        /// holder keeps the mapping, tab and connection; nothing is replaced; the older helper
        /// stays routed to the run.
        @MainActor
        func testAnOlderHelpersRequestRehydrateNeverDisplacesTheNewerLiveHolder() async throws {
            let fixture = try await twoRoutedHelpersWithRunTab()
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            try bindRunTab(fixture, for: fixture.newerID)
            try require(window.mcpServer.connectionIDByRunID[runID] == fixture.newerID, "fixture: the window maps the run to the newer helper")

            let outcome = await manager.rehydrateRunTabContextForConnectionIfPossible(
                fixture.olderID,
                displacesHolder: false
            )

            XCTAssertEqual(outcome, .yieldedToHolder)
            XCTAssertFalse(outcome.didRehydrate)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, "the newer holder keeps the window's run mapping")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[fixture.newerID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.olderID])
            XCTAssertNil(window.mcpServer.boundTabID(forConnection: fixture.olderID))
            let olderRoute = await manager.debugCachedRunID(for: fixture.olderID)
            XCTAssertEqual(olderRoute, runID, "the older helper stays routed to the run")
            let olderPolicy = await manager.debugConnectionPolicyState(for: fixture.olderID)
            XCTAssertEqual(olderPolicy.purpose, .agentModeRun, "the run policy was applied")
            let runTab = await manager.actorRoutedRunPolicyTab(for: fixture.olderID)
            XCTAssertEqual(runTab?.tabID, fixture.tabID, "its tools resolve the run tab through the actor-side route")
            let yields = await routingEvents(manager, runID: runID, named: "tab_rebind_yielded_to_holder")
            XCTAssertEqual(yields.map { $0["source"] }, ["rehydrate"], "one bind, yielded once")
            XCTAssertEqual(yields.first?["holder_connection_id"], fixture.newerID.uuidString)
            XCTAssertEqual(yields.first?["reason"], "different_holder")
            await assertNeverDisplaced(fixture.newerID, runID: runID)
            let newerStillRegistered = await manager.debugContainsConnection(fixture.newerID)
            XCTAssertTrue(newerStillRegistered)

            await tearDownRunTabFixture(fixture)
        }

        /// The production request paths on the shared manager, with the newer live helper holding
        /// the window's run mapping: the older helper's agent_run / agent_explore spawn parent and
        /// agent_run launch source resolve the run's own tab through the resolver's actor-side run
        /// route (never failing, never the active tab, which is another tab here), and its ask_user
        /// controller provenance stays unverified; none of them moves the mapping or replaces the
        /// holder. Mutates `ServerNetworkManager.shared`: XCTest runs this class's tests serially in
        /// one process, the fixture uses fresh run, connection and window IDs, and teardown restores
        /// the shared manager's process-table reader.
        @MainActor
        func testRefusedRequestRehydratesFallBackToTheRunTabWithoutMovingTheMapping() async throws {
            let shared = ServerNetworkManager.shared
            let fixture = try await twoRoutedHelpersWithRunTab(on: shared, activeDecoyTab: true)
            try require(
                window(fixture).workspaceManager.activeWorkspace?.activeComposeTabID != fixture.tabID,
                "fixture: the run tab is not the active tab"
            )
            let (runID, window) = (fixture.runID, fixture.window)
            try bindRunTab(fixture, for: fixture.newerID)
            try require(window.mcpServer.connectionIDByRunID[runID] == fixture.newerID, "fixture: the window maps the run to the newer helper")
            // Captured before the rehydrate: these resolvers read the actor-side run tab themselves.
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: fixture.olderID,
                clientName: clientName,
                windowID: window.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: nil
            )

            let spawnParent = await window.mcpServer.resolveSpawnParentSourceTabIDForAgentSessionCreation(metadata: metadata)
            XCTAssertEqual(spawnParent, fixture.tabID, "the spawn parent is the run's own tab")
            let exploreSource = await window.mcpServer.resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
            XCTAssertEqual(exploreSource, fixture.tabID)
            try await window.mcpServer.validateAgentRunStartRouting(metadata: metadata, resolvedSourceTabID: spawnParent)
            let launch = try await window.mcpServer.resolveAgentRunOracleReviewLaunchSnapshot(
                metadata: metadata,
                targetWindow: window
            )
            XCTAssertEqual(launch.route, .runScoped)
            XCTAssertEqual(launch.tabID, fixture.tabID, "the run tab, never the active tab")
            XCTAssertEqual(launch.workspaceID, fixture.workspaceID)
            XCTAssertEqual(launch.routedRunID, runID)
            let provenance = await MCPAskUserToolProvider.verifiedControllerProvenance(
                controllerConnectionID: fixture.olderID,
                networkManager: shared
            )
            XCTAssertEqual(provenance, .unverified, "an Agent Mode controller is never verified as external")

            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, "the newer holder keeps the window's run mapping")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[fixture.newerID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.olderID], "the older helper is never registered window-side")
            let yields = await routingEvents(shared, runID: runID, named: "tab_rebind_yielded_to_holder")
            XCTAssertFalse(yields.isEmpty)
            XCTAssertTrue(yields.allSatisfy { $0["source"] == "rehydrate" && $0["reason"] == "different_holder" })
            await assertNeverDisplaced(fixture.newerID, runID: runID)

            await tearDownRunTabFixture(fixture)
        }

        /// `mapConnectionToRunID(displacesHolder: false)` (the tool-call live-affinity restore and
        /// persisted-policy hydration) for a connection without a window mapping of its own: it
        /// yields while a different connection holds the window's run mapping, registering
        /// nothing window-side; with the slot empty it maps.
        @MainActor
        func testANonDisplacingRunMappingYieldsToADifferentHolderAndMapsAnEmptySlot() async throws {
            let fixture = try await twoRoutedHelpersWithRunTab()
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            try bindRunTab(fixture, for: fixture.newerID)

            let outcome = await manager.mapConnectionToRunIDWithOutcome(
                fixture.olderID,
                runID: runID,
                windowID: window.windowID,
                displacesHolder: false,
                refusalSource: "tool_call_affinity_restore"
            )
            XCTAssertEqual(outcome, .yieldedToHolder(holder: fixture.newerID))
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.olderID])
            let yields = await routingEvents(manager, runID: runID, named: "run_mapping_yielded_to_holder")
            XCTAssertEqual(yields.map { $0["source"] }, ["tool_call_affinity_restore"])
            XCTAssertEqual(yields.first?["reason"], "different_holder")
            XCTAssertEqual(yields.first?["route_assigned"], "true")
            await assertNeverDisplaced(fixture.newerID, runID: runID)
            let fillsAfterYield = await emptySlotFills(manager, runID: runID)
            XCTAssertTrue(fillsAfterYield.isEmpty, "a yield never counts as filling the slot")

            // The slot emptied (the holder's mapping cleaned up): the same request maps.
            window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: fixture.newerID, signalRoutingFailure: false)
            let mapped = await manager.mapConnectionToRunID(
                fixture.olderID,
                runID: runID,
                windowID: window.windowID,
                displacesHolder: false,
                refusalSource: "tool_call_affinity_restore"
            )
            XCTAssertTrue(mapped)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.olderID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.olderID), fixture.tabID, "the policy's run-tab bind took the empty slot")
            await assertNeverDisplaced(fixture.newerID, runID: runID)
            let fills = await emptySlotFills(manager, runID: runID)
            XCTAssertEqual(fills.map { $0["mechanism"] }, ["run_mapping"], "one fill: the mapping, not again for the policy's run-tab bind")
            XCTAssertEqual(fills.first?["source"], "tool_call_affinity_restore")
            XCTAssertEqual(fills.first?["window_id"], String(window.windowID))

            await tearDownRunTabFixture(fixture)
        }

        /// An ordinary tab-context tool (a selection read or write resolves with
        /// `.allowLegacyImplicitRouting`) called by the older helper after its per-call rebind
        /// yielded the window's run mapping: its request metadata carries the actor-side run tab,
        /// and the resolver returns the run tab (source `actorRunRoute`, unbound, no active UI
        /// capture), never active-tab compatibility (the active tab is another tab). A run tab in
        /// another window fails closed. Shared manager: see the test above.
        @MainActor
        func testARefusedRunRoutedHelpersOrdinaryToolResolvesTheRunTabNeverTheActiveTab() async throws {
            let shared = ServerNetworkManager.shared
            let fixture = try await twoRoutedHelpersWithRunTab(on: shared, activeDecoyTab: true)
            let (runID, window) = (fixture.runID, fixture.window)
            let activeTabID = window.workspaceManager.activeWorkspace?.activeComposeTabID
            try require(activeTabID != nil && activeTabID != fixture.tabID, "fixture: another tab is active")
            try bindRunTab(fixture, for: fixture.newerID)
            let rebind = await shared.debugRunScopedTabRebindFallbackForToolCall(
                connectionID: fixture.olderID,
                runID: runID,
                windowID: window.windowID
            )
            try require(rebind == .yieldedToHolder(holder: fixture.newerID), "fixture: the older helper's rebind yielded")

            let metadata = await ServerNetworkManager.withConnectionID(fixture.olderID) {
                await window.mcpServer.captureRequestMetadata()
            }
            XCTAssertEqual(metadata.runPurpose, .agentModeRun)
            XCTAssertEqual(metadata.actorRoutedRunTab, ServerNetworkManager.RunPolicyTab(
                runID: runID,
                windowID: window.windowID,
                workspaceID: fixture.workspaceID,
                tabID: fixture.tabID
            ))
            for policy in [MCPServerViewModel.TabContextResolutionPolicy.allowLegacyImplicitRouting, .requireExplicitOrRunScoped] {
                let resolved = try window.mcpServer.resolveTabContextSnapshot(
                    from: metadata,
                    toolName: "selection",
                    policy: policy,
                    startMirroring: false
                )
                XCTAssertFalse(resolved.usesActiveTabCompatibility, "\(policy)")
                XCTAssertEqual(resolved.source, .actorRunRoute, "\(policy)")
                XCTAssertEqual(resolved.snapshot.tabID, fixture.tabID, "\(policy): the run tab, never the active tab")
                XCTAssertEqual(resolved.snapshot.runID, runID)
                XCTAssertFalse(resolved.snapshot.explicitlyBound)
            }
            XCTAssertNil(window.mcpServer.boundTabID(forConnection: fixture.olderID), "resolving binds nothing")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID)

            // The run tab in another window: fail closed, never the active tab.
            let elsewhere = metadata.withActorRoutedRunTab(ServerNetworkManager.RunPolicyTab(
                runID: runID,
                windowID: window.windowID + 1,
                workspaceID: fixture.workspaceID,
                tabID: fixture.tabID
            ))
            XCTAssertThrowsError(try window.mcpServer.resolveTabContextSnapshot(
                from: elsewhere,
                toolName: "selection",
                policy: .allowLegacyImplicitRouting,
                startMirroring: false
            ))
            await assertNeverDisplaced(fixture.newerID, runID: runID)

            await tearDownRunTabFixture(fixture)
        }

        /// The reviewer's interleaving: the old launch's helper reconnected after the new launch's
        /// helper registered and holds the window's run mapping; pending-policy admission makes the
        /// new launch's helper the holder (scheduling the old helper's replacement). Before that
        /// replacement completes, the old helper's late request (the per-call rebind, the
        /// rehydrate, the non-displacing run mapping) yields every time: the mapping never moves
        /// back and the new helper is never displaced.
        @MainActor
        func testALateRequestOfTheReplacedOldHelperNeverRetakesTheMappingFromTheAdmittedHelper() async throws {
            let fixture = try await pendingAdmissionOverReconnectedOldLaunchHelper()
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            try require(window.mcpServer.connectionIDByRunID[runID] == fixture.newID, "fixture: admission made the new launch's helper the holder")
            let holderStillLive = await manager.debugContainsConnection(fixture.holderID)
            let holderRoute = await manager.debugCachedRunID(for: fixture.holderID)
            try require(holderStillLive && holderRoute == runID, "fixture: the old helper's replacement has not completed")

            let rebind = await manager.debugRunScopedTabRebindFallbackForToolCall(
                connectionID: fixture.holderID, runID: runID, windowID: window.windowID
            )
            XCTAssertEqual(rebind, .yieldedToHolder(holder: fixture.newID))
            let rehydrate = await manager.rehydrateRunTabContextForConnectionIfPossible(fixture.holderID, displacesHolder: false)
            XCTAssertEqual(rehydrate, .yieldedToHolder)
            let mapped = await manager.mapConnectionToRunIDWithOutcome(
                fixture.holderID, runID: runID, windowID: window.windowID, displacesHolder: false
            )
            XCTAssertEqual(mapped, .yieldedToHolder(holder: fixture.newID))

            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newID, "the mapping never moves back")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[fixture.newID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newID), fixture.tabID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.holderID])
            await assertNeverDisplaced(fixture.newID, runID: runID, "the admitted helper is never displaced")
            let pendingReplacements = await manager.debugPendingPolicyReplacementScheduleCount(
                existing: fixture.newID, replacement: fixture.holderID, runID: runID
            )
            XCTAssertEqual(pendingReplacements, 0)
            let yields = await yieldEvents(manager, runID: runID)
            XCTAssertEqual(yields.count, 3, "each late request yields once")
            XCTAssertTrue(yields.allSatisfy { $0["reason"] == "different_holder" && $0["holder_connection_id"] == fixture.newID.uuidString })

            await tearDown(fixture)
        }

        /// No evidence sampled before the hop authorizes a replacement: the window's run mapping
        /// is empty when the request starts, and during its hop (`.beforeMutationHop`) a holder is
        /// installed: a connection never routed to the run, or the newer helper regaining its
        /// route and mapping after being temporarily unrouted. The request yields at the mutation,
        /// on the run-tab rebind and on `mapConnectionToRunID`.
        @MainActor
        func testAHolderInstalledOrRestoredDuringTheHopIsNeverDisplaced() async throws {
            for path in ["tab_rebind", "run_mapping"] {
                for holderKind in ["unknown_connection", "regained_newer_holder"] {
                    let label = "\(path)/\(holderKind)"
                    let fixture = try await twoRoutedHelpersWithRunTab()
                    let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
                    let holderID: UUID
                    if holderKind == "regained_newer_holder" {
                        // The newer holder is temporarily unrouted and its window mapping gone.
                        try bindRunTab(fixture, for: fixture.newerID)
                        await manager.debugSeedConnectionRunRouting(connectionID: fixture.newerID, runID: UUID())
                        window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: fixture.newerID, signalRoutingFailure: false)
                        holderID = fixture.newerID
                    } else {
                        holderID = UUID()
                    }
                    try require(window.mcpServer.connectionIDByRunID[runID] == nil, "\(label) fixture: the slot is empty before the hop")
                    let mcpServer = window.mcpServer
                    let windowID = window.windowID
                    let callerID = fixture.olderID
                    let regains = holderKind == "regained_newer_holder"
                    let once = OnceFlag()
                    await manager.debugSetRequestWindowRouteHook { stage, hookRunID, hookCallerID in
                        guard stage == .beforeMutationHop, hookRunID == runID, hookCallerID == callerID, once.claim() else { return }
                        if regains {
                            await manager.debugSeedConnectionRunRouting(connectionID: holderID, runID: runID)
                        }
                        await MainActor.run {
                            _ = mcpServer.registerRunIDMapping(connectionID: holderID, runID: runID, windowID: windowID)
                        }
                    }

                    if path == "tab_rebind" {
                        let outcome = await manager.debugRunScopedTabRebindFallbackForToolCall(
                            connectionID: callerID, runID: runID, windowID: window.windowID
                        )
                        XCTAssertEqual(outcome, .yieldedToHolder(holder: holderID), label)
                    } else {
                        let outcome = await manager.mapConnectionToRunIDWithOutcome(
                            callerID, runID: runID, windowID: window.windowID, displacesHolder: false
                        )
                        XCTAssertEqual(outcome, .yieldedToHolder(holder: holderID), label)
                    }
                    XCTAssertFalse(once.claim(), "\(label): the hook ran")
                    XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], holderID, "\(label): the installed holder keeps the mapping")
                    XCTAssertNil(window.mcpServer.connectionIDToRunID[callerID], label)
                    XCTAssertNil(window.mcpServer.boundTabID(forConnection: callerID), label)
                    await assertNeverDisplaced(holderID, runID: runID, "\(label): the installed holder is never displaced")
                    let yields = await yieldEvents(manager, runID: runID)
                    XCTAssertEqual(yields.map { $0["reason"] }, ["different_holder"], label)
                    XCTAssertEqual(yields.first?["holder_connection_id"], holderID.uuidString, label)
                    let fills = await emptySlotFills(manager, runID: runID)
                    XCTAssertTrue(fills.isEmpty, "\(label): a yield never counts as filling the slot")

                    await tearDownRunTabFixture(fixture)
                }
            }
        }

        /// The non-displacing intent covers the whole request operation: the run mapping's success
        /// branch registers the caller (the slot was empty), then suspends before the run policy's
        /// application; a holder is admitted meanwhile (displacing the caller, as admission does).
        /// The policy's run-tab bind is request-originated too: it yields to the admitted holder,
        /// and the operation reports the yield instead of `.mapped`, with no reverse displacement
        /// or replacement of the admitted holder. Through the production tool-call affinity
        /// restore as well.
        @MainActor
        func testTheRunMappingsPolicyApplicationNeverDisplacesAHolderAdmittedAfterTheRegistration() async throws {
            for path in ["map_connection_to_run_id", "tool_call_affinity_restore"] {
                let fixture = try await twoRoutedHelpersWithRunTab()
                let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
                let callerID: UUID = if path == "tool_call_affinity_restore" {
                    await policylessReconnect(on: manager, runID: runID, window: window, helperPID: helperPID)
                } else {
                    fixture.olderID
                }
                let admittedID = fixture.newerID
                let mcpServer = window.mcpServer
                let windowID = window.windowID
                let tabID = fixture.tabID
                let workspaceID = fixture.workspaceID
                let once = OnceFlag()
                let callerWasRegistered = LockedValue(false)
                await manager.debugSetRequestWindowRouteHook { stage, hookRunID, hookCallerID in
                    guard stage == .afterRunMappingRegistered, hookRunID == runID, hookCallerID == callerID, once.claim() else { return }
                    await MainActor.run {
                        callerWasRegistered.set(mcpServer.connectionIDByRunID[runID] == callerID)
                        // An admission's displacing run-tab bind for the newer helper.
                        try? mcpServer.bindTabForConnection(
                            connectionID: admittedID,
                            clientName: nil,
                            tabID: tabID,
                            workspaceID: workspaceID,
                            windowID: windowID,
                            runID: runID,
                            explicitlyBound: false
                        )
                    }
                }

                if path == "tool_call_affinity_restore" {
                    let chosenWindowID = await manager.debugRestoreRunAffinityForToolCall(connectionID: callerID, clientName: clientName)
                    XCTAssertEqual(chosenWindowID, window.windowID, path)
                    let restored = await routingEvents(manager, runID: runID, named: "live_affinity_route_restored")
                    XCTAssertTrue(restored.isEmpty, "\(path): a yield records no route-restored event")
                } else {
                    let outcome = await manager.mapConnectionToRunIDWithOutcome(
                        callerID, runID: runID, windowID: window.windowID, displacesHolder: false, refusalSource: path
                    )
                    XCTAssertEqual(outcome, .yieldedToHolder(holder: admittedID), path)
                }
                XCTAssertFalse(once.claim(), "\(path): the hook ran")
                XCTAssertTrue(callerWasRegistered.get(), "\(path): the caller's registration preceded the admission")
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], admittedID, "\(path): the admitted holder keeps the mapping")
                XCTAssertEqual(window.mcpServer.boundTabID(forConnection: admittedID), fixture.tabID, path)
                XCTAssertNil(window.mcpServer.boundTabID(forConnection: callerID), "\(path): no run tab is bound for the caller")
                XCTAssertNil(window.mcpServer.connectionIDToRunID[callerID], path)
                await assertNeverDisplaced(admittedID, runID: runID, "\(path): the admitted holder is never displaced")
                let route = await manager.debugCachedRunID(for: callerID)
                XCTAssertEqual(route, runID, "\(path): the caller stays routed actor-side")
                let policy = await manager.debugConnectionPolicyState(for: callerID)
                XCTAssertEqual(policy.purpose, .agentModeRun, "\(path): with the run policy")
                let yields = await routingEvents(manager, runID: runID, named: "tab_rebind_yielded_to_holder")
                XCTAssertEqual(yields.map { $0["source"] }, [path], path)
                XCTAssertEqual(yields.first?["holder_connection_id"], admittedID.uuidString, path)

                if path == "tool_call_affinity_restore" {
                    await manager.removeConnection(callerID)
                }
                await tearDownRunTabFixture(fixture)
            }
        }

        /// The new launch's helper whose admission-time bind failed while the old launch's helper
        /// still held the window's run mapping: its tool call yields while that holder is live.
        /// Removing the holder clears its window mappings (for a bound holder, the tab-context
        /// teardown; for a holder whose mapping no run-tab binding carries, the removal's own
        /// receipt-checked cleanup), and the next tool call takes the empty slot without
        /// displacing anyone.
        @MainActor
        func testRemovingTheHolderClearsItsWindowMappingAndTheYieldedHelperRepairs() async throws {
            for holderShape in ["bound_run_tab", "mapping_only"] {
                let fixture = try await twoRoutedHelpersWithRunTab()
                let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
                if holderShape == "bound_run_tab" {
                    try bindRunTab(fixture, for: fixture.olderID)
                } else {
                    window.mcpServer.registerRunIDMapping(connectionID: fixture.olderID, runID: runID, windowID: window.windowID)
                    try require(window.mcpServer.boundTabID(forConnection: fixture.olderID) == nil, "\(holderShape) fixture: no run-tab binding carries the mapping")
                }
                try require(window.mcpServer.connectionIDByRunID[runID] == fixture.olderID, "\(holderShape) fixture: the old helper holds the mapping")
                try require(window.mcpServer.boundTabID(forConnection: fixture.newerID) == nil, "\(holderShape) fixture: the newer helper's admission-time bind failed")

                let yielded = await manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.newerID, runID: runID, windowID: window.windowID
                )
                XCTAssertEqual(yielded, .yieldedToHolder(holder: fixture.olderID), "\(holderShape): yields while the holder is live")
                let fillsAfterYield = await emptySlotFills(manager, runID: runID)
                XCTAssertTrue(fillsAfterYield.isEmpty, "\(holderShape): a yield never counts as filling the slot")

                await manager.removeConnection(fixture.olderID)
                XCTAssertNil(window.mcpServer.connectionIDByRunID[runID], "\(holderShape): the removed holder's window mapping is cleared")
                XCTAssertNil(window.mcpServer.connectionIDToRunID[fixture.olderID], holderShape)

                let repaired = await manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.newerID, runID: runID, windowID: window.windowID
                )
                XCTAssertEqual(repaired, .bound, "\(holderShape): the next call takes the empty slot")
                let fills = await emptySlotFills(manager, runID: runID)
                XCTAssertEqual(fills.map { $0["mechanism"] }, ["run_tab_bind"], holderShape)
                XCTAssertEqual(fills.first?["source"], "tool_call", holderShape)
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, holderShape)
                XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID, holderShape)
                await assertNeverDisplaced(fixture.olderID, runID: runID, "\(holderShape): nothing was displaced")

                await tearDownRunTabFixture(fixture)
            }
        }

        /// The removal's window cleanup is receipt-checked: a run mapping re-installed for a
        /// different connection before the removed connection's cleanup is never touched (the
        /// removed connection was routed to the run, so its cleanup visits that run's mapping).
        @MainActor
        func testRemovalCleanupNeverRemovesAMappingReinstalledForAnotherConnection() async throws {
            let fixture = try await twoRoutedHelpersWithRunTab()
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            window.mcpServer.registerRunIDMapping(connectionID: fixture.olderID, runID: runID, windowID: window.windowID)
            try bindRunTab(fixture, for: fixture.newerID)
            try require(window.mcpServer.connectionIDByRunID[runID] == fixture.newerID, "fixture: the mapping was re-installed for the newer helper")
            try require(window.mcpServer.boundTabID(forConnection: fixture.newerID) == fixture.tabID, "fixture: the new holder is bound to the run tab")
            let olderRoute = await manager.debugCachedRunID(for: fixture.olderID)
            try require(olderRoute == runID, "fixture: the removed connection is still routed to the run")

            await manager.removeConnection(fixture.olderID)

            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, "the re-installed mapping survives")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[fixture.newerID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID, "the holder's run-tab binding is unchanged")

            await tearDownRunTabFixture(fixture)
        }

        /// The yield is scoped to Claude native clients: a non-Claude client's request-path rebind
        /// and non-displacing run mapping still replace a different live routed holder, as at HEAD.
        @MainActor
        func testANonClaudeRequestPathRebindStillDisplacesAsAtHead() async throws {
            let codexClientID = AgentProviderKind.codexMCPClientID
            try require(MCPClientIdentity.canonicalFamilyID(codexClientID) != "claude-code", "fixture: a non-Claude client")
            for path in ["tab_rebind", "run_mapping"] {
                let fixture = try await twoRoutedHelpersWithRunTab(clientName: codexClientID)
                let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
                try bindRunTab(fixture, for: fixture.newerID)
                if path == "tab_rebind" {
                    let outcome = await manager.debugRunScopedTabRebindFallbackForToolCall(
                        connectionID: fixture.olderID, runID: runID, windowID: window.windowID
                    )
                    XCTAssertEqual(outcome, .bound, path)
                } else {
                    let outcome = await manager.mapConnectionToRunIDWithOutcome(
                        fixture.olderID, runID: runID, windowID: window.windowID, displacesHolder: false
                    )
                    XCTAssertEqual(outcome, .mapped, path)
                }
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.olderID, "\(path): the caller takes the mapping")
                XCTAssertEqual(MCPServerViewModel.debugRunMappingDisplacementCount(existing: fixture.newerID, runID: runID), 1, "\(path): the holder is displaced")
                let yields = await yieldEvents(manager, runID: runID)
                XCTAssertTrue(yields.isEmpty, path)

                await tearDownRunTabFixture(fixture)
            }
        }

        /// The production PRIORITY 2b step of tool-call routing (`restoreRunAffinityForToolCall`)
        /// and persisted-policy hydration (`hydratePersistedAgentModePolicyForConnectionIfNeeded`,
        /// reached from tools/call, tools/list and resources/read), for a policy-less reconnect of
        /// the old launch's helper while the new launch's live helper holds the window's run
        /// mapping: each yields (never displacing the holder) yet routes the reconnect to the run
        /// actor-side with the run's tool policy, so its tools resolve the run tab, never a
        /// policy-less or active-tab route. Flipping either call site to displacing fails here.
        @MainActor
        func testTheToolCallAffinityRestoreAndHydrationYieldToTheNewerLiveHolder() async throws {
            for path in ["tool_call_affinity_restore", "persisted_policy_hydration"] {
                let fixture = try await twoRoutedHelpersWithRunTab(activeDecoyTab: true)
                let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
                try bindRunTab(fixture, for: fixture.newerID)
                let reconnectID = await policylessReconnect(on: manager, runID: runID, window: window, helperPID: helperPID)
                let before = await manager.debugConnectionPolicyState(for: reconnectID)
                try require(before.purpose == .unknown && before.restrictedTools.isEmpty, "fixture: the reconnect has no policy")

                if path == "tool_call_affinity_restore" {
                    let chosenWindowID = await manager.debugRestoreRunAffinityForToolCall(connectionID: reconnectID, clientName: clientName)
                    XCTAssertEqual(chosenWindowID, window.windowID, path)
                } else {
                    let hydrated = await manager.debugHydratePersistedAgentModePolicy(connectionID: reconnectID, reason: "tools/call")
                    XCTAssertTrue(hydrated, "\(path): the run policy is hydrated")
                }

                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.newerID, "\(path): the newer holder keeps the mapping")
                XCTAssertNil(window.mcpServer.connectionIDToRunID[reconnectID], path)
                await assertNeverDisplaced(fixture.newerID, runID: runID, "\(path): the newer holder is never displaced")
                let route = await manager.debugCachedRunID(for: reconnectID)
                XCTAssertEqual(route, runID, "\(path): routed to the run actor-side")
                let after = await manager.debugConnectionPolicyState(for: reconnectID)
                XCTAssertEqual(after.purpose, .agentModeRun, path)
                XCTAssertEqual(after.restrictedTools, AgentModeMCPToolPolicy.restrictedTools, "\(path): the run's tool policy applies")
                let yields = await routingEvents(manager, runID: runID, named: "run_mapping_yielded_to_holder")
                XCTAssertEqual(yields.map { $0["source"] }, [path])
                XCTAssertEqual(yields.first?["reason"], "different_holder", path)
                XCTAssertEqual(yields.first?["route_assigned"], "true", path)
                let restored = await routingEvents(manager, runID: runID, named: "live_affinity_route_restored")
                XCTAssertTrue(restored.isEmpty, "\(path): no route-restored event without the mapping")

                let runTab = await manager.actorRoutedRunPolicyTab(for: reconnectID)
                let metadata = MCPServerViewModel.RequestMetadata(
                    connectionID: reconnectID,
                    clientName: clientName,
                    windowID: window.windowID,
                    runPurpose: after.purpose,
                    actorRoutedRunTab: runTab
                )
                let resolved = try window.mcpServer.resolveTabContextSnapshot(
                    from: metadata,
                    toolName: "selection",
                    policy: .allowLegacyImplicitRouting,
                    startMirroring: false
                )
                XCTAssertFalse(resolved.usesActiveTabCompatibility, path)
                XCTAssertEqual(resolved.snapshot.tabID, fixture.tabID, "\(path): the run tab, never the active tab")

                await manager.removeConnection(reconnectID)
                await tearDownRunTabFixture(fixture)
            }
        }

        /// The accepted residual of a re-route to another run: a Claude native connection that
        /// holds the run's window mapping and is then re-routed actor-side to another run (here
        /// through a tab-less run policy, which registers nothing window-side) leaves its forward
        /// mapping of the first run behind. Until that connection is removed, the first run's other
        /// helper yields on a request path (never displacing it) and resolves the run tab through
        /// step 4b. Removing the connection clears the stale mapping (the removal sweep visits every
        /// run a window maps to it), and the next request takes the empty slot.
        @MainActor
        func testAReroutedConnectionsStaleMappingIsAYieldingResidualUntilItsRemoval() async throws {
            let fixture = try await twoRoutedHelpersWithRunTab(activeDecoyTab: true)
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            let staleID = fixture.newerID
            try bindRunTab(fixture, for: staleID)
            let tablessRunID = UUID()
            await manager.debugSeedRunPolicyState(
                runID: tablessRunID,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun
            )

            await manager.debugApplyRunPolicyState(runID: tablessRunID, connectionID: staleID)

            let staleRoute = await manager.debugCachedRunID(for: staleID)
            try require(staleRoute == tablessRunID, "fixture: re-routed actor-side to the other run")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], staleID, "the first run's forward mapping is left behind")

            let yielded = await manager.debugRunScopedTabRebindFallbackForToolCall(
                connectionID: fixture.olderID, runID: runID, windowID: window.windowID
            )
            XCTAssertEqual(yielded, .yieldedToHolder(holder: staleID), "the first run's other helper yields to the stale holder")
            await assertNeverDisplaced(staleID, runID: runID, "the stale holder is never displaced by a request path")
            let runTab = await manager.actorRoutedRunPolicyTab(for: fixture.olderID)
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: fixture.olderID,
                clientName: clientName,
                windowID: window.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: runTab
            )
            let resolved = try window.mcpServer.resolveTabContextSnapshot(
                from: metadata,
                toolName: "selection",
                policy: .allowLegacyImplicitRouting,
                startMirroring: false
            )
            XCTAssertEqual(resolved.source, .actorRunRoute, "the yielded helper resolves through step 4b")
            XCTAssertEqual(resolved.snapshot.tabID, fixture.tabID, "the run tab, never the active tab")
            XCTAssertFalse(resolved.usesActiveTabCompatibility)

            await manager.removeConnection(staleID)
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID], "the removal sweep clears the stale mapping")
            let repaired = await manager.debugRunScopedTabRebindFallbackForToolCall(
                connectionID: fixture.olderID, runID: runID, windowID: window.windowID
            )
            XCTAssertEqual(repaired, .bound, "the next request takes the empty slot")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], fixture.olderID)

            await manager.cleanupRunRoutingState(for: tablessRunID, windowID: window.windowID)
            await tearDownRunTabFixture(fixture)
        }

        /// A non-Claude (Codex) routed connection keeps the client-agnostic resolver rules. Step 4b
        /// resolves the actor-side run tab for a connection without its run-tab binding (never the
        /// active tab). Step 1 releases a binding to a non-run tab when only the actor-side run
        /// route names the run (`requiredRunID` falls back to `actorRoutedRunTab`), then resolves
        /// the run tab through step 4b.
        @MainActor
        func testACodexRoutedConnectionResolvesTheActorRunTabAndReleasesANonRunTabBinding() async throws {
            let codexClientID = AgentProviderKind.codexMCPClientID
            let fixture = try await twoRoutedHelpersWithRunTab(activeDecoyTab: true, clientName: codexClientID)
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            let decoyTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            try require(decoyTabID != fixture.tabID, "fixture: another tab is active")
            let runTab = await manager.actorRoutedRunPolicyTab(for: fixture.olderID)
            XCTAssertEqual(runTab, ServerNetworkManager.RunPolicyTab(
                runID: runID,
                windowID: window.windowID,
                workspaceID: fixture.workspaceID,
                tabID: fixture.tabID
            ))
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: fixture.olderID,
                clientName: codexClientID,
                windowID: window.windowID,
                runPurpose: .agentModeRun,
                actorRoutedRunTab: runTab
            )

            // Step 4b: no binding of its own.
            let unbound = try window.mcpServer.resolveTabContextSnapshot(
                from: metadata,
                toolName: "selection",
                policy: .allowLegacyImplicitRouting,
                startMirroring: false
            )
            XCTAssertEqual(unbound.source, .actorRunRoute)
            XCTAssertEqual(unbound.snapshot.tabID, fixture.tabID, "the run tab, never the active tab")
            XCTAssertFalse(unbound.usesActiveTabCompatibility)

            // Step 1: bound to a non-run tab, with no window run mapping of its own.
            try window.mcpServer.bindTabForConnection(
                connectionID: fixture.olderID,
                clientName: codexClientID,
                tabID: decoyTabID,
                workspaceID: fixture.workspaceID,
                windowID: window.windowID,
                runID: nil,
                explicitlyBound: false
            )
            try require(window.mcpServer.boundTabID(forConnection: fixture.olderID) == decoyTabID, "fixture: bound to the non-run tab")
            try require(window.mcpServer.connectionIDToRunID[fixture.olderID] == nil, "fixture: only the actor-side route names the run")
            let released = try window.mcpServer.resolveTabContextSnapshot(
                from: metadata,
                toolName: "selection",
                policy: .allowLegacyImplicitRouting,
                startMirroring: false
            )
            XCTAssertEqual(released.source, .actorRunRoute)
            XCTAssertEqual(released.snapshot.tabID, fixture.tabID, "the run tab, never the non-run binding")
            XCTAssertNil(window.mcpServer.boundTabID(forConnection: fixture.olderID), "the non-run binding was released")

            await tearDownRunTabFixture(fixture)
        }

        private struct PendingAdmissionFixture {
            let window: WindowState
            let manager: ServerNetworkManager
            let runID: UUID
            let tabID: UUID
            let ownPID: pid_t
            /// The new launch's helper, admitted through the pending policy.
            let newID: UUID
            /// The old launch's helper, reconnected after `newID` registered; the holder before admission.
            let holderID: UUID
            let admissionOutcome: String
        }

        /// The new launch's helper (peer: the test process under agent 4100) registers first; the
        /// old launch's helper (under agent 4000) then reconnects, is routed and holds the run tab
        /// and mapping; then pending-policy admission of the new launch's helper runs.
        @MainActor
        private func pendingAdmissionOverReconnectedOldLaunchHelper() async throws -> PendingAdmissionFixture {
            let window = makeWindow()
            let (tabID, workspaceID) = try await addRunTab(to: window)
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let ownPID = getpid()
            let fixturePIDs: Set<pid_t> = [shellPID, agentPID, otherAgentPID, helperPID, otherHelperPID]
            try require(!fixturePIDs.contains(ownPID), "the test process PID must not collide with a fixture PID")
            table.spawn(ownPID, parent: otherAgentPID, start: 520)
            await manager.debugSeedRunPolicyState(
                runID: runID,
                windowID: window.windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: nil,
                purpose: .agentModeRun
            )
            // The new launch's helper connects first.
            let newID = UUID()
            let token = "route-retention-admission-\(UUID().uuidString)"
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: newID,
                connection: FixtureConnection(),
                clientName: clientName,
                sessionToken: token
            )
            await manager.debugSetBootstrapPeerPID(connectionID: newID, pid: ownPID)
            // Then the old launch's helper reconnects, is routed, and holds the run tab and mapping.
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let holderID = await routedHelper(on: manager, runID: runID, helperPID: helperPID)
            try window.mcpServer.bindTabForConnection(
                connectionID: holderID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: runID,
                explicitlyBound: false
            )
            try require(window.mcpServer.connectionIDByRunID[runID] == holderID, "fixture: the reconnected old helper holds the mapping")

            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "restart turn",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            await manager.registerExpectedAgentPID(ownPID, for: clientName, runID: runID)
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: newID,
                clientPid: Int(ownPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: token,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            return PendingAdmissionFixture(
                window: window,
                manager: manager,
                runID: runID,
                tabID: tabID,
                ownPID: ownPID,
                newID: newID,
                holderID: holderID,
                admissionOutcome: result.outcome
            )
        }

        @MainActor
        private func tearDown(_ fixture: PendingAdmissionFixture) async {
            let (manager, runID, window) = (fixture.manager, fixture.runID, fixture.window)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.clearExpectedAgentPID(fixture.ownPID, for: clientName, runID: runID)
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            for connectionID in [fixture.newID, fixture.holderID] {
                await manager.removeConnection(connectionID)
            }
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        /// Fresh pending-policy admission keeps the displacing behavior: the new launch's helper
        /// (whose socket registered before the old launch's helper reconnected) is admitted with a
        /// policy naming the run tab while that later-registered, live, routed helper holds the
        /// window's run mapping. Admission still establishes the new helper's mapping and tab and
        /// schedules the holder's replacement.
        @MainActor
        func testPendingPolicyAdmissionStillReplacesALaterRegisteredLiveHolder() async throws {
            let fixture = try await pendingAdmissionOverReconnectedOldLaunchHelper()
            let (manager, runID, window, newID, holderID) = (fixture.manager, fixture.runID, fixture.window, fixture.newID, fixture.holderID)

            XCTAssertEqual(fixture.admissionOutcome, "applied")
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], newID, "admission establishes the new helper's mapping")
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[newID], runID)
            XCTAssertEqual(window.mcpServer.boundTabID(forConnection: newID), fixture.tabID)
            let route = await manager.debugCachedRunID(for: newID)
            XCTAssertEqual(route, runID)
            let scheduled = await manager.debugPendingPolicyReplacementScheduleCount(
                existing: holderID,
                replacement: newID,
                runID: runID
            )
            XCTAssertEqual(scheduled, 1, "the displaced holder's replacement is scheduled")
            XCTAssertEqual(MCPServerViewModel.debugRunMappingDisplacementCount(existing: holderID, runID: runID), 1, "the window displaced the holder once")
            let yields = await yieldEvents(manager, runID: runID)
            XCTAssertTrue(yields.isEmpty, "admission never yields")
            let fills = await emptySlotFills(manager, runID: runID)
            XCTAssertTrue(fills.isEmpty, "admission is no request-path fill")

            await tearDown(fixture)
        }

        /// The cases where a request-originated rebind proceeds, with a newer live helper routed to
        /// the run: the holder's own tab repair (it holds the mapping, its tab is unbound), its
        /// fast path, and a missing mapping. And the short gap before a dead or unrouted holder's
        /// mapping is cleaned up: a holder whose removal has begun, a removed holder whose mapping
        /// still lingers, and a live holder no longer routed to the run all still hold the slot, so
        /// the caller yields (resolving the run tab actor-side) and never displaces them.
        @MainActor
        func testThePerCallRebindRepairsTheHoldersTabAndAnEmptySlotAndYieldsToAnyOtherHolder() async throws {
            do {
                // The newer helper holds the mapping without its run tab: its own call repairs it.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                window.mcpServer.registerRunIDMapping(connectionID: fixture.newerID, runID: fixture.runID, windowID: window.windowID)
                try require(window.mcpServer.boundTabID(forConnection: fixture.newerID) == nil, "fixture: the holder's tab is unbound")
                let outcome = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.newerID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(outcome, .bound, "holder repair")
                XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.newerID), fixture.tabID)
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.newerID)
                let again = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.newerID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(again, .alreadyBound, "the holder's fast path")
                let fills = await emptySlotFills(fixture.manager, runID: fixture.runID)
                XCTAssertTrue(fills.isEmpty, "the holder's own tab repair fills no empty slot")
                await tearDownRunTabFixture(fixture)
            }
            do {
                // The older helper holds the mapping without its run tab: it repairs its own tab.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                window.mcpServer.registerRunIDMapping(connectionID: fixture.olderID, runID: fixture.runID, windowID: window.windowID)
                let outcome = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.olderID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(outcome, .bound, "older holder repair")
                XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.olderID), fixture.tabID)
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.olderID)
                await tearDownRunTabFixture(fixture)
            }
            do {
                // No connection holds the window's run mapping: the older helper's call takes it.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                let outcome = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.olderID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(outcome, .bound, "missing mapping repair")
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.olderID)
                XCTAssertEqual(window.mcpServer.boundTabID(forConnection: fixture.olderID), fixture.tabID)
                await tearDownRunTabFixture(fixture)
            }
            do {
                // The newer holder's removal has begun: until its cleanup runs, it holds the slot.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                try bindRunTab(fixture, for: fixture.newerID)
                await fixture.manager.debugMarkConnectionBeingRemovedForTesting(fixture.newerID, true)
                let outcome = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.olderID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(outcome, .yieldedToHolder(holder: fixture.newerID), "a holder being removed")
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.newerID)
                await assertNeverDisplaced(fixture.newerID, runID: fixture.runID, "a holder being removed")
                await fixture.manager.debugMarkConnectionBeingRemovedForTesting(fixture.newerID, false)
                await tearDownRunTabFixture(fixture)
            }
            do {
                // The newer holder was removed while the window still maps the run to it (its
                // cleanup has not run yet): the caller yields.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                await fixture.manager.removeConnection(fixture.newerID)
                window.mcpServer.registerRunIDMapping(connectionID: fixture.newerID, runID: fixture.runID, windowID: window.windowID)
                try require(window.mcpServer.connectionIDByRunID[fixture.runID] == fixture.newerID, "fixture: the mapping lingers for the removed holder")
                let outcome = await fixture.manager.debugRunScopedTabRebindFallbackForToolCall(
                    connectionID: fixture.olderID, runID: fixture.runID, windowID: window.windowID
                )
                XCTAssertEqual(outcome, .yieldedToHolder(holder: fixture.newerID), "a removed holder whose mapping lingers")
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.newerID)
                await assertNeverDisplaced(fixture.newerID, runID: fixture.runID, "a removed holder whose mapping lingers")
                await tearDownRunTabFixture(fixture)
            }
            do {
                // The newer holder is live but no longer routed to the run: the caller yields.
                let fixture = try await twoRoutedHelpersWithRunTab()
                let window = fixture.window
                try bindRunTab(fixture, for: fixture.newerID)
                await fixture.manager.debugSeedConnectionRunRouting(connectionID: fixture.newerID, runID: UUID())
                let outcome = await fixture.manager.mapConnectionToRunIDWithOutcome(
                    fixture.olderID, runID: fixture.runID, windowID: window.windowID, displacesHolder: false
                )
                XCTAssertEqual(outcome, .yieldedToHolder(holder: fixture.newerID), "an unrouted holder")
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[fixture.runID], fixture.newerID)
                await assertNeverDisplaced(fixture.newerID, runID: fixture.runID, "an unrouted holder")
                await tearDownRunTabFixture(fixture)
            }
        }

        @MainActor
        func testLaterTurnRevocationKeepsTheWindowMappingAffinityAndRunState() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            let affinityBefore = await manager.debugLiveRunAffinityRunIDs()
            XCTAssertTrue(affinityBefore.contains(runID))

            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "turn 2",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID })
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID)
            XCTAssertEqual(window.mcpServer.liveConnectionID(forRunID: runID), connectionID)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertEqual(runPolicy?.windowID, window.windowID)
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertEqual(runWindow, window.windowID)
            let admitted = await manager.debugIsRunAdmitted(runID)
            XCTAssertTrue(admitted)
            let affinityAfter = await manager.debugLiveRunAffinityRunIDs()
            XCTAssertTrue(affinityAfter.contains(runID))
            let preservations = await manager.debugRoutingPreservingPolicyRevocationCount
            XCTAssertEqual(preservations, 1)

            // End-of-scope cleanup still unmaps everything.
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID))
            await manager.removeConnection(connectionID)
        }

        /// Fail-closed revocation with a real registered window: the agent instance is gone, so the
        /// window-side mapping is cleared along with the actor-side routing.
        @MainActor
        func testFailClosedRevocationClearsTheRegisteredWindowMapping() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            table.set(agentPID, .absent)

            await installTurnPolicy(manager, runID: runID, windowID: window.windowID)
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)

            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID))
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy)
            let affinity = await manager.debugLiveRunAffinityRunIDs()
            XCTAssertFalse(affinity.contains(runID))
            let fields = await lastPolicyRevokedFields(manager, runID: runID)
            XCTAssertEqual(fields?["routing_preserved"], "false")
            await manager.removeConnection(connectionID)
        }

        /// The production turn-1 pending-policy admission (with a task label kind) records the same
        /// fingerprint a later turn's refresh compares against: an identical turn-2 install sends
        /// no notification.
        @MainActor
        func testProductionAdmissionFingerprintMatchesAnIdenticalLaterTurnInstall() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let (connectionID, connection) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, taskLabelKind: .explore
            )
            let admittedFingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertEqual(admittedFingerprint, true, "admission records the seeded run state's projection")
            let baseline = await connection.toolListChangedCount

            await installTurnPolicy(manager, runID: runID, windowID: window.windowID, taskLabelKind: .explore)

            let afterInstall = await connection.toolListChangedCount
            XCTAssertEqual(afterInstall, baseline, "an identical turn-2 install announces nothing")
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 0)
            let laterFingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertEqual(laterFingerprint, true)

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        /// Restart overlap with a real window: the window maps the run to the old launch's helper.
        /// Clearing the old launch's PID unroutes that helper together with its window mapping, and
        /// the restarted launch's helper is routed actor-side only; the revocation re-points
        /// nothing, so the run has no window mapping. The conservative outcome: a later turn's early release refuses (launch-bound
        /// evidence needs the window mapping) and the turn falls back to the routing wait, whose
        /// timeout revokes while keeping the proven route, so its loss is still observed.
        @MainActor
        func testAfterPruningAWindowlessRunFallsBackToTheRoutingWait() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let oldConnectionID = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID
            ).connectionID
            try require(
                window.mcpServer.liveConnectionID(forRunID: runID) == oldConnectionID,
                "fixture: the window maps the run to the old launch's helper"
            )
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.debugAwaitScheduledRunWindowCleanups()
            let oldRoute = await manager.debugCachedRunID(for: oldConnectionID)
            XCTAssertNil(oldRoute, "clearing the old launch's PID unroutes its helper")
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID), "and its window mapping goes with it")
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.last?["window_mapping_removed"], "true")
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let newConnectionID = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, seedsWindow: false
            )
            await manager.debugApplyRunPolicyState(runID: runID, connectionID: newConnectionID)

            await installTurnPolicy(manager, runID: runID, windowID: window.windowID)
            await manager.revokeClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)

            let newRoute = await manager.debugCachedRunID(for: newConnectionID)
            XCTAssertEqual(newRoute, runID)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID), "the removed mapping is not re-pointed")

            // The next turn: no early release, the routing wait runs and keeps the proven route.
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")
            let released = await lease.releaseWithProvenExistingRoute(agentPID: otherAgentPID)
            XCTAssertFalse(released, "without the window mapping the early release refuses")
            let routed = await lease.releaseWhenRouted(timeoutMs: 50)

            XCTAssertFalse(routed)
            let earlyReleases = await manager.debugProvenRouteEarlyReleaseCount
            XCTAssertEqual(earlyReleases, 0)
            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertEqual(revoked.last?["routing_preserved"], "true", "the wait's revocation keeps the proven route")
            let routeAfterWait = await manager.debugCachedRunID(for: newConnectionID)
            XCTAssertEqual(routeAfterWait, runID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID })

            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(oldConnectionID)
            await manager.removeConnection(newConnectionID)
        }

        /// The retained connection is removed from inside its own `tools/list_changed` delivery
        /// (the last step of a refresh's apply): nothing re-routes it afterwards, no route is left
        /// behind, the apply never re-points the window mapping, and the run has no live route
        /// evidence. The removal clears the window-side run mapping it held (this tab-less fixture
        /// has no tab context, so the removal's own receipt-checked window cleanup does), and the
        /// apply never re-installs it afterwards.
        @MainActor
        func testRemovalDuringApplyLeavesNoRouteOrWindowMapping() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let (connectionID, connection) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID
            )
            let once = OnceFlag()
            await connection.setNotificationHook {
                guard once.claim() else { return }
                await manager.removeConnection(
                    connectionID,
                    context: MCPConnectionCloseContext(reason: "peer_eof", initiator: .peer)
                )
            }
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")
            let mappedBefore = window.mcpServer.connectionIDByRunID[runID]
            let reverseMappedBefore = window.mcpServer.connectionIDToRunID[connectionID]
            try require(mappedBefore == connectionID, "fixture: the window maps the run to the connection")

            await installTurnPolicy(manager, runID: runID, windowID: window.windowID, restrictedTools: changed)

            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 1, "fixture: the refresh applied and announced")
            let registered = await manager.debugConnectionIsRegistered(connectionID: connectionID)
            XCTAssertFalse(registered)
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route, "no route outlives the removal")
            try require(reverseMappedBefore == runID, "fixture: the window reverse-maps the connection to the run")
            XCTAssertNil(
                window.mcpServer.connectionIDByRunID[runID],
                "the removal cleared the window mapping and the apply never re-installed it"
            )
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID])
            let evidence = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
            )
            XCTAssertFalse(evidence, "a removed connection is no live route")

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID), "no window mapping outlives the end-of-scope cleanup")
        }

        /// A registration removal outside any revocation unroutes exactly the connections whose
        /// proof depended on that PID: route and fingerprint at once, the window mapping by the
        /// scheduled cleanup. A route proven by another registered PID and an unproven route are
        /// untouched, and the run state, its window and the pending queue stay. A run without
        /// routes is unaffected.
        @MainActor
        func testRegistrationRemovalUnroutesOnlyItsDependents() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let (dependentID, _) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID
            )
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let otherToken = "route-retention-other-\(UUID().uuidString)"
            let otherID = await routedHelper(
                on: manager, runID: runID, helperPID: otherHelperPID, sessionToken: otherToken
            )
            // Not in the fake table: no admission snapshot, so never proven.
            let unprovenID = await routedHelper(on: manager, runID: runID, helperPID: 7777)
            let unprovenIsProven = await manager.debugAncestryProvesExpectedAgent(connectionID: unprovenID, runID: runID)
            try require(!unprovenIsProven, "fixture: the third route is unproven")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "next turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            try require(window.mcpServer.connectionIDByRunID[runID] == dependentID, "fixture: the window maps the run to the dependent")
            let fingerprintBefore = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: dependentID, runID: runID
            )
            try require(fingerprintBefore == true, "fixture: the dependent carries the run's projection")
            let affinityBefore = await manager.debugLiveRunAffinityRunIDs()
            try require(affinityBefore.contains(runID), "fixture: the dependent's session has run affinity")

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)

            let dependentRoute = await manager.debugCachedRunID(for: dependentID)
            XCTAssertNil(dependentRoute, "unrouted in the clear's synchronous step")
            let dependentFingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: dependentID, runID: runID
            )
            XCTAssertNil(dependentFingerprint, "its fingerprint goes with its route")
            let otherRoute = await manager.debugCachedRunID(for: otherID)
            XCTAssertEqual(otherRoute, runID, "proven by another registered PID: kept")
            let affinityAfter = await manager.debugLiveRunAffinityRunIDs()
            XCTAssertFalse(affinityAfter.contains(runID), "the dependent's affinity goes with its route")
            let unprovenRoute = await manager.debugCachedRunID(for: unprovenID)
            XCTAssertEqual(unprovenRoute, runID, "never depended on the PID: untouched (the next prune decides)")
            await manager.debugAwaitScheduledRunWindowCleanups()
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID], "the dependent's window mapping is cleaned up")
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy, "the hook never clears run-level state")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertEqual(runWindow, window.windowID)
            let queued = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(queued.count(where: { $0.runID == runID }), 1, "the pending queue is untouched")
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.count, 1)
            XCTAssertEqual(proofLost.first?["cause"], "expected_pid_cleared")
            XCTAssertEqual(proofLost.first?["unrouted_connection_count"], "1")
            XCTAssertEqual(proofLost.first?["window_mapping_removed"], "true")

            // A run without routes: registering and clearing a PID changes nothing.
            let routelessRunID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: routelessRunID)
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: routelessRunID)
            let routelessEvents = await routingEvents(manager, runID: routelessRunID, named: "proof_lost_routes_unrouted")
            XCTAssertTrue(routelessEvents.isEmpty)
            let otherRouteAfter = await manager.debugCachedRunID(for: otherID)
            XCTAssertEqual(otherRouteAfter, runID)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            for connectionID in [dependentID, otherID, unprovenID] {
                await manager.removeConnection(connectionID)
            }
        }

        /// A restart within the run, in production order: the restarted turn's policy is installed
        /// (run state seeded, queue entry pending), then the old agent's PID is cleared, both while
        /// the old process is still in the table and after it already exited (absent before its PID
        /// is cleared, so its helper held no live proof at the clear). The clear unroutes the old
        /// helper (route, fingerprint, affinity, window mapping) but leaves the run state, its
        /// window and the queue entry, so the new launch's helper is still routed by the pending
        /// policy afterwards, carrying the restarted turn's policy.
        @MainActor
        func testRestartClearingTheOldPIDAfterTheNewTurnInstallStillRoutesTheNewHelper() async throws {
            for oldProcessExitedFirst in [false, true] {
                try await assertRestartClearingTheOldPIDRoutesTheNewHelper(oldProcessExitedFirst: oldProcessExitedFirst)
            }
        }

        @MainActor
        private func assertRestartClearingTheOldPIDRoutesTheNewHelper(oldProcessExitedFirst: Bool) async throws {
            let label = oldProcessExitedFirst ? "old process already exited" : "old process present"
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let oldToken = "route-retention-restart-old-\(UUID().uuidString)"
            let (oldID, _) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, sessionToken: oldToken
            )
            var restarted = AgentModeMCPToolPolicy.restrictedTools
            restarted.insert("route_retention_restart_tool")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: restarted,
                oneShot: true,
                reason: "restarted turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )

            // The old process exits: its PID is cleared, then its helper closes.
            if oldProcessExitedFirst {
                table.set(agentPID, .absent)
                let provenAtClear = await manager.debugConnectionHoldsProvenRunRoute(
                    connectionID: oldID, runID: runID, clientName: clientName
                )
                try require(!provenAtClear, "fixture: the old helper holds no live proof before the clear")
            }
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.debugAwaitScheduledRunWindowCleanups()
            let oldRoute = await manager.debugCachedRunID(for: oldID)
            XCTAssertNil(oldRoute, label)
            let oldFingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: oldID, runID: runID
            )
            XCTAssertNil(oldFingerprint, label)
            let oldAffinity = await manager.debugLiveRunAffinityRunID(sessionKey: oldToken)
            XCTAssertNil(oldAffinity, label)
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID], label)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertEqual(runPolicy?.restrictedTools, restarted, "\(label): the restarted turn's seeded run state stays")
            let runWindow = await manager.debugWindowIDForRunID(runID)
            XCTAssertEqual(runWindow, window.windowID, label)
            let queued = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(
                queued.count(where: { $0.runID == runID }), 1, "\(label): the restarted turn's queue entry stays"
            )
            let proofLost = await routingEvents(manager, runID: runID, named: "proof_lost_routes_unrouted")
            XCTAssertEqual(proofLost.last?["cause"], "expected_pid_cleared", label)
            await manager.removeConnection(
                oldID,
                context: MCPConnectionCloseContext(reason: "peer_eof", initiator: .peer)
            )

            // The new launch registers and its helper is admitted (the test process stands in).
            let ownPID = getpid()
            await manager.registerExpectedAgentPID(ownPID, for: clientName, runID: runID)
            let newID = UUID()
            let token = "route-retention-restarted-\(UUID().uuidString)"
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: newID,
                connection: FixtureConnection(),
                clientName: clientName,
                sessionToken: token
            )
            await manager.debugSetBootstrapPeerPID(connectionID: newID, pid: ownPID)
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: newID,
                clientPid: Int(ownPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: token,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            XCTAssertEqual(result.outcome, "applied", "\(label): the new helper is routed by the pending policy")
            let newRoute = await manager.debugCachedRunID(for: newID)
            XCTAssertEqual(newRoute, runID, label)
            XCTAssertEqual(window.mcpServer.liveConnectionID(forRunID: runID), newID, label)
            let state = await manager.debugConnectionPolicyState(for: newID)
            XCTAssertEqual(state.restrictedTools, restarted, label)

            await manager.clearExpectedAgentPID(ownPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(newID)
        }

        /// The fingerprint describes what a pending-policy application wrote. The run's state is
        /// newer than the queued policy (another projection, which `cacheRunPolicyStateIfNeeded`
        /// keeps): at the staging write, where the connection carries the queued policy's values, no
        /// fingerprint is recorded. The route installation then applies the run state and records
        /// its projection with it, so the connection ends consistent and an identical refresh sends
        /// nothing.
        @MainActor
        func testPendingApplyRecordsNoFingerprintWhenTheRunStateIsNewer() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = UUID()
            var newer = AgentModeMCPToolPolicy.restrictedTools
            newer.insert("route_retention_newer_tool")
            let windowID = window.windowID
            let atStaging = LockedValue<(fingerprint: Bool?, restrictedTools: Set<String>)?>(nil)
            let (_, connection) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, connectionID: connectionID,
                beforeAdmission: {
                    await manager.debugSeedRunPolicyState(
                        runID: runID,
                        windowID: windowID,
                        restrictedTools: newer,
                        additionalTools: nil,
                        purpose: .agentModeRun,
                        updatedAt: Date().addingTimeInterval(60)
                    )
                    await manager.debugSuspendNextPendingPolicyRouteInstallation()
                    Task {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                        while await !manager.debugIsPendingPolicyRouteInstallationSuspended(),
                              ContinuousClock.now < deadline
                        {
                            try? await Task.sleep(for: .milliseconds(2))
                        }
                        let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                            connectionID: connectionID, runID: runID
                        )
                        let state = await manager.debugConnectionPolicyState(for: connectionID)
                        atStaging.set((fingerprint, state.restrictedTools))
                        await manager.debugResumePendingPolicyRouteInstallation()
                    }
                }
            )
            let staged = try XCTUnwrap(atStaging.get(), "the staging suspension was observed")
            XCTAssertEqual(staged.restrictedTools, AgentModeMCPToolPolicy.restrictedTools, "fixture: the queued policy was staged")
            XCTAssertNil(staged.fingerprint, "the staged projection differs from the run state's: no fingerprint")
            let finalState = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(finalState.restrictedTools, newer, "the route installation applied the run state")
            let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertEqual(fingerprint, true, "recorded with the run state's write")
            let baseline = await connection.toolListChangedCount

            await manager.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: runID)

            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, baseline, "nothing left to correct")

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        // MARK: - Launch-bound connected evidence

        /// The Claude connected-evidence fallback binds to one launch: the routed helper must
        /// descend from exactly the agent instance registered for the required PID. An old launch's
        /// helper never certifies the restarted launch, even while both PIDs are registered; the
        /// default (OMP, `nil`) evidence is unchanged.
        @MainActor
        func testLaunchBoundEvidenceRejectsAnOldLaunchHelperWhileBothPIDsAreRegistered() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID

            let provenForOwnLaunch = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
            )
            XCTAssertTrue(provenForOwnLaunch)
            let defaultEvidence = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: nil
            )
            XCTAssertTrue(defaultEvidence)

            // A restarted launch registers its agent while the old launch's PID is still registered.
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let certifiesNewLaunch = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: otherAgentPID
            )
            XCTAssertFalse(certifiesNewLaunch, "an old launch's helper route never certifies a restart")
            let stillCertifiesOldLaunch = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
            )
            XCTAssertTrue(stillCertifiesOldLaunch)
            let defaultEvidenceAfterRestart = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: nil
            )
            XCTAssertTrue(defaultEvidenceAfterRestart, "the default evidence is unchanged")

            // A PID the run no longer registers proves nothing.
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let afterOldPIDCleared = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
            )
            XCTAssertFalse(afterOldPIDCleared)

            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        @MainActor
        func testLaunchBoundEvidenceProvesTheNewLaunchHelper() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID, underAgent: otherAgentPID, peerStart: 530
            ).connectionID

            let proven = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: otherAgentPID
            )
            XCTAssertTrue(proven)
            let unregisteredPID = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
            )
            XCTAssertFalse(unregisteredPID, "a PID the run does not register proves nothing")

            // The registered agent instance replaced by a process reusing its PID.
            table.spawn(otherAgentPID, parent: shellPID, start: 990)
            let reusedPID = await manager.hasAuthoritativeLiveRunRoute(
                runID: runID, expectedClientName: clientName, requiredAgentPID: otherAgentPID
            )
            XCTAssertFalse(reusedPID, "a reused agent PID is not the registered instance")

            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        private enum TerminalCase: CaseIterable {
            case terminalClaimed
            case beingRemoved
            case watchdogTerminal
        }

        @MainActor
        func testLaunchBoundEvidenceRejectsTerminalConnections() async throws {
            for terminalCase in TerminalCase.allCases {
                let label = "\(terminalCase)"
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
                switch terminalCase {
                case .terminalClaimed:
                    await manager.debugCommitTerminalRecordForTesting(connectionID: connectionID, reason: "peer_eof")
                case .beingRemoved:
                    await manager.debugMarkConnectionBeingRemovedForTesting(connectionID, true)
                case .watchdogTerminal:
                    await manager.debugAbortConnectionForExecutionWatchdog(connectionID: connectionID, toolName: "slow_tool")
                }

                let launchBound = await manager.hasAuthoritativeLiveRunRoute(
                    runID: runID, expectedClientName: clientName, requiredAgentPID: agentPID
                )
                XCTAssertFalse(launchBound, label)
                if terminalCase == .beingRemoved {
                    let defaultEvidence = await manager.hasAuthoritativeLiveRunRoute(
                        runID: runID, expectedClientName: clientName, requiredAgentPID: nil
                    )
                    XCTAssertTrue(defaultEvidence, "the default (OMP) evidence is unchanged")
                    await manager.debugMarkConnectionBeingRemovedForTesting(connectionID, false)
                }

                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await manager.removeConnection(connectionID)
            }
        }

        // MARK: - Real bootstrap lease against the real manager

        /// A real lease on a private manager and routing waiter, with the default policy hooks
        /// (`installClientConnectionPolicy`, `revokeClientConnectionPolicy`,
        /// `releasePendingRunPolicyForProvenRoute`).
        private func makeLease(
            manager: ServerNetworkManager,
            windowID: Int,
            runID: UUID,
            retainedRunPolicyRefresher: ((MCPBootstrapLeaseSpec) async -> Void)? = nil
        ) async -> MCPBootstrapLease {
            await HeadlessAgentConnectionGate.cancelAll()
            let coordinator = AgentRunCoordinator(
                mcpHost: manager,
                routingWaiter: MCPRoutingWaiter(mcpHost: manager)
            )
            return MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: UUID(),
                    windowID: windowID,
                    tabID: nil,
                    clientName: clientName,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    additionalTools: nil,
                    oneShot: true,
                    reason: "later turn",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: true
                ),
                runCoordinator: coordinator,
                retainedRunPolicyRefresher: retainedRunPolicyRefresher
            )
        }

        /// A later turn whose launch's helper is already routed finishes its lease at once: the
        /// turn's pending policy is cleared (not revoked), the route stays, and later failure or
        /// cancellation cleanup never revokes.
        @MainActor
        func testLaterTurnWithAProvenRouteReleasesWithoutTheRoutingWait() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")
            let pendingBefore = await manager.debugPendingPolicySnapshot(for: clientName)
            try require(pendingBefore.contains { $0.runID == runID }, "the turn's pending policy is installed")

            let started = ContinuousClock.now
            let released = await lease.releaseWithProvenExistingRoute(agentPID: agentPID)
            let elapsed = ContinuousClock.now - started

            XCTAssertTrue(released)
            XCTAssertLessThan(elapsed, .seconds(5), "no routing wait")
            let pendingAfter = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pendingAfter.contains { $0.runID == runID }, "the turn's pending policy is cleared")
            let applicationID = await manager.debugPendingPolicyApplicationID(runID: runID)
            XCTAssertNil(applicationID)
            let earlyReleases = await manager.debugProvenRouteEarlyReleaseCount
            XCTAssertEqual(earlyReleases, 1)
            let skipped = await routingEvents(manager, runID: runID, named: "route_wait_skipped_proven_route")
            XCTAssertEqual(skipped.count, 1)
            let waitStarted = await routingEvents(manager, runID: runID, named: "route_wait_started")
            XCTAssertTrue(waitStarted.isEmpty, "the routing wait never ran")
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.hasReleased)
            XCTAssertTrue(snapshot.didReleaseWithProvenExistingRoute)
            XCTAssertTrue(snapshot.didCleanupRouting)
            XCTAssertFalse(snapshot.didRevokePolicy)

            await lease.failAndRelease()
            await lease.cancelAndCleanup()

            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertTrue(revoked.isEmpty, "neither the early release nor later cleanup revokes")
            let finalSnapshot = await lease.debugCleanupSnapshot()
            XCTAssertFalse(finalSnapshot.didRevokePolicy)
            XCTAssertEqual(finalSnapshot.routingCleanupCount, 1)
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID)
            XCTAssertEqual(window.mcpServer.liveConnectionID(forRunID: runID), connectionID)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy)

            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        /// A turn fails after its early release, by which time its agent is gone: the lease never
        /// revokes (the turn's policy is already cleared), but runs the revoke's routing half once.
        /// The run's routing state is cleared, and a newer queued policy of the run stays untouched.
        @MainActor
        func testFailureAfterAnEarlyReleaseCleansUpRoutingWithoutTouchingPendingPolicies() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")
            let released = await lease.releaseWithProvenExistingRoute(agentPID: agentPID)
            try require(released, "fixture: the early release applies")
            // A newer queued policy of the run: the routing-only cleanup must not touch it.
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "newer turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            let pendingBefore = await manager.debugPendingPolicySnapshot(for: clientName).filter { $0.runID == runID }
            try require(pendingBefore.count == 1, "fixture: one queued policy of the run")
            table.set(agentPID, .absent)

            await lease.failAndRelease()
            await lease.cancelAndCleanup()

            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(runPolicy, "the agent is gone: the run's routing state is cleared")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID))
            let pendingAfter = await manager.debugPendingPolicySnapshot(for: clientName).filter { $0.runID == runID }
            XCTAssertEqual(pendingAfter.count, 1, "the pending queue is untouched")
            XCTAssertEqual(pendingAfter.map(\.windowID), pendingBefore.map(\.windowID))
            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertTrue(revoked.isEmpty, "never revoked after an early release")
            let cleanups = await routingEvents(manager, runID: runID, named: "routing_cleanup_if_unproven")
            XCTAssertEqual(cleanups.count, 1, "the routing-only cleanup runs once")
            XCTAssertEqual(cleanups.first?["routing_preserved"], "false")
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.didCleanUpRoutingAfterEarlyRelease)
            XCTAssertFalse(snapshot.didRevokePolicy)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.removeConnection(connectionID)
        }

        /// A turn is cancelled after its early release while its agent is still alive: the lease
        /// never revokes, its routing-only cleanup runs once and preserves the proven route
        /// (`routing_preserved=true`), and a newer queued policy of the run is untouched. The
        /// route, window mapping and run state all stay.
        @MainActor
        func testCancellationAfterAnEarlyReleaseWithTheAgentAliveKeepsRoutingAndTheQueue() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")
            let released = await lease.releaseWithProvenExistingRoute(agentPID: agentPID)
            try require(released, "fixture: the early release applies")
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "newer turn",
                ttl: 10,
                runID: runID,
                purpose: .agentModeRun,
                requiresExpectedAgentPID: true
            )
            let pendingBefore = await manager.debugPendingPolicySnapshot(for: clientName).filter { $0.runID == runID }
            try require(pendingBefore.count == 1, "fixture: one queued policy of the run")

            await lease.cancelAndCleanup()

            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertTrue(revoked.isEmpty, "never revoked after an early release")
            let cleanups = await routingEvents(manager, runID: runID, named: "routing_cleanup_if_unproven")
            XCTAssertEqual(cleanups.count, 1, "the routing-only cleanup runs once")
            XCTAssertEqual(cleanups.first?["routing_preserved"], "true", "the live agent's proven route is preserved")
            XCTAssertEqual(cleanups.first?["preserved_connection_count"], "1")
            XCTAssertEqual(cleanups.first?["pruned_connection_count"], "0")
            let pendingAfter = await manager.debugPendingPolicySnapshot(for: clientName).filter { $0.runID == runID }
            XCTAssertEqual(pendingAfter.count, 1, "the pending queue is untouched")
            XCTAssertEqual(pendingAfter.map(\.windowID), pendingBefore.map(\.windowID))
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID)
            XCTAssertEqual(window.mcpServer.liveConnectionID(forRunID: runID), connectionID)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNotNil(runPolicy)
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.didCleanUpRoutingAfterEarlyRelease)
            XCTAssertFalse(snapshot.didRevokePolicy)
            XCTAssertEqual(snapshot.routingCleanupCount, 1)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        /// Cancellation lands while the turn-start refresh is suspended (after the gate release):
        /// `acquire()` never reports success after it, and the lease's cleanup runs exactly once.
        func testCancellationDuringTheTurnStartRefreshFailsAcquireAndCleansUpOnce() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
            let gate = LifecycleAsyncGate()
            let lease = await makeLease(manager: manager, windowID: windowID, runID: runID) { _ in
                await gate.arriveAndWait()
            }

            let acquire = Task { await lease.acquire() }
            await gate.waitUntilArrived()
            acquire.cancel()
            await gate.release()
            let acquired = await acquire.value

            XCTAssertFalse(acquired, "no success after a cancellation")
            // Both the cancellation handler's cleanup and acquire's own abort path have run.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await routingEvents(manager, runID: runID, named: "lease_cancelled").count < 2 {
                try require(ContinuousClock.now < deadline, "the cancellation cleanups never ran")
                try await Task.sleep(for: .milliseconds(5))
            }
            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertEqual(revoked.count, 1, "the policy is revoked exactly once")
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.didRevokePolicy)
            XCTAssertEqual(snapshot.routingCleanupCount, 1, "routing is cleaned exactly once")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pending.contains { $0.runID == runID })
            let lateAcquire = await lease.acquire()
            XCTAssertFalse(lateAcquire)
        }

        /// The turn-start refresh could not prove the route (a transient unreadable agent read), so
        /// the retained helper still has the older projection. The later early release proves it,
        /// removes the turn's queue entry before the refresh suspends (no new helper can reserve
        /// it meanwhile), then brings the helper to the turn's projection with exactly one
        /// notification.
        @MainActor
        func testEarlyReleaseDeliversThePolicyTheTurnStartRefreshCouldNotProve() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let (connectionID, connection) = try await productionRoutedHelper(
                on: manager, table: table, window: window, runID: runID
            )
            let baseline = await connection.toolListChangedCount
            var changed = AgentModeMCPToolPolicy.restrictedTools
            changed.insert("route_retention_probe_tool")

            table.set(agentPID, .unreadable)
            await installTurnPolicy(manager, runID: runID, windowID: window.windowID, restrictedTools: changed)
            let afterTurnStart = await connection.toolListChangedCount
            try require(afterTurnStart == baseline, "fixture: the turn-start refresh could not prove the route")
            table.spawn(agentPID, parent: shellPID, start: agentStart)

            let pendingDuringRefresh = LockedValue<Bool?>(nil)
            let clientName = clientName
            await manager.debugSetRetainedRunPolicyRefreshSuspension { _ in
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                pendingDuringRefresh.set(pending.contains { $0.runID == runID })
            }
            let released = await manager.releasePendingRunPolicyForProvenRoute(
                for: clientName, windowID: window.windowID, runID: runID, agentPID: agentPID
            )
            await manager.debugSetRetainedRunPolicyRefreshSuspension(nil)

            XCTAssertTrue(released)
            XCTAssertEqual(
                pendingDuringRefresh.get(), false,
                "the queue entry is removed synchronously with the release's checks, before the refresh suspends"
            )
            let notified = await connection.toolListChangedCount
            XCTAssertEqual(notified, baseline + 1, "exactly one tools/list_changed")
            let state = await manager.debugConnectionPolicyState(for: connectionID)
            XCTAssertEqual(state.restrictedTools, changed, "the connection ends on the new projection")
            let fingerprint = await manager.debugAppliedRunPolicyProjectionMatchesRunPolicy(
                connectionID: connectionID, runID: runID
            )
            XCTAssertEqual(fingerprint, true)
            let pendingAfter = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pendingAfter.contains { $0.runID == runID })
            let refreshes = await manager.debugRetainedRunPolicyRefreshCount
            XCTAssertEqual(refreshes, 1)

            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }

        /// With an application of the run's policy in flight, or its queued policy reserved by a
        /// connection, a new helper is being routed: the early release refuses, the pending policy
        /// stays, and the lease is left for the routing wait.
        @MainActor
        func testEarlyReleaseRefusesWhileAnApplicationIsInFlightOrReserved() async throws {
            for applicationInFlight in [true, false] {
                let label = applicationInFlight ? "application in flight" : "reservation held"
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                let connectionID = try await productionRoutedHelper(
                    on: manager, table: table, window: window, runID: runID
                ).connectionID
                let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
                let acquired = await lease.acquire()
                try require(acquired, "lease acquire (\(label))")
                if applicationInFlight {
                    _ = await manager.debugBeginPendingPolicyApplicationForTesting(runID: runID)
                } else {
                    let reserved = await manager.debugSetPendingPolicyReservationForTesting(
                        runID: runID, connectionID: UUID()
                    )
                    try require(reserved, "fixture (\(label)): the run's pending policy is reserved")
                }

                let released = await lease.releaseWithProvenExistingRoute(agentPID: agentPID)

                XCTAssertFalse(released, label)
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(pending.contains { $0.runID == runID }, "\(label): the pending policy remains")
                let snapshot = await lease.debugCleanupSnapshot()
                XCTAssertFalse(snapshot.hasReleased, "\(label): the lease is not released")
                XCTAssertFalse(snapshot.didReleaseWithProvenExistingRoute, label)
                let earlyReleases = await manager.debugProvenRouteEarlyReleaseCount
                XCTAssertEqual(earlyReleases, 0, label)

                await lease.cancelAndCleanup()
                await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await manager.removeConnection(connectionID)
            }
        }

        /// A first turn (no route yet) and a restarted launch (the route belongs to the old agent)
        /// keep the routing wait: the early release refuses and leaves the lease untouched, and the
        /// wait's timeout revokes as before (failing closed for the restart's unproven old route).
        @MainActor
        func testWithoutAProvenLaunchRouteTheRoutingWaitStillRuns() async throws {
            // First turn: nothing routed for the run.
            do {
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                await manager.registerExpectedAgentPID(agentPID, for: clientName, runID: runID)
                let lease = await makeLease(manager: manager, windowID: windowID, runID: runID)
                let acquired = await lease.acquire()
                try require(acquired, "lease acquire")
                let released = await lease.releaseWithProvenExistingRoute(agentPID: agentPID)
                XCTAssertFalse(released, "first turn")
                let snapshot = await lease.debugCleanupSnapshot()
                XCTAssertFalse(snapshot.hasReleased)
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(pending.contains { $0.runID == runID }, "the first turn's policy stays pending")
                await lease.cancelAndCleanup()
            }

            // Restarted launch: the run's route belongs to the cleared old agent.
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            await manager.clearExpectedAgentPID(agentPID, for: clientName, runID: runID)
            await manager.registerExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")

            let released = await lease.releaseWithProvenExistingRoute(agentPID: otherAgentPID)
            XCTAssertFalse(released, "restarted launch")
            let routed = await lease.releaseWhenRouted(timeoutMs: 50)

            XCTAssertFalse(routed)
            let earlyReleases = await manager.debugProvenRouteEarlyReleaseCount
            XCTAssertEqual(earlyReleases, 0)
            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertEqual(revoked.count, 1)
            XCTAssertEqual(revoked.last?["routing_preserved"], "false")
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertNil(route)
            XCTAssertNil(window.mcpServer.liveConnectionID(forRunID: runID))
            await manager.clearExpectedAgentPID(otherAgentPID, for: clientName, runID: runID)
            await manager.removeConnection(connectionID)
        }

        /// The revocation paths through a real lease and the default policy clearer keep the proven
        /// route: a short routing-wait timeout, and cancellation cleanup.
        @MainActor
        func testRealLeaseRevocationPreservesTheProvenRoute() async throws {
            for useCancellation in [false, true] {
                let label = useCancellation ? "cancelAndCleanup" : "releaseWhenRouted timeout"
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
                let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
                let acquired = await lease.acquire()
                try require(acquired, "lease acquire (\(label))")

                if useCancellation {
                    await lease.cancelAndCleanup()
                } else {
                    let routed = await lease.releaseWhenRouted(timeoutMs: 50)
                    XCTAssertFalse(routed, label)
                }

                let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
                XCTAssertEqual(revoked.count, 1, label)
                XCTAssertEqual(revoked.last?["routing_preserved"], "true", label)
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertFalse(pending.contains { $0.runID == runID }, label)
                let route = await manager.debugCachedRunID(for: connectionID)
                XCTAssertEqual(route, runID, label)
                XCTAssertEqual(window.mcpServer.liveConnectionID(forRunID: runID), connectionID, label)
                let snapshot = await lease.debugCleanupSnapshot()
                XCTAssertTrue(snapshot.didRevokePolicy, label)
                XCTAssertEqual(snapshot.routingCleanupCount, 1, label)

                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await manager.removeConnection(connectionID)
            }
        }

        /// Cancellation cleanup while `releaseWhenRouted` is suspended in its wait revokes once; the
        /// resumed wait neither revokes nor cleans routing again.
        @MainActor
        func testCancellationDuringTheRoutingWaitRevokesOnce() async throws {
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let connectionID = try await productionRoutedHelper(on: manager, table: table, window: window, runID: runID).connectionID
            let lease = await makeLease(manager: manager, windowID: window.windowID, runID: runID)
            let acquired = await lease.acquire()
            try require(acquired, "lease acquire")

            let wait = Task { await lease.releaseWhenRouted(timeoutMs: 5000) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await routingEvents(manager, runID: runID, named: "route_wait_started").isEmpty {
                try require(ContinuousClock.now < deadline, "the routing wait never started")
                try await Task.sleep(for: .milliseconds(5))
            }
            await lease.cancelAndCleanup()
            let routed = await wait.value

            XCTAssertFalse(routed)
            let revoked = await routingEvents(manager, runID: runID, named: "policy_revoked")
            XCTAssertEqual(revoked.count, 1, "revoked exactly once")
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.didRevokePolicy)
            XCTAssertEqual(snapshot.routingCleanupCount, 1)
            let route = await manager.debugCachedRunID(for: connectionID)
            XCTAssertEqual(route, runID)

            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            await manager.removeConnection(connectionID)
        }
    }
#endif
