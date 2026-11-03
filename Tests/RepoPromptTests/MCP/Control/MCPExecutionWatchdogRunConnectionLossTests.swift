import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptPlatform
import RepoPromptShared
import XCTest

#if DEBUG
    /// WS2: an execution-watchdog abort delivers one immutable run-connection-loss event per
    /// registered launch of the owning run, captured synchronously at the terminal commit (before
    /// the abort's first suspension), and never gating containment. Each event is addressed to its
    /// launch and carries that launch's ownership evidence. Uses a private manager instance and an
    /// in-memory fixture connection (no socket, no helper, no Claude process).
    final class MCPExecutionWatchdogRunConnectionLossTests: XCTestCase {
        private actor AbortRecordingConnection: MCPServerConnection {
            private(set) var abortCount = 0

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
            func abortForExecutionWatchdog() async {
                abortCount += 1
            }

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

        private actor LossRecorder {
            private(set) var losses: [AgentMCPRunConnectionLoss] = []
            private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

            func record(_ loss: AgentMCPRunConnectionLoss) {
                losses.append(loss)
                let ready = waiters.filter { $0.count <= losses.count }
                waiters.removeAll { $0.count <= losses.count }
                ready.forEach { $0.continuation.resume() }
            }

            func waitForCount(_ count: Int) async {
                guard losses.count < count else { return }
                await withCheckedContinuation { waiters.append((count: count, continuation: $0)) }
            }
        }

        /// Blocks every observer call until released.
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

        /// A private manager whose accepted-socket terminal records go to a temporary directory.
        private func makeManager() async -> ServerNetworkManager {
            let manager = ServerNetworkManager()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws2-loss-terminal-records-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            await manager.debugSetTerminalRecordsDirectoryOverride(directory)
            return manager
        }

        private func launch(_ agentProcessID: pid_t = pid_t.max) -> AgentMCPRunLaunchIdentity {
            AgentMCPRunLaunchIdentity(token: UUID(), agentProcessID: agentProcessID)
        }

        private func registerFixture(
            on manager: ServerNetworkManager,
            runID: UUID
        ) async -> (UUID, AbortRecordingConnection) {
            let connectionID = UUID()
            let connection = AbortRecordingConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: "claude-code",
                sessionToken: "ws2-loss-\(connectionID.uuidString)"
            )
            await manager.debugSeedConnectionRunRouting(connectionID: connectionID, runID: runID, purpose: .agentModeRun)
            return (connectionID, connection)
        }

        func testWatchdogAbortDeliversOneEventToOwningRunOnlyAndNeverWaitsForObservers() async throws {
            let manager = await makeManager()
            let owningRunID = UUID()
            let otherRunID = UUID()
            let owningRecorder = LossRecorder()
            let otherRecorder = LossRecorder()
            let slowGate = ObserverGate()
            // The helper peer is this test process; its parent stands in for the Claude agent.
            let agentPID = getppid()
            let owningLaunch = launch(agentPID)
            _ = await manager.registerRunConnectionLossObserver(for: owningRunID, launch: owningLaunch) { loss in
                await slowGate.arriveAndWait()
                await owningRecorder.record(loss)
            }
            _ = await manager.registerRunConnectionLossObserver(for: otherRunID, launch: launch()) { loss in
                await otherRecorder.record(loss)
            }
            await manager.registerExpectedAgentPID(agentPID, for: "claude-code", runID: owningRunID)
            let (connectionID, connection) = await registerFixture(on: manager, runID: owningRunID)
            await manager.debugSetBootstrapPeerPID(connectionID: connectionID, pid: getpid())

            await manager.debugAbortConnectionForExecutionWatchdog(
                connectionID: connectionID,
                toolName: "slow_tool"
            )

            // The abort completed while the owning observer is still blocked.
            let abortsBeforeRelease = await connection.abortCount
            XCTAssertEqual(abortsBeforeRelease, 1)
            let terminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: connectionID)
            XCTAssertTrue(terminal)

            // A duplicate watchdog firing for the same connection delivers nothing further.
            await manager.debugAbortConnectionForExecutionWatchdog(
                connectionID: connectionID,
                toolName: "slow_tool"
            )
            let abortsAfterDuplicate = await connection.abortCount
            XCTAssertEqual(abortsAfterDuplicate, 1)

            await slowGate.release()
            await owningRecorder.waitForCount(1)
            // A marker loss for the other run proves its observer was reachable and saw nothing else.
            let (markerConnectionID, _) = await registerFixture(on: manager, runID: otherRunID)
            await manager.debugAbortConnectionForExecutionWatchdog(
                connectionID: markerConnectionID,
                toolName: "marker_tool"
            )
            await otherRecorder.waitForCount(1)

            let owningLosses = await owningRecorder.losses
            XCTAssertEqual(owningLosses.count, 1)
            let loss = try XCTUnwrap(owningLosses.first)
            XCTAssertEqual(loss.runID, owningRunID)
            XCTAssertEqual(loss.connectionID, connectionID)
            XCTAssertEqual(loss.toolName, "slow_tool")
            XCTAssertEqual(loss.reason, .toolExecutionWatchdog)
            XCTAssertEqual(loss.closeReason, "tool_execution_watchdog")
            XCTAssertEqual(loss.agentProcessID, agentPID)
            XCTAssertEqual(loss.launchToken, owningLaunch.token)
            XCTAssertFalse(loss.connectionPredatesLaunch)
            XCTAssertTrue(loss.provesOwnership(by: owningLaunch))
            let otherLosses = await otherRecorder.losses
            XCTAssertEqual(otherLosses.map(\.connectionID), [markerConnectionID])
            XCTAssertNil(otherLosses.first?.agentProcessID, "no proven agent PID for an unregistered run")
            let arrivals = await slowGate.arrivals
            XCTAssertEqual(arrivals, 1)
        }

        func testCallTimeRunIDRoutesLossWhenConnectionRoutingIsAbsent() async {
            let manager = await makeManager()
            let runID = UUID()
            let recorder = LossRecorder()
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: launch()) { await recorder.record($0) }
            let connectionID = UUID()
            let connection = AbortRecordingConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: "claude-code",
                sessionToken: "ws2-call-time-\(connectionID.uuidString)"
            )

            await manager.debugAbortConnectionForExecutionWatchdog(
                connectionID: connectionID,
                toolName: "slow_tool",
                callTimeRunID: runID
            )
            await recorder.waitForCount(1)

            let losses = await recorder.losses
            XCTAssertEqual(losses.map(\.runID), [runID])
            let aborts = await connection.abortCount
            XCTAssertEqual(aborts, 1)
        }

        func testUnregisteredObserverReceivesNothing() async {
            let manager = await makeManager()
            let runID = UUID()
            let removedRecorder = LossRecorder()
            let keptRecorder = LossRecorder()
            let removedToken = await manager.registerRunConnectionLossObserver(for: runID, launch: launch()) {
                await removedRecorder.record($0)
            }
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: launch()) {
                await keptRecorder.record($0)
            }
            await manager.unregisterRunConnectionLossObserver(for: runID, token: removedToken)
            let (connectionID, _) = await registerFixture(on: manager, runID: runID)

            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: connectionID, toolName: "slow_tool")
            await keptRecorder.waitForCount(1)

            let removedLosses = await removedRecorder.losses
            XCTAssertTrue(removedLosses.isEmpty)
        }

        /// Each registered launch gets its own addressed event: PID proof is computed against that
        /// launch's registered agent PID, and a connection admitted before a launch registered is
        /// flagged as predating it.
        func testLossIsAddressedPerLaunchWithThatLaunchsOwnershipEvidence() async throws {
            let manager = await makeManager()
            let runID = UUID()
            let earlierRecorder = LossRecorder()
            let successorRecorder = LossRecorder()
            let earlierLaunch = launch(getppid())
            let successorLaunch = launch(pid_t.max)
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: earlierLaunch) {
                await earlierRecorder.record($0)
            }
            let (earlierConnectionID, _) = await registerFixture(on: manager, runID: runID)
            await manager.debugSetBootstrapPeerPID(connectionID: earlierConnectionID, pid: getpid())
            _ = await manager.registerRunConnectionLossObserver(for: runID, launch: successorLaunch) {
                await successorRecorder.record($0)
            }
            let (laterConnectionID, _) = await registerFixture(on: manager, runID: runID)

            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: earlierConnectionID, toolName: "slow_tool")
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: laterConnectionID, toolName: "slow_tool")
            await earlierRecorder.waitForCount(2)
            await successorRecorder.waitForCount(2)

            let earlier = await earlierRecorder.losses
            let earlierOnOwn = try XCTUnwrap(earlier.first { $0.connectionID == earlierConnectionID })
            XCTAssertEqual(earlierOnOwn.launchToken, earlierLaunch.token)
            XCTAssertEqual(earlierOnOwn.agentProcessID, getppid(), "proven against the earlier launch's PID")
            XCTAssertFalse(earlierOnOwn.connectionPredatesLaunch)
            XCTAssertTrue(earlierOnOwn.provesOwnership(by: earlierLaunch))

            let successor = await successorRecorder.losses
            let successorOnEarlier = try XCTUnwrap(successor.first { $0.connectionID == earlierConnectionID })
            XCTAssertEqual(successorOnEarlier.launchToken, successorLaunch.token)
            XCTAssertNil(successorOnEarlier.agentProcessID, "the successor's PID is not the helper's ancestor")
            XCTAssertTrue(successorOnEarlier.connectionPredatesLaunch)
            XCTAssertFalse(successorOnEarlier.provesOwnership(by: successorLaunch))
            XCTAssertFalse(successorOnEarlier.provesOwnership(by: earlierLaunch), "addressed to another launch")
            let successorOnLater = try XCTUnwrap(successor.first { $0.connectionID == laterConnectionID })
            XCTAssertNil(successorOnLater.agentProcessID)
            XCTAssertFalse(successorOnLater.connectionPredatesLaunch)
            XCTAssertTrue(successorOnLater.provesOwnership(by: successorLaunch))
        }

        // MARK: - Manager → controller

        private func fixtureProcess() -> (SpawnedProcess, [Pipe]) {
            let pipes = [Pipe(), Pipe(), Pipe()]
            let process = SpawnedProcess(
                pid: pid_t.max,
                processGroupID: nil,
                stdin: pipes[0].fileHandleForWriting,
                stdinDescriptor: pipes[0].fileHandleForWriting.fileDescriptor,
                stdout: pipes[1].fileHandleForReading,
                stderr: pipes[2].fileHandleForReading
            )
            return (process, pipes)
        }

        private func waitForLossDecision(
            _ controller: ClaudeNativeProcessSessionController,
            connectionID: UUID,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> String? {
            for _ in 0 ..< 500 {
                if let decision = await controller.test_repoPromptMCPLossDecisions()
                    .first(where: { $0.connectionID == connectionID })?.decision
                {
                    return decision
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("No loss decision for \(connectionID)", file: file, line: line)
            return nil
        }

        /// The launch is replaced between the connection's admission and its abort, and an event
        /// built for the replaced launch arrives after the replacement; neither has a proven agent
        /// PID, and neither marks the successor launch unhealthy. A connection admitted after the
        /// successor registered still does (the real registration and delivery path).
        func testReplacedLaunchsUnprovenLossNeverMarksTheSuccessorUnhealthy() async throws {
            let manager = await makeManager()
            let runID = UUID()
            let controller = try ClaudeNativeProcessSessionController(
                runID: runID,
                tabID: UUID(),
                windowID: 1,
                workspacePath: nil,
                config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: .standard, permissionMode: nil),
                mcpHost: manager
            )
            let (firstProcess, firstPipes) = fixtureProcess()
            await controller.test_attachSpawnedProcess(firstProcess)
            await controller.test_registerExpectedAgentPID(firstProcess.pid)
            let registeredFirstLaunch = await controller.test_currentRunConnectionLossObserverLaunch()
            let firstLaunch = try XCTUnwrap(registeredFirstLaunch)
            let (oldConnectionID, _) = await registerFixture(on: manager, runID: runID)

            // Replace the launch (same placeholder PID, so only the token tells them apart).
            let (successorProcess, successorPipes) = fixtureProcess()
            await controller.test_attachSpawnedProcess(successorProcess)
            await controller.test_registerExpectedAgentPID(successorProcess.pid)
            let registeredSuccessorLaunch = await controller.test_currentRunConnectionLossObserverLaunch()
            let successorLaunch = try XCTUnwrap(registeredSuccessorLaunch)
            XCTAssertNotEqual(successorLaunch.token, firstLaunch.token)
            XCTAssertEqual(successorLaunch.agentProcessID, firstLaunch.agentProcessID)

            // An event built for the first launch and delivered after the replacement.
            let builtForFirstLaunch = AgentMCPRunConnectionLoss(
                runID: runID,
                connectionID: oldConnectionID,
                clientName: "claude-code",
                launchToken: firstLaunch.token,
                agentProcessID: nil,
                connectionPredatesLaunch: false,
                toolName: "slow_tool",
                reason: .toolExecutionWatchdog,
                closeReason: "tool_execution_watchdog"
            )
            await controller.noteRepoPromptMCPConnectionLost(builtForFirstLaunch)
            // The old connection aborted after the replacement: addressed to the successor, unproven.
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: oldConnectionID, toolName: "slow_tool")
            for _ in 0 ..< 500 {
                if await controller.test_repoPromptMCPLossDecisions().count >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let decisions = await controller.test_repoPromptMCPLossDecisions()
            XCTAssertEqual(decisions.map(\.decision), ["stale_launch", "unproven_predates_launch"])
            let healthAfterStale = await controller.currentRepoPromptMCPHealth
            XCTAssertEqual(healthAfterStale, .unknown)

            let (ownConnectionID, _) = await registerFixture(on: manager, runID: runID)
            await manager.debugAbortConnectionForExecutionWatchdog(connectionID: ownConnectionID, toolName: "slow_tool")
            let ownDecision = try await waitForLossDecision(controller, connectionID: ownConnectionID)
            XCTAssertEqual(ownDecision, "applied")
            let health = await controller.currentRepoPromptMCPHealth
            XCTAssertEqual(health, .unhealthy(reason: "tool_execution_watchdog"))

            await controller.test_detachFixtureTransport()
            _ = (firstPipes, successorPipes)
        }
    }
#endif
