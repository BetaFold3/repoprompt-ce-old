import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 write fences of the central Codex app-server client with fixture-enabled registration:
/// thread association before resumes and turn/thread writes, association of returned threads,
/// sessionless and multithread requests, uncommitted transports, and stale launches after the root
/// is reaped. Requests run over the DEBUG test transport with a recording frame writer; the
/// registry uses scripted process boundaries. No Codex process is spawned.
final class CodexAppServerRuntimeFenceTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    /// Every outgoing frame, with the runtime's durable conversation IDs at the moment of the write.
    private final class FrameRecorder: @unchecked Sendable {
        struct Frame {
            let method: String?
            let id: Int?
            let conversationIDsAtWrite: [String]
        }

        private let lock = NSLock()
        private var recorded: [Frame] = []
        var conversationIDsProvider: @Sendable () -> [String] = { [] }

        var frames: [Frame] {
            lock.withLock { recorded }
        }

        func record(_ data: Data) {
            let object = (try? JSONSerialization.jsonObject(with: data.filter { $0 != UInt8(ascii: "\n") })) as? [String: Any]
            let frame = Frame(
                method: object?["method"] as? String,
                id: object?["id"] as? Int,
                conversationIDsAtWrite: conversationIDsProvider()
            )
            lock.withLock { recorded.append(frame) }
        }
    }

    private var root: URL!
    private var recoveryRoot: URL!
    private var processes: ScriptedProcessSystem!
    private var store: AgentRecoveryStore!
    private var registry: AgentProcessRegistry!
    private var recorder: FrameRecorder!

    override func setUp() async throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("CodexAppServerRuntimeFenceTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        processes = ScriptedProcessSystem()
        recorder = FrameRecorder()
    }

    override func tearDown() async throws {
        await registry?.disposeWatches()
        registry = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func startRegistry() async {
        store = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        // The production candidate's qualification (D 3.5 item 1: Codex owner operations under it).
        registry = AgentProcessRegistry(
            store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime, system: processes.system
        )
        await registry.start()
    }

    /// The owner-captured session scope thread operations carry in these fixtures.
    private let owner = AgentRuntimeSessionScope.session(AgentProcessRegistryFixtures.session())

    /// A Codex app-server launch whose root (`pid`) is reserved and committed `live`.
    private func committedLaunch(pid: pid_t = 4000, worktreePath: String = "/tmp/wt-codex") async throws -> (AgentRuntimeLaunch, UUID) {
        let launch = try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(
            Fixtures.context(.codexAppServer, worktreePath: worktreePath)
        ))
        let runtimeID = try await launch.prepareSpawn()
        processes.add(processes.observation(pid: pid, executable: "/opt/fixture/bin/codex", group: pid, marker: runtimeID))
        try await launch.commitSpawn(pid: pid, processGroupID: pid)
        let store = store!
        recorder.conversationIDsProvider = { Fixtures.record(store, runtimeID)?.conversationIDs ?? [] }
        return (launch, runtimeID)
    }

    private func makeClient(launch: AgentRuntimeLaunch, committed: Bool = true) async -> CodexAppServerClient {
        let recorder = recorder!
        let client = CodexAppServerClient(
            mcpHost: ServerNetworkManager.shared,
            writeFrameHandler: { _, frame in recorder.record(frame) },
            livenessProbe: { _ in true },
            expectedAgentPIDRegistrar: .init(register: { _, _, _ in }, clear: { _, _, _ in })
        )
        await client.debugInstallTestTransport()
        await client.debugInstallTestRuntimeLaunch(launch, committed: committed)
        return client
    }

    /// Sends `method`, waits for its frame, answers it with `result`, and returns the response.
    private func roundTrip(
        _ client: CodexAppServerClient,
        method: String,
        params: [String: Any],
        result: String = "{}"
    ) async throws -> [String: Any] {
        let before = recorder.frames.count
        let owner = owner
        let task = Task {
            try await client.request(method: method, params: params, timeout: nil, useDefaultTimeout: false, runtimeSession: owner)
        }
        let written = await Fixtures.eventually { self.recorder.frames.count > before }
        guard written, let id = recorder.frames.last?.id else {
            task.cancel()
            XCTFail("Expected a \(method) frame")
            return [:]
        }
        XCTAssertEqual(recorder.frames.last?.method, method)
        await client.debugIngestRawStdoutChunk(Data("{\"id\":\(id),\"result\":\(result)}\n".utf8))
        return try await task.value
    }

    // MARK: Tests

    func testTurnWritesAssociateTheThreadBeforeTheFrameIsWritten() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-1", "input": []])
        XCTAssertEqual(recorder.frames.map(\.conversationIDsAtWrite), [["thread-1"]], "durably associated before the write")
        _ = try await roundTrip(client, method: "turn/steer", params: ["threadId": "thread-1", "input": []])
        _ = try await roundTrip(client, method: "thread/goal/set", params: ["threadId": "thread-1", "goal": "g"])
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, ["thread-1"])
    }

    func testResumeAssociatesBeforeTheRequestAndConflictingThreadsWriteNothing() async throws {
        processes.add(processes.observation(pid: 4100, executable: "/opt/fixture/bin/codex", group: 4100))
        let other = try Fixtures.seed(
            rootURL: recoveryRoot,
            family: .codexAppServer,
            root: processes.identity(pid: 4100),
            rootGroup: 4100,
            conversationIDs: ["thread-taken"]
        )
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        _ = try await roundTrip(client, method: "thread/resume", params: ["threadId": "thread-mine"])
        XCTAssertEqual(recorder.frames.first?.conversationIDsAtWrite, ["thread-mine"])

        for method in ["thread/resume", "turn/start", "thread/name/set"] {
            do {
                _ = try await client.request(
                    method: method,
                    params: ["threadId": "thread-taken"],
                    timeout: nil,
                    useDefaultTimeout: false,
                    runtimeSession: owner
                )
                XCTFail("\(method) on another runtime's thread must be refused")
            } catch {
                XCTAssertEqual(error as? AgentProcessRegistryError, .ownershipConflict(runtimeID: other.runtimeID), method)
            }
        }
        XCTAssertEqual(recorder.frames.count, 1, "refused writes never reach the transport")
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, ["thread-mine"])
    }

    func testCreatedThreadsAreAssociatedFromTheResponseAndSessionlessRequestsPass() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        _ = try await roundTrip(client, method: "model/list", params: [:], result: "{\"data\":[]}")
        XCTAssertEqual(recorder.frames.last?.conversationIDsAtWrite, [], "sessionless requests need no association")

        _ = try await roundTrip(client, method: "thread/start", params: [:], result: "{\"thread\":{\"id\":\"thread-new\"}}")
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, ["thread-new"])

        // One app-server runtime serves several threads (multithread).
        _ = try await roundTrip(client, method: "thread/fork", params: ["threadId": "thread-new"], result: "{\"thread\":{\"id\":\"thread-fork\"}}")
        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-other", "input": []])
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, ["thread-new", "thread-fork", "thread-other"])
    }

    func testUncommittedTransportGenerationWritesNothing() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch()
        let client = await makeClient(launch: launch, committed: false)

        for method in ["model/list", "thread/start"] {
            do {
                _ = try await client.request(method: method, params: [:], timeout: nil, useDefaultTimeout: false, runtimeSession: owner)
                XCTFail("\(method) must not be written before the birth identity is committed")
            } catch {
                guard case .processNotRunning? = error as? CodexAppServerClient.ClientError else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
        }
        XCTAssertTrue(recorder.frames.isEmpty)
    }

    func testReapedLaunchFencesThreadWrites() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)
        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-1", "input": []])

        let requests = await client.subscribeServerRequests()
        var requestIterator = requests.makeAsyncIterator()
        await client.debugIngestRawStdoutChunk(Data(#"{"id":90,"method":"item/commandExecution/requestApproval","params":{}}"#.utf8 + [0x0A]))
        let pendingRequest = await requestIterator.next()
        let pendingReceipt = try XCTUnwrap(pendingRequest?.receipt)

        processes.remove(pid: 4000)
        await launch.rootReaped(pid: 4000, confirmed: true)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.rootReaped, true)
        // Every outgoing operation is authorized against the captured launch: thread writes,
        // sessionless requests (models), thread creation, notifications and replies alike.
        for (method, params) in [
            ("turn/start", ["threadId": "thread-1"]),
            ("turn/steer", ["threadId": "thread-1"]),
            ("thread/goal/clear", ["threadId": "thread-1"]),
            ("model/list", [:]),
            ("thread/start", [:]),
            ("thread/read", ["threadId": "thread-1"])
        ] as [(String, [String: Any])] {
            do {
                _ = try await client.request(
                    method: method,
                    params: params,
                    timeout: nil,
                    useDefaultTimeout: false,
                    runtimeSession: owner
                )
                XCTFail("\(method) through a reaped launch must be refused")
            } catch {
                XCTAssertEqual(error as? AgentProcessRegistryError, .staleLaunch, method)
            }
        }
        do {
            try await client.notify(method: "initialized", params: nil)
            XCTFail("A notification through a reaped launch must be refused")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .staleLaunch)
        }
        do {
            try await client.respondToServerRequest(receipt: pendingReceipt, result: ["decision": "accept"])
            XCTFail("A reply through a reaped launch must be refused")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .staleLaunch)
        }
        XCTAssertEqual(recorder.frames.count, 1)
    }

    func testThreadCreationValidatesSessionContextBeforeTheWrite() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        for method in ["thread/start", "thread/fork"] {
            do {
                // No owner-captured session: the client default scope is `unavailable`.
                _ = try await client.request(method: method, params: ["threadId": "thread-src"], timeout: nil, useDefaultTimeout: false)
                XCTFail("\(method) without session context must be refused before it is written")
            } catch {
                XCTAssertEqual(error as? AgentProcessRegistryError, .sessionContextUnavailable, method)
            }
        }
        XCTAssertTrue(recorder.frames.isEmpty, "no thread is created that could not be associated")
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, [])
    }

    func testThreadRequestsAreWritesByDefaultAndOnlyNamedReadsSkipAssociation() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        // An unlisted method naming a thread is a write: without session context it is refused.
        do {
            _ = try await client.request(
                method: "thread/futureMutation",
                params: ["threadId": "thread-1"],
                timeout: nil,
                useDefaultTimeout: false
            )
            XCTFail("An unlisted thread method must be treated as a write")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .sessionContextUnavailable)
        }
        XCTAssertTrue(recorder.frames.isEmpty)

        // With the owner's session it associates the thread before the write.
        _ = try await roundTrip(client, method: "thread/futureMutation", params: ["threadId": "thread-1"])
        XCTAssertEqual(recorder.frames.last?.conversationIDsAtWrite, ["thread-1"])

        // A named read authorizes the transport only: no session needed, no association created.
        let before = recorder.frames.count
        let read = Task {
            try await client.request(method: "thread/read", params: ["threadId": "thread-unowned"], timeout: nil, useDefaultTimeout: false)
        }
        let written = await Fixtures.eventually { self.recorder.frames.count > before }
        XCTAssertTrue(written)
        let id = try XCTUnwrap(recorder.frames.last?.id)
        await client.debugIngestRawStdoutChunk(Data("{\"id\":\(id),\"result\":{}}\n".utf8))
        _ = try await read.value
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, ["thread-1"])
    }

    func testEachThreadOperationAssociatesItsOwnWorktree() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-a", "cwd": "/tmp/wt-a", "input": []])
        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-b", "cwd": "/tmp/wt-b", "input": []])
        _ = try await roundTrip(
            client,
            method: "thread/start",
            params: ["cwd": "/tmp/wt-c"],
            result: "{\"thread\":{\"id\":\"thread-c\"}}"
        )

        let associations = try XCTUnwrap(Fixtures.record(store, runtimeID)?.associations)
        func worktrees(_ thread: String) -> Set<String?> {
            Set(associations.filter { $0.conversationID == thread }.map(\.worktreePath))
        }
        XCTAssertEqual(worktrees("thread-a"), ["/tmp/wt-a"])
        XCTAssertEqual(worktrees("thread-b"), ["/tmp/wt-b"], "never the transport's or another thread's worktree")
        XCTAssertEqual(worktrees("thread-c"), ["/tmp/wt-c"], "a created thread carries its creating operation's worktree")
    }

    // MARK: Owner capture and replacement cuts

    /// Replaces the transport and launch (a fresh committed `live` launch on a new generation)
    /// while a request is suspended at `checkpoint`; the request must give the replacement zero
    /// bytes and no association.
    private func assertReplacementAtCheckpointGetsZeroBytes(
        _ checkpoint: String,
        method: String,
        params: [String: Any],
        pids: (first: pid_t, replacement: pid_t),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> CodexAppServerClient {
        recorder = FrameRecorder()
        // A distinct worktree per cut: an earlier cut's runtimes never restrict this one.
        let worktreePath = "/tmp/wt-codex-\(pids.first)"
        let (first, _) = try await committedLaunch(pid: pids.first, worktreePath: worktreePath)
        let client = await makeClient(launch: first)
        let gate = InventoryGate()
        await client.debugSetRuntimeFenceCheckpoint { name in
            guard name == checkpoint else { return }
            await gate.pass()
        }
        // A distinct owner session per cut: a suspended write still associates on the launch it
        // captured, and one session is never served by two live runtimes (R6 same-session rule).
        let owner = AgentRuntimeSessionScope.session(Fixtures.session())
        let request = Task {
            try await client.request(method: method, params: params, timeout: nil, useDefaultTimeout: false, runtimeSession: owner)
        }
        let arrived = await Fixtures.eventually { await gate.hasArrived }
        XCTAssertTrue(arrived, "\(method) reached \(checkpoint)", file: file, line: line)

        // The replacement: a new transport generation and a new committed launch.
        let (replacement, replacementID) = try await committedLaunch(pid: pids.replacement, worktreePath: worktreePath)
        await client.debugInstallTestTransport()
        await client.debugInstallTestRuntimeLaunch(replacement, committed: true)
        await gate.open()

        do {
            _ = try await request.value
            XCTFail("\(method) suspended at \(checkpoint) must not reach the replacement", file: file, line: line)
        } catch {
            if case .processNotRunning? = error as? CodexAppServerClient.ClientError {} else {
                XCTFail("Unexpected error \(error)", file: file, line: line)
            }
        }
        XCTAssertTrue(recorder.frames.isEmpty, "zero bytes to the replacement (\(checkpoint))", file: file, line: line)
        XCTAssertEqual(Fixtures.record(store, replacementID)?.conversationIDs, [], "no association on the replacement", file: file, line: line)

        // The replacement itself still serves its own new requests.
        await client.debugSetRuntimeFenceCheckpoint(nil)
        _ = try await roundTrip(client, method: "model/list", params: [:], result: "{\"data\":[]}")
        XCTAssertEqual(recorder.frames.map(\.method), ["model/list"], file: file, line: line)
        return client
    }

    func testReplacementDuringTheFirstAwaitReceivesZeroBytes() async throws {
        await startRegistry()
        // Clients stay alive for the whole test (a released client's teardown would reap its launch).
        var clients: [CodexAppServerClient] = []
        // Before the first await: the transport is captured; the replacement arrives in that await.
        try await clients.append(assertReplacementAtCheckpointGetsZeroBytes(
            "ownerCaptured",
            method: "turn/start",
            params: ["threadId": "thread-1", "input": []],
            pids: (4200, 4201)
        ))
        try await clients.append(assertReplacementAtCheckpointGetsZeroBytes(
            "ownerCaptured",
            method: "model/list",
            params: [:],
            pids: (4202, 4203)
        ))
        // After the association await, before the final synchronous write.
        try await clients.append(assertReplacementAtCheckpointGetsZeroBytes(
            "associated",
            method: "turn/start",
            params: ["threadId": "thread-2", "input": []],
            pids: (4204, 4205)
        ))
        try await clients.append(assertReplacementAtCheckpointGetsZeroBytes(
            "associated",
            method: "thread/resume",
            params: ["threadId": "thread-3"],
            pids: (4206, 4207)
        ))
        XCTAssertEqual(clients.count, 4)
    }

    func testOwnerlessThreadWritesAreRefusedAndInterruptsOnlyAuthorize() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch()
        let client = await makeClient(launch: launch)

        // No owner-captured session (the client default is `unavailable`): refused, nothing written.
        do {
            _ = try await client.request(method: "turn/start", params: ["threadId": "thread-1", "input": []], timeout: nil, useDefaultTimeout: false)
            XCTFail("An Agent Mode write without session context must be refused")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .sessionContextUnavailable)
        }
        XCTAssertTrue(recorder.frames.isEmpty)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, [])

        // An interrupt (a callback) never associates: refused on a thread no owner associated.
        do {
            _ = try await client.request(method: "turn/interrupt", params: ["threadId": "thread-x"], timeout: nil, useDefaultTimeout: false)
            XCTFail("An interrupt must not create ownership")
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, .ownershipConflict(runtimeID: nil))
        }
        XCTAssertTrue(recorder.frames.isEmpty)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.conversationIDs, [])

        _ = try await roundTrip(client, method: "turn/start", params: ["threadId": "thread-1", "input": []])
        let associationsBefore = Fixtures.record(store, runtimeID)?.associations
        // Authorized on the owner's associated thread, with no session of its own.
        let before = recorder.frames.count
        let interrupt = Task {
            try await client.request(method: "turn/interrupt", params: ["threadId": "thread-1"], timeout: nil, useDefaultTimeout: false)
        }
        let written = await Fixtures.eventually { self.recorder.frames.count > before }
        XCTAssertTrue(written)
        let id = try XCTUnwrap(recorder.frames.last?.id)
        XCTAssertEqual(recorder.frames.last?.method, "turn/interrupt")
        await client.debugIngestRawStdoutChunk(Data("{\"id\":\(id),\"result\":{}}\n".utf8))
        _ = try await interrupt.value
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.associations, associationsBefore, "the interrupt changed no association")
    }

    private func assertProcessNotRunning(
        _ operation: () async throws -> Void,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail(message, file: file, line: line)
        } catch {
            guard case .processNotRunning? = error as? CodexAppServerClient.ClientError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
        }
    }

    func testServerRequestRepliesGoOnlyToTheIssuingTransport() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch()
        let client = await makeClient(launch: launch)
        let requests = await client.subscribeServerRequests()
        var iterator = requests.makeAsyncIterator()

        await client.debugIngestRawStdoutChunk(Data(#"{"id":77,"method":"item/commandExecution/requestApproval","params":{}}"#.utf8 + [0x0A]))
        let firstRequest = await iterator.next()
        let first = try XCTUnwrap(firstRequest?.receipt)
        try await client.respondToServerRequest(receipt: first, result: ["decision": "decline"])
        XCTAssertEqual(recorder.frames.count, 1, "a reply on the issuing transport is written once")
        await assertProcessNotRunning(
            { try await client.respondToServerRequest(receipt: first, result: ["decision": "decline"]) },
            "a receipt is answered at most once"
        )

        await client.debugIngestRawStdoutChunk(Data(#"{"id":77,"method":"item/commandExecution/requestApproval","params":{}}"#.utf8 + [0x0A]))
        let staleRequest = await iterator.next()
        let stale = try XCTUnwrap(staleRequest?.receipt)
        let (replacement, _) = try await committedLaunch(pid: 4001)
        await client.debugInstallTestTransport()
        await client.debugInstallTestRuntimeLaunch(replacement, committed: true)
        // The replacement issues its own request reusing wire ID 77.
        await client.debugIngestRawStdoutChunk(Data(#"{"id":77,"method":"item/commandExecution/requestApproval","params":{}}"#.utf8 + [0x0A]))
        let reusedRequest = await iterator.next()
        let reused = try XCTUnwrap(reusedRequest?.receipt)
        XCTAssertEqual(stale.id, reused.id)
        XCTAssertNotEqual(stale, reused, "the receipt carries the issuing transport generation")

        await assertProcessNotRunning(
            { try await client.respondToServerRequest(receipt: stale, result: ["decision": "accept"]) },
            "a reply to the replaced transport's request must not reach the replacement, even with a reused wire ID"
        )
        await assertProcessNotRunning(
            { try await client.respondToServerRequest(id: .int(77), result: ["decision": "accept"]) },
            "a registered transport refuses a wire-ID-only reply"
        )
        await assertProcessNotRunning(
            { try await client.respondToServerRequestError(id: .int(77), message: "wire id only") },
            "a registered transport refuses a wire-ID-only error reply"
        )
        let neverIssued = CodexServerRequestReceipt(clientInstanceID: reused.clientInstanceID, transportGeneration: reused.transportGeneration, id: .int(79))
        await assertProcessNotRunning(
            { try await client.respondToServerRequestError(receipt: neverIssued, message: "never issued") },
            "a reply to a request this transport never issued must be refused"
        )
        XCTAssertEqual(recorder.frames.count, 1, "zero bytes to the replacement from stale or unrouted replies")

        try await client.respondToServerRequest(receipt: reused, result: ["decision": "decline"])
        XCTAssertEqual(recorder.frames.count, 2, "the replacement's own request is answered on it")
    }

    // MARK: Lossless-restart Phase 4 cold recovery observation

    /// A registered client (registry launch authority) whose start installs the DEBUG test transport
    /// with `launch`, advancing the transport generation exactly as a real start does; no spawn.
    private func makeColdRegisteredClient(startingWith launch: AgentRuntimeLaunch) async -> CodexAppServerClient {
        let recorder = recorder!
        let client = CodexAppServerClient(
            mcpHost: ServerNetworkManager.shared,
            writeFrameHandler: { _, frame in recorder.record(frame) },
            livenessProbe: { _ in true },
            expectedAgentPIDRegistrar: .init(register: { _, _, _ in }, clear: { _, _, _ in }),
            launchAuthority: .registry(registry)
        )
        await client.debugSetStartupOverride { client in
            await client.debugInstallTestTransport()
            await client.debugInstallTestRuntimeLaunch(launch, committed: true)
        }
        return client
    }

    private func makeObservationController(client: CodexAppServerClient) -> CodexNativeSessionController {
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/wt-codex",
            options: CodexNativeSessionController.Options(
                requestTimeout: 5,
                configOverridesProvider: { [:] },
                launchEnvironmentProvider: { [:] },
                approvalPolicyProvider: { .never },
                sandboxModeProvider: { .readOnly },
                approvalReviewerProvider: { .user },
                authTokensRefreshHandler: nil
            )
        )
        controller.useOwnerCapturedRuntimeSessions()
        return controller
    }

    /// Cold path through the real observation: the registered transport is started first (its
    /// generation advances), the expected thread is associated with that runtime for the owner's
    /// session before the read's frame, and only `thread/turns/list` is written. The first cold read
    /// is attributed to the started generation, not rejected as stale.
    func testColdRecoveryObservationStartsTheRegisteredTransportBeforeCapturingItsGeneration() async throws {
        await startRegistry()
        let (launch, runtimeID) = try await committedLaunch(pid: 4300)
        let client = await makeColdRegisteredClient(startingWith: launch)
        let controller = makeObservationController(client: client)
        let generationBeforeStart = await client.currentTransportGeneration()
        let processRunningBeforeStart = await client.debugIsProcessRunning()
        XCTAssertFalse(processRunningBeforeStart, "cold: no transport before the observation")

        let owner = owner
        let observing = Task {
            try await AgentRuntimeOperationOwner.$session.withValue(owner) {
                try await controller.observeRecovery(threadID: "thread-r", expectedTurnID: "turn-r", timeout: nil)
            }
        }
        let written = await Fixtures.eventually { self.recorder.frames.count == 1 }
        XCTAssertTrue(written)
        let frame = try XCTUnwrap(recorder.frames.first)
        XCTAssertEqual(frame.method, "thread/turns/list")
        XCTAssertEqual(frame.conversationIDsAtWrite, ["thread-r"], "associated with the started runtime before the read")
        let id = try XCTUnwrap(frame.id)
        await client.debugIngestRawStdoutChunk(Data(
            #"{"id":\#(id),"result":{"data":[{"id":"turn-r","status":"completed","items":[{"id":"i1","type":"agentMessage","text":"done"}]}]}}"#.utf8 + [0x0A]
        ))
        let observation = try await observing.value

        XCTAssertEqual(observation.terminal, .completed)
        XCTAssertEqual(observation.turnID, "turn-r")
        XCTAssertEqual(observation.items, [.init(nativeItemID: "i1", kind: .agentMessage, text: "done")])
        XCTAssertEqual(observation.source, .turnsList)
        XCTAssertEqual(observation.transportGeneration, generationBeforeStart + 1, "captured after the start")
        XCTAssertEqual(recorder.frames.map(\.method), ["thread/turns/list"], "no resume, start, steer or interrupt")
        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.conversationIDs, ["thread-r"])
        guard case let .session(expected) = owner else { return XCTFail("fixture owner is a session scope") }
        XCTAssertTrue(record.associations.contains { $0.session == expected && $0.conversationID == "thread-r" })
        await client.stop()
    }

    /// A transport replaced during the read is stale: no `thread/read` fallback (even on an
    /// unsupported-method reply from the replaced transport) and no retry.
    func testRecoveryObservationIsStaleWhenTheTransportIsReplacedMidRead() async throws {
        await startRegistry()
        let (launch, _) = try await committedLaunch(pid: 4310)
        let client = await makeColdRegisteredClient(startingWith: launch)
        let controller = makeObservationController(client: client)
        let owner = owner
        let observing = Task {
            try await AgentRuntimeOperationOwner.$session.withValue(owner) {
                try await controller.observeRecovery(threadID: "thread-s", expectedTurnID: "turn-s", timeout: nil)
            }
        }
        let written = await Fixtures.eventually { self.recorder.frames.count == 1 }
        XCTAssertTrue(written)
        let id = try XCTUnwrap(recorder.frames.first?.id)
        await client.debugInstallTestTransport()
        await client.debugIngestRawStdoutChunk(Data(
            #"{"id":\#(id),"error":{"code":-32601,"message":"Method not found: thread/turns/list"}}"#.utf8 + [0x0A]
        ))

        do {
            _ = try await observing.value
            XCTFail("a replaced transport's reply is never attributed")
        } catch {
            XCTAssertEqual(error as? CodexRecoveryObservationError, .staleTransportGeneration)
        }
        XCTAssertEqual(recorder.frames.map(\.method), ["thread/turns/list"], "no fallback read and no retry")
        await client.stop()
    }
}
