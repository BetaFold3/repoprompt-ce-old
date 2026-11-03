import Darwin
import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// Lossless-restart Step 11 ("quiet by default"): O49 ACP Stop evidence, the O51 one-time
/// settlement of ordinary-exit `deliveryUnknown` intents, and O50 wording by exit kind. The Claude
/// steer/Stop route tests live with the other Claude handoff tests (`AgentProviderHandoffTests`).
@MainActor
final class AgentDeliveryQuietByDefaultTests: XCTestCase {
    // MARK: O49 ACP Stop

    /// A stdin/stdout/stderr pipe set standing in for a spawned child (no process exists; the
    /// controller is never shut down, so nothing is signalled).
    private final class FixtureTransport: @unchecked Sendable {
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
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
    }

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

        /// Every agent message chunk is model content.
        func normalizeSessionUpdate(_ update: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            guard update["sessionUpdate"] as? String == "agent_message_chunk" else { return [] }
            return [.stream(AIStreamResult(type: "content", text: "hi"))]
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

    /// Drives one written ACP prompt that fails with the transport closing (RepoPrompt's own
    /// teardown), optionally after the agent streamed content and/or RepoPrompt sent `session/cancel`.
    /// Returns the controller's evidence for the failed prompt.
    private func promptFailureEvidence(
        agentStreamed: Bool,
        repoPromptCancelled: Bool,
        teardownRequestedBeforePrompt: Bool = false,
        teardownRequested: Bool = false
    ) async throws -> Bool {
        let transport = FixtureTransport()
        let controller = try await makeACP(transport: transport)
        if teardownRequestedBeforePrompt {
            controller.noteRepoPromptTeardownRequested()
        }
        let observation = ACPPromptWriteObservation()
        let prompt = startPrompt(controller, observation: observation)
        try await waitForActivePrompt(controller)
        if agentStreamed {
            await streamAgentChunk(controller)
        }
        if teardownRequested {
            controller.noteRepoPromptTeardownRequested()
        }
        if repoPromptCancelled {
            await controller.cancelPrompt()
        }
        await controller.debugFailPendingRequestsAsTransportClosed()
        await expectFailure(prompt)
        return observation.failedAfterAgentReceipt
    }

    private func startPrompt(
        _ controller: ACPAgentSessionController,
        observation: ACPPromptWriteObservation
    ) -> Task<Void, Error> {
        Task {
            try await controller.prompt(
                AgentMessage(userMessage: "hello"),
                onSubmitted: observation.onSubmitted,
                onFailure: observation.onFailure
            )
        }
    }

    private func waitForActivePrompt(_ controller: ACPAgentSessionController) async throws {
        var active = false
        for _ in 0 ..< 300 {
            active = await controller.debugHasActivePromptTurn()
            if active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(active, "The prompt is written and awaiting its response")
    }

    private func streamAgentChunk(_ controller: ACPAgentSessionController) async {
        await controller.debugHandleSessionUpdate(params: [
            "sessionId": "acp-session",
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hi"]]
        ])
    }

    private func expectFailure(_ prompt: Task<Void, Error>) async {
        do {
            try await prompt.value
            XCTFail("The prompt fails when the transport closes")
        } catch {}
    }

    /// Two written prompts whose requests are both pending: the older one stopped being active
    /// before the newer one started. Each prompt's failure reports only its own evidence.
    private func interleavedPromptEvidence(
        olderStartedAndCancelled: Bool,
        newerStartedAndCancelled: Bool,
        teardownRequestedWhileNewerActive: Bool = false
    ) async throws -> (older: Bool, newer: Bool) {
        let transport = FixtureTransport()
        let controller = try await makeACP(transport: transport)
        let older = ACPPromptWriteObservation()
        let olderPrompt = startPrompt(controller, observation: older)
        try await waitForActivePrompt(controller)
        if olderStartedAndCancelled {
            await streamAgentChunk(controller)
            await controller.cancelPrompt()
        }
        await controller.debugAbandonActivePromptTurn()

        let newer = ACPPromptWriteObservation()
        let newerPrompt = startPrompt(controller, observation: newer)
        try await waitForActivePrompt(controller)
        XCTAssertTrue(newer.wasWritten)
        if newerStartedAndCancelled {
            // From the newer prompt or, equally, delayed output of the older one: the session
            // update carries no prompt identity.
            await streamAgentChunk(controller)
            await controller.cancelPrompt()
        }
        if teardownRequestedWhileNewerActive {
            controller.noteRepoPromptTeardownRequested()
        }
        await controller.debugFailPendingRequestsAsTransportClosed()
        await expectFailure(olderPrompt)
        await expectFailure(newerPrompt)
        return (older.failedAfterAgentReceipt, newer.failedAfterAgentReceipt)
    }

    /// O49 (ACP Stop): the agent started the turn and RepoPrompt's own Stop sent `session/cancel`
    /// before tearing the transport down: the written prompt was received.
    func testACPPromptCancelledByRepoPromptAfterTheAgentStartedIsEvidenceOfReceipt() async throws {
        let evidence = try await promptFailureEvidence(agentStreamed: true, repoPromptCancelled: true)
        XCTAssertTrue(evidence)
    }

    /// Without RepoPrompt's cancel, or before the agent produced anything, a failed written prompt
    /// stays uncertain.
    func testACPPromptFailureWithoutCancelOrWithoutAgentOutputIsNotEvidence() async throws {
        let noCancel = try await promptFailureEvidence(agentStreamed: true, repoPromptCancelled: false)
        XCTAssertFalse(noCancel, "A transport loss RepoPrompt did not request is not acceptance")
        let notStarted = try await promptFailureEvidence(agentStreamed: false, repoPromptCancelled: true)
        XCTAssertFalse(notStarted, "A cancel before the agent produced output proves nothing")
    }

    /// G1: a prompt that starts while another is still outstanding fences both. Output is credited
    /// to whichever prompt is active, so neither prompt's evidence is attributable and neither ever
    /// reports receipt, whatever was streamed, cancelled or torn down.
    func testOverlappingPromptsAreFencedAndNeverReportReceipt() async throws {
        let lend = try await interleavedPromptEvidence(olderStartedAndCancelled: false, newerStartedAndCancelled: true)
        XCTAssertFalse(lend.older, "The newer prompt's evidence is not lent to the older one")
        XCTAssertFalse(lend.newer, "Output while two prompts are outstanding is not the newer one's")

        let reset = try await interleavedPromptEvidence(olderStartedAndCancelled: true, newerStartedAndCancelled: false)
        XCTAssertFalse(reset.older, "An overlapped prompt's evidence is no longer attributable")
        XCTAssertFalse(reset.newer)

        let torn = try await interleavedPromptEvidence(
            olderStartedAndCancelled: true,
            newerStartedAndCancelled: true,
            teardownRequestedWhileNewerActive: true
        )
        XCTAssertFalse(torn.older)
        XCTAssertFalse(torn.newer, "A teardown does not lift the overlap fence")
    }

    /// G1: prompt A is written and pending with no output; B starts behind it; A's delayed output
    /// arrives while B is active, and RepoPrompt cancels. B never began, so it must not report
    /// receipt, and neither does A.
    func testDelayedOlderPromptOutputNeverStartsAQueuedNewerPrompt() async throws {
        let transport = FixtureTransport()
        let controller = try await makeACP(transport: transport)
        let promptA = ACPPromptWriteObservation()
        let taskA = startPrompt(controller, observation: promptA)
        try await waitForActivePrompt(controller)
        await controller.debugAbandonActivePromptTurn()

        let promptB = ACPPromptWriteObservation()
        let taskB = startPrompt(controller, observation: promptB)
        try await waitForActivePrompt(controller)
        XCTAssertTrue(promptB.wasWritten)
        // A's delayed chunk: indistinguishable from B's own output.
        await streamAgentChunk(controller)
        await controller.cancelPrompt()
        controller.noteRepoPromptTeardownRequested()
        await controller.debugFailPendingRequestsAsTransportClosed()
        await expectFailure(taskA)
        await expectFailure(taskB)
        XCTAssertFalse(promptB.failedAfterAgentReceipt, "A queued prompt is not accepted on another prompt's output")
        XCTAssertFalse(promptA.failedAfterAgentReceipt)
    }

    /// G5: RepoPrompt's own Stop, window close or quit, recorded synchronously before the run task
    /// is cancelled, is evidence for a started prompt that fails before any `session/cancel` is
    /// written. A teardown requested before the prompt started, or a started prompt without
    /// output, is not.
    func testRepoPromptTeardownRequestedBeforeCancelIsEvidenceForAStartedPrompt() async throws {
        let torn = try await promptFailureEvidence(agentStreamed: true, repoPromptCancelled: false, teardownRequested: true)
        XCTAssertTrue(torn, "Stop/quit before the run task is cancelled: the started prompt was received")
        let earlier = try await promptFailureEvidence(
            agentStreamed: true,
            repoPromptCancelled: false,
            teardownRequestedBeforePrompt: true
        )
        XCTAssertFalse(earlier, "A teardown requested before this prompt started is not its teardown")
        let silent = try await promptFailureEvidence(agentStreamed: false, repoPromptCancelled: false, teardownRequested: true)
        XCTAssertFalse(silent, "Without output for the prompt a teardown proves nothing")
    }

    // MARK: O51 one-time settlement

    private struct Seed {
        let intent: AgentRecoveryIntent
        let attempts: [AgentRecoveryAttempt]
        let runAttempts: [AgentRecoveryRunAttempt]
    }

    private static let earlierLaunch = UUID()

    private func seed(
        terminal: (AgentSessionRunState, AgentRunTerminalCause?)?,
        shutdown: AgentRecoveryShutdownReason? = nil,
        outcome: AgentRecoveryDeliveryOutcome? = .deliveryUnknown,
        state: AgentRecoveryDeliveryState = .deliveryUnknown
    ) -> Seed {
        let intentID = UUID()
        let userItemID = UUID()
        let run = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: UUID(),
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10),
            appInstanceID: Self.earlierLaunch,
            terminal: terminal.map {
                AgentRecoveryRunTerminalEvidence(
                    commitID: UUID(),
                    terminalState: $0.0,
                    expectedRunID: nil,
                    recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 20),
                    cause: $0.1
                )
            },
            shutdown: shutdown.map {
                AgentRecoveryRunShutdownEvidence(
                    reason: $0,
                    observedAt: AgentRecoveryTimestamp(millisecondsSince1970: 20),
                    lastConfirmedActivityAt: nil
                )
            }
        )
        let attempt = AgentRecoveryAttempt(
            attemptID: UUID(),
            intentID: intentID,
            userItemID: userItemID,
            runAttemptID: run.runAttemptID,
            transcriptTurnID: run.transcriptTurnID,
            appInstanceID: Self.earlierLaunch,
            dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 11),
            outcome: outcome.map { AgentRecoveryAttemptOutcome(outcome: $0, recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 19)) }
        )
        let intent = AgentRecoveryIntent(
            intentID: intentID,
            userItemID: userItemID,
            origin: .composer,
            target: .session,
            createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 9),
            appInstanceID: Self.earlierLaunch,
            transcriptResetGeneration: 0,
            deliveryState: state,
            payload: RecoveryTestSupport.content("payload"),
            scheduleReference: nil
        )
        return Seed(intent: intent, attempts: [attempt], runAttempts: [run])
    }

    @discardableResult
    private func write(_ seeds: [Seed], sessionID: UUID = UUID(), store: AgentRecoveryStore) throws -> AgentRecoveryRecord {
        let record = AgentRecoveryRecord(
            sessionID: sessionID,
            revision: .make(),
            incarnationID: UUID(),
            transcriptResetGeneration: 0,
            updatedAt: AgentRecoveryTimestamp(millisecondsSince1970: 30),
            composer: nil,
            intents: seeds.map(\.intent),
            attempts: seeds.flatMap(\.attempts),
            runAttempts: seeds.flatMap(\.runAttempts)
        )
        try FileManager.default.createDirectory(at: store.sessionsDirectoryURL, withIntermediateDirectories: true)
        try AgentRecoveryRecordCodec.encode(record).write(to: store.recordFileURL(sessionID: sessionID))
        return record
    }

    private func makeStore(_ name: String) throws -> (root: URL, store: AgentRecoveryStore) {
        let root = try RecoveryTestSupport.makeTemporaryRoot(name)
        let store = AgentRecoveryStore(rootURL: Self.recoveryRoot(root))
        return (root, store)
    }

    private static func recoveryRoot(_ root: URL) -> URL {
        root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
    }

    func testOrdinaryExitIntentsSettleOnceWithTheirReasonAndEverythingElseIsUntouched() async throws {
        let (root, store) = try makeStore("o51-settle")
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = seed(terminal: (.completed, .ordinary))
        let cancelled = seed(terminal: (.cancelled, .ordinary))
        let untouched: [String: Seed] = [
            "crash (no terminal)": seed(terminal: nil),
            "userCancel": seed(terminal: (.cancelled, .userCancel)),
            "appQuit": seed(terminal: (.cancelled, .appQuit)),
            "providerProcessLost": seed(terminal: (.failed, .providerProcessLost)),
            "legacy cause": seed(terminal: (.cancelled, nil)),
            "failed ordinary": seed(terminal: (.failed, .ordinary)),
            "shutdown evidence": seed(terminal: (.cancelled, .ordinary), shutdown: .appQuit),
            "dispatching (open attempt)": seed(terminal: (.cancelled, .ordinary), outcome: nil, state: .dispatching),
            "no attempt": Seed(intent: seed(terminal: (.cancelled, .ordinary)).intent, attempts: [], runAttempts: [])
        ]
        let sessionID = UUID()
        try write([completed, cancelled] + untouched.values, sessionID: sessionID, store: store)
        let crashOnly = seed(terminal: nil)
        let crashSessionID = UUID()
        try write([crashOnly], sessionID: crashSessionID, store: store)
        let crashBytes = try Data(contentsOf: store.recordFileURL(sessionID: crashSessionID))

        let result = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(result.ran)
        XCTAssertEqual(Set(result.settledIntentIDs), [completed.intent.intentID, cancelled.intent.intentID])
        XCTAssertTrue(result.failedSessionIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.ordinaryExitSettlementMarkerURL.path))

        guard case let .supported(record) = await store.read(sessionID: sessionID) else {
            return XCTFail("The settled record reads back")
        }
        for settled in [completed, cancelled] {
            let intent = try XCTUnwrap(record.intent(id: settled.intent.intentID))
            XCTAssertEqual(intent.deliveryState, .providerAccepted)
            guard case let .object(fact)? = intent.extras[AgentRecoveryStore.ordinaryExitSettlementExtrasKey] else {
                return XCTFail("The intent records why it was settled")
            }
            XCTAssertEqual(fact["reason"], .string(AgentRecoveryStore.ordinaryExitSettlementReason))
            XCTAssertNotNil(fact["recordedAt"])
            let attempt = try XCTUnwrap(record.attempts.first { $0.intentID == settled.intent.intentID })
            XCTAssertEqual(attempt.outcome?.outcome, .providerAccepted)
            XCTAssertEqual(attempt.outcome?.extras["settledBy"], .string(AgentRecoveryStore.ordinaryExitSettlementReason))
            XCTAssertEqual(attempt.supersededOutcome?.outcome, .deliveryUnknown, "The earlier evidence is kept")
            XCTAssertEqual(record.runAttempt(id: settled.runAttempts[0].runAttemptID), settled.runAttempts[0])
        }
        for (reason, seed) in untouched {
            XCTAssertEqual(record.intent(id: seed.intent.intentID), seed.intent, reason)
            XCTAssertEqual(record.attempts.filter { $0.intentID == seed.intent.intentID }, seed.attempts, reason)
        }
        let crashBytesAfter = try Data(contentsOf: store.recordFileURL(sessionID: crashSessionID))
        XCTAssertEqual(crashBytesAfter, crashBytes, "A record with nothing qualifying is never rewritten")
    }

    func testSettlementIsOneTimeAndASecondLaunchIsANoOp() async throws {
        let (root, store) = try makeStore("o51-once")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = seed(terminal: (.cancelled, .ordinary))
        let sessionID = UUID()
        try write([first], sessionID: sessionID, store: store)
        let firstPass = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertEqual(firstPass.settledIntentIDs, [first.intent.intentID])
        let settledBytes = try Data(contentsOf: store.recordFileURL(sessionID: sessionID))

        // A later launch: the marker ends the pass, even for newly recorded qualifying uncertainty.
        let laterLaunch = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID())
        let later = seed(terminal: (.completed, .ordinary))
        let laterSessionID = UUID()
        try write([later], sessionID: laterSessionID, store: laterLaunch)
        let laterBytes = try Data(contentsOf: laterLaunch.recordFileURL(sessionID: laterSessionID))
        let secondPass = await laterLaunch.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertFalse(secondPass.ran)
        XCTAssertTrue(secondPass.completed)
        XCTAssertTrue(secondPass.settledIntentIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.recordFileURL(sessionID: sessionID)), settledBytes)
        XCTAssertEqual(try Data(contentsOf: laterLaunch.recordFileURL(sessionID: laterSessionID)), laterBytes)
    }

    // MARK: O51 failure paths (F5)

    /// Fails marker or record writes on demand; everything else is the live implementation.
    private final class FaultInjection: @unchecked Sendable {
        private let lock = NSLock()
        private var failInProgressMarker = false
        private var failCompletionMarker = false
        private var failRecordWrites = false

        func set(inProgressMarker: Bool = false, completionMarker: Bool = false, recordWrites: Bool = false) {
            lock.withLock {
                failInProgressMarker = inProgressMarker
                failCompletionMarker = completionMarker
                failRecordWrites = recordWrites
            }
        }

        var fileOperations: AgentRecoveryStore.FileOperations {
            AgentRecoveryStore.FileOperations(
                writeAtomically: { [self] data, url in
                    if url.lastPathComponent == "ordinary-exit-settlement.json" {
                        let completed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["completed"] as? Bool
                        let fail = lock.withLock { completed == true ? failCompletionMarker : failInProgressMarker }
                        if fail { throw CocoaError(.fileWriteUnknown) }
                    } else if url.deletingLastPathComponent().lastPathComponent == "sessions" {
                        if lock.withLock({ failRecordWrites }) { throw CocoaError(.fileWriteUnknown) }
                    }
                    try AgentRecoveryStore.FileOperations.live.writeAtomically(data, url)
                },
                removeItem: AgentRecoveryStore.FileOperations.live.removeItem
            )
        }
    }

    private func marker(_ store: AgentRecoveryStore) throws -> (cutoffMs: Int64, completed: Bool)? {
        guard let data = try? Data(contentsOf: store.ordinaryExitSettlementMarkerURL) else { return nil }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try (
            XCTUnwrap((object["cutoffMs"] as? NSNumber)?.int64Value),
            XCTUnwrap(object["completed"] as? Bool)
        )
    }

    /// A seed whose only attempt was dispatched at `dispatchedAtMs`.
    private func seed(dispatchedAtMs: Int64) -> Seed {
        let base = seed(terminal: (.cancelled, .ordinary))
        let attempt = base.attempts[0]
        return Seed(intent: base.intent, attempts: [AgentRecoveryAttempt(
            attemptID: attempt.attemptID,
            intentID: attempt.intentID,
            userItemID: attempt.userItemID,
            runAttemptID: attempt.runAttemptID,
            transcriptTurnID: attempt.transcriptTurnID,
            appInstanceID: attempt.appInstanceID,
            dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: dispatchedAtMs),
            outcome: attempt.outcome
        )], runAttempts: base.runAttempts)
    }

    /// An enumeration failure (not an absent directory) writes no completion; the next launch
    /// resumes with the stored cutoff and settles only attempts dispatched before it.
    func testEnumerationFailureWritesNoCompletionAndTheResumedPassKeepsItsCutoff() async throws {
        let (root, store) = try makeStore("o51-enumeration")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: Self.recoveryRoot(root), withIntermediateDirectories: true)
        // The sessions path exists but is not a directory: enumeration fails.
        let sessionsPath = Self.recoveryRoot(root).appendingPathComponent("sessions", isDirectory: false)
        try Data().write(to: sessionsPath)

        let failed = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(failed.ran)
        XCTAssertFalse(failed.completed)
        let inProgress = try XCTUnwrap(try marker(store))
        XCTAssertFalse(inProgress.completed, "No completion marker after an enumeration failure")

        try FileManager.default.removeItem(at: sessionsPath)
        let earlier = seed(dispatchedAtMs: inProgress.cutoffMs - 1)
        let later = seed(dispatchedAtMs: inProgress.cutoffMs + 60000)
        let sessionID = UUID()
        let laterLaunch = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID())
        try write([earlier, later], sessionID: sessionID, store: laterLaunch)

        let resumed = await laterLaunch.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.settledIntentIDs, [earlier.intent.intentID], "Only attempts dispatched before the stored cutoff")
        let done = try XCTUnwrap(try marker(laterLaunch))
        XCTAssertEqual(done.cutoffMs, inProgress.cutoffMs, "The resumed pass keeps the first cutoff")
        XCTAssertTrue(done.completed)
        guard case let .supported(record) = await laterLaunch.read(sessionID: sessionID) else {
            return XCTFail("The record reads back")
        }
        XCTAssertEqual(record.intent(id: later.intent.intentID), later.intent, "A later launch's attempt is never settled")
    }

    /// An absent sessions directory is a complete pass with nothing to settle.
    func testAbsentSessionsDirectoryCompletesThePass() async throws {
        let (root, store) = try makeStore("o51-absent")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(result.ran)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(try marker(store)?.completed, true)
    }

    /// A record that cannot be written keeps the pass unfinished; the next launch finishes it.
    func testRecordWriteFailureLeavesThePassUnfinishedUntilTheNextLaunch() async throws {
        let (root, _) = try makeStore("o51-record-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = FaultInjection()
        let store = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID(), fileOperations: faults.fileOperations)
        let pending = seed(terminal: (.cancelled, .ordinary))
        let sessionID = UUID()
        try write([pending], sessionID: sessionID, store: store)
        let bytes = try Data(contentsOf: store.recordFileURL(sessionID: sessionID))

        faults.set(recordWrites: true)
        let failed = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(failed.ran)
        XCTAssertFalse(failed.completed)
        XCTAssertEqual(failed.failedSessionIDs, [sessionID])
        XCTAssertTrue(failed.settledIntentIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.recordFileURL(sessionID: sessionID)), bytes)
        XCTAssertEqual(try marker(store)?.completed, false)

        faults.set()
        let next = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID(), fileOperations: faults.fileOperations)
        let finished = await next.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(finished.completed)
        XCTAssertEqual(finished.settledIntentIDs, [pending.intent.intentID])
        XCTAssertEqual(try marker(next)?.completed, true)
    }

    /// Marker write failures: without the in-progress marker nothing is modified; without the
    /// completion marker the next launch runs again (settling nothing twice) and completes.
    func testMarkerWriteFailuresNeverModifyWithoutACutoffAndNeverClaimCompletion() async throws {
        let (root, _) = try makeStore("o51-marker-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = FaultInjection()
        let store = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID(), fileOperations: faults.fileOperations)
        let pending = seed(terminal: (.cancelled, .ordinary))
        let sessionID = UUID()
        try write([pending], sessionID: sessionID, store: store)
        let bytes = try Data(contentsOf: store.recordFileURL(sessionID: sessionID))

        faults.set(inProgressMarker: true)
        let notStarted = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertFalse(notStarted.ran)
        XCTAssertEqual(try Data(contentsOf: store.recordFileURL(sessionID: sessionID)), bytes, "No record is modified before the cutoff is stored")
        XCTAssertNil(try marker(store))

        faults.set(completionMarker: true)
        let unconfirmed = await store.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(unconfirmed.ran)
        XCTAssertFalse(unconfirmed.completed)
        XCTAssertEqual(unconfirmed.settledIntentIDs, [pending.intent.intentID])
        XCTAssertEqual(try marker(store)?.completed, false)
        let settledBytes = try Data(contentsOf: store.recordFileURL(sessionID: sessionID))

        faults.set()
        let next = AgentRecoveryStore(rootURL: Self.recoveryRoot(root), appInstanceID: UUID(), fileOperations: faults.fileOperations)
        let finished = await next.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(finished.completed)
        XCTAssertTrue(finished.settledIntentIDs.isEmpty, "A settled intent no longer qualifies")
        XCTAssertEqual(try Data(contentsOf: next.recordFileURL(sessionID: sessionID)), settledBytes)
        XCTAssertEqual(try marker(next)?.completed, true)
    }

    /// G4: launch L1, the first to run the settlement, cannot write its in-progress marker. Its
    /// launch mark (already written) carries L1's start, so launch L2 settles only attempts
    /// dispatched before L1, never uncertainty L1 itself created, and stores that same cutoff.
    func testFailedInProgressMarkerNeverLetsALaterLaunchSettleTheFirstLaunchsUncertainty() async throws {
        let (root, _) = try makeStore("o51-first-launch-cutoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = FaultInjection()
        let l1StartMs: Int64 = 1_000_000
        let l1 = AgentRecoveryStore(
            rootURL: Self.recoveryRoot(root),
            appInstanceID: UUID(),
            fileOperations: faults.fileOperations,
            now: { Date(timeIntervalSince1970: 1000) }
        )
        _ = await l1.readLaunchMark()
        _ = try await l1.recordCurrentLaunchRunning()
        let earlier = seed(dispatchedAtMs: 11)
        let sessionID = UUID()
        try write([earlier], sessionID: sessionID, store: l1)

        faults.set(inProgressMarker: true)
        let notStarted = await l1.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertFalse(notStarted.ran)
        XCTAssertNil(try marker(l1))
        // L1 itself leaves new qualifying uncertainty.
        let l1Uncertainty = seed(dispatchedAtMs: l1StartMs + 5000)
        try write([earlier, l1Uncertainty], sessionID: sessionID, store: l1)

        faults.set()
        let l2 = AgentRecoveryStore(
            rootURL: Self.recoveryRoot(root),
            appInstanceID: UUID(),
            fileOperations: faults.fileOperations,
            now: { Date(timeIntervalSince1970: 2000) }
        )
        _ = await l2.readLaunchMark()
        _ = try await l2.recordCurrentLaunchRunning()
        let pass = await l2.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(pass.completed)
        XCTAssertEqual(pass.settledIntentIDs, [earlier.intent.intentID], "Only attempts from before the first settlement launch")
        XCTAssertEqual(try marker(l2)?.cutoffMs, l1StartMs, "L2 keeps L1's start, not its own")
        guard case let .supported(record) = await l2.read(sessionID: sessionID) else {
            return XCTFail("The record reads back")
        }
        XCTAssertEqual(record.intent(id: l1Uncertainty.intent.intentID), l1Uncertainty.intent, "L1's uncertainty is never settled")
    }

    /// H1: L1 starts after the hard upper bound, cannot write its in-progress marker, and leaves new
    /// uncertainty; a legacy build then rewrites the launch mark without the carried cutoff, so L2
    /// finds neither. The hard bound still keeps every attempt dispatched on or after it unsettled.
    func testHardCutoffBoundsTheCohortWhenTheMarkerAndTheCarriedCutoffAreBothLost() async throws {
        let (root, _) = try makeStore("o51-hard-cutoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let faults = FaultInjection()
        let bound = AgentRecoveryStore.ordinaryExitSettlementLatestCutoff.millisecondsSince1970
        let l1StartMs = bound + 4 * 86_400_000
        let l1 = AgentRecoveryStore(
            rootURL: Self.recoveryRoot(root),
            appInstanceID: UUID(),
            fileOperations: faults.fileOperations,
            now: { Date(timeIntervalSince1970: TimeInterval(l1StartMs) / 1000) }
        )
        _ = await l1.readLaunchMark()
        _ = try await l1.recordCurrentLaunchRunning()
        let earlier = seed(dispatchedAtMs: 11)
        let sessionID = UUID()
        try write([earlier], sessionID: sessionID, store: l1)
        faults.set(inProgressMarker: true)
        let notStarted = await l1.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertFalse(notStarted.ran)
        let l1Uncertainty = seed(dispatchedAtMs: l1StartMs + 5000)
        try write([earlier, l1Uncertainty], sessionID: sessionID, store: l1)

        // A legacy build rewrites the launch mark and drops the carried cutoff.
        let legacyMark: [String: Any] = [
            "schemaVersion": 1,
            "appInstanceID": UUID().uuidString,
            "state": "cleanExit",
            "recordedAtMs": NSNumber(value: l1StartMs + 60000)
        ]
        try JSONSerialization.data(withJSONObject: legacyMark).write(to: l1.launchStateFileURL)

        faults.set()
        let l2StartMs = bound + 14 * 86_400_000
        let l2 = AgentRecoveryStore(
            rootURL: Self.recoveryRoot(root),
            appInstanceID: UUID(),
            fileOperations: faults.fileOperations,
            now: { Date(timeIntervalSince1970: TimeInterval(l2StartMs) / 1000) }
        )
        _ = await l2.readLaunchMark()
        _ = try await l2.recordCurrentLaunchRunning()
        let carried = await l2.ordinaryExitSettlementLaunchCutoff
        XCTAssertEqual(carried?.millisecondsSince1970, l2StartMs, "The carried cutoff was lost: L2 looks like the first launch")
        let pass = await l2.settleOrdinaryExitDeliveryUnknownIntentsOnce()
        XCTAssertTrue(pass.completed)
        XCTAssertEqual(pass.settledIntentIDs, [earlier.intent.intentID])
        XCTAssertEqual(try marker(l2)?.cutoffMs, bound, "The hard bound caps the cutoff")
        guard case let .supported(record) = await l2.read(sessionID: sessionID) else {
            return XCTFail("The record reads back")
        }
        XCTAssertEqual(record.intent(id: l1Uncertainty.intent.intentID), l1Uncertainty.intent, "Never settled after the bound")
    }

    /// The coordinator runs the settlement during startup (before discovery, so a settled intent
    /// is never a crash-hold input); crash-cause uncertainty is left as it is. Reconcile is stubbed,
    /// so this checks the records only.
    func testCoordinatorStartupSettlesBeforeDiscoveryAndLeavesCrashCauseUncertainty() async throws {
        let (root, store) = try makeStore("o51-startup")
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = seed(terminal: (.cancelled, .ordinary))
        let crash = seed(terminal: nil)
        let ordinarySessionID = UUID()
        let crashSessionID = UUID()
        try write([ordinary], sessionID: ordinarySessionID, store: store)
        try write([crash], sessionID: crashSessionID, store: store)

        let service = AgentSessionDataService(
            tombstoneRoot: Self.recoveryRoot(root).appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        coordinator.startIfNeeded()
        let startup = await coordinator.awaitStartup()
        XCTAssertEqual(startup, .ready)

        guard case let .supported(settled) = await store.read(sessionID: ordinarySessionID),
              case let .supported(held) = await store.read(sessionID: crashSessionID)
        else {
            return XCTFail("Both records read back")
        }
        XCTAssertEqual(settled.intent(id: ordinary.intent.intentID)?.deliveryState, .providerAccepted)
        XCTAssertEqual(held.intent(id: crash.intent.intentID), crash.intent, "Crash-cause uncertainty is never settled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.ordinaryExitSettlementMarkerURL.path))
    }

    // MARK: O50 wording by exit kind

    func testRecordedRunEndEvidenceTellsCleanFromUncleanExits() {
        let clean = seed(terminal: (.cancelled, .ordinary))
        let quit = seed(terminal: nil, shutdown: .appQuit)
        let crash = seed(terminal: nil)
        let record = AgentRecoveryRecord(
            sessionID: UUID(),
            revision: .make(),
            incarnationID: UUID(),
            transcriptResetGeneration: 0,
            updatedAt: AgentRecoveryTimestamp(millisecondsSince1970: 30),
            composer: nil,
            intents: [clean, quit, crash].map(\.intent),
            attempts: [clean, quit, crash].flatMap(\.attempts),
            runAttempts: [clean, quit, crash].flatMap(\.runAttempts)
        )
        XCTAssertTrue(record.intentRunsEndedWithRecordedEvidence(intentID: clean.intent.intentID))
        XCTAssertTrue(record.intentRunsEndedWithRecordedEvidence(intentID: quit.intent.intentID))
        XCTAssertFalse(record.intentRunsEndedWithRecordedEvidence(intentID: crash.intent.intentID), "No run end recorded: unclean")
        XCTAssertFalse(record.intentRunsEndedWithRecordedEvidence(intentID: UUID()), "No attempts proves nothing")
    }

    func testDeliveryWordingNamesACrashOnlyForAnUncleanExit() {
        let attempts: [AgentRecoveryAttempt] = []
        XCTAssertEqual(AgentColdRestoreInterruptionContext.unacceptedDelivery(state: .deliveryUnknown, attempts: attempts, runsEndedWithRecordedEvidence: false), .unconfirmed)
        XCTAssertEqual(
            AgentColdRestoreInterruptionContext.unacceptedDelivery(state: .deliveryUnknown, attempts: attempts, runsEndedWithRecordedEvidence: true),
            .notConfirmedByAgent
        )
        XCTAssertEqual(
            AgentColdRestoreInterruptionContext.unacceptedDelivery(state: .dispatching, attempts: attempts, runsEndedWithRecordedEvidence: true),
            .notConfirmedByAgent
        )

        XCTAssertEqual(AgentMessageBubble.recoveryDeliveryLabel(.unconfirmed), "Delivery unconfirmed")
        XCTAssertTrue(AgentMessageBubble.recoveryDeliveryHelp(.unconfirmed).hasPrefix("RepoPrompt stopped"))
        let cleanLabel = AgentMessageBubble.recoveryDeliveryLabel(.notConfirmedByAgent)
        let cleanHelp = AgentMessageBubble.recoveryDeliveryHelp(.notConfirmedByAgent)
        XCTAssertEqual(cleanLabel, "Not confirmed")
        XCTAssertEqual(cleanHelp, "The agent didn't confirm it received this message. Sending it again might duplicate it.")
        for text in [cleanLabel, cleanHelp] {
            XCTAssertFalse(text.contains("Delivery unconfirmed"), text)
            XCTAssertFalse(text.contains("RepoPrompt stopped"), text)
        }
        // Verified non-delivery names no exit kind.
        XCTAssertEqual(AgentMessageBubble.recoveryDeliveryHelp(.notSent), "This message was not delivered to the agent.")

        let crashRow = AgentModeViewModel.recoveryListCertainty(of: .deliveryUnknown, earlierLaunch: true, runsEndedWithRecordedEvidence: false)
        XCTAssertTrue(crashRow.hasPrefix("RepoPrompt closed while sending it"), crashRow)
        let cleanRow = AgentModeViewModel.recoveryListCertainty(
            of: .deliveryUnknown,
            earlierLaunch: true,
            runsEndedWithRecordedEvidence: true
        )
        XCTAssertEqual(cleanRow, "The agent didn't confirm it received it. Sending it again could deliver it twice.")
        let liveRow = AgentModeViewModel.recoveryListCertainty(
            of: .deliveryUnknown,
            earlierLaunch: false,
            runsEndedWithRecordedEvidence: true
        )
        XCTAssertEqual(liveRow, cleanRow)
    }
}
