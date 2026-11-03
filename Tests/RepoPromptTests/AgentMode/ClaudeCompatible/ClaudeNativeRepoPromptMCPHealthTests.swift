import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// WS2 launch-scoped RepoPrompt MCP health of the Claude native controller: a watchdog
/// connection loss for the owning run and launch marks it unhealthy exactly once, an unhealthy
/// launch never publishes RepoPrompt `connected`, refuses reuse before any write, and fresh
/// connected evidence comes only from a current launch. Fixture transports are pipes with no
/// child process.
final class ClaudeNativeRepoPromptMCPHealthTests: XCTestCase {
    private final class FixtureTransport: @unchecked Sendable {
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
        private let lock = NSLock()
        private var received = Data()
        let process: SpawnedProcess

        /// `pid` is a placeholder no process has; no signal is ever sent to it.
        init(pid: pid_t = pid_t.max) {
            process = SpawnedProcess(
                pid: pid,
                processGroupID: nil,
                stdin: stdinPipe.fileHandleForWriting,
                stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
            let descriptor = stdinPipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        var frames: [[String: Any]] {
            lock.withLock {
                let descriptor = stdinPipe.fileHandleForReading.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    guard count > 0 else { break }
                    received.append(contentsOf: buffer[0 ..< count])
                }
                return received.split(separator: 0x0A).compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                }
            }
        }

        var mcpStatusRequestIDs: [String] {
            frames.compactMap { frame in
                guard frame["type"] as? String == "control_request",
                      (frame["request"] as? [String: Any])?["subtype"] as? String == "mcp_status"
                else { return nil }
                return frame["request_id"] as? String
            }
        }
    }

    /// A minimal MCP host whose app-side live-route lookup can be held mid-flight, and which
    /// records the order of the launch registrations it receives.
    private actor GatedRouteMCPHost: AgentMCPHosting {
        private var routeIsLive: Bool
        private var routeGate: LifecycleAsyncGate?
        /// As the manager does: a lookup for a PID never registered as an expected agent fails closed.
        private let answersOnlyForRegisteredPIDs: Bool
        private var registeredPIDs: Set<pid_t> = []
        private(set) var routeLookupCount = 0
        private(set) var routeLookupRequiredAgentPIDs: [pid_t?] = []
        private(set) var calls: [String] = []

        init(routeIsLive: Bool, routeGate: LifecycleAsyncGate? = nil, answersOnlyForRegisteredPIDs: Bool = false) {
            self.routeIsLive = routeIsLive
            self.routeGate = routeGate
            self.answersOnlyForRegisteredPIDs = answersOnlyForRegisteredPIDs
        }

        func isRunning() -> Bool {
            true
        }

        func hasAuthoritativeLiveRunRoute(
            runID _: UUID,
            expectedClientName _: String,
            requiredAgentPID: pid_t?
        ) async -> Bool {
            routeLookupCount += 1
            routeLookupRequiredAgentPIDs.append(requiredAgentPID)
            if let routeGate {
                await routeGate.arriveAndWait()
            }
            if answersOnlyForRegisteredPIDs {
                return routeIsLive && requiredAgentPID.map { registeredPIDs.contains($0) } == true
            }
            return routeIsLive
        }

        func refreshRetainedRunPolicyForTurnStart(for _: String, runID _: UUID) {}

        func releasePendingRunPolicyForProvenRoute(
            for _: String,
            windowID _: Int,
            runID _: UUID,
            agentPID _: pid_t
        ) -> Bool {
            false
        }

        func waitForNewConnection(clientName _: String?, timeout _: TimeInterval) -> UUID? {
            nil
        }

        func registerExpectedAgentPID(
            _ pid: pid_t,
            for _: String,
            runID _: UUID?,
            expectedProcessExecutablePath _: String?,
            expectedProcessExecutableIdentity _: ExecutableFileIdentity?
        ) {
            calls.append("registerExpectedAgentPID")
            registeredPIDs.insert(pid)
        }

        func clearExpectedAgentPID(_ pid: pid_t, for _: String, runID _: UUID?) {
            calls.append("clearExpectedAgentPID:\(pid)")
            registeredPIDs.remove(pid)
        }

        var registeredExpectedAgentPIDs: Set<pid_t> {
            registeredPIDs
        }

        func requireExpectedAgentPIDForPendingPolicy(for _: String, runID _: UUID, windowID _: Int?) -> Bool {
            true
        }

        // swiftlint:disable:next function_parameter_count
        func installClientConnectionPolicy(
            for _: String,
            windowID _: Int,
            restrictedTools _: Set<String>,
            oneShot _: Bool,
            reason _: String?,
            ttl _: TimeInterval,
            tabID _: UUID?,
            runID _: UUID?,
            additionalTools _: Set<String>?,
            allowedToolsOverride _: Set<String>?,
            sessionProfile _: AgentSessionProfile,
            purpose _: MCPRunPurpose,
            taskLabelKind _: AgentModelCatalog.TaskLabelKind?,
            allowsAgentExternalControlTools _: Bool,
            requiresExpectedAgentPID _: Bool
        ) {}

        func clearClientConnectionPolicy(for _: String, windowID _: Int?, runID _: UUID?) {}

        func revokeClientConnectionPolicy(for _: String, windowID _: Int, runID _: UUID) {}

        func cleanupRunRoutingIfUnproven(for _: String, windowID _: Int, runID _: UUID) {}

        func registerToolEventObserver(
            for _: UUID,
            onCalled _: @escaping @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void,
            onCompleted _: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?,
            observationPolicy _: AgentToolTrackingObservationPolicy
        ) -> UUID {
            UUID()
        }

        func unregisterToolEventObserver(for _: UUID, token _: UUID) {}

        func unregisterToolObservers(for _: UUID) {}

        func registerRunConnectionLossObserver(
            for _: UUID,
            launch _: AgentMCPRunLaunchIdentity,
            observer _: @escaping @Sendable (AgentMCPRunConnectionLoss) async -> Void
        ) -> UUID {
            calls.append("registerRunConnectionLossObserver")
            return UUID()
        }

        func unregisterRunConnectionLossObserver(for _: UUID, token _: UUID) {
            calls.append("unregisterRunConnectionLossObserver")
        }

        #if DEBUG
            func debugRecordRunRoutingEvent(runID _: UUID, event _: String, connectionID _: UUID?, fields _: [String: String]) {}
        #endif
    }

