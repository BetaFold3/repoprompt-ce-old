@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

/// Remote `start`/`steer` input durability (lossless restart Phase 1b, inactive in production):
/// the delivery attempt is committed before the remote request, a refused/failed commit or a stale
/// target never reaches the bridge, and a host response or an ambiguous bridge failure is never
/// provider acceptance. Real temporary recovery store and DataService gate; fake remote bridge.
@MainActor
final class RemoteAgentDispatchEvidenceTests: XCTestCase {
    private static let hostID = "host-recovery"
    private static let remoteSessionID = "remote-session-recovery"

    private var fixture: RecoveryLaneFixture!
    private var cleanups: [@MainActor () -> Void] = []

    override func setUp() async throws {
        fixture = try await RecoveryLaneFixture.make("RemoteAgentDispatchEvidenceTests")
    }

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() {
            cleanup()
        }
        cleanups = []
        fixture?.tearDown()
        fixture = nil
    }

    private struct Harness {
        let coordinator: RemoteAgentModeCoordinator
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let connection: DispatchRecordingConnection
    }

    private func makeHarness(
        remoteSessionID: String = RemoteAgentDispatchEvidenceTests.remoteSessionID,
        admission: AgentRecoveryAdmissionMode = .mandatory,
        connection: DispatchRecordingConnection = DispatchRecordingConnection()
    ) -> Harness {
        let coordinator = RemoteAgentModeCoordinator()
        let viewModel = AgentModeViewModel(
            testWindowID: 41,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            testRemoteCoordinator: coordinator
        )
        let session = fixture.boundTabSession()
        let binding = AgentSessionRemoteHostBinding(
            hostID: Self.hostID,
            hostDisplayName: "Remote Host",
            remoteSessionID: remoteSessionID
        )
        session.remoteHost = binding
        session.recoveryAdmissionMode = admission
        viewModel.test_installLiveSession(session)
        coordinator.test_installController(
            RemoteAgentSessionController(binding: binding, connection: connection),
            for: session,
            hostID: Self.hostID
        )
        cleanups.append { coordinator.stop(tabID: session.tabID) }
        return Harness(coordinator: coordinator, viewModel: viewModel, session: session, connection: connection)
    }

    private func intent(_ identity: AgentQueuedInputIdentity) async throws -> AgentRecoveryIntent {
        let intent = await fixture.intent(identity)
        return try XCTUnwrap(intent)
    }

    private func attemptCount(_ identity: AgentQueuedInputIdentity) async -> Int {
        let record = await fixture.store.read(sessionID: fixture.sessionID).record
        return record?.attempts.count { $0.intentID == identity.intentID } ?? 0
    }

    /// Makes the recovery sessions directory read-only so every record replacement fails.
    private func makeRecordWritesFail() throws {
        let directory = fixture.store.sessionsDirectoryURL.path
        let original = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        cleanups.append {
            try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: directory)
        }
    }

    private func assertNotHandedOff(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line,
        cause matches: (RemoteInputHandoffError.Cause) -> Bool
    ) -> RemoteInputHandoffError? {
        guard let handoffError = error as? RemoteInputHandoffError else {
            XCTFail("expected RemoteInputHandoffError, got \(error)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(handoffError.disposition, .notHandedOff, file: file, line: line)
        XCTAssertTrue(matches(handoffError.cause), "unexpected cause \(handoffError.cause)", file: file, line: line)
        return handoffError
    }

    // MARK: Durable handoff

    func testDurableStartCommitsDispatchBeforeRequestAndHostResponseIsNotAcceptance() async throws {
        let userItemID = UUID()
        let identity = try await fixture.queuedIdentity("start original", userItemID: userItemID)
        let store = fixture.store
        let sessionID = fixture.sessionID
        let intentID = try XCTUnwrap(identity.intentID)
        let connection = DispatchRecordingConnection(onInputCommand: { _ in
            await store.read(sessionID: sessionID).record?.intent(id: intentID)?.deliveryState.rawValue
        })
        let harness = makeHarness(remoteSessionID: "", connection: connection)

        let evidence = try await harness.coordinator.startRemoteSession(
            session: harness.session,
            message: "start provider text",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil,
            dispatch: RemoteInputDispatch(input: identity)
        )

        let observedAtHandoff = await connection.observedStatesAtInputCommands()
        XCTAssertEqual(
            observedAtHandoff,
            [AgentRecoveryDeliveryState.dispatching.rawValue],
            "dispatch is durable before the start request"
        )
        let startFrames = await connection.frames(type: "start")
        XCTAssertEqual(startFrames.count, 1)
        XCTAssertEqual(startFrames.first?.payload?.objectValue?["message"]?.stringValue, "start provider text")
        XCTAssertTrue(evidence.isDurable)
        XCTAssertEqual(evidence.observation, .deliveryUnknown, "a host start response is not provider acceptance")
        let writeFailures = await evidence.settled()
        XCTAssertEqual(writeFailures, [])
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .deliveryUnknown)
        XCTAssertEqual(stored.userItemID, userItemID, "the original user item is retained")
        XCTAssertEqual(stored.payload, RecoveryTestSupport.content("start original"), "original payload, not provider text")
        let attempts = await attemptCount(identity)
        XCTAssertEqual(attempts, 1)
    }

    func testDurableSteerAmbiguousFailureStaysUnknownAndIsNeverAutomaticallyResent() async throws {
        let userItemID = UUID()
        let identity = try await fixture.queuedIdentity("steer original", userItemID: userItemID)
        let harness = makeHarness(connection: DispatchRecordingConnection(failingCommandTypes: ["steer"]))

        do {
            try await harness.coordinator.steer(
                session: harness.session,
                text: "steer provider text",
                dispatch: RemoteInputDispatch(input: identity)
            )
            XCTFail("the synthetic bridge failure must surface")
        } catch let error as RemoteInputHandoffError {
            XCTAssertEqual(error.disposition, .deliveryUnknown)
            XCTAssertNotNil(error.remoteError as? RemoteClientError)
            XCTAssertEqual(error.evidence?.observation, .deliveryUnknown)
            let writeFailures = await error.evidence?.settled()
            XCTAssertEqual(writeFailures, [])
        }

        var steerCount = await harness.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 1)
        var stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .deliveryUnknown, "ambiguous handoff never becomes retryable")
        XCTAssertEqual(stored.userItemID, userItemID)
        XCTAssertEqual(stored.payload, RecoveryTestSupport.content("steer original"))

        // A live-queue redispatch (automatic resend) is refused before the bridge.
        do {
            try await harness.coordinator.steer(
                session: harness.session,
                text: "steer provider text",
                dispatch: RemoteInputDispatch(input: identity)
            )
            XCTFail("an automatic redispatch of a delivery-unknown intent must be refused")
        } catch {
            _ = assertNotHandedOff(error) { cause in
                if case .dispatchRefused = cause { return true }
                return false
            }
        }
        steerCount = await harness.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 1, "no automatic resend after an ambiguous handoff")
        stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .deliveryUnknown)
    }

    func testExplicitUserResendMayRedispatchADeliveryUnknownIntent() async throws {
        let identity = try await fixture.queuedIdentity("resend original")
        let harness = makeHarness()
        let first = try await harness.coordinator.steer(
            session: harness.session,
            text: "resend provider text",
            dispatch: RemoteInputDispatch(input: identity)
        )
        _ = await first.settled()

        let second = try await harness.coordinator.steer(
            session: harness.session,
            text: "resend provider text",
            dispatch: RemoteInputDispatch(input: identity, authorization: .explicitUserAction)
        )
        let writeFailures = await second.settled()

        XCTAssertEqual(writeFailures, [])
        let steerCount = await harness.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 2)
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .deliveryUnknown)
        let attempts = await attemptCount(identity)
        XCTAssertEqual(attempts, 2, "each explicit resend is its own delivery attempt of the same intent")
    }

    // MARK: Fail-closed before the bridge

    func testDispatchWriteFailureSendsNothingAndKeepsTheSameQueuedIntent() async throws {
        let userItemID = UUID()
        let identity = try await fixture.queuedIdentity("write failure", userItemID: userItemID)
        let harness = makeHarness(remoteSessionID: "")
        try makeRecordWritesFail()

        do {
            try await harness.coordinator.startRemoteSession(
                session: harness.session,
                message: "write failure provider text",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil,
                dispatch: RemoteInputDispatch(input: identity)
            )
            XCTFail("a failed dispatch commit must not hand off")
        } catch {
            let handoffError = assertNotHandedOff(error) { cause in
                if case .dispatchRefused(.commitFailed) = cause { return true }
                return false
            }
            XCTAssertNil(handoffError?.evidence)
        }

        let frameCount = await harness.connection.totalFrameCount()
        XCTAssertEqual(frameCount, 0, "zero network handoff on a failed dispatch write")
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .queued)
        XCTAssertEqual(stored.userItemID, userItemID)
        XCTAssertEqual(stored.payload, RecoveryTestSupport.content("write failure"))
        XCTAssertNotEqual(harness.session.runState, .running, "no optimistic start status without a handoff")
    }

    func testOutcomeWriteFailureAfterHandoffKeepsDurableDispatchingAndReportsIt() async throws {
        let identity = try await fixture.queuedIdentity("outcome write failure")
        let directory = fixture.store.sessionsDirectoryURL.path
        let original = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
        )
        cleanups.append {
            try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: directory)
        }
        // Writes start failing at the moment the steer reaches the bridge (after the dispatch commit).
        let connection = DispatchRecordingConnection(onInputCommand: { _ in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
            return nil
        })
        let harness = makeHarness(connection: connection)

        let evidence = try await harness.coordinator.steer(
            session: harness.session,
            text: "outcome provider text",
            dispatch: RemoteInputDispatch(input: identity)
        )
        let writeFailures = await evidence.settled()

        XCTAssertEqual(evidence.observation, .deliveryUnknown)
        XCTAssertFalse(writeFailures.isEmpty, "the failed outcome write is exposed, never hidden")
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .dispatching, "durable dispatching is preserved; never a retryable draft")
    }

    func testMandatoryAdmissionRefusesUntrackedRemoteInputWithoutNetwork() async throws {
        let harness = makeHarness(admission: .inactive)
        let untracked = AgentQueuedInputIdentity.inactiveForTesting(userItemID: UUID(), in: harness.session)
        harness.session.recoveryAdmissionMode = .mandatory

        do {
            try await harness.coordinator.steer(
                session: harness.session,
                text: "untracked",
                dispatch: RemoteInputDispatch(input: untracked)
            )
            XCTFail("untracked input under mandatory admission must fail closed")
        } catch {
            _ = assertNotHandedOff(error) { cause in
                if case .dispatchRefused(.refused(.untrackedInput)) = cause { return true }
                return false
            }
        }
        let steerCount = await harness.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 0)
    }

    func testRetiredLaneRefusesRemoteDispatchWithoutNetwork() async throws {
        let identity = try await fixture.queuedIdentity("retired")
        let harness = makeHarness(remoteSessionID: "")
        await fixture.coordinator.releaseLane(fixture.lane).value

        do {
            try await harness.coordinator.startRemoteSession(
                session: harness.session,
                message: "retired provider text",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil,
                dispatch: RemoteInputDispatch(input: identity)
            )
            XCTFail("a retired lane must refuse the dispatch")
        } catch {
            _ = assertNotHandedOff(error) { cause in
                if case .dispatchRefused(.refused(.laneRetired)) = cause { return true }
                return false
            }
        }
        let frameCount = await harness.connection.totalFrameCount()
        XCTAssertEqual(frameCount, 0)
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .queued)
    }

    func testTargetGoingStaleDuringDispatchCommitSettlesSameIntentWithoutNetwork() async throws {
        let userItemID = UUID()
        let identity = try await fixture.queuedIdentity("stale target", userItemID: userItemID)
        let harness = makeHarness(remoteSessionID: "")
        let coordinator = harness.coordinator
        let session = harness.session

        let send = Task { @MainActor in
            try await coordinator.startRemoteSession(
                session: session,
                message: "stale provider text",
                modelSelectionRaw: nil,
                sessionName: nil,
                windowID: nil,
                workspaceID: nil,
                workspaceName: nil,
                dispatch: RemoteInputDispatch(input: identity)
            )
        }
        // Runs before the send task's first await resumes: the tab is gone at revalidation.
        harness.viewModel.test_removeLiveSession(tabID: session.tabID)

        do {
            _ = try await send.value
            XCTFail("a stale target must not hand off")
        } catch {
            let handoffError = assertNotHandedOff(error) { cause in
                if case .staleTarget = cause { return true }
                return false
            }
            XCTAssertEqual(handoffError?.evidence?.observation, .notHandedOff)
            let writeFailures = await handoffError?.evidence?.settled()
            XCTAssertEqual(writeFailures, [])
        }

        let frameCount = await harness.connection.totalFrameCount()
        XCTAssertEqual(frameCount, 0, "a stale target holds without network")
        let stored = try await intent(identity)
        XCTAssertEqual(stored.deliveryState, .queued, "proven pre-handoff: the same intent returns to queued")
        XCTAssertEqual(stored.intentID, identity.intentID)
        XCTAssertEqual(stored.userItemID, userItemID)
        XCTAssertEqual(stored.payload, RecoveryTestSupport.content("stale target"))
        XCTAssertNotEqual(session.runState, .running)
    }

    // MARK: Explicit inactive (legacy) mode

    func testInactiveUntrackedSteerWritesNothingAndKeepsLegacyHandoff() async throws {
        let harness = makeHarness(admission: .inactive)
        let revisionBefore = await fixture.store.read(sessionID: fixture.sessionID).record?.revision
        let untracked = AgentQueuedInputIdentity.inactiveForTesting(userItemID: UUID(), in: harness.session)

        let evidence = try await harness.coordinator.steer(
            session: harness.session,
            text: "legacy",
            dispatch: RemoteInputDispatch(input: untracked)
        )

        XCTAssertFalse(evidence.isDurable)
        let steerCount = await harness.connection.commandCount(type: "steer")
        XCTAssertEqual(steerCount, 1)
        let revisionAfter = await fixture.store.read(sessionID: fixture.sessionID).record?.revision
        XCTAssertEqual(revisionAfter, revisionBefore, "untracked input writes nothing")
    }
}

