import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 final-byte writers of the Claude native and ACP controllers in registered mode, driven
/// through their production send and fence methods: zero bytes before the birth commit, without
/// an owner scope, on an ownership conflict, or when the transport is replaced during any fence
/// await (including the first); exactly one write otherwise; owner writes associate (with the
/// requested permission) before their bytes; replies go only to the issuing transport. Fixture
/// transports are pipes with no child process (except the EOF reap test's private owned `/bin/cat`
/// root); the registry uses scripted process boundaries.
final class RegisteredNativeTransportWriteFenceTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    /// A stdin/stdout/stderr pipe set standing in for a spawned child (no process exists).
    private final class FixtureTransport: @unchecked Sendable {
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
        private let lock = NSLock()
        private var received = Data()
        let process: SpawnedProcess

        init() {
            process = SpawnedProcess(
                pid: pid_t.max,
                processGroupID: nil,
                stdin: stdinPipe.fileHandleForWriting,
                stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
            let descriptor = stdinPipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        /// Every complete frame written to this transport's stdin so far.
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
    }

    private var root: URL!
    private var recoveryRoot: URL!
    private var processes: ScriptedProcessSystem!
    private var store: AgentRecoveryStore!
    private var registry: AgentProcessRegistry!
    private var nextPID: pid_t = 6000
    private let owner = AgentRuntimeSessionScope.session(AgentProcessRegistryFixtures.session())

    override func setUp() async throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("RegisteredNativeTransportWriteFenceTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        processes = ScriptedProcessSystem()
    }

    override func tearDown() async throws {
        await registry?.disposeWatches()
        registry = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Claude tests run under the production candidate (`.claudeAndCodex`); ACP is not covered
    /// there, so its fence tests pass the all-pairs fixture qualification.
    private func startRegistry(
        _ qualification: AgentRuntimeQualification = AgentRecoveryActivation.claudeAndCodex.runtime
    ) async {
        store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        registry = AgentProcessRegistry(store: store, qualification: qualification, system: processes.system)
        await registry.start()
    }

    /// A reserved and committed (`live`) launch of `family` on a fresh scripted PID.
    private func committedLaunch(_ family: AgentRuntimeFamily) async throws -> (AgentRuntimeLaunch, UUID) {
        let launch = try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(
            Fixtures.context(family, worktreePath: "/tmp/wt-native")
        ))
        let runtimeID = try await launch.prepareSpawn()
        let pid = nextPID
        nextPID += 1
        processes.add(processes.observation(pid: pid, group: pid, marker: runtimeID))
        try await launch.commitSpawn(pid: pid, processGroupID: pid)
        return (launch, runtimeID)
    }

    private func assertProcessNotRunning(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        // The ACP controller's error type is private: match its case name.
        if case ClaudeNativeProcessSessionController.ControllerError.processNotRunning = error { return }
        XCTAssertEqual(String(describing: error), "processNotRunning", "Expected processNotRunning, got \(error)", file: file, line: line)
    }

    // MARK: Claude native

    private func makeClaude(permissionMode: String? = nil) throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: .standard, permissionMode: permissionMode),
            mcpHost: ServerNetworkManager.shared
        )
    }

    private func sendClaudeTurn(_ controller: ClaudeNativeProcessSessionController, as scope: AgentRuntimeSessionScope?) async throws {
        if let scope {
            _ = try await AgentRuntimeOperationOwner.$session.withValue(scope) { try await controller.sendUserMessage("hello") }
        } else {
            _ = try await controller.sendUserMessage("hello")
        }
    }

    func testClaudeUserTurnWritesOnceOnlyThroughItsCommittedOwnerAfterAssociating() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        defer { Task { await controller.test_detachFixtureTransport() } }

        await controller.test_installRuntimeLaunch(launch, committed: false)
        do {
            try await sendClaudeTurn(controller, as: owner)
            XCTFail("An uncommitted transport must not be written")
        } catch {
            assertProcessNotRunning(error)
        }
        XCTAssertTrue(transport.frames.isEmpty)

        await controller.test_installRuntimeLaunch(launch, committed: true)
        do {
            try await sendClaudeTurn(controller, as: nil)
            XCTFail("An owner write without a captured session scope must be refused")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .sessionContextUnavailable)
        }
        XCTAssertTrue(transport.frames.isEmpty)

        try await sendClaudeTurn(controller, as: owner)
        XCTAssertEqual(transport.frames.count, 1, "exactly one write")
        XCTAssertEqual(transport.frames.first?["type"] as? String, "user")
        guard case let .session(expected) = owner else { return XCTFail("fixture owner") }
        XCTAssertTrue(
            Fixtures.record(store, runtimeID)?.associations.contains { $0.session == expected } ?? false,
            "the owner's session and run attempt were associated before the write"
        )
    }

    func testClaudeReplacementDuringAnyFenceAwaitGetsZeroBytes() async throws {
        await startRegistry()
        let controller = try makeClaude()
        for checkpoint in ["launchCaptured", "associated", "authorized"] {
            let (first, _) = try await committedLaunch(.claudeNative)
            let firstPID = nextPID - 1
            let original = FixtureTransport()
            await controller.test_attachSpawnedProcess(original.process)
            await controller.test_installRuntimeLaunch(first, committed: true)
            let gate = InventoryGate()
            await controller.test_setRuntimeFenceCheckpoint { name in
                guard name == checkpoint else { return }
                await gate.pass()
            }
            // A distinct owner session per cut (R6 same-session rule across live runtimes).
            let owner = AgentRuntimeSessionScope.session(Fixtures.session())
            let send = Task { try await self.sendClaudeTurn(controller, as: owner) }
            let arrived = await Fixtures.eventually { await gate.hasArrived }
            XCTAssertTrue(arrived, "the write reached \(checkpoint)")

            let (replacement, replacementID) = try await committedLaunch(.claudeNative)
            let replacementTransport = FixtureTransport()
            await controller.test_attachSpawnedProcess(replacementTransport.process)
            await controller.test_installRuntimeLaunch(replacement, committed: true)
            await gate.open()
            do {
                try await send.value
                XCTFail("A write suspended at \(checkpoint) must not reach the replacement")
            } catch {
                assertProcessNotRunning(error)
            }
            XCTAssertTrue(original.frames.isEmpty, checkpoint)
            XCTAssertTrue(replacementTransport.frames.isEmpty, "zero bytes to the replacement (\(checkpoint))")
            XCTAssertEqual(Fixtures.record(store, replacementID)?.associations.compactMap(\.session), [], checkpoint)

            // The replaced runtime is retired (its exact root reaped, family gone) before the
            // replacement serves the same session; until then the session has another live writer.
            processes.remove(pid: firstPID)
            await first.rootReaped(pid: firstPID, confirmed: true)
            await controller.test_setRuntimeFenceCheckpoint(nil)
            try await sendClaudeTurn(controller, as: owner)
            XCTAssertEqual(replacementTransport.frames.count, 1, "the replacement serves its own writes (\(checkpoint))")
        }
        await controller.test_detachFixtureTransport()
    }

    func testClaudeOwnershipConflictPreventsTheWrite() async throws {
        guard case let .session(expected) = owner else { return XCTFail("fixture owner") }
        processes.add(processes.observation(pid: 6900, group: 6900))
        let holder = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 6900),
            rootGroup: 6900,
            associations: [AgentRuntimeAssociation(session: expected, conversationID: nil, worktreePath: nil, permission: .unavailable)]
        )
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }

        do {
            try await sendClaudeTurn(controller, as: owner)
            XCTFail("A session another possible writer holds must not be written")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .ownershipConflict(runtimeID: holder.runtimeID))
        }
        XCTAssertTrue(transport.frames.isEmpty)
        XCTAssertFalse(Fixtures.record(store, runtimeID)?.associations.contains { $0.session == expected } ?? true)
    }

    func testClaudePermissionChangeIsPersistedBeforeItsSingleWrite() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude(permissionMode: "plan")
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        let stdoutLaunch = await controller.test_beginSyntheticUsageLaunch()
        defer { Task { await controller.test_detachFixtureTransport() } }

        // Without a captured owner scope the permission change is refused before any byte.
        do {
            try await controller.test_applyInitialPermissionMode()
            XCTFail("A permission change without an owner scope must be refused")
        } catch {}
        XCTAssertTrue(transport.frames.isEmpty)

        let owner = owner
        let apply = Task {
            try await AgentRuntimeOperationOwner.$session.withValue(owner) { try await controller.test_applyInitialPermissionMode() }
        }
        let written = await Fixtures.eventually { !transport.frames.isEmpty }
        XCTAssertTrue(written)
        let frame = try XCTUnwrap(transport.frames.first)
        XCTAssertEqual((frame["request"] as? [String: Any])?["subtype"] as? String, "set_permission_mode")
        XCTAssertTrue(
            Fixtures.record(store, runtimeID)?.associations.contains { $0.permission == .claude(permissionMode: "plan") } ?? false,
            "the requested permission is durable by the time its request is written"
        )
        let requestID = try XCTUnwrap(frame["request_id"] as? String)
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": [:]]
        ]) + Data([0x0A])
        await controller.test_handleStdoutChunk(response, launchToken: stdoutLaunch.token)
        try await apply.value
        XCTAssertEqual(transport.frames.count, 1, "exactly one write")
    }

    func testClaudePermissionReplyGoesOnlyToItsIssuingTransport() async throws {
        await startRegistry()
        let (first, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let original = FixtureTransport()
        await controller.test_attachSpawnedProcess(original.process)
        await controller.test_installRuntimeLaunch(first, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let request: [String: Any] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": [:]]

        await controller.test_storePendingPermissionRequest(id: "perm-1", request: request)
        await controller.respondToPermissionRequest(id: "perm-1", decision: .decline)
        XCTAssertEqual(original.frames.count, 1, "a reply on the issuing transport is written once")

        await controller.test_storePendingPermissionRequest(id: "perm-2", request: request)
        let (replacement, _) = try await committedLaunch(.claudeNative)
        let replacementTransport = FixtureTransport()
        await controller.test_attachSpawnedProcess(replacementTransport.process)
        await controller.test_installRuntimeLaunch(replacement, committed: true)
        await controller.respondToPermissionRequest(id: "perm-2", decision: .decline)
        XCTAssertEqual(original.frames.count, 1)
        XCTAssertTrue(replacementTransport.frames.isEmpty, "zero bytes to the replacement")

        // The stale reply was dropped without shutting the replacement down.
        try await sendClaudeTurn(controller, as: owner)
        XCTAssertEqual(replacementTransport.frames.count, 1)
    }

    func testClaudeObservedFreshConversationIsAssociatedBeforeItsPermissionReply() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        let stdoutLaunch = await controller.test_beginSyntheticUsageLaunch()
        defer { Task { await controller.test_detachFixtureTransport() } }

        // First turn of a fresh conversation: the owner write associates no native ID yet.
        try await sendClaudeTurn(controller, as: owner)
        XCTAssertEqual(transport.frames.count, 1)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, [])

        // Claude reports its real session ID: it is associated durably with the launch.
        let observed = try JSONSerialization.data(withJSONObject: [
            "type": "system",
            "subtype": "init",
            "session_id": "claude-fresh-1"
        ]) + Data([0x0A])
        await controller.test_handleStdoutChunk(observed, launchToken: stdoutLaunch.token)
        let associated = await Fixtures.eventually { Fixtures.record(self.store, runtimeID)?.conversationIDs == ["claude-fresh-1"] }
        XCTAssertTrue(associated, "the observed conversation is associated before conversation-dependent replies")
        guard case let .session(expected) = owner else { return XCTFail("fixture owner") }
        XCTAssertTrue(
            Fixtures.record(store, runtimeID)?.associations.contains { $0.conversationID == "claude-fresh-1" && $0.session == expected } ?? false,
            "attributed to the owner whose operation produced it"
        )

        // A permission reply during that first turn authorizes on the observed conversation.
        await controller.test_storePendingPermissionRequest(
            id: "perm-fresh",
            request: ["subtype": "can_use_tool", "tool_name": "Bash", "input": [:]]
        )
        await controller.respondToPermissionRequest(id: "perm-fresh", decision: .decline)
        XCTAssertEqual(transport.frames.count, 2, "the reply is written once on the issuing transport")

        // An interrupt (no owner scope) only authorizes on the observed conversation: exactly its
        // interrupt request is written, and it creates no association.
        let associationsBeforeInterrupt = Fixtures.record(store, runtimeID)?.associations
        let interrupt = Task { await controller.interruptTurn(reason: "fixture-interrupt") }
        let interruptWritten = await Fixtures.eventually { transport.frames.count == 3 }
        XCTAssertTrue(interruptWritten, "the interrupt request is written")
        let interruptFrame = try XCTUnwrap(transport.frames.last)
        XCTAssertEqual(interruptFrame["type"] as? String, "control_request")
        let interruptRequest = try XCTUnwrap(interruptFrame["request"] as? [String: Any])
        XCTAssertEqual(interruptRequest["subtype"] as? String, "interrupt")
        XCTAssertEqual(interruptRequest["reason"] as? String, "fixture-interrupt")
        let interruptRequestID = try XCTUnwrap(interruptFrame["request_id"] as? String)
        let interruptAck = try JSONSerialization.data(withJSONObject: [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": interruptRequestID, "response": [:]]
        ]) + Data([0x0A])
        await controller.test_handleStdoutChunk(interruptAck, launchToken: stdoutLaunch.token)
        let interruptOutcome = await interrupt.value
        guard case .acknowledged = interruptOutcome else {
            return XCTFail("Expected the interrupt to be acknowledged, got \(interruptOutcome)")
        }
        XCTAssertEqual(transport.frames.count, 3, "the interrupt is written exactly once")
        XCTAssertEqual(
            Fixtures.record(store, runtimeID)?.associations,
            associationsBeforeInterrupt,
            "an authorize-only interrupt creates no association"
        )

        // The session was not shut down: the owner keeps writing.
        try await sendClaudeTurn(controller, as: owner)
        XCTAssertEqual(transport.frames.count, 4)
    }

    /// R6 EOF reap barrier: after the production stdout-EOF path, the registered launch's exact
    /// root keeps one retained, bounded reap, and `shutdown()` joins it — it returns only after this
    /// controller itself reaped that root (confirmed) and its post-reap discovery resolved the
    /// record. The root is a private owned `/bin/cat` child whose stdin is the gate: it exits only
    /// when the test closes stdin, well inside the reap's bounded wait, so nothing is signalled.
    func testClaudeStdoutEOFReapIsRetainedAndJoinedByShutdownUntilTheExactRootIsReaped() async throws {
        await startRegistry()
        let launch = try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(
            Fixtures.context(.claudeNative, worktreePath: "/tmp/wt-native")
        ))
        let runtimeID = try await launch.prepareSpawn()
        let child = try ProcessLauncher.spawn(
            command: "/bin/cat",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp"
        )
        let childPID = child.pid
        addTeardownBlock {
            // Signal-free cleanup on any early failure: closing stdin ends `cat`; reap it if still ours.
            try? child.stdin?.close()
            var status: Int32 = 0
            var attempts = 0
            while attempts < 400, waitpid(childPID, &status, WNOHANG) == 0 {
                usleep(5000)
                attempts += 1
            }
        }
        processes.add(processes.observation(pid: childPID, group: child.processGroupID ?? childPID, marker: runtimeID))
        try await launch.commitSpawn(pid: childPID, processGroupID: child.processGroupID)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .live)

        let controller = try makeClaude()
        await controller.test_attachSpawnedProcess(child)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        let stdoutLaunch = await controller.test_beginSyntheticUsageLaunch()

        // Process loss: the production EOF handler detaches the transport and retains the root's reap.
        await controller.test_handleStdoutEOF(launchToken: stdoutLaunch.token)

        let shutdownFinished = LifecycleCompletionFlag()
        let shutdown = Task {
            await controller.shutdown()
            await shutdownFinished.set()
        }
        // Bounded hold (far below the reap's 2 s wait before escalation): the root is still alive.
        try await Task.sleep(nanoseconds: 200_000_000)
        let finishedWhileRootAlive = await shutdownFinished.isSet
        XCTAssertFalse(finishedWhileRootAlive, "shutdown joins the retained EOF reap of the live root")
        XCTAssertNotEqual(Fixtures.record(store, runtimeID)?.rootReaped, true, "no reap is reported before the root exits")
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .live)

        // Release the gate: the root exits on its own and its family is gone from discovery.
        processes.remove(pid: childPID)
        try child.stdin?.close()
        await shutdown.value

        XCTAssertEqual(Fixtures.record(store, runtimeID)?.rootReaped, true, "the controller's own wait reaped the exact root")
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .exited, "post-reap discovery resolved before shutdown returned")
        var status: Int32 = 0
        let laterWait = waitpid(childPID, &status, WNOHANG)
        let laterWaitErrno = errno
        XCTAssertEqual(laterWait, -1, "the root was already reaped by the owned reap")
        XCTAssertEqual(laterWaitErrno, ECHILD)
    }

    func testClaudeOwnerWriteRechecksItsOperationAdmissionAfterTheFence() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }

        // The captured dispatch no longer owns the controller by the time the fence returns.
        let owner = owner
        do {
            try await AgentRuntimeOperationOwner.$writeAdmission.withValue({ _ in .denied }) {
                try await AgentRuntimeOperationOwner.$session.withValue(owner) { _ = try await controller.sendUserMessage("hello") }
            }
            XCTFail("A write whose operation is no longer current must not be written")
        } catch {
            assertProcessNotRunning(error)
        }
        XCTAssertTrue(transport.frames.isEmpty, "zero bytes from a superseded operation")

        try await AgentRuntimeOperationOwner.$writeAdmission.withValue({ _ in .admittedWithoutIdentity }) {
            try await AgentRuntimeOperationOwner.$session.withValue(owner) { _ = try await controller.sendUserMessage("hello") }
        }
        XCTAssertEqual(transport.frames.count, 1, "a current operation writes once")
    }

    /// Step 4d1: the user frame carries a lowercase top-level `uuid` only when the write's own single
    /// admission returned one for an eligible launch (automatic command or configured exact path,
    /// first-party backend, no backend-routing keys); an ordinary admission (a retry after `alreadyRecorded`) omits it and
    /// keeps the legacy frame exactly; an ineligible launch never encodes one.
    func testClaudeUserFrameCarriesTheAdmittedOutboundUUIDOnlyForAnEligibleLaunch() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let owner = owner
        let eligibility = MessageLog()
        func send(_ admission: AgentRuntimeWriteAdmission) async throws {
            try await AgentRuntimeOperationOwner.$writeAdmission.withValue({ eligible in
                eligibility.append("\(eligible)")
                return admission
            }) {
                try await AgentRuntimeOperationOwner.$session.withValue(owner) { _ = try await controller.sendUserMessage("hello") }
            }
        }

        // No launch identity: ineligible, so even an admitted UUID is never encoded.
        try await send(.admitted(outboundUserMessageUUID: UUID()))
        XCTAssertEqual(eligibility.messages, ["false"])
        XCTAssertNil(transport.frames.last?["uuid"], "an unqualified launch never carries an outbound identity")

        // A programmatic command override is ineligible.
        await controller.test_beginSyntheticUsageLaunch(commandProvenance: .programmaticOverride)
        try await send(.admitted(outboundUserMessageUUID: UUID()))
        XCTAssertEqual(eligibility.messages.last, "false")
        XCTAssertNil(transport.frames.last?["uuid"])

        // A compatible backend is ineligible, even with a configured exact path.
        await controller.test_beginSyntheticUsageLaunch(commandProvenance: .configuredOverride, backend: .compatible(.glmZAI))
        try await send(.admitted(outboundUserMessageUUID: UUID()))
        XCTAssertEqual(eligibility.messages.last, "false")
        XCTAssertNil(transport.frames.last?["uuid"])

        // A routing key on a configured exact path is ineligible.
        await controller.test_beginSyntheticUsageLaunch(commandProvenance: .configuredOverride, environmentOverrideKeys: ["CLAUDE_CONFIG_DIR"])
        try await send(.admitted(outboundUserMessageUUID: UUID()))
        XCTAssertEqual(eligibility.messages.last, "false")
        XCTAssertNil(transport.frames.last?["uuid"])

        // Owner decision (2026-10-29): a configured exact path (e.g. the owner's pass-through
        // wrapper) on the first-party backend with no routing keys is eligible.
        await controller.test_beginSyntheticUsageLaunch(commandProvenance: .configuredOverride)
        let configuredClaim = UUID()
        try await send(.admitted(outboundUserMessageUUID: configuredClaim))
        XCTAssertEqual(eligibility.messages.last, "true")
        XCTAssertEqual(transport.frames.last?["uuid"] as? String, configuredClaim.uuidString.lowercased())

        // A routing key on an otherwise automatic first-party launch is ineligible.
        await controller.test_beginSyntheticUsageLaunch(environmentOverrideKeys: ["ANTHROPIC_BASE_URL"])
        try await send(.admitted(outboundUserMessageUUID: UUID()))
        XCTAssertEqual(eligibility.messages.last, "false")
        XCTAssertNil(transport.frames.last?["uuid"])

        // Eligible launch, newly committed claim: exactly that UUID, lowercase, at the top level.
        await controller.test_beginSyntheticUsageLaunch()
        let claimed = UUID()
        try await send(.admitted(outboundUserMessageUUID: claimed))
        XCTAssertEqual(eligibility.messages.last, "true")
        XCTAssertEqual(transport.frames.last?["uuid"] as? String, claimed.uuidString.lowercased())
        XCTAssertNil((transport.frames.last?["message"] as? [String: Any])?["uuid"], "top-level only")

        // Retry of the same dispatch (admission reports no new claim): no UUID, legacy keys exactly.
        try await send(.admittedWithoutIdentity)
        XCTAssertEqual(eligibility.messages.last, "true")
        let retried = try XCTUnwrap(transport.frames.last)
        XCTAssertNil(retried["uuid"], "a retry never reuses or mints an identity")
        XCTAssertEqual(Set(retried.keys), ["type", "message", "parent_tool_use_id"])
        XCTAssertEqual(transport.frames.count, 8, "one write per send, one admission each")
        XCTAssertEqual(eligibility.messages.count, 8)

        // Denied: zero bytes even for an eligible launch.
        do {
            try await send(.denied)
            XCTFail("A denied admission must not be written")
        } catch {
            assertProcessNotRunning(error)
        }
        XCTAssertEqual(transport.frames.count, 8)
    }

    // MARK: Claude native: inbound binding, automatic replies, cancellation (re-review A05/A06/A12)

    /// Protocol failures the controller would have shut down for (the DEBUG interceptor keeps the
    /// fixture transport attached so zero bytes can be asserted).
    private final class MessageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var messages: [String] {
            lock.withLock { stored }
        }

        func append(_ message: String) {
            lock.withLock { stored.append(message) }
        }
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    func testClaudeBufferedInboundLinesNeverReachAReplacementTransport() async throws {
        await startRegistry()
        let (first, firstID) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let original = FixtureTransport()
        await controller.test_attachSpawnedProcess(original.process)
        await controller.test_installRuntimeLaunch(first, committed: true)
        let stdoutLaunch = await controller.test_beginSyntheticUsageLaunch()
        defer { Task { await controller.test_detachFixtureTransport() } }
        let gate = InventoryGate()
        await controller.test_setRuntimeFenceCheckpoint { name in
            guard name == "observedAssociating" else { return }
            await gate.pass()
        }

        // One chunk from the original transport: its conversation report, then a request that
        // would get an automatic reply.
        let chunk = try jsonLine(["type": "system", "subtype": "init", "session_id": "claude-a05"])
            + jsonLine(["type": "control_request", "request_id": "req-a05", "request": ["subtype": "fixture_unsupported"]])
        let delivery = Task { await controller.test_handleStdoutChunk(chunk, launchToken: stdoutLaunch.token) }
        let arrived = await Fixtures.eventually { await gate.hasArrived }
        XCTAssertTrue(arrived, "the observed conversation's association suspended")

        // The transport is replaced while the first line's association is awaited.
        let (replacement, replacementID) = try await committedLaunch(.claudeNative)
        let replacementTransport = FixtureTransport()
        await controller.test_attachSpawnedProcess(replacementTransport.process)
        await controller.test_installRuntimeLaunch(replacement, committed: true)
        await gate.open()
        await delivery.value

        XCTAssertTrue(original.frames.isEmpty)
        XCTAssertTrue(replacementTransport.frames.isEmpty, "the buffered request is never answered on the replacement")
        XCTAssertEqual(Fixtures.record(store, replacementID)?.conversationIDs, [], "nothing is associated with the replacement")
        XCTAssertEqual(
            Fixtures.record(store, firstID)?.conversationIDs,
            ["claude-a05"],
            "the observation is attributed only to the transport that reported it"
        )
    }

    func testClaudeAutomaticRepliesPassTheRegistryFenceAndOnlyTheirReceivingTransport() async throws {
        await startRegistry()
        let (first, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let original = FixtureTransport()
        await controller.test_attachSpawnedProcess(original.process)
        await controller.test_installRuntimeLaunch(first, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }
        let failures = MessageLog()
        await controller.test_setProtocolFailureInterceptor { failures.append($0) }

        // Authorized: one reply on the receiving transport.
        await controller.test_handleControlRequest(requestID: "auto-1", subtype: "fixture_unsupported", request: [:])
        XCTAssertEqual(original.frames.count, 1)
        XCTAssertEqual(original.frames.last?["type"] as? String, "control_response")

        // Suspended in its registry fence while the transport is replaced: dropped, not failed.
        let gate = InventoryGate()
        await controller.test_setRuntimeFenceCheckpoint { name in
            guard name == "authorized" else { return }
            await gate.pass()
        }
        let pending = Task { await controller.test_handleControlRequest(requestID: "auto-2", subtype: "fixture_unsupported", request: [:]) }
        let arrived = await Fixtures.eventually { await gate.hasArrived }
        XCTAssertTrue(arrived, "the automatic reply awaited its registry fence")
        let (replacement, _) = try await committedLaunch(.claudeNative)
        let replacementPID = nextPID - 1
        let replacementTransport = FixtureTransport()
        await controller.test_attachSpawnedProcess(replacementTransport.process)
        await controller.test_installRuntimeLaunch(replacement, committed: true)
        await gate.open()
        await pending.value
        await controller.test_setRuntimeFenceCheckpoint(nil)
        XCTAssertEqual(original.frames.count, 1, "nothing more on the replaced transport")
        XCTAssertTrue(replacementTransport.frames.isEmpty, "zero bytes to the replacement")
        XCTAssertTrue(failures.messages.isEmpty, "a replaced transport's reply is dropped without failing the replacement")

        // Revoked while still installed: the registry refuses, zero bytes, and the transport fails.
        processes.remove(pid: replacementPID)
        await replacement.rootReaped(pid: replacementPID, confirmed: true)
        await controller.test_handleControlRequest(requestID: "auto-3", subtype: "fixture_unsupported", request: [:])
        XCTAssertTrue(replacementTransport.frames.isEmpty, "a revoked launch gets zero bytes")
        XCTAssertEqual(failures.messages.count, 1)
        XCTAssertTrue(
            failures.messages.first?.hasPrefix("Failed replying to unsupported Claude control request") ?? false,
            "\(failures.messages)"
        )

        // The auto-approval branch on the same revoked launch: refused, zero bytes, transport fails.
        await controller.test_handleControlRequest(requestID: "auto-4", subtype: "can_use_tool", request: [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_auto_4",
            "input": ["path": "Sources/App.swift"]
        ])
        XCTAssertTrue(replacementTransport.frames.isEmpty, "a revoked launch gets no auto-approval bytes")
        XCTAssertEqual(failures.messages.count, 2)
        XCTAssertTrue(
            failures.messages.last?.hasPrefix("Failed auto-approving RepoPrompt Claude permission request") ?? false,
            "\(failures.messages)"
        )
    }

    func testClaudeCancelledLaunchReservationIsReleasedAndSpawnsNothing() async throws {
        // A previous instance left a live record whose (scripted) root is gone, so the next registry's
        // startup discovery has a pass to run.
        await startRegistry()
        _ = try await committedLaunch(.claudeNative)
        processes.remove(pid: nextPID - 1)
        await registry.disposeWatches()

        // Registry not yet started: the reservation's admission runs that startup discovery, whose
        // scripted inventory is held so the start can be cancelled while its reservation is suspended.
        store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        registry = AgentProcessRegistry(
            store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime, system: processes.system
        )
        let gate = InventoryGate()
        processes.inventoryHook = { await gate.pass() }
        let controller = try makeClaude()

        let cancelledLaunch = try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(
            Fixtures.context(.claudeNative, worktreePath: "/tmp/wt-reserve")
        ))
        let cancelled = Task { try await controller.test_reserveSpawn(launch: cancelledLaunch) }
        let held = await Fixtures.eventually { await gate.hasArrived }
        XCTAssertTrue(held, "the reservation suspended in startup discovery")
        let heldID = await cancelledLaunch.runtimeID
        XCTAssertNil(heldID, "the reservation is still suspended")
        cancelled.cancel()
        await gate.open()
        do {
            _ = try await cancelled.value
            XCTFail("A start cancelled during its reservation must not go on to spawn")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let reservedID = await cancelledLaunch.runtimeID
        let runtimeID = try XCTUnwrap(reservedID)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .exited, "the reservation completed, then was released")
        do {
            try await cancelledLaunch.commitSpawn(pid: nextPID, processGroupID: nextPID)
            XCTFail("A released reservation can never commit a spawn")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .staleLaunch)
        }

        // Positive control: an uncancelled reservation proceeds and stays reserved for its spawn.
        let proceeding = try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(
            Fixtures.context(.claudeNative, worktreePath: "/tmp/wt-reserve")
        ))
        let proceeds = try await controller.test_reserveSpawn(launch: proceeding)
        XCTAssertTrue(proceeds)
        let proceedingValue = await proceeding.runtimeID
        let proceedingID = try XCTUnwrap(proceedingValue)
        XCTAssertEqual(Fixtures.record(store, proceedingID)?.state, .reserved)
        await proceeding.spawnFailed()
    }

    func testClaudeUserTurnCancelledDuringItsAdmissionCheckWritesNothing() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude()
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        defer { Task { await controller.test_detachFixtureTransport() } }

        let admissionGate = LifecycleAsyncGate()
        let owner = owner
        let send = Task {
            try await AgentRuntimeOperationOwner.$writeAdmission.withValue({ _ in
                await admissionGate.arriveAndWait()
                return .admitted(outboundUserMessageUUID: UUID())
            }) {
                try await AgentRuntimeOperationOwner.$session.withValue(owner) { _ = try await controller.sendUserMessage("hello") }
            }
        }
        await admissionGate.waitUntilArrived()
        send.cancel()
        await admissionGate.release()
        do {
            try await send.value
            XCTFail("A turn cancelled during its admission check must not be written")
        } catch {
            assertProcessNotRunning(error)
        }
        XCTAssertTrue(transport.frames.isEmpty, "zero bytes after an admitted-but-cancelled check")

        // Contrast: the same admission without cancellation writes once.
        try await AgentRuntimeOperationOwner.$writeAdmission.withValue({ _ in .admittedWithoutIdentity }) {
            try await AgentRuntimeOperationOwner.$session.withValue(owner) { _ = try await controller.sendUserMessage("hello") }
        }
        XCTAssertEqual(transport.frames.count, 1)
    }

    func testClaudeInterruptFromACancelledTaskIsStillWrittenButOtherControlRequestsAreNot() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch(.claudeNative)
        let controller = try makeClaude(permissionMode: "plan")
        let transport = FixtureTransport()
        await controller.test_attachSpawnedProcess(transport.process)
        await controller.test_installRuntimeLaunch(launch, committed: true)
        let stdoutLaunch = await controller.test_beginSyntheticUsageLaunch()
        defer { Task { await controller.test_detachFixtureTransport() } }

        // Contrast: a cancelled (non-interrupt) control request writes nothing.
        let owner = owner
        let cancelledPermission = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AgentRuntimeOperationOwner.$session.withValue(owner) { try await controller.test_applyInitialPermissionMode() }
        }
        do {
            try await cancelledPermission.value
            XCTFail("A cancelled permission change must not be written")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(transport.frames.isEmpty)

        try await sendClaudeTurn(controller, as: owner)
        XCTAssertEqual(transport.frames.count, 1)

        // A stop path's interrupt, issued from an already-cancelled task, is still written once.
        let interrupt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.interruptTurn(reason: "cancelled-stop")
        }
        let written = await Fixtures.eventually { transport.frames.count == 2 }
        XCTAssertTrue(written, "the interrupt is written despite the cancelled caller")
        let interruptFrame = try XCTUnwrap(transport.frames.last)
        XCTAssertEqual((interruptFrame["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
        let requestID = try XCTUnwrap(interruptFrame["request_id"] as? String)
        try await controller.test_handleStdoutChunk(
            jsonLine(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": [:]]]),
            launchToken: stdoutLaunch.token
        )
        let outcome = await interrupt.value
        guard case .acknowledged = outcome else { return XCTFail("Expected an acknowledged interrupt, got \(outcome)") }
        XCTAssertEqual(transport.frames.count, 2, "exactly once")
    }

    // MARK: ACP

    private struct FixtureACPProvider: ACPAgentProvider {
        let providerID: ACPProviderID = .cursor

        func support(for _: ACPRunRequest) async -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            ACPLaunchConfiguration(
                providerID: providerID,
                command: "/nonexistent/fixture-acp",
                arguments: [],
                environment: [:],
                workingDirectory: request.workspacePath,
                additionalPathHints: [],
                enableDebugLogging: false
            )
        }

        func makeSessionConfiguration(
            for request: ACPRunRequest,
            mcpServer _: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            ACPSessionConfiguration(mode: .new, workingDirectory: request.workspacePath ?? "/tmp", mcpServers: [])
        }

        func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
            [["type": "text", "text": message.userMessage]]
        }

        func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            []
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }

    private func makeACP(transport: FixtureTransport) async throws -> ACPAgentSessionController {
        let controller = try ACPAgentSessionController(
            provider: FixtureACPProvider(),
            runRequest: ACPRunRequest(
                agentKind: .cursor,
                modelString: nil,
                workspacePath: "/tmp/wt-native",
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            ),
            mcpHost: ServerNetworkManager.shared
        )
        await controller.debugAttachTestTransport(transport.process, sessionID: "acp-session")
        return controller
    }

    private func sendACPOwnerRequest(
        _ controller: ACPAgentSessionController,
        as scope: AgentRuntimeSessionScope?
    ) async throws {
        let send = {
            _ = try await controller.debugSendOwnerRequest(
                method: "session/set_config_option",
                params: ["sessionId": "acp-session", "configId": "mode", "value": "plan"],
                permission: .acp(sessionModeID: "plan", autoApproveAllToolPermissions: false),
                timeoutSeconds: 0.2
            )
        }
        if let scope {
            try await AgentRuntimeOperationOwner.$session.withValue(scope) { try await send() }
        } else {
            try await send()
        }
    }

    /// One frame written, then the fixture never answers: the request times out.
    private func assertWrittenThenTimedOut(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            String(describing: error).hasPrefix("requestTimedOut("),
            "Expected the written request to time out, got \(error)",
            file: file,
            line: line
        )
    }

    /// Step 9-activation-a acceptance 3: under `.claudeAndCodex`, a covered pair's controller
    /// registers (joins retirement, reserves before its spawn, carries the marker); an uncovered
    /// pair (ACP, a Claude-compatible backend, headless GLM) gets no launch owner, no runtime file
    /// and no marker, its controller does not join retirement, and an inherited marker is still
    /// stripped at the managed launch boundary.
    func testUncoveredPairsLaunchUnregisteredUnderClaudeAndCodex() async throws {
        await startRegistry()
        let authority = AgentRuntimeLaunchAuthority.registry(registry)
        func claude(_ variant: ClaudeCodeRuntimeVariant) throws -> ClaudeNativeProcessSessionController {
            try ClaudeNativeProcessSessionController(
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePath: nil,
                config: .agentMode(commandName: "claude", modelString: nil, runtimeVariant: variant, permissionMode: nil),
                mcpHost: ServerNetworkManager.shared,
                launchAuthority: authority
            )
        }
        let acp = try ACPAgentSessionController(
            provider: FixtureACPProvider(),
            runRequest: ACPRunRequest(
                agentKind: .cursor,
                modelString: nil,
                workspacePath: "/tmp/wt-native",
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            ),
            mcpHost: ServerNetworkManager.shared,
            launchAuthority: authority
        )
        XCTAssertTrue(try claude(.standard).joinsRetirementBeforeSuccessor, "Claude Code is covered")
        XCTAssertFalse(try claude(.glm).joinsRetirementBeforeSuccessor, "a compatible backend is not")
        XCTAssertFalse(acp.joinsRetirementBeforeSuccessor, "ACP is not")

        let uncovered: [(AgentRuntimeFamily, AgentRuntimeProvider)] = [
            (.acp, .acp(.cursor)),
            (.claudeCompatible, .claude(.glm)),
            (.claudeHeadless, .claude(.glm))
        ]
        for (family, provider) in uncovered {
            XCTAssertFalse(authority.isRegistrationActive(family: family, provider: provider), "\(family) \(provider)")
            XCTAssertNil(
                authority.makeLaunch(Fixtures.context(family, provider: provider, session: owner, worktreePath: "/tmp/wt-native")),
                "\(family) \(provider) launches unregistered"
            )
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0, "no uncovered pair writes a runtime file")

        // The launch environment of an unregistered spawn: the inherited marker is stripped and,
        // with no launch owner (`runtimeID == nil`), none is added.
        let marker = ProcessLauncher.runtimeMarkerEnvironmentKey
        let inherited = ["PATH": "/usr/bin", marker: UUID().uuidString]
        let unregistered = ProcessLauncher.launchEnvironment(
            AgentRuntimeLaunchAuthority.strippingInheritedMarker(inherited), runtimeID: nil
        )
        XCTAssertNil(unregistered[marker])
        XCTAssertEqual(unregistered["PATH"], "/usr/bin")

        // The covered pair reserves before its spawn and its child carries the reserved marker.
        let covered = try XCTUnwrap(authority.makeLaunch(
            Fixtures.context(.claudeNative, provider: .claude(.standard), session: owner, worktreePath: "/tmp/wt-native")
        ))
        let runtimeID = try await covered.prepareSpawn()
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 1)
        let registered = ProcessLauncher.launchEnvironment(
            AgentRuntimeLaunchAuthority.strippingInheritedMarker(inherited), runtimeID: runtimeID
        )
        XCTAssertEqual(registered[marker], runtimeID.uuidString)
        await covered.spawnFailed()
    }

    func testACPOwnerRequestAssociatesItsPermissionAndWritesOnceOnlyWhenCommitted() async throws {
        await startRegistry(Fixtures.qualified())
        let (launch, runtimeID) = try await committedLaunch(.acp)
        let transport = FixtureTransport()
        let controller = try await makeACP(transport: transport)

        await controller.debugInstallTestRuntimeLaunch(launch, committed: false)
        do {
            try await sendACPOwnerRequest(controller, as: owner)
            XCTFail("An uncommitted transport must not be written")
        } catch {
            assertProcessNotRunning(error)
        }
        await controller.debugInstallTestRuntimeLaunch(launch, committed: true)
        do {
            try await sendACPOwnerRequest(controller, as: nil)
            XCTFail("An owner write without a captured session scope must be refused")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .sessionContextUnavailable)
        }
        XCTAssertTrue(transport.frames.isEmpty)

        do {
            try await sendACPOwnerRequest(controller, as: owner)
            XCTFail("The fixture never answers")
        } catch {
            assertWrittenThenTimedOut(error)
        }
        XCTAssertEqual(transport.frames.map { $0["method"] as? String }, ["session/set_config_option"], "exactly one write")
        guard case let .session(expected) = owner else { return XCTFail("fixture owner") }
        let association = try XCTUnwrap(Fixtures.record(store, runtimeID)?.associations.first { $0.session == expected })
        XCTAssertEqual(association.conversationID, "acp-session")
        XCTAssertEqual(association.permission, .acp(sessionModeID: "plan", autoApproveAllToolPermissions: false))
    }

    func testACPReplacementDuringAnyFenceAwaitGetsZeroBytes() async throws {
        await startRegistry(Fixtures.qualified())
        let original = FixtureTransport()
        let controller = try await makeACP(transport: original)
        for checkpoint in ["launchCaptured", "associated", "authorized"] {
            // A distinct conversation per cut: a suspended write still associates on the launch it
            // captured, so an earlier cut's launch holds its own conversation.
            let conversationID = "acp-\(checkpoint)"
            let (first, _) = try await committedLaunch(.acp)
            let current = FixtureTransport()
            await controller.debugAttachTestTransport(current.process, sessionID: conversationID)
            await controller.debugInstallTestRuntimeLaunch(first, committed: true)
            let gate = InventoryGate()
            await controller.debugSetRuntimeFenceCheckpoint { name in
                guard name == checkpoint else { return }
                await gate.pass()
            }
            // A distinct owner session per cut (R6 same-session rule across live runtimes).
            let owner = AgentRuntimeSessionScope.session(Fixtures.session())
            let send = Task { try await self.sendACPOwnerRequest(controller, as: owner) }
            let arrived = await Fixtures.eventually { await gate.hasArrived }
            XCTAssertTrue(arrived, "the write reached \(checkpoint)")

            let (replacement, replacementID) = try await committedLaunch(.acp)
            let replacementTransport = FixtureTransport()
            await controller.debugAttachTestTransport(replacementTransport.process, sessionID: conversationID)
            await controller.debugInstallTestRuntimeLaunch(replacement, committed: true)
            await gate.open()
            do {
                try await send.value
                XCTFail("A write suspended at \(checkpoint) must not reach the replacement")
            } catch {
                assertProcessNotRunning(error)
            }
            XCTAssertTrue(current.frames.isEmpty, checkpoint)
            XCTAssertTrue(replacementTransport.frames.isEmpty, "zero bytes to the replacement (\(checkpoint))")
            XCTAssertEqual(Fixtures.record(store, replacementID)?.associations.compactMap(\.session), [], checkpoint)
            await controller.debugSetRuntimeFenceCheckpoint(nil)
        }
        XCTAssertTrue(original.frames.isEmpty)
    }

    func testACPPermissionReplyGoesOnlyToItsIssuingTransport() async throws {
        await startRegistry(Fixtures.qualified())
        let (first, _) = try await committedLaunch(.acp)
        let firstPID = nextPID - 1
        let original = FixtureTransport()
        let controller = try await makeACP(transport: original)
        await controller.debugInstallTestRuntimeLaunch(first, committed: true)
        // An owner operation associated the open session; replies only authorize on it.
        try await first.associate(session: owner, conversationID: "acp-session")
        let params: [String: Any] = [
            "sessionId": "acp-session",
            "toolCall": ["toolCallId": "tool-1", "title": "Edit file", "kind": "edit"],
            "options": [["optionId": "allow", "kind": "allow_once"], ["optionId": "reject", "kind": "reject_once"]]
        ]

        await controller.debugHandlePermissionRequest(id: 7, params: params)
        await controller.respondToPermissionRequest(id: "7", decision: .decline)
        XCTAssertEqual(original.frames.count, 1, "a reply on the issuing transport is written once")

        await controller.debugHandlePermissionRequest(id: 8, params: params)
        let (replacement, _) = try await committedLaunch(.acp)
        let replacementTransport = FixtureTransport()
        await controller.debugAttachTestTransport(replacementTransport.process, sessionID: "acp-session-2")
        await controller.debugInstallTestRuntimeLaunch(replacement, committed: true)
        await controller.respondToPermissionRequest(id: "8", decision: .decline)
        XCTAssertEqual(original.frames.count, 1)
        XCTAssertTrue(replacementTransport.frames.isEmpty, "zero bytes to the replacement")

        // The replaced runtime is retired before the replacement serves the same owner session.
        processes.remove(pid: firstPID)
        await first.rootReaped(pid: firstPID, confirmed: true)
        // The stale reply was dropped without failing the replacement's session.
        do {
            try await sendACPOwnerRequest(controller, as: owner)
            XCTFail("The fixture never answers")
        } catch {
            assertWrittenThenTimedOut(error)
        }
        XCTAssertEqual(replacementTransport.frames.count, 1)
    }
}