    private let runID = UUID()
    private let repoPromptServerName = MCPIntegrationHelper.repoPromptMCPServerName

    private func makeController(mcpHost: (any AgentMCPHosting)? = nil) throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: runID,
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: .standard, permissionMode: nil),
            // A private manager by default: the production expected-PID and loss-observer
            // registrations of these fixtures never touch the shared server.
            mcpHost: mcpHost ?? ServerNetworkManager()
        )
    }

    /// Attaches the fixture as the current launch and runs the production expected-PID +
    /// loss-observer registration; returns the launch identity losses must be addressed to.
    @discardableResult
    private func attach(
        _ transport: FixtureTransport,
        to controller: ClaudeNativeProcessSessionController
    ) async throws -> AgentMCPRunLaunchIdentity {
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_registerExpectedAgentPID(transport.process.pid)
        let launch = await controller.test_currentRunConnectionLossObserverLaunch()
        let token = await controller.test_currentRepoPromptMCPLaunchToken()
        XCTAssertEqual(launch?.token, token)
        XCTAssertEqual(launch?.agentProcessID, transport.process.pid)
        return try XCTUnwrap(launch)
    }

    private enum LossProof {
        case provenAgentPID
        case agentPID(pid_t)
        case unproven(predatesLaunch: Bool)
    }

    private func loss(
        for launch: AgentMCPRunLaunchIdentity,
        runID: UUID? = nil,
        connectionID: UUID = UUID(),
        launchToken: UUID? = nil,
        proof: LossProof = .provenAgentPID,
        reason: AgentMCPRunConnectionLoss.Reason = .toolExecutionWatchdog,
        closeReason: String? = nil
    ) -> AgentMCPRunConnectionLoss {
        let agentProcessID: pid_t?
        let predatesLaunch: Bool
        switch proof {
        case .provenAgentPID:
            (agentProcessID, predatesLaunch) = (launch.agentProcessID, true)
        case let .agentPID(pid):
            (agentProcessID, predatesLaunch) = (pid, true)
        case let .unproven(predates):
            (agentProcessID, predatesLaunch) = (nil, predates)
        }
        return AgentMCPRunConnectionLoss(
            runID: runID ?? self.runID,
            connectionID: connectionID,
            clientName: "claude-code",
            launchToken: launchToken ?? launch.token,
            agentProcessID: agentProcessID,
            connectionPredatesLaunch: predatesLaunch,
            toolName: reason == .toolExecutionWatchdog ? "fixture_tool" : nil,
            reason: reason,
            closeReason: closeReason ?? (reason == .toolExecutionWatchdog ? "tool_execution_watchdog" : "peer_eof")
        )
    }

    /// Every controller event emitted so far, up to an in-band marker (FIFO, so complete).
    private func drainEvents(
        _ controller: ClaudeNativeProcessSessionController
    ) async -> [ClaudeNativeProcessSessionController.Event] {
        let stream = await controller.events
        let marker = UUID()
        // Through the protocol witness (as Agent Mode calls it); the concrete-type call site
        // resolves to the protocol extension's `nil` default instead.
        let runtime: any NativeAgentRuntimeControlling = controller
        let generation = await runtime.emitEventMarker(marker)
        XCTAssertNotNil(generation, "the events stream must be ready")
        let collector = EventCollector()
        let reachedMarker = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if case let .marker(id) = event, id == marker { return true }
                    await collector.append(event)
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let collected = await collector.events
        XCTAssertTrue(reachedMarker, "Events before the marker: \(collected)")
        return collected
    }

    private actor EventCollector {
        private(set) var events: [ClaudeNativeProcessSessionController.Event] = []
        func append(_ event: ClaudeNativeProcessSessionController.Event) {
            events.append(event)
        }
    }

    private func systemInit(repoPromptStatus: String) -> [String: Any] {
        [
            "type": "system",
            "subtype": "init",
            "session_id": "health-session",
            "tools": [],
            "mcp_servers": [["name": repoPromptServerName, "status": repoPromptStatus]]
        ]
    }

    private func respond(
        _ controller: ClaudeNativeProcessSessionController,
        requestID: String,
        subtype: String = "success",
        response: [String: Any] = [:],
        error: String? = nil
    ) async throws {
        var body: [String: Any] = ["subtype": subtype, "request_id": requestID, "response": response]
        if let error { body["error"] = error }
        let line = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": body])
        await controller.test_handleLine(line)
    }

    private func mcpStatusResponse(_ status: String) -> [String: Any] {
        ["mcpServers": [["name": repoPromptServerName, "status": status]]]
    }

    private func waitForMCPStatusRequests(
        _ transport: FixtureTransport,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        for _ in 0 ..< 500 {
            let ids = transport.mcpStatusRequestIDs
            if ids.count >= count { return ids }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) mcp_status requests", file: file, line: line)
        return transport.mcpStatusRequestIDs
    }

    // MARK: - Loss events

    func testWatchdogLossMarksOnlyTheOwningLaunchUnhealthyExactlyOnce() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        await controller.ensureEventsStreamReady()
        defer { Task { await controller.test_detachFixtureTransport() } }

        // Another run's loss, another launch's loss, a different proven agent PID, and an
        // unproven loss of a connection that predates this launch are all ignored.
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, runID: UUID()))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, launchToken: UUID()))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, proof: .agentPID(4242)))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, proof: .unproven(predatesLaunch: true)))
        let healthAfterForeign = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(healthAfterForeign, .unknown)
        let ignored = await controller.test_repoPromptMCPLossDecisions().map(\.decision)
        XCTAssertEqual(ignored, ["run_mismatch", "stale_launch", "agent_pid_mismatch", "unproven_predates_launch"])

        let connectionID = UUID()
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, connectionID: connectionID))
        // Duplicate delivery of the same connection, and a later loss, change nothing more.
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, connectionID: connectionID))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, proof: .unproven(predatesLaunch: false)))

        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unhealthy(reason: "tool_execution_watchdog"))
        let events = await drainEvents(controller)
        let errors = events.compactMap { event -> String? in
            if case let .error(message) = event { return message }
            return nil
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("fixture_tool") == true)
        let runtimeInits = events.compactMap { event -> ClaudeNativeProcessSessionController.RuntimeInitStatus? in
            if case let .runtimeInit(status) = event { return status }
            return nil
        }
        XCTAssertEqual(runtimeInits.count, 1)
        XCTAssertEqual(runtimeInits.last?.repoPromptMCPHealth, .unhealthy(reason: "tool_execution_watchdog"))
        XCTAssertTrue(transport.frames.isEmpty, "a loss event writes nothing to Claude")
    }

    /// WS5: a helper that exited, or never restored its route, marks the owning launch unhealthy
    /// like a watchdog loss, with reason-specific wording that describes the close in plain words
    /// (the raw close code is never shown), and the published RepoPrompt status is `disconnected`
    /// (never the terminal `failed`).
    func testHelperExitReasonsMarkTheLaunchUnhealthyWithReasonSpecificWording() async throws {
        let cases: [(AgentMCPRunConnectionLoss.Reason, String, String)] = [
            (.helperExited, "peer_eof", "RepoPrompt MCP disconnected from Claude: the RepoPrompt MCP helper process exited."),
            (
                .helperExited,
                "idle_timeout",
                "RepoPrompt closed the idle connection, and the RepoPrompt MCP helper process exited."
            ),
            (
                .helperExited,
                "user_boot_from_dashboard",
                "RepoPrompt disconnected it from the dashboard, and the RepoPrompt MCP helper process exited."
            ),
            (
                .routeNotRestored,
                "peer_eof",
                "the RepoPrompt MCP helper lost its connection to RepoPrompt, and the helper has not reconnected."
            ),
            (.routeNotRestored, "idle_timeout", "RepoPrompt closed the idle connection, and the helper has not reconnected.")
        ]
        for (reason, closeReason, expectedFragment) in cases {
            let controller = try makeController()
            let transport = FixtureTransport()
            let launch = try await attach(transport, to: controller)
            await controller.ensureEventsStreamReady()
            await controller.test_handleStreamPayload(systemInit(repoPromptStatus: "connected"))

            let helperLoss = loss(for: launch, reason: reason, closeReason: closeReason)
            XCTAssertNil(helperLoss.toolName)
            await controller.noteRepoPromptMCPConnectionLost(helperLoss)

            let health = await controller.currentRepoPromptMCPHealth
            XCTAssertEqual(health, .unhealthy(reason: reason.rawValue), "\(reason) \(closeReason)")
            let events = await drainEvents(controller)
            let errors = events.compactMap { event -> String? in
                if case let .error(message) = event { return message }
                return nil
            }
            XCTAssertEqual(errors.count, 1, "\(reason)")
            let message = try XCTUnwrap(errors.first)
            XCTAssertEqual(message, ClaudeNativeProcessSessionController.repoPromptMCPDisconnectedMessage(for: helperLoss))
            XCTAssertTrue(message.contains(expectedFragment), message)
            XCTAssertFalse(message.contains(closeReason), "the raw close code stays in the log payload: \(message)")
            XCTAssertTrue(message.contains("Claude restarts and resumes this conversation"), message)
            let latest = try XCTUnwrap(events.compactMap { event -> ClaudeNativeProcessSessionController.RuntimeInitStatus? in
                if case let .runtimeInit(status) = event { return status }
                return nil
            }.last)
            XCTAssertEqual(latest.mcpServerStatuses[repoPromptServerName], "disconnected", "\(reason)")
            XCTAssertEqual(latest.repoPromptMCPHealth, .unhealthy(reason: reason.rawValue))
            XCTAssertTrue(transport.frames.isEmpty, "a loss event writes nothing to Claude")
            await controller.test_detachFixtureTransport()
        }
    }

    /// `handleStdoutEOF` retires the launch's stdout generation before its awaited tail while
    /// `process` is still set: a loss arriving in that window is ignored.
    func testLossAfterStdoutRetirementIsIgnored() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        defer { Task { await controller.test_detachFixtureTransport() } }

        await controller.test_retireActiveStdoutLaunchForCurrentLaunch()
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, reason: .helperExited))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch))

        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unknown)
        let decisions = await controller.test_repoPromptMCPLossDecisions().map(\.decision)
        XCTAssertEqual(decisions, ["stdout_retired", "stdout_retired"])
    }

    /// The same connection reported under two reasons applies once; another connection's loss
    /// after that is `already_unhealthy`.
    func testDuplicateLossAcrossReasonsIsIgnored() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        await controller.ensureEventsStreamReady()
        defer { Task { await controller.test_detachFixtureTransport() } }

        let connectionID = UUID()
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, connectionID: connectionID, reason: .helperExited))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, connectionID: connectionID, reason: .routeNotRestored))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, connectionID: connectionID))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, reason: .routeNotRestored))

        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unhealthy(reason: "helper_exited"))
        let decisions = await controller.test_repoPromptMCPLossDecisions().map(\.decision)
        XCTAssertEqual(decisions, ["applied", "duplicate", "duplicate", "already_unhealthy"])
        let errors = await drainEvents(controller).filter { event in
            if case .error = event { return true }
            return false
        }
        XCTAssertEqual(errors.count, 1)
    }

    func testLossWithoutCurrentLaunchIsIgnored() async throws {
        let controller = try makeController()
        let unregistered = AgentMCPRunLaunchIdentity(token: UUID(), agentProcessID: pid_t.max)
        await controller.noteRepoPromptMCPConnectionLost(loss(for: unregistered, proof: .unproven(predatesLaunch: false)))
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unknown)
    }

    /// A loss addressed to a launch that has since been replaced is ignored even without a proven
    /// agent PID and even though the successor reuses the same PID; the successor's own unproven
    /// loss of a connection admitted after it registered still counts.
    func testLossAddressedToAReplacedLaunchNeverMarksTheSuccessorUnhealthy() async throws {
        let controller = try makeController()
        let first = FixtureTransport()
        let firstLaunch = try await attach(first, to: controller)
        let successor = FixtureTransport()
        let successorLaunch = try await attach(successor, to: controller)
        defer { Task { await controller.test_detachFixtureTransport() } }
        XCTAssertNotEqual(firstLaunch.token, successorLaunch.token)

        await controller.noteRepoPromptMCPConnectionLost(loss(for: firstLaunch, proof: .unproven(predatesLaunch: false)))
        await controller.noteRepoPromptMCPConnectionLost(loss(for: firstLaunch))
        let healthAfterStale = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(healthAfterStale, .unknown)

        await controller.noteRepoPromptMCPConnectionLost(loss(for: successorLaunch, proof: .unproven(predatesLaunch: false)))
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unhealthy(reason: "tool_execution_watchdog"))
        let decisions = await controller.test_repoPromptMCPLossDecisions().map(\.decision)
        XCTAssertEqual(decisions, ["stale_launch", "stale_launch", "applied"])
    }

    // MARK: - Published status

    func testUnhealthyLaunchPublishesDisconnectedDespiteConnectedSystemInit() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        await controller.ensureEventsStreamReady()
        defer { Task { await controller.test_detachFixtureTransport() } }

        await controller.test_handleStreamPayload(systemInit(repoPromptStatus: "connected"))
        let connectedHealth = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(connectedHealth, .connected)

        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch))
        // Claude's cached per-turn snapshot still says connected: it must not win.
        await controller.test_handleStreamPayload(systemInit(repoPromptStatus: "connected"))

        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unhealthy(reason: "tool_execution_watchdog"))
        let runtimeInits = await drainEvents(controller).compactMap { event -> ClaudeNativeProcessSessionController.RuntimeInitStatus? in
            if case let .runtimeInit(status) = event { return status }
            return nil
        }
        let latest = try XCTUnwrap(runtimeInits.last)
        XCTAssertEqual(latest.mcpServerStatuses[repoPromptServerName], "disconnected")
        XCTAssertEqual(latest.repoPromptMCPHealth, .unhealthy(reason: "tool_execution_watchdog"))
        let firstUnhealthy = try XCTUnwrap(runtimeInits.firstIndex { $0.repoPromptMCPHealth.isUnhealthy })
        XCTAssertTrue(
            runtimeInits[..<firstUnhealthy].contains { $0.mcpServerStatuses[repoPromptServerName] == "connected" },
            "before the loss the reported connected status is published as-is"
        )
        XCTAssertFalse(
            runtimeInits[firstUnhealthy...].contains { $0.mcpServerStatuses[repoPromptServerName] == "connected" },
            "once unhealthy, no published status says connected"
        )
    }

    // MARK: - Reuse gates

    func testUnhealthyLaunchRefusesFastPathResumeAndSendWithoutWriting() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        defer { Task { await controller.test_detachFixtureTransport() } }
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch))

        do {
            _ = try await controller.startOrResume(
                existingSessionID: "health-session",
                model: nil,
                effortLevel: nil,
                systemPromptOverride: nil
            )
            XCTFail("An unhealthy launch must not be reused")
        } catch ClaudeNativeProcessSessionController.ControllerError.repoPromptMCPRecoveryRequired {}

        do {
            _ = try await controller.sendUserMessage("must not be written")
            XCTFail("An unhealthy launch must not accept a turn")
        } catch ClaudeNativeProcessSessionController.ControllerError.repoPromptMCPRecoveryRequired {}
        XCTAssertTrue(transport.frames.isEmpty)
    }

    /// The reuse gates do not depend on the loss reason.
    func testHelperExitReasonsGateFastPathResumeAndSend() async throws {
        for reason in [AgentMCPRunConnectionLoss.Reason.helperExited, .routeNotRestored] {
            let controller = try makeController()
            let transport = FixtureTransport()
            let launch = try await attach(transport, to: controller)
            await controller.noteRepoPromptMCPConnectionLost(loss(for: launch, reason: reason))

            do {
                _ = try await controller.startOrResume(
                    existingSessionID: "health-session",
                    model: nil,
                    effortLevel: nil,
                    systemPromptOverride: nil
                )
                XCTFail("An unhealthy launch must not be reused (\(reason))")
            } catch ClaudeNativeProcessSessionController.ControllerError.repoPromptMCPRecoveryRequired {}

            do {
                _ = try await controller.sendUserMessage("must not be written")
                XCTFail("An unhealthy launch must not accept a turn (\(reason))")
            } catch ClaudeNativeProcessSessionController.ControllerError.repoPromptMCPRecoveryRequired {}
            XCTAssertTrue(transport.frames.isEmpty, "\(reason)")
            await controller.test_detachFixtureTransport()
        }
    }

    // MARK: - Protocol witnesses

    /// Agent Mode reaches the controller through `any NativeAgentRuntimeControlling` (inside the
    /// Claude-compatible adapter): the health and evidence members must be the controller's own
    /// witnesses, never the protocol extension's `unknown` / not-connected defaults.
    func testHealthAndEvidenceReachTheControllerThroughTheRuntimeProtocolAndAdapter() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let runtime: any NativeAgentRuntimeControlling = controller
        let coreConfig = try ClaudeCodeAgentConfig.agentMode(
            commandName: "claude",
            modelString: nil,
            runtimeVariant: .standard,
            permissionMode: nil
        )
        let adapter: any NativeAgentRuntimeControlling = ClaudeCompatibleNativeSessionAdapter(
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: coreConfig, mode: .agentMode)
        ) { controller }

        await controller.test_handleStreamPayload(systemInit(repoPromptStatus: "connected"))
        let connectedThroughRuntime = await runtime.currentRepoPromptMCPHealth
        let connectedThroughAdapter = await adapter.currentRepoPromptMCPHealth
        XCTAssertEqual(connectedThroughRuntime, .connected)
        XCTAssertEqual(connectedThroughAdapter, .connected)
        let evidence = await adapter.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 1, pollIntervalSeconds: 0.01)
        XCTAssertEqual(evidence, .connected)
        // The launch PID gates the later-turn early release; the adapter must forward it.
        let launchPIDThroughController = await controller.repoPromptMCPLaunchAgentPID
        let launchPIDThroughAdapter = await adapter.repoPromptMCPLaunchAgentPID
        XCTAssertNotNil(launchPIDThroughController)
        XCTAssertEqual(launchPIDThroughAdapter, launchPIDThroughController)

        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch))
        let unhealthyThroughAdapter = await adapter.currentRepoPromptMCPHealth
        XCTAssertEqual(unhealthyThroughAdapter, .unhealthy(reason: "tool_execution_watchdog"))
        let refusedEvidence = await adapter.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 1, pollIntervalSeconds: 0.01)
        XCTAssertEqual(refusedEvidence, .notConnected("tool_execution_watchdog"))
        let unhealthyLaunchPIDThroughAdapter = await adapter.repoPromptMCPLaunchAgentPID
        XCTAssertNil(unhealthyLaunchPIDThroughAdapter)
        XCTAssertTrue(transport.mcpStatusRequestIDs.isEmpty)
    }

    // MARK: - Connected evidence

    func testConnectedEvidenceWaitsThroughPendingMCPStatus() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let first = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: first[0], response: mcpStatusResponse("pending"))
        let second = try await waitForMCPStatusRequests(transport, count: 2)
        try await respond(controller, requestID: second[1], response: mcpStatusResponse("connected"))

        let outcome = await probe.value
        XCTAssertEqual(outcome, .connected)
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .connected)
    }

    func testConnectedEvidenceFailsOnFailedMCPStatus() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: requests[0], response: mcpStatusResponse("failed"))

        let outcome = await probe.value
        guard case let .notConnected(reason) = outcome else {
            return XCTFail("Expected not connected, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("failed"))
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .unknown)
    }

    func testConnectedEvidenceFallsBackToAppRouteWhenMCPStatusIsUnsupported() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 0.3, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: requests[0], subtype: "error", error: "Unsupported control request")

        // This run has no live app-side route, so the bounded wait ends not connected.
        let outcome = await probe.value
        guard case let .notConnected(reason) = outcome else {
            return XCTFail("Expected not connected, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no live run route"), reason)
        XCTAssertEqual(transport.mcpStatusRequestIDs.count, 1, "an unsupported mcp_status is not retried")
    }

    // MARK: - Evidence bound to the probed launch

    /// Launch A's probe is suspended in the app-route lookup when A is replaced by launch B; the
    /// lookup then answers "live". A's evidence must not mark B connected, A's probe must not
    /// report connected, and B's own later probe still asks Claude.
    func testProbeSuspendedInRouteLookupNeverMarksTheReplacementLaunchConnected() async throws {
        let routeGate = LifecycleAsyncGate()
        let host = GatedRouteMCPHost(routeIsLive: true, routeGate: routeGate)
        let controller = try makeController(mcpHost: host)
        let first = FixtureTransport()
        await controller.test_attachSpawnedProcess(first.process)
        // The app-route fallback binds to the launch's registered agent PID; without one it makes
        // no lookup at all (`testAppRouteFallbackWithoutARegisteredAgentPIDIsNeverConnected`).
        await controller.test_registerExpectedAgentPID(first.process.pid)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(first, count: 1)
        try await respond(controller, requestID: requests[0], subtype: "error", error: "Unsupported control request")
        await routeGate.waitUntilArrived()

        let successor = FixtureTransport()
        await controller.test_attachSpawnedProcess(successor.process)
        await routeGate.release()

        let outcome = await probe.value
        XCTAssertEqual(
            outcome,
            .notConnected(ClaudeNativeProcessSessionController.repoPromptMCPProbeSupersededReason)
        )
        let successorHealth = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(successorHealth, .unknown, "A's route evidence never applies to B")
        let lookups = await host.routeLookupCount
        XCTAssertEqual(lookups, 1)

        // B is probed on its own: it asks Claude rather than reusing A's evidence.
        let successorProbe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let successorRequests = try await waitForMCPStatusRequests(successor, count: 1)
        try await respond(controller, requestID: successorRequests[0], response: mcpStatusResponse("connected"))
        let successorOutcome = await successorProbe.value
        XCTAssertEqual(successorOutcome, .connected)
    }

    /// The same fence on the control-response path: A's `mcp_status` answer arrives after A was
    /// replaced, and it is not applied to B.
    func testProbeSuspendedInMCPStatusNeverMarksTheReplacementLaunchConnected() async throws {
        let controller = try makeController()
        let first = FixtureTransport()
        await controller.test_attachSpawnedProcess(first.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(first, count: 1)
        let successor = FixtureTransport()
        await controller.test_attachSpawnedProcess(successor.process)
        try await respond(controller, requestID: requests[0], response: mcpStatusResponse("connected"))

        let outcome = await probe.value
        XCTAssertEqual(
            outcome,
            .notConnected(ClaudeNativeProcessSessionController.repoPromptMCPProbeSupersededReason)
        )
        let successorHealth = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(successorHealth, .unknown)
    }

    // MARK: - Probe tolerance

    /// A CLI that never answers `mcp_status` (the request times out) is treated like one that
    /// rejects it: the probe switches to the app-side route instead of failing the launch.
    func testUnansweredMCPStatusFallsBackToAppRoute() async throws {
        let host = GatedRouteMCPHost(routeIsLive: true)
        let controller = try makeController(mcpHost: host)
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_registerExpectedAgentPID(transport.process.pid)
        defer { Task { await controller.test_detachFixtureTransport() } }

        // Under a second left: the single `mcp_status` request times out after 0.5 s.
        let outcome = await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 0.9, pollIntervalSeconds: 0.01)

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(transport.mcpStatusRequestIDs.count, 1, "an unanswered mcp_status is not retried")
        let lookups = await host.routeLookupCount
        XCTAssertEqual(lookups, 1)
        let requiredAgentPIDs = await host.routeLookupRequiredAgentPIDs
        XCTAssertEqual(
            requiredAgentPIDs, [transport.process.pid],
            "the Claude fallback binds the route to this launch's own registered agent PID"
        )
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertEqual(health, .connected)
    }

    /// Right after a respawn, before the new launch registers, the launch agent PID (used by the
    /// early release) and the probe's app-route fallback name the spawned process installed with
    /// the current launch token: never the previous process, and independent of the loss-observer
    /// registration. The manager fails closed for that PID until it is registered, so the probe
    /// stays not connected until then.
    func testLaunchAgentPIDAfterARespawnIsNeverThePreviousProcess() async throws {
        let host = GatedRouteMCPHost(routeIsLive: true, answersOnlyForRegisteredPIDs: true)
        let controller = try makeController(mcpHost: host)
        let first = FixtureTransport(pid: pid_t.max)
        await controller.test_attachSpawnedProcess(first.process)
        await controller.test_registerExpectedAgentPID(first.process.pid)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let firstPID = await controller.repoPromptMCPLaunchAgentPID
        XCTAssertEqual(firstPID, first.process.pid)

        let successor = FixtureTransport(pid: pid_t.max - 1)
        await controller.test_attachSpawnedProcess(successor.process)

        let beforeRegistration = await controller.repoPromptMCPLaunchAgentPID
        XCTAssertEqual(beforeRegistration, successor.process.pid, "the spawned process, never the previous one")
        let observerLaunch = await controller.test_currentRunConnectionLossObserverLaunch()
        XCTAssertNotEqual(observerLaunch?.agentProcessID, successor.process.pid, "fixture: the new launch's observer is not registered yet")
        // The probe's app-route fallback binds the lookup to the spawned process; the manager
        // fails closed for an unregistered PID.
        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 0.3, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(successor, count: 1)
        try await respond(controller, requestID: requests[0], subtype: "error", error: "Unsupported control request")
        let outcome = await probe.value
        guard case let .notConnected(reason) = outcome else {
            return XCTFail("Expected not connected, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no live run route"), reason)
        let lookupPIDs = await host.routeLookupRequiredAgentPIDs
        XCTAssertFalse(lookupPIDs.isEmpty, "the fallback looked the route up")
        XCTAssertTrue(lookupPIDs.allSatisfy { $0 == successor.process.pid }, "only the spawned process's PID: \(lookupPIDs)")
        XCTAssertFalse(lookupPIDs.contains(first.process.pid), "the previous process's PID is never looked up")

        await controller.test_registerExpectedAgentPID(successor.process.pid)
        let afterRegistration = await controller.repoPromptMCPLaunchAgentPID
        XCTAssertEqual(afterRegistration, successor.process.pid)
    }

    /// Before the launch registers its agent PID, the fallback never asks for a
    /// launch-independent route: every lookup binds the spawned process's PID, which the manager
    /// fails closed for until it is registered, so the probe stays not connected.
    func testAppRouteFallbackWithoutARegisteredAgentPIDIsNeverConnected() async throws {
        let host = GatedRouteMCPHost(routeIsLive: true, answersOnlyForRegisteredPIDs: true)
        let controller = try makeController(mcpHost: host)
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 0.9, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: requests[0], subtype: "error", error: "Unsupported control request")
        let outcome = await probe.value

        guard case .notConnected = outcome else {
            return XCTFail("Expected not connected, got \(outcome)")
        }
        let lookupPIDs = await host.routeLookupRequiredAgentPIDs
        XCTAssertFalse(lookupPIDs.isEmpty, "fixture: the app-route fallback ran")
        XCTAssertTrue(
            lookupPIDs.allSatisfy { $0 == transport.process.pid },
            "no launch-independent lookup; only the spawned process's PID: \(lookupPIDs)"
        )
        let health = await controller.currentRepoPromptMCPHealth
        XCTAssertNotEqual(health, .connected)
    }

    /// RepoPrompt not yet listed in `mcp_status` is treated like `pending`: the probe keeps
    /// polling until it is connected (or the deadline).
    func testAbsentRepoPromptEntryKeepsWaitingLikePending() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let first = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: first[0], response: ["mcpServers": [[String: Any]]()])
        let second = try await waitForMCPStatusRequests(transport, count: 2)
        try await respond(
            controller,
            requestID: second[1],
            response: ["mcpServers": [["name": "other-server", "status": "connected"]]]
        )
        let third = try await waitForMCPStatusRequests(transport, count: 3)
        try await respond(controller, requestID: third[2], response: mcpStatusResponse("connected"))

        let outcome = await probe.value
        XCTAssertEqual(outcome, .connected)
    }

    func testAbsentRepoPromptEntryUntilTheDeadlineIsNotConnected() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 0.5, pollIntervalSeconds: 0.01)
        }
        // Every poll is answered with no RepoPrompt entry until the probe ends.
        let answerer = Task {
            var answered = Set<String>()
            while !Task.isCancelled {
                for requestID in transport.mcpStatusRequestIDs where !answered.contains(requestID) {
                    answered.insert(requestID)
                    if let line = Self.controlResponseLine(requestID: requestID, response: ["mcpServers": [[String: Any]]()]) {
                        await controller.test_handleLine(line)
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return answered.count
        }
        let outcome = await probe.value
        answerer.cancel()
        let answeredCount = await answerer.value

        guard case let .notConnected(reason) = outcome else {
            return XCTFail("Expected not connected at the deadline, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("timed out") && reason.contains("absent"), reason)
        XCTAssertGreaterThan(answeredCount, 1, "an absent entry is re-polled, not final")
    }

    private static func controlResponseLine(requestID: String, response: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": response]
        ])
    }

    func testNeedsAuthMCPStatusFailsImmediately() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let probe = Task {
            await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 10, pollIntervalSeconds: 0.01)
        }
        let requests = try await waitForMCPStatusRequests(transport, count: 1)
        try await respond(controller, requestID: requests[0], response: mcpStatusResponse("needs-auth"))

        let outcome = await probe.value
        guard case let .notConnected(reason) = outcome else {
            return XCTFail("Expected not connected, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("needs-auth"), reason)
        XCTAssertEqual(transport.mcpStatusRequestIDs.count, 1, "an explicit needs-auth is not re-polled")
    }

    // MARK: - Registration

    /// The loss observer is registered before the expected agent PID, so the launch's helper
    /// cannot be admitted between the two registrations.
    func testLossObserverRegistersBeforeTheExpectedAgentPID() async throws {
        let host = GatedRouteMCPHost(routeIsLive: false)
        let controller = try makeController(mcpHost: host)
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        await controller.test_registerExpectedAgentPID(transport.process.pid)

        let calls = await host.calls
        XCTAssertEqual(calls, ["registerRunConnectionLossObserver", "registerExpectedAgentPID"])
    }

    /// A same-controller respawn (an unexpected stdout EOF never clears the previous PID): the next
    /// registration moves the loss observer to the new launch, then clears the previous process's
    /// expected PID, then registers the new one, so no stale PID stays registered for the run.
    func testASameControllerRespawnClearsThePreviousExpectedAgentPIDBeforeRegisteringTheNewOne() async throws {
        let host = GatedRouteMCPHost(routeIsLive: false)
        let controller = try makeController(mcpHost: host)
        let first = FixtureTransport(pid: pid_t.max)
        await controller.test_attachSpawnedProcess(first.process)
        await controller.test_registerExpectedAgentPID(first.process.pid)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let successor = FixtureTransport(pid: pid_t.max - 1)
        await controller.test_attachSpawnedProcess(successor.process)

        await controller.test_registerExpectedAgentPID(successor.process.pid)

        let calls = await host.calls
        XCTAssertEqual(calls, [
            "registerRunConnectionLossObserver",
            "registerExpectedAgentPID",
            "unregisterRunConnectionLossObserver",
            "registerRunConnectionLossObserver",
            "clearExpectedAgentPID:\(first.process.pid)",
            "registerExpectedAgentPID"
        ])
        let registered = await host.registeredExpectedAgentPIDs
        XCTAssertEqual(registered, [successor.process.pid], "only the new launch's PID stays registered")

        // Re-registering the same PID clears nothing.
        await controller.test_registerExpectedAgentPID(successor.process.pid)
        let repeated = await host.calls
        XCTAssertFalse(repeated.dropFirst(calls.count).contains { $0.hasPrefix("clearExpectedAgentPID") })
    }

    func testUnhealthyLaunchNeverProducesConnectedEvidence() async throws {
        let controller = try makeController()
        let transport = FixtureTransport()
        let launch = try await attach(transport, to: controller)
        defer { Task { await controller.test_detachFixtureTransport() } }
        await controller.noteRepoPromptMCPConnectionLost(loss(for: launch))

        let outcome = await controller.awaitRepoPromptMCPConnectedEvidence(timeoutSeconds: 5, pollIntervalSeconds: 0.01)
        XCTAssertEqual(outcome, .notConnected("tool_execution_watchdog"))
        XCTAssertTrue(transport.mcpStatusRequestIDs.isEmpty)
    }
}