/// Fake remote bridge: records frames, optionally fails input commands, and runs a hook when a
/// `start`/`steer` frame arrives (recording the returned delivery-state raw value, when any).
private actor DispatchRecordingConnection: RemoteAgentSessionConnection {
    typealias InputCommandHook = @Sendable (RemoteClientFrame) async -> String?

    private var recordedFrames: [RemoteClientFrame] = []
    private var observedStates: [String] = []
    private let failingCommandTypes: Set<String>
    private let onInputCommand: InputCommandHook?

    init(failingCommandTypes: Set<String> = [], onInputCommand: InputCommandHook? = nil) {
        self.failingCommandTypes = failingCommandTypes
        self.onInputCommand = onInputCommand
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        recordedFrames.append(frame)
        if frame.type == "start" || frame.type == "steer", let onInputCommand {
            if let state = await onInputCommand(frame) {
                observedStates.append(state)
            }
        }
        if failingCommandTypes.contains(frame.type) {
            throw RemoteClientError.protocolViolation("synthetic delivery failure")
        }
        switch frame.type {
        case "start":
            return .object([
                "status": .string("running"),
                "session_id": .string("remote-started-by-recovery-test")
            ])
        case "get_log":
            return .object([
                "turn_offset": .int(0),
                "turn_limit": .int(20),
                "returned_turn_count": .int(0),
                "total_turns": .int(0),
                "transcript_xml": .string("<transcript/>")
            ])
        default:
            var payload: [String: JSONValue] = ["status": .string("running")]
            if let sessionID = frame.sessionID {
                payload["session_id"] = .string(sessionID)
            }
            return .object(payload)
        }
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func commandCount(type: String) -> Int {
        recordedFrames.count { $0.type == type }
    }

    func totalFrameCount() -> Int {
        recordedFrames.count
    }

    func frames(type: String) -> [RemoteClientFrame] {
        recordedFrames.filter { $0.type == type }
    }

    func observedStatesAtInputCommands() -> [String] {
        observedStates
    }
}
