import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

#if DEBUG
    /// WS5: a closed run-routed `repoprompt-mcp` helper connection opens a helper-exit watch; the
    /// manager reports `helper_exited` once the helper process is gone (after a 2 s grace) or
    /// `route_not_restored` when it stays alive without restoring the route for 20 s, addressed only
    /// to launches proven by the helper's admission ancestry. A qualifying successor cancels the
    /// watch. Uses a private manager, an in-memory fixture connection, a fake process table, a
    /// manual tick and a manual clock (no socket, helper or Claude process).
    final class MCPHelperExitRunConnectionLossTests: XCTestCase {
        private actor FixtureConnection: MCPServerConnection {
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
            func notifyToolListChanged() async {}
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

        private actor ObserverGate {
            private var released = false
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private(set) var arrivals = 0

            func arriveAndWait() async {
                arrivals += 1
                guard !released else { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func release() {
                released = true
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            }
        }

        // Process tree: shell 3000 → agent 4000 → helper 5000. Another agent 4100.
        private let shellPID: pid_t = 3000
        private let agentPID: pid_t = 4000
        private let otherAgentPID: pid_t = 4100
        private let helperPID: pid_t = 5000
        private let agentStart: Int64 = 400

        private func makeManager(table: FakeProcessTable) async -> ServerNetworkManager {
            let manager = ServerNetworkManager()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws5-helper-exit-terminal-records-\(UUID().uuidString)", isDirectory: true)
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
            return table
        }

        /// Registers a bootstrap helper connection (its admission snapshot is captured from the
        /// table) and, unless `route` is false, routes it to `runID`.
        @discardableResult
        private func registerHelperConnection(
            on manager: ServerNetworkManager,
            runID: UUID,
            helperPID: pid_t,
            sessionToken: String = "ws5-\(UUID().uuidString)",
            route: Bool = true
        ) async -> UUID {
            let connectionID = UUID()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: FixtureConnection(),
                clientName: "claude-code",
                sessionToken: sessionToken
            )
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: helperPID)
            if route {
                await manager.debugSeedConnectionRunRouting(connectionID: connectionID, runID: runID, purpose: .agentModeRun)
            }
            return connectionID
        }

        private func close(_ manager: ServerNetworkManager, _ connectionID: UUID, reason: String) async {
            await manager.removeConnection(
                connectionID,
                context: MCPConnectionCloseContext(reason: reason, initiator: .peer)
            )
        }

        private func launch(_ pid: pid_t) -> AgentMCPRunLaunchIdentity {
            AgentMCPRunLaunchIdentity(token: UUID(), agentProcessID: pid)
        }

        @discardableResult
        private func observe(
            _ manager: ServerNetworkManager,
            runID: UUID,
            launch: AgentMCPRunLaunchIdentity,
            recorder: LossRecorder
        ) async -> UUID {
            await manager.registerRunConnectionLossObserver(for: runID, launch: launch) { loss in
                await recorder.record(loss)
            }
        }

        private func advanceAndTick(_ manager: ServerNetworkManager, seconds: Int64) async -> Int {
            await manager.debugAdvanceHelperExitWatchClock(by: .seconds(seconds))
            return await manager.debugRunHelperExitWatchTick()
        }

        // MARK: - Emission

        func testEligibleCloseThenHelperExitEmitsOnceAfterTheGraceWithCorrectFields() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)

            await close(manager, connectionID, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 1)
            let whileAlive = await manager.debugRunHelperExitWatchTick()
            XCTAssertEqual(whileAlive, 0)

            table.set(helperPID, .absent)
            let withinGrace = await advanceAndTick(manager, seconds: 1)
            XCTAssertEqual(withinGrace, 0, "an exited helper waits for the 2 s grace")
            let afterGrace = await advanceAndTick(manager, seconds: 1)
            XCTAssertEqual(afterGrace, 1)
            await recorder.waitForCount(1)

            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.runID, runID)
            XCTAssertEqual(loss.connectionID, connectionID)
            XCTAssertEqual(loss.clientName, "claude-code")
            XCTAssertEqual(loss.launchToken, owningLaunch.token)
            XCTAssertEqual(loss.agentProcessID, agentPID)
            XCTAssertNil(loss.toolName)
            XCTAssertEqual(loss.reason, .helperExited)
            XCTAssertEqual(loss.closeReason, "peer_eof")
            XCTAssertFalse(loss.connectionPredatesLaunch)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))

            // Retired: nothing more, ever.
            let later = await advanceAndTick(manager, seconds: 60)
            XCTAssertEqual(later, 0)
            let remaining = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(remaining, 0)
            let count = await recorder.losses.count
            XCTAssertEqual(count, 1)
        }

        func testAliveHelperPastTheDeadlineEmitsRouteNotRestored() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)

            await close(manager, connectionID, reason: TerminationReason.idleTimeout.rawValue)
            let beforeDeadline = await advanceAndTick(manager, seconds: 19)
            XCTAssertEqual(beforeDeadline, 0)
            let atDeadline = await advanceAndTick(manager, seconds: 1)
            XCTAssertEqual(atDeadline, 1)
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .routeNotRestored)
            XCTAssertEqual(loss.closeReason, "idle_timeout")
            XCTAssertEqual(loss.agentProcessID, agentPID)
        }

        func testUnknownLivenessNeverBecomesExitedButTheRouteDeadlineStillApplies() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)

            await close(manager, connectionID, reason: "read_error")
            table.set(helperPID, .unreadable)
            let afterGrace = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(afterGrace, 0, "unknown is never treated as exited")
            let midway = await advanceAndTick(manager, seconds: 10)
            XCTAssertEqual(midway, 0)
            let atDeadline = await advanceAndTick(manager, seconds: 8)
            XCTAssertEqual(atDeadline, 1)
            await recorder.waitForCount(1)
            let reasons = await recorder.losses.map(\.reason)
            XCTAssertEqual(reasons, [.routeNotRestored])
        }

        func testZombieGoneAndReusedPIDAllCountAsExited() async {
            let exitedEntries: [(String, MCPProcessTableEntry)] = [
                ("gone", .absent),
                ("zombie", .present(
                    identity: MCPHelperProcessIdentity(pid: helperPID, startSeconds: 500, startMicroseconds: 0),
                    parentPID: agentPID,
                    isZombie: true
                )),
                ("pid reuse", .present(
                    identity: MCPHelperProcessIdentity(pid: helperPID, startSeconds: 900, startMicroseconds: 0),
                    parentPID: 1,
                    isZombie: false
                ))
            ]
            for (label, entry) in exitedEntries {
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                let recorder = LossRecorder()
                await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
                let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
                await close(manager, connectionID, reason: "peer_eof")

                table.set(helperPID, entry)
                let delivered = await advanceAndTick(manager, seconds: 2)
                XCTAssertEqual(delivered, 1, label)
                await recorder.waitForCount(1)
                let reasons = await recorder.losses.map(\.reason)
                XCTAssertEqual(reasons, [.helperExited], label)
            }
        }

        /// The helper-exit watch addresses only launches whose agent PID is in the helper's
        /// admission ancestry; `connectionPredatesLaunch` is never proof for these reasons.
        func testLaunchWithoutAncestryProofGetsNoEvent() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let unprovenRecorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(otherAgentPID), recorder: unprovenRecorder)
            let unprovenOnly = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, unprovenOnly, reason: "peer_eof")
            let noWatch = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(noWatch, 0, "no proven launch, no watch")

            // Mixed: only the proven launch is addressed.
            let provenRecorder = LossRecorder()
            let provenLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: provenLaunch, recorder: provenRecorder)
            let mixed = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, mixed, reason: "peer_eof")
            let addressees = await manager.debugHelperExitObservationAddresseeTokens(connectionID: mixed)
            XCTAssertEqual(addressees, [provenLaunch.token])
            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 1)
            await provenRecorder.waitForCount(1)
            let unprovenLosses = await unprovenRecorder.losses
            XCTAssertTrue(unprovenLosses.isEmpty)
        }

        // MARK: - Eligibility

        func testExcludedCloseReasonsAndWatchdogAbortOpenNoWatch() async {
            let excluded = [
                TerminationReason.runCompleted.rawValue,
                TerminationReason.runCancelled.rawValue,
                TerminationReason.serverShutdown.rawValue,
                TerminationReason.connectionReplaced.rawValue,
                TerminationReason.toolExecutionWatchdog.rawValue
            ]
            XCTAssertEqual(ServerNetworkManager.helperExitWatchExcludedCloseReasons, Set(excluded))
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            for reason in excluded {
                let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
                await close(manager, connectionID, reason: reason)
                let count = await manager.debugHelperExitObservationCount()
                XCTAssertEqual(count, 0, reason)
            }

            // A watchdog-aborted connection reports its own loss and is never watched, whatever
            // reason its later removal records.
            let aborted = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: aborted, toolName: "slow_tool")
            await close(manager, aborted, reason: "peer_eof")
            let afterAbort = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(afterAbort, 0)
            await recorder.waitForCount(1)
            let reasons = await recorder.losses.map(\.reason)
            XCTAssertEqual(reasons, [.toolExecutionWatchdog])

            // Any other reason, including an unknown future one, is watched.
            for reason in ["peer_eof", "some_future_close_reason", TerminationReason.userBootFromDashboard.rawValue] {
                let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
                await close(manager, connectionID, reason: reason)
                let count = await manager.debugHelperExitObservationCount()
                XCTAssertEqual(count, 1, reason)
                // Drain it through a same-token-free route-not-restored emission.
                _ = await advanceAndTick(manager, seconds: 20)
            }
        }

        func testNoObserversOrNoRouteOpensNoWatch() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let unobservedRunID = UUID()
            let unobserved = await registerHelperConnection(on: manager, runID: unobservedRunID, helperPID: helperPID)
            await close(manager, unobserved, reason: "peer_eof")
            let withoutObservers = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(withoutObservers, 0, "a run with no loss observers (Codex) is never watched")

            let runID = UUID()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let unrouted = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, route: false)
            await close(manager, unrouted, reason: "peer_eof")
            let withoutRoute = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(withoutRoute, 0, "an unrouted connection is never watched")
        }

        // MARK: - Successors

        func testSameSessionTokenSuccessorCancelsTheWatch() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let token = "ws5-same-token-\(UUID().uuidString)"
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, sessionToken: token)
            await close(manager, connectionID, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(opened, 1)

            // The same helper reconnects with its session token and is re-routed to the run.
            await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, sessionToken: token)
            let afterSuccessor = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(afterSuccessor, 0)
            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 30)
            XCTAssertEqual(delivered, 0)
        }

        func testProvenSameLaunchSuccessorWithFreshTokenCancelsTheWatch() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, connectionID, reason: "peer_eof")

            // A replacement helper spawned by the same agent process instance, with a new token.
            table.set(helperPID, .absent)
            table.spawn(5100, parent: agentPID, start: 510)
            await registerHelperConnection(on: manager, runID: runID, helperPID: 5100)
            let afterSuccessor = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(afterSuccessor, 0)
            let delivered = await advanceAndTick(manager, seconds: 30)
            XCTAssertEqual(delivered, 0)
        }

        /// A successor routed before its admission snapshot exists is caught by the re-check that
        /// runs before every emission.
        func testSuccessorProvenAfterItsRouteIsCaughtBeforeEmission() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, connectionID, reason: "peer_eof")

            table.set(helperPID, .absent)
            table.spawn(5100, parent: agentPID, start: 510)
            let successorID = UUID()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: successorID,
                connection: FixtureConnection(),
                clientName: "claude-code",
                sessionToken: "ws5-late-snapshot-\(UUID().uuidString)"
            )
            await manager.debugSeedConnectionRunRouting(connectionID: successorID, runID: runID, purpose: .agentModeRun)
            let stillOpen = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(stillOpen, 1, "not provable without a snapshot")
            await manager.debugSetBootstrapPeerPID(connectionID: successorID, pid: 5100)

            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 0)
            let remaining = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(remaining, 0)
        }

        /// An accepted but unrouted successor never cancels the watch. When it matches the observed
        /// helper (same session token, or the same agent instance in its ancestry), its admission
        /// may still restore the route, so an exited helper is reported only at the 20 s route
        /// deadline instead of after the 2 s grace (B-P2-4). An unrelated unrouted accept changes
        /// nothing.
        func testUnroutedAcceptNeverCancelsAndAMatchingOneExtendsAnExitedHelperToTheRouteDeadline() async {
            enum Successor: String, CaseIterable {
                case sameToken, sameAgentFreshToken, otherAgent
            }
            for successor in Successor.allCases {
                let label = successor.rawValue
                let table = makeTable()
                let manager = await makeManager(table: table)
                let runID = UUID()
                let recorder = LossRecorder()
                await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
                let token = "ws5-unrouted-\(UUID().uuidString)"
                let connectionID = await registerHelperConnection(
                    on: manager, runID: runID, helperPID: helperPID, sessionToken: token
                )
                await close(manager, connectionID, reason: "peer_eof")

                // Accepted but never routed to the run.
                switch successor {
                case .sameToken:
                    table.spawn(5100, parent: otherAgentPID, start: 510)
                    await registerHelperConnection(on: manager, runID: runID, helperPID: 5100, sessionToken: token, route: false)
                case .sameAgentFreshToken:
                    table.spawn(5100, parent: agentPID, start: 510)
                    await registerHelperConnection(on: manager, runID: runID, helperPID: 5100, route: false)
                case .otherAgent:
                    table.spawn(5100, parent: otherAgentPID, start: 510)
                    await registerHelperConnection(on: manager, runID: runID, helperPID: 5100, route: false)
                }
                let stillOpen = await manager.debugHelperExitObservationCount()
                XCTAssertEqual(stillOpen, 1, label)

                table.set(helperPID, .absent)
                let afterGrace = await advanceAndTick(manager, seconds: 2)
                if successor == .otherAgent {
                    XCTAssertEqual(afterGrace, 1, "\(label): an unrelated accept does not extend the grace")
                } else {
                    XCTAssertEqual(afterGrace, 0, "\(label): a matching unrouted accept extends the wait")
                    let beforeDeadline = await advanceAndTick(manager, seconds: 17)
                    XCTAssertEqual(beforeDeadline, 0, label)
                    let atDeadline = await advanceAndTick(manager, seconds: 1)
                    XCTAssertEqual(atDeadline, 1, "\(label): reported at the route deadline")
                }
                await recorder.waitForCount(1)
                let reasons = await recorder.losses.map(\.reason)
                XCTAssertEqual(reasons, [.helperExited], label)
            }
        }

        func testDifferentLaunchSuccessorDoesNotCancelTheWatch() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, connectionID, reason: "peer_eof")

            // Another agent's helper, and a helper whose parent reuses the agent PID with a
            // different start time: neither is the same launch.
            table.spawn(6000, parent: otherAgentPID, start: 600)
            await registerHelperConnection(on: manager, runID: runID, helperPID: 6000)
            table.spawn(agentPID, parent: shellPID, start: agentStart + 99)
            table.spawn(7100, parent: agentPID, start: 710)
            await registerHelperConnection(on: manager, runID: runID, helperPID: 7100)
            let stillOpen = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(stillOpen, 1)

            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 1)
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.connectionID, connectionID)
            XCTAssertEqual(loss.reason, .helperExited)
        }

        // MARK: - Unregistration and lifecycle

        func testPartialUnregisterNarrowsAddresseesAndFullUnregisterCancels() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let keptRecorder = LossRecorder()
            let removedRecorder = LossRecorder()
            let keptLaunch = launch(agentPID)
            let removedToken = await observe(manager, runID: runID, launch: launch(agentPID), recorder: removedRecorder)
            let keptToken = await observe(manager, runID: runID, launch: keptLaunch, recorder: keptRecorder)

            let first = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, first, reason: "peer_eof")
            await manager.unregisterRunConnectionLossObserver(for: runID, token: removedToken)
            let addressees = await manager.debugHelperExitObservationAddresseeTokens(connectionID: first)
            XCTAssertEqual(addressees, [keptLaunch.token])
            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 1)
            await keptRecorder.waitForCount(1)
            let removedLosses = await removedRecorder.losses
            XCTAssertTrue(removedLosses.isEmpty)

            table.spawn(5100, parent: agentPID, start: 510)
            let second = await registerHelperConnection(on: manager, runID: runID, helperPID: 5100)
            await close(manager, second, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(opened, 1)
            await manager.unregisterRunConnectionLossObserver(for: runID, token: keptToken)
            let afterFull = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(afterFull, 0)
        }

        func testPollerRunsOnlyWhileObservationsExistAndManagerStopCancelsIt() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            await manager.debugSetHelperExitWatchManualTicks(false)
            await manager.debugSetHelperExitWatchTickNanoseconds(3_600_000_000_000)
            let runID = UUID()
            let observerToken = await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let idle = await manager.debugHelperExitWatchPollingActive
            XCTAssertFalse(idle)

            let first = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, first, reason: "peer_eof")
            let pollingWithObservation = await manager.debugHelperExitWatchPollingActive
            XCTAssertTrue(pollingWithObservation)
            await manager.unregisterRunConnectionLossObserver(for: runID, token: observerToken)
            let drained = await manager.debugHelperExitWatchPollingActive
            XCTAssertFalse(drained, "the poller stops when no observation remains")

            await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let second = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, second, reason: "peer_eof")
            let pollingAgain = await manager.debugHelperExitWatchPollingActive
            XCTAssertTrue(pollingAgain)
            await manager.stop()
            let afterStop = await manager.debugHelperExitWatchPollingActive
            XCTAssertFalse(afterStop)
            let remaining = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(remaining, 0)
        }

        /// Delivery is detached: a blocked observer neither blocks the tick nor another observer.
        func testDeliveryIsDetachedFromABlockingObserver() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let gate = ObserverGate()
            // Never leave the detached observer blocked past the test, whatever fails first.
            addTeardownBlock { await gate.release() }
            let blockedRecorder = LossRecorder()
            let recorder = LossRecorder()
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: launch(agentPID)) { loss in
                await gate.arriveAndWait()
                await blockedRecorder.record(loss)
            }
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, connectionID, reason: "peer_eof")

            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 2, "the tick returned while one observer is blocked")
            await recorder.waitForCount(1)
            let blockedBeforeRelease = await blockedRecorder.losses
            XCTAssertTrue(blockedBeforeRelease.isEmpty)
            await gate.release()
            await blockedRecorder.waitForCount(1)
        }

        /// B-P2-3: a poller tick from an invalidated lifecycle cancels every observation and stops
        /// the poller; a current tick keeps it running.
        func testPollerTickFromAStaleLifecycleCancelsTheWatch() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            await manager.debugSetHelperExitWatchManualTicks(false)
            await manager.debugSetHelperExitWatchTickNanoseconds(3_600_000_000_000)
            let runID = UUID()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, connectionID, reason: "peer_eof")
            let polling = await manager.debugHelperExitWatchPollingActive
            XCTAssertTrue(polling)

            let current = await manager.debugRunHelperExitWatchPollerTick(staleLifecycle: false)
            XCTAssertEqual(current, true, "a current-lifecycle tick keeps polling")
            let stillOpen = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(stillOpen, 1)

            let stale = await manager.debugRunHelperExitWatchPollerTick(staleLifecycle: true)
            XCTAssertEqual(stale, false, "a stale-lifecycle tick stops the poller")
            let remaining = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(remaining, 0)
            let afterStale = await manager.debugHelperExitWatchPollingActive
            XCTAssertFalse(afterStale)
            let noPoller = await manager.debugRunHelperExitWatchPollerTick(staleLifecycle: false)
            XCTAssertNil(noPoller)
        }

        // MARK: - Agent process identity (PID reuse)

        /// A-P1-1 regression: the old agent exited and its PID was reused before the replacement
        /// launch's observer registered and before the old helper connection closed. The
        /// replacement's agent identity (PID plus start time, read at registration) is not the one
        /// in the old helper's admission ancestry, so it is not addressed by the helper-exit watch
        /// and the watchdog does not prove its ownership.
        func testAgentPIDReusedBeforeTheReplacementRegistersProvesNothing() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let oldToken = await observe(manager, runID: runID, launch: launch(agentPID), recorder: LossRecorder())
            let closing = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            table.spawn(5200, parent: agentPID, start: 520)
            let aborting = await registerHelperConnection(on: manager, runID: runID, helperPID: 5200)

            // The old agent exits; its observer unregisters; the PID is reused by the replacement.
            await manager.unregisterRunConnectionLossObserver(for: runID, token: oldToken)
            table.spawn(agentPID, parent: shellPID, start: 900)
            let recorder = LossRecorder()
            let replacement = launch(agentPID)
            await observe(manager, runID: runID, launch: replacement, recorder: recorder)

            await close(manager, closing, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(opened, 0, "no launch is proven, so no watch opens")
            table.set(helperPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 60)
            XCTAssertEqual(delivered, 0)

            // The watchdog still reports the loss, but unproven: the controller ignores it as a
            // connection that predates the launch.
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: aborting, toolName: "slow_tool")
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            XCTAssertEqual(losses.map(\.reason), [.toolExecutionWatchdog])
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.connectionID, aborting)
            XCTAssertNil(loss.agentProcessID, "a recycled agent PID is no proof")
            XCTAssertTrue(loss.connectionPredatesLaunch)
            XCTAssertFalse(loss.provesOwnership(by: replacement))
        }

        /// The same agent process instance still proves ownership when the identity is readable at
        /// registration; when it is unreadable, the watchdog falls back to the PID alone and the
        /// helper-exit watch addresses nobody.
        func testUnreadableAgentIdentityFallsBackToPIDForTheWatchdogOnly() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            table.set(agentPID, .unreadable)
            let recorder = LossRecorder()
            let unreadable = launch(agentPID)
            await observe(manager, runID: runID, launch: unreadable, recorder: recorder)
            table.spawn(agentPID, parent: shellPID, start: agentStart)

            let closing = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await close(manager, closing, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(opened, 0, "helper-exit never addresses a launch without an agent identity")

            let aborting = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: aborting, toolName: "slow_tool")
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.agentProcessID, agentPID, "PID-only fallback")
            XCTAssertTrue(loss.provesOwnership(by: unreadable))
        }

        // MARK: - Production readmission (B-P1-1)

        /// The same-token helper readmitted after a transient drop goes through production
        /// `applyPendingPolicyIfAvailable`: with its one-shot policy consumed it takes the live-run
        /// affinity fallback, which restores the run route through `assignRunRoute` during the
        /// handshake and so cancels the helper-exit watch before any loss.
        func testProductionSameTokenReadmissionRestoresTheRouteAndCancelsTheWatch() async {
            let table = makeTable()
            await assertSameTokenReadmissionCancelsTheWatch(
                table: table,
                policyClient: AgentProviderKind.openCodeMCPClientID,
                keepExpectedAgentPID: false,
                helperPeerPID: helperPID
            )
        }

        /// The Claude variant: the Claude MCP client ID, the run's expected agent PID registered
        /// across the reconnect (as the Claude runner leaves it), and a helper peer PID equal to the
        /// admitted `clientPid`, which the fake table places under the observed agent.
        func testProductionSameTokenReadmissionForTheClaudeClientKeepingTheExpectedAgentPID() async {
            let table = makeTable()
            let ownPID = getpid()
            let fixturePIDs: Set<pid_t> = [shellPID, agentPID, otherAgentPID, helperPID]
            let helperPeerPID = fixturePIDs.contains(ownPID) ? helperPID : ownPID
            table.spawn(helperPeerPID, parent: agentPID, start: 500)
            await assertSameTokenReadmissionCancelsTheWatch(
                table: table,
                policyClient: AgentProviderKind.claudeMCPClientID,
                keepExpectedAgentPID: true,
                helperPeerPID: helperPeerPID
            )
        }

        private func assertSameTokenReadmissionCancelsTheWatch(
            table: FakeProcessTable,
            policyClient: String,
            keepExpectedAgentPID: Bool,
            helperPeerPID: pid_t,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let manager = await makeManager(table: table)
            let runID = UUID()
            let windowID = 61501
            let token = "ws5-readmission-\(UUID().uuidString)"
            await manager.installClientConnectionPolicy(
                for: policyClient,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "WS5 helper readmission test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)

            func admit(_ connectionID: UUID) async -> String {
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: FixtureConnection(),
                    clientName: policyClient,
                    sessionToken: token
                )
                await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: helperPeerPID)
                return await manager.debugApplyPendingPolicy(
                    clientName: policyClient,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: token,
                    pidGateTimeout: 0.25,
                    requireRunRouting: false
                ).outcome
            }

            await manager.registerExpectedAgentPID(getpid(), for: policyClient, runID: runID)
            let first = UUID()
            let firstOutcome = await admit(first)
            XCTAssertEqual(firstOutcome, "applied", file: file, line: line)
            if !keepExpectedAgentPID {
                await manager.clearExpectedAgentPID(getpid(), for: policyClient, runID: runID)
            }
            let firstRoute = await manager.runIDForConnection(first)
            XCTAssertEqual(firstRoute, runID, file: file, line: line)

            await close(manager, first, reason: TerminationReason.idleTimeout.rawValue)
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 1, file: file, line: line)

            let second = UUID()
            let secondOutcome = await admit(second)
            XCTAssertEqual(
                secondOutcome, "fallback", "no consumable policy: the live affinity routes it",
                file: file, line: line
            )
            let restored = await manager.runIDForConnection(second)
            XCTAssertEqual(restored, runID, file: file, line: line)
            let afterReadmission = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(afterReadmission, 0, "the restored route cancelled the watch", file: file, line: line)
            let delivered = await advanceAndTick(manager, seconds: 60)
            XCTAssertEqual(delivered, 0, file: file, line: line)
            let losses = await recorder.losses
            XCTAssertTrue(losses.isEmpty, file: file, line: line)

            if keepExpectedAgentPID {
                await manager.clearExpectedAgentPID(getpid(), for: policyClient, runID: runID)
            }
            await manager.clearClientConnectionPolicy(for: policyClient, windowID: windowID, runID: runID)
            await manager.removeConnection(second)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

        // MARK: - Production bootstrap registration (B-P2-1)

        /// The production bootstrap admission (`makeAcceptedBootstrapAdmission` → `postAccept` →
        /// `commitAcceptedBootstrapConnection` → `registerAndStartBootstrapConnection`) records the
        /// connection's lifecycle generation and the helper's admission snapshot, so a routed,
        /// observed helper connection opens a watch and reports its helper's exit. No listener is
        /// started; the accepted descriptor is one end of a socketpair.
        func testProductionBootstrapRegistrationRecordsTheGenerationAndOpensAWatch() async throws {
            let table = makeTable()
            let ownPID = getpid()
            let fixturePIDs: Set<pid_t> = [shellPID, agentPID, otherAgentPID, helperPID]
            XCTAssertFalse(fixturePIDs.contains(ownPID), "the test process PID must not collide with a fixture PID")
            table.spawn(ownPID, parent: agentPID, start: 500)
            let manager = await makeManager(table: table)
            // Without a handler the started server removes the connection at once
            // (`connection_approval_handler_unavailable`); approval itself waits for the silent peer.
            await manager.setConnectionApprovalHandler { _, _ in true }
            await manager.debugEnterRunningStateWithoutListenersForTesting()

            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)

            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            defer { if descriptors[1] >= 0 { Darwin.close(descriptors[1]) } }
            let connectionID = UUID()
            let optionalAdmission = await manager.debugMakeReservedBootstrapAdmissionForShutdownTest(
                connectionID: connectionID,
                sessionToken: "ws5-bootstrap-\(UUID().uuidString)",
                clientPid: Int(ownPID),
                clientName: AgentProviderKind.claudeMCPClientID,
                clientFD: descriptors[0]
            )
            let admission = try XCTUnwrap(optionalAdmission)
            await admission.postAccept?()

            let registered = await manager.debugContainsConnection(connectionID)
            XCTAssertTrue(registered, "postAccept registered the connection")
            let state = await manager.debugDirectAdmissionStateForTesting(connectionID: connectionID)
            XCTAssertNotNil(state.connectionLifecycleGeneration)
            XCTAssertEqual(state.connectionLifecycleGeneration, state.lifecycleGeneration)
            let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
            XCTAssertEqual(snapshot?.peer.pid, ownPID)
            XCTAssertEqual(snapshot?.ancestorPIDs, [agentPID, shellPID])

            await manager.debugSeedConnectionRunRouting(connectionID: connectionID, runID: runID, purpose: .agentModeRun)
            let stillRegistered = await manager.debugContainsConnection(connectionID)
            XCTAssertTrue(stillRegistered, "the connection is still live when the peer closes")
            await close(manager, connectionID, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 1, "the production-registered connection passes the generation guard")
            let rejections = await manager.debugHelperExitGenerationGuardRejectionCount
            XCTAssertEqual(rejections, 0)

            table.set(ownPID, .absent)
            let delivered = await advanceAndTick(manager, seconds: 2)
            XCTAssertEqual(delivered, 1)
            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .helperExited)
            XCTAssertEqual(loss.connectionID, connectionID)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
        }

        /// A routed, observed connection whose recorded generation is missing is not watched, and
        /// the rejection is counted (and logged as a warning) rather than silent. A connection the
        /// watch would not cover anyway (no run route) is not counted.
        func testGenerationGuardRejectionOfARoutedObservedConnectionIsRecorded() async {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)

            let unrouted = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, route: false)
            await manager.debugForgetConnectionLifecycleGeneration(unrouted)
            await close(manager, unrouted, reason: "peer_eof")
            let unroutedRejections = await manager.debugHelperExitGenerationGuardRejectionCount
            XCTAssertEqual(unroutedRejections, 0, "an unrouted connection is never watched; nothing to report")

            let routed = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            await manager.debugForgetConnectionLifecycleGeneration(routed)
            await close(manager, routed, reason: "peer_eof")
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 0)
            let rejections = await manager.debugHelperExitGenerationGuardRejectionCount
            XCTAssertEqual(rejections, 1)
        }

        // MARK: - Watchdog ownership from the admission snapshot

        /// Regression: the helper was reparented (its agent's process entry is gone) before the
        /// watchdog abort; the admission snapshot still proves the agent PID.
        func testWatchdogProvesOwnershipFromTheSnapshotForAReparentedHelper() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)
            let connectionID = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: connectionID)
            XCTAssertEqual(snapshot?.ancestorPIDs, [agentPID, shellPID])

            table.spawn(helperPID, parent: 1, start: 500)
            table.set(agentPID, .absent)
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: connectionID, toolName: "slow_tool")
            await recorder.waitForCount(1)

            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .toolExecutionWatchdog)
            XCTAssertEqual(loss.closeReason, "tool_execution_watchdog")
            XCTAssertEqual(loss.toolName, "slow_tool")
            XCTAssertEqual(loss.agentProcessID, agentPID)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
        }

        // MARK: - DEBUG diagnostics ops (live-acceptance fault injection)

        private func diagnostics(
            _ manager: ServerNetworkManager,
            caller: UUID,
            _ arguments: [String: Value],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> (payload: [String: Any], isError: Bool) {
            let result = await manager.handleDebugDiagnosticsTool(connectionID: caller, arguments: arguments)
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
                file: file,
                line: line
            )
            return (payload, result.isError ?? false)
        }

        private func assertInvalidParams(
            _ manager: ServerNetworkManager,
            caller: UUID,
            _ arguments: [String: Value],
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let (payload, isError) = try await diagnostics(manager, caller: caller, arguments, file: file, line: line)
            XCTAssertTrue(isError, label, file: file, line: line)
            XCTAssertEqual(payload["ok"] as? Bool, false, label, file: file, line: line)
            XCTAssertEqual(payload["code"] as? String, "invalid_params", label, file: file, line: line)
        }

        func testDebugFaultInjectionOpsRequireAllowDestructiveAndANonCallerTarget() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let caller = UUID()
            let target = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            let targetString = Value.string(target.uuidString)

            for op in ["force_execution_watchdog_abort", "soft_disconnect_connection"] {
                try await assertInvalidParams(
                    manager, caller: caller,
                    ["op": .string(op), "connection_id": targetString],
                    "\(op): missing allow_destructive"
                )
                try await assertInvalidParams(
                    manager, caller: caller,
                    ["op": .string(op), "allow_destructive": .bool(false), "connection_id": targetString],
                    "\(op): allow_destructive=false"
                )
                try await assertInvalidParams(
                    manager, caller: caller,
                    ["op": .string(op), "allow_destructive": .bool(true), "connection_id": .string("not-a-uuid")],
                    "\(op): malformed connection_id"
                )
                try await assertInvalidParams(
                    manager, caller: caller,
                    ["op": .string(op), "allow_destructive": .bool(true)],
                    "\(op): missing connection_id"
                )
                try await assertInvalidParams(
                    manager, caller: target,
                    ["op": .string(op), "allow_destructive": .bool(true), "connection_id": targetString],
                    "\(op): the calling connection"
                )
            }
            try await assertInvalidParams(
                manager, caller: caller,
                [
                    "op": .string("force_execution_watchdog_abort"), "allow_destructive": .bool(true),
                    "connection_id": targetString, "run_id": .string("nope")
                ],
                "watchdog: malformed run_id"
            )
            try await assertInvalidParams(
                manager, caller: caller,
                [
                    "op": .string("soft_disconnect_connection"), "allow_destructive": .bool(true),
                    "connection_id": targetString, "reason": .string("not_a_reason")
                ],
                "soft disconnect: unknown reason"
            )

            // No guard failure touched the target.
            let stillRegistered = await manager.debugConnectionIsRegistered(connectionID: target)
            XCTAssertTrue(stillRegistered)
            let terminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: target)
            XCTAssertFalse(terminal)
        }

        func testDebugForceExecutionWatchdogAbortDrivesTheProductionLoss() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            let owningLaunch = launch(agentPID)
            await observe(manager, runID: runID, launch: owningLaunch, recorder: recorder)
            let target = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)

            let (payload, isError) = try await diagnostics(manager, caller: UUID(), [
                "op": .string("force_execution_watchdog_abort"),
                "allow_destructive": .bool(true),
                "connection_id": .string(target.uuidString)
            ])
            XCTAssertFalse(isError)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["connection_id"] as? String, target.uuidString)
            XCTAssertEqual(payload["tool_name"] as? String, "debug_forced_watchdog")
            XCTAssertEqual(payload["existed"] as? Bool, true)
            XCTAssertEqual(payload["already_terminal"] as? Bool, false)
            XCTAssertEqual(payload["aborted"] as? Bool, true)
            XCTAssertEqual(payload["helper_peer_pid"] as? Int, Int(helperPID))

            await recorder.waitForCount(1)
            let losses = await recorder.losses
            let loss = try XCTUnwrap(losses.first)
            XCTAssertEqual(loss.reason, .toolExecutionWatchdog)
            XCTAssertEqual(loss.toolName, "debug_forced_watchdog")
            XCTAssertEqual(loss.closeReason, "tool_execution_watchdog")
            XCTAssertEqual(loss.connectionID, target)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
            let watches = await manager.debugHelperExitObservationCount()
            XCTAssertEqual(watches, 0, "a watchdog terminal never opens a helper-exit watch")

            // An unknown target is reported, not aborted.
            let unknown = UUID()
            let (missing, missingIsError) = try await diagnostics(manager, caller: UUID(), [
                "op": .string("force_execution_watchdog_abort"),
                "allow_destructive": .bool(true),
                "connection_id": .string(unknown.uuidString)
            ])
            XCTAssertFalse(missingIsError)
            XCTAssertEqual(missing["existed"] as? Bool, false)
            XCTAssertEqual(missing["aborted"] as? Bool, false)
        }

        /// Negative control: a soft disconnect opens a watch, and the helper's same-token
        /// reconnect cancels it before any loss is reported.
        func testDebugSoftDisconnectOpensAWatchThatTheSameTokenReconnectCancels() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let recorder = LossRecorder()
            await observe(manager, runID: runID, launch: launch(agentPID), recorder: recorder)
            let sessionToken = "ws5-soft-\(UUID().uuidString)"
            let target = await registerHelperConnection(
                on: manager, runID: runID, helperPID: helperPID, sessionToken: sessionToken
            )

            let (payload, isError) = try await diagnostics(manager, caller: UUID(), [
                "op": .string("soft_disconnect_connection"),
                "allow_destructive": .bool(true),
                "connection_id": .string(target.uuidString)
            ])
            XCTAssertFalse(isError)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["reason"] as? String, TerminationReason.idleTimeout.rawValue)
            XCTAssertEqual(payload["existed"] as? Bool, true)
            XCTAssertEqual(payload["disconnected"] as? Bool, true)
            XCTAssertEqual(payload["helper_peer_pid"] as? Int, Int(helperPID))
            let opened = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(opened, 1)

            await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, sessionToken: sessionToken)
            let afterReconnect = await manager.debugHelperExitObservationCount(runID: runID)
            XCTAssertEqual(afterReconnect, 0)
            let delivered = await advanceAndTick(manager, seconds: 60)
            XCTAssertEqual(delivered, 0)
            let losses = await recorder.losses
            XCTAssertTrue(losses.isEmpty)
        }

        func testDebugConnectionsRowsCarryTheRunRouteAndHelperAncestry() async throws {
            let table = makeTable()
            let manager = await makeManager(table: table)
            let runID = UUID()
            let routed = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID)
            let unrouted = await registerHelperConnection(on: manager, runID: runID, helperPID: helperPID, route: false)

            let (payload, isError) = try await diagnostics(manager, caller: UUID(), ["op": .string("connections")])
            XCTAssertFalse(isError)
            let rows = try XCTUnwrap(payload["connections"] as? [[String: Any]])
            let routedRow = try XCTUnwrap(rows.first { $0["id"] as? String == routed.uuidString })
            XCTAssertEqual(routedRow["run_id"] as? String, runID.uuidString)
            XCTAssertEqual(routedRow["helper_peer_pid"] as? Int, Int(helperPID))
            let snapshot = await manager.debugHelperPeerProcessSnapshot(connectionID: routed)
            XCTAssertEqual(routedRow["helper_process_start"] as? String, snapshot?.peer.startDescription)
            XCTAssertNotNil(routedRow["helper_process_start"] as? String)
            XCTAssertEqual(routedRow["helper_ancestor_pids"] as? [Int], [Int(agentPID), Int(shellPID)])

            let unroutedRow = try XCTUnwrap(rows.first { $0["id"] as? String == unrouted.uuidString })
            XCTAssertTrue(unroutedRow["run_id"] is NSNull)
        }
    }
#endif
