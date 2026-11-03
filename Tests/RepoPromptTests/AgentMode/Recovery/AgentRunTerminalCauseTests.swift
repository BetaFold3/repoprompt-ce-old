import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Phase 2: the typed terminal cause, its effective resolution in the terminal barrier, its
/// persisted evidence, the live interruption stamp, cold-restore precedence, and the one shared
/// classifier.
@MainActor
final class AgentRunTerminalCauseTests: XCTestCase {
    private typealias Status = AgentRecoveryInterruptedTurn.Status

    // MARK: Effective cause

    func testCompletedTerminalIsAlwaysOrdinary() {
        for requested in AgentRunTerminalCause.allCases {
            for teardown in [nil] + AgentRunTerminalCause.allCases.map(Optional.some) {
                XCTAssertEqual(
                    AgentRunTerminalCause.effective(requested: requested, terminalState: .completed, lifecycleTeardown: teardown),
                    .ordinary,
                    "Completion wins against a provisional or lifecycle reason"
                )
            }
        }
    }

    func testUserCancelIsKeptAndTeardownWinsOtherwise() {
        XCTAssertEqual(
            AgentRunTerminalCause.effective(requested: .userCancel, terminalState: .cancelled, lifecycleTeardown: .appQuit),
            .userCancel
        )
        XCTAssertEqual(
            AgentRunTerminalCause.effective(requested: .ordinary, terminalState: .cancelled, lifecycleTeardown: .windowClose),
            .windowClose
        )
        XCTAssertEqual(
            AgentRunTerminalCause.effective(requested: .ordinary, terminalState: .failed, lifecycleTeardown: .appQuit),
            .appQuit
        )
        XCTAssertEqual(
            AgentRunTerminalCause.effective(requested: .providerProcessLost, terminalState: .failed, lifecycleTeardown: nil),
            .providerProcessLost
        )
        XCTAssertEqual(
            AgentRunTerminalCause.effective(requested: .ordinary, terminalState: .cancelled, lifecycleTeardown: nil),
            .ordinary
        )
    }

    func testOnlyInterruptionCausesMapToAReason() {
        XCTAssertNil(AgentRunTerminalCause.ordinary.interruptionReason)
        XCTAssertNil(AgentRunTerminalCause.userCancel.interruptionReason)
        XCTAssertEqual(AgentRunTerminalCause.appQuit.interruptionReason, .appQuit)
        XCTAssertEqual(AgentRunTerminalCause.windowClose.interruptionReason, .windowClose)
        XCTAssertEqual(AgentRunTerminalCause.providerProcessLost.interruptionReason, .providerProcessLost)
        XCTAssertFalse(AgentRunTerminalCause.allCases.map(\.rawValue).contains("appCrash"), "A crash never commits")
    }

    /// Review A F06: only Codex finalize reasons where the transport or process ended under the
    /// run and recovery could not reattach are typed process loss; provider failures stay ordinary.
    func testCodexFinalizeReasonsMapOnlyTransportLossToProcessLoss() {
        XCTAssertEqual(CodexAgentModeCoordinator.terminalCause(forFinalizeReason: "transport-closed-fallback"), .providerProcessLost)
        XCTAssertEqual(CodexAgentModeCoordinator.terminalCause(forFinalizeReason: "unexpected-stream-end"), .providerProcessLost)
        for reason in ["question-persistence-failed", "turn-completed", "turn-failed", "user-cancel", ""] {
            XCTAssertEqual(CodexAgentModeCoordinator.terminalCause(forFinalizeReason: reason), .ordinary, reason)
        }
    }

    // MARK: Shared classifier

    private func terminal(_ state: AgentSessionRunState, _ cause: AgentRunTerminalCause?) -> AgentRecoveryRunTerminalEvidence {
        AgentRecoveryRunTerminalEvidence(
            commitID: UUID(),
            terminalState: state,
            expectedRunID: nil,
            recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1),
            cause: cause
        )
    }

    private let shutdown = AgentRecoveryRunShutdownEvidence(
        reason: .appQuit,
        observedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1),
        lastConfirmedActivityAt: nil
    )

    func testClassifierNeverPresentsFailedOrCancelledAsCompleted() {
        XCTAssertEqual(Status.classify(terminal: nil, shutdown: nil), .interrupted)
        XCTAssertEqual(Status.classify(terminal: terminal(.completed, nil), shutdown: nil), .completedTailMayBeMissing)
        XCTAssertEqual(Status.classify(terminal: terminal(.completed, .ordinary), shutdown: shutdown), .completedTailMayBeMissing)
        XCTAssertEqual(Status.classify(terminal: terminal(.completed, .appQuit), shutdown: nil), .unknown)

        XCTAssertEqual(Status.classify(terminal: terminal(.failed, nil), shutdown: nil), .failed)
        XCTAssertEqual(Status.classify(terminal: terminal(.failed, .ordinary), shutdown: shutdown), .failed)
        XCTAssertEqual(Status.classify(terminal: terminal(.failed, .providerProcessLost), shutdown: nil), .interrupted)

        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, .userCancel), shutdown: shutdown), .cancelledByUser)
        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, .ordinary), shutdown: nil), .stopped)
        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, .windowClose), shutdown: nil), .interrupted)
        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, .appQuit), shutdown: nil), .interrupted)
        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, nil), shutdown: shutdown), .interrupted, "Legacy: shutdown evidence")
        XCTAssertEqual(Status.classify(terminal: terminal(.cancelled, nil), shutdown: nil), .unknown, "Legacy: no evidence")

        for state in [AgentSessionRunState.failed, .cancelled] {
            for cause in [nil] + AgentRunTerminalCause.allCases.map(Optional.some) {
                XCTAssertNotEqual(
                    Status.classify(terminal: terminal(state, cause), shutdown: shutdown),
                    .completedTailMayBeMissing
                )
            }
        }
        XCTAssertEqual(Status.classify(attempt: nil), .interrupted, "A legacy stamped turn keeps its stamp")
    }

    // MARK: Persisted evidence

    private func record(cause: AgentRunTerminalCause?, extras: AgentRecoveryExtras = [:]) -> AgentRecoveryRecord {
        let sessionID = UUID()
        let attempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: UUID(),
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10),
            appInstanceID: UUID(),
            terminal: AgentRecoveryRunTerminalEvidence(
                commitID: UUID(),
                terminalState: .cancelled,
                expectedRunID: nil,
                recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 20),
                cause: cause,
                extras: extras
            )
        )
        return AgentRecoveryRecord(
            sessionID: sessionID,
            revision: .make(),
            incarnationID: UUID(),
            transcriptResetGeneration: 0,
            updatedAt: AgentRecoveryTimestamp(millisecondsSince1970: 30),
            composer: nil,
            intents: [],
            attempts: [],
            runAttempts: [attempt]
        )
    }

    private func roundTrip(_ record: AgentRecoveryRecord) throws -> (AgentRecoveryRecord, Data) {
        let data = try AgentRecoveryRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRecoveryRecordCodec.decode(data, expectedSessionID: record.sessionID) else {
            XCTFail("Record must decode")
            throw CancellationError()
        }
        return (decoded, data)
    }

    func testCauseRoundTripsAndAbsentCauseStaysAbsent() throws {
        for cause in AgentRunTerminalCause.allCases {
            let (decoded, data) = try roundTrip(record(cause: cause))
            XCTAssertEqual(decoded.runAttempts.first?.terminal?.cause, cause)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(cause.rawValue)\""))
        }
        let (legacy, legacyData) = try roundTrip(record(cause: nil))
        XCTAssertNil(legacy.runAttempts.first?.terminal?.cause)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("\"cause\""), "Existing bytes unchanged")
    }

    func testUnrecognizedCauseIsPreservedAndReadsAsUnspecified() throws {
        let original = record(cause: nil, extras: ["cause": .string("appCrashFromTheFuture")])
        let (decoded, data) = try roundTrip(original)
        XCTAssertNil(decoded.runAttempts.first?.terminal?.cause)
        XCTAssertEqual(decoded.runAttempts.first?.terminal?.extras["cause"], .string("appCrashFromTheFuture"))
        let (again, againData) = try roundTrip(decoded)
        XCTAssertEqual(again.runAttempts, decoded.runAttempts)
        XCTAssertEqual(againData, data, "An unknown value round-trips exactly")
    }

    // MARK: Cold restore precedence

    private func openTurn(id: UUID) -> AgentTranscriptTurn {
        AgentTranscriptTurn(
            id: id,
            responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .open, startedAt: Date(timeIntervalSince1970: 100))],
            terminalState: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func coldRestore(turnID: UUID, terminal: AgentRecoveryRunTerminalEvidence?) -> AgentTranscriptTurn? {
        let attempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: turnID,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10),
            appInstanceID: UUID(),
            terminal: terminal
        )
        let context = AgentColdRestoreInterruptionContext(
            observedAt: Date(timeIntervalSince1970: 500),
            providerConversationID: nil,
            runAttempts: [attempt],
            launchReason: .appCrash,
            launchStateCaptured: true
        )
        let restored = AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
            AgentTranscript(turns: [openTurn(id: turnID)]),
            interruptionContext: context,
            protectedItemIDs: []
        )
        return restored.turns.first
    }

    /// Step 4d5: a cold restore leaves a Claude-associated tool row's projected payload untouched,
    /// with a valid or a cleared proof alike (the ledger's own protected set), while an ordinary
    /// pending tool is cancelled and the turn and its spans close and are stamped exactly as without
    /// the protection.
    func testColdRestoreKeepsAnAssociatedToolPayloadAndStillClosesTheTurnHonestly() throws {
        var read = AgentChatItem.toolCall(name: "Read", invocationID: UUID(), argsJSON: #"{"file_path":"/fixture/notes.txt"}"#, sequenceIndex: 1)
        read.isStreaming = true
        let bash = AgentChatItem.toolCall(name: "Bash", invocationID: UUID(), argsJSON: #"{"command":"ls"}"#, sequenceIndex: 2)
        var user = AgentChatItem.user("Use Read on notes.txt")
        user.sequenceIndex = 0
        let saved = AgentTranscriptIO.buildTranscript(from: [user, read, bash], terminalState: .running, nextSequenceIndex: 3, policy: .canonical)
        let savedTurn = try XCTUnwrap(saved.turns.first)
        XCTAssertEqual(savedTurn.terminalState?.isActive, true, "the saved turn was running")
        func activity(_ id: UUID, in turn: AgentTranscriptTurn) throws -> AgentTranscriptActivity {
            try XCTUnwrap(turn.allActivities.first { $0.id == id })
        }
        let savedRead = try activity(read.id, in: savedTurn)
        XCTAssertTrue([.pending, .running].contains(savedRead.toolExecution?.status), "the saved call is still pending")
        let savedBash = try activity(bash.id, in: savedTurn)
        XCTAssertTrue([.pending, .running].contains(savedBash.toolExecution?.status))
        let attempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(), transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: savedTurn.id,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10), appInstanceID: UUID(), terminal: nil
        )
        let context = AgentColdRestoreInterruptionContext(
            observedAt: Date(timeIntervalSince1970: 500), providerConversationID: nil, runAttempts: [attempt],
            launchReason: .appCrash, launchStateCaptured: true
        )
        let unprotected = try XCTUnwrap(AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
            saved, interruptionContext: context, protectedItemIDs: []
        ).turns.first)
        XCTAssertEqual(unprotected.terminalState, .cancelled)
        XCTAssertEqual(unprotected.interruption?.reason, .appCrash)
        XCTAssertFalse(unprotected.responseSpans.contains { $0.lifecycle == .open })
        XCTAssertEqual(try activity(read.id, in: unprotected).toolExecution?.status, .cancelled, "an unassociated call is cancelled")

        for digest in [String(repeating: "a", count: 64), nil] {
            let label = digest == nil ? "cleared proof" : "valid proof"
            let ledger = AgentSessionProviderHistoryRecovery(nativeItems: [.init(
                providerRaw: "claude", nativeSessionID: "native-session", nativeEntryID: "c1",
                rowKindRaw: ClaudeSessionHistoryReader.RowKind.toolCall.rawValue, ordinal: 0,
                localItemID: read.id, envelopeDigest: digest
            )])
            let restored = try XCTUnwrap(AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
                saved, interruptionContext: context, protectedItemIDs: ledger.claudeLocalItemIDs
            ).turns.first)
            let restoredRead = try activity(read.id, in: restored)
            XCTAssertEqual(restoredRead.toolExecution, savedRead.toolExecution, "\(label): the payload survives")
            XCTAssertEqual(restoredRead.text, savedRead.text, label)
            XCTAssertFalse(restoredRead.isStreaming, "\(label): streaming still ends")
            let restoredBash = try activity(bash.id, in: restored)
            XCTAssertEqual(restoredBash.toolExecution?.status, .cancelled, "\(label): an ordinary pending tool is cancelled")
            XCTAssertEqual(restoredBash.toolExecution?.toolIsError, true, label)
            // Everything but the protected row is exactly the unprotected restore: the turn's
            // outcome, interruption, completion, summary, and every span's lifecycle and close.
            var comparable = restored
            for span in comparable.responseSpans.indices {
                for index in comparable.responseSpans[span].activities.indices where comparable.responseSpans[span].activities[index].id == read.id {
                    comparable.responseSpans[span].activities[index] = try activity(read.id, in: unprotected)
                }
            }
            XCTAssertEqual(comparable, unprotected, "\(label): the turn closes honestly, as before")
        }
    }

    func testColdRestoreDoesNotStampAUserCancel() throws {
        let turnID = UUID()
        let turn = try XCTUnwrap(coldRestore(turnID: turnID, terminal: terminal(.cancelled, .userCancel)))
        XCTAssertEqual(turn.terminalState, .cancelled)
        XCTAssertNil(turn.interruption, "An explicit user cancel is not an interruption")
    }

    func testColdRestoreStampsTheRecordedInterruptionCause() throws {
        let turn = try XCTUnwrap(coldRestore(turnID: UUID(), terminal: terminal(.cancelled, .windowClose)))
        XCTAssertEqual(turn.terminalState, .cancelled)
        XCTAssertEqual(turn.interruption?.reason, .windowClose, "Recorded cause wins over the launch reason")
        let unrecorded = try XCTUnwrap(coldRestore(turnID: UUID(), terminal: nil))
        XCTAssertEqual(unrecorded.interruption?.reason, .appCrash, "Existing launch-state stamping is unchanged")
    }

    /// Review B F1: a steer under a running attempt opens its own transcript turn (closing the start
    /// turn) while the run attempt keeps its start turn. The steer's dispatch attempt joins that turn
    /// to the run, so cold restore applies the run's own evidence to the turn that was open.
    private func coldRestoreSteered(
        terminal: AgentRecoveryRunTerminalEvidence?,
        includeSteerDispatch: Bool
    ) -> (start: AgentTranscriptTurn?, steer: AgentTranscriptTurn?, runAttemptID: UUID) {
        let startTurnID = UUID()
        let steerTurnID = UUID()
        let runAttemptID = UUID()
        let instanceID = UUID()
        let attempt = AgentRecoveryRunAttempt(
            runAttemptID: runAttemptID,
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: startTurnID,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10),
            appInstanceID: instanceID,
            terminal: terminal
        )
        let dispatches = [
            AgentRecoveryAttempt(
                attemptID: UUID(), intentID: UUID(), userItemID: startTurnID, runAttemptID: runAttemptID,
                transcriptTurnID: nil, appInstanceID: instanceID, dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10)
            ),
            AgentRecoveryAttempt(
                attemptID: UUID(), intentID: UUID(), userItemID: steerTurnID, runAttemptID: runAttemptID,
                transcriptTurnID: nil, appInstanceID: instanceID, dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 20)
            )
        ]
        let context = AgentColdRestoreInterruptionContext(
            observedAt: Date(timeIntervalSince1970: 500),
            providerConversationID: nil,
            runAttempts: [attempt],
            intentAttempts: includeSteerDispatch ? dispatches : [],
            launchReason: .appCrash,
            launchStateCaptured: true
        )
        let closedStart = AgentTranscriptTurn(
            id: startTurnID,
            responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: Date(timeIntervalSince1970: 50))],
            terminalState: .completed,
            startedAt: Date(timeIntervalSince1970: 50)
        )
        let restored = AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
            AgentTranscript(turns: [closedStart, openTurn(id: steerTurnID)]),
            interruptionContext: context,
            protectedItemIDs: []
        )
        let join = AgentRecoveryRunTurnJoin(runAttempts: [attempt], intentAttempts: includeSteerDispatch ? dispatches : [])
        XCTAssertEqual(join.latestTurnID(of: attempt), includeSteerDispatch ? steerTurnID : startTurnID)
        return (
            restored.turns.first { $0.id == startTurnID },
            restored.turns.first { $0.id == steerTurnID },
            runAttemptID
        )
    }

    func testColdRestoreJoinsASteeredTurnToItsRunAttempt() throws {
        let interrupted = coldRestoreSteered(terminal: terminal(.cancelled, .windowClose), includeSteerDispatch: true)
        let steer = try XCTUnwrap(interrupted.steer)
        XCTAssertEqual(steer.interruption?.reason, .windowClose, "The run's recorded cause, not the launch reason")
        XCTAssertEqual(steer.interruption?.runAttemptID, interrupted.runAttemptID, "Joined to the run attempt")
        XCTAssertNil(interrupted.start?.interruption, "The start turn the steer closed is untouched")

        let completed = coldRestoreSteered(terminal: terminal(.completed, nil), includeSteerDispatch: true)
        let completedSteer = try XCTUnwrap(completed.steer)
        XCTAssertNil(completedSteer.interruption, "An ordinary completion closes the steered turn without an interruption")
        XCTAssertEqual(completedSteer.terminalState, .completed)

        // Without the steer's dispatch evidence the turn cannot be joined (R4 behavior): launch reason.
        let unjoined = try XCTUnwrap(coldRestoreSteered(terminal: terminal(.cancelled, .windowClose), includeSteerDispatch: false).steer)
        XCTAssertEqual(unjoined.interruption?.reason, .appCrash)
        XCTAssertNil(unjoined.interruption?.runAttemptID)
    }

    // MARK: Provider process loss (review A F06)

    /// The real Claude controller's unexpected stdout EOF (not a requested shutdown) records the
    /// turns it failed as provider-process loss, answered once per turn; a replaced launch's stale
    /// EOF records nothing.
    func testClaudeControllerAttributesOnlyUnexpectedEOFTurnsToProcessLoss() async throws {
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
        let subscription = await controller.eventsSubscription()
        let launch = await controller.test_beginSyntheticUsageLaunch()
        let lostTurn = await controller.test_beginTurnTracking()
        await controller.test_handleStdoutEOF(launchToken: launch.token)
        let launchAfterEOF = await controller.test_currentUsageLaunchToken()
        XCTAssertNil(launchAfterEOF, "the EOF reached the current launch")
        var failedTurns: [UUID] = []
        for await event in subscription.events {
            if case let .turnCompleted(turnID, status, _) = event, status == .failed { failedTurns.append(turnID) }
        }
        XCTAssertEqual(failedTurns, [lostTurn], "the EOF failed the tracked turn")
        // Review R1: the runner asks through the protocol existential; the real witness must answer
        // (not the extension's `false` default). The answer is consumed once.
        let runtime: any NativeAgentRuntimeControlling = controller
        let lost = await runtime.turnEndedByProcessLoss(lostTurn)
        XCTAssertTrue(lost, "the EOF failed this turn by process loss (protocol lookup)")
        let again = await controller.turnEndedByProcessLoss(lostTurn)
        XCTAssertFalse(again, "answered once")
        let unrelated = await controller.turnEndedByProcessLoss(UUID())
        XCTAssertFalse(unrelated)

        _ = await controller.test_beginSyntheticUsageLaunch()
        let currentTurn = await controller.test_beginTurnTracking()
        await controller.test_handleStdoutEOF(launchToken: launch.token)
        let stale = await controller.turnEndedByProcessLoss(currentTurn)
        XCTAssertFalse(stale, "a replaced launch's EOF never fails the current turn")
        await controller.shutdown()
    }

    /// The real ACP controller over a scripted local agent process: the process exiting under a
    /// prompt is provider-process loss for the run; the agent answering the prompt with an error is
    /// ordinary; completion and our own shutdown never are.
    func testACPProcessExitUnderAPromptIsProcessLossAndAnErrorResponseIsOrdinary() async throws {
        for (behavior, expected) in [("exit", AgentRunTerminalCause.providerProcessLost), ("error", .ordinary)] {
            let controller = try makeScriptedACPController(promptBehavior: behavior)
            _ = try await controller.bootstrap()
            do {
                try await controller.prompt(AgentMessage(userMessage: "hello"))
                XCTFail("\(behavior): the prompt fails")
            } catch {}
            let failed = await ACPIntegratedAgentModeRunner.terminalCause(terminalState: .failed, controller: controller)
            XCTAssertEqual(failed, expected, behavior)
            let completed = await ACPIntegratedAgentModeRunner.terminalCause(terminalState: .completed, controller: controller)
            XCTAssertEqual(completed, .ordinary, behavior)
            await controller.shutdown()
            let afterShutdown = await ACPIntegratedAgentModeRunner.terminalCause(terminalState: .failed, controller: controller)
            XCTAssertEqual(afterShutdown, expected, "\(behavior): our shutdown neither sets nor clears it")
        }
    }

    /// Review R1: the headless ACP bridge's outer catch passes a typed process loss through
    /// unnormalized (provider normalization may rewrap it); other errors are still normalized.
    func testHeadlessBridgePassesTypedProcessLossThroughProviderNormalization() {
        let rewrap: (Error) -> Error = { AIProviderError.invalidConfiguration(detail: $0.localizedDescription) }
        let lost = HeadlessProviderProcessLostError(message: "agent exited")
        XCTAssertEqual(
            ACPHeadlessAgentProviderBridge.outerStreamError(lost, normalize: rewrap) as? HeadlessProviderProcessLostError,
            lost
        )
        let other = ACPHeadlessAgentProviderBridge.outerStreamError(CocoaError(.fileNoSuchFile), normalize: rewrap)
        XCTAssertFalse(other is HeadlessProviderProcessLostError)
        XCTAssertTrue(other is AIProviderError, "other errors are still normalized")
    }

    private func makeScriptedACPController(promptBehavior: String) throws -> ACPAgentSessionController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalCauseACP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("agent.py")
        try ScriptedProcessLossACPAgent.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: directory.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: ScriptedProcessLossACPProvider(
                commandPath: scriptURL.path,
                environment: ["FAKE_ACP_PROMPT": promptBehavior]
            ),
            runRequest: request,
            mcpHost: ServerNetworkManager.shared
        )
        addTeardownBlock { await controller.shutdown() }
        return controller
    }

    // MARK: Barrier

    private func runningSession(turnID: UUID) -> (AgentTabSession, AgentRunOwnership) {
        let session = AgentTabSession(tabID: UUID())
        session.appendItem(.user("question", id: turnID, sequenceIndex: session.nextSequenceIndex))
        session.transcript = AgentTranscript(turns: [openTurn(id: turnID)])
        session.providerSessionID = "provider-conversation"
        session.runID = UUID()
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.terminalCause")
        return (session, ownership)
    }

    func testLiveStampRecordsInterruptionCauseOnce() throws {
        let turnID = UUID()
        let (session, ownership) = runningSession(turnID: turnID)
        AgentRunTerminalCommitBarrier.stampLiveInterruption(
            cause: .windowClose,
            terminalState: .cancelled,
            turnID: turnID,
            runAttemptID: ownership.attemptID,
            session: session,
            now: Date(timeIntervalSince1970: 900)
        )
        let stamped = try XCTUnwrap(session.transcript.turns.first?.interruption)
        XCTAssertEqual(stamped.reason, .windowClose)
        XCTAssertEqual(stamped.runAttemptID, ownership.attemptID)
        XCTAssertEqual(stamped.providerConversationID, "provider-conversation")
        XCTAssertEqual(stamped.observedAt, Date(timeIntervalSince1970: 900))
        XCTAssertTrue(session.isDirty)

        AgentRunTerminalCommitBarrier.stampLiveInterruption(
            cause: .appQuit,
            terminalState: .cancelled,
            turnID: turnID,
            runAttemptID: ownership.attemptID,
            session: session,
            now: Date(timeIntervalSince1970: 999)
        )
        XCTAssertEqual(session.transcript.turns.first?.interruption, stamped, "Never refreshed or replaced")
    }

    func testLiveStampSkipsUserCancelOrdinaryAndCompletion() {
        for (cause, state) in [
            (AgentRunTerminalCause.userCancel, AgentSessionRunState.cancelled),
            (.ordinary, .cancelled),
            (.ordinary, .failed),
            (.appQuit, .completed)
        ] {
            let turnID = UUID()
            let (session, ownership) = runningSession(turnID: turnID)
            session.isDirty = false
            AgentRunTerminalCommitBarrier.stampLiveInterruption(
                cause: cause,
                terminalState: state,
                turnID: turnID,
                runAttemptID: ownership.attemptID,
                session: session
            )
            XCTAssertNil(session.transcript.turns.first?.interruption, "\(cause) \(state)")
            XCTAssertFalse(session.isDirty)
        }
    }
}

/// OpenCode-identified ACP provider for the scripted local agent below.
private struct ScriptedProcessLossACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID = .openCode
    let commandPath: String
    let environment: [String: String]

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID)
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

/// A local ACP agent that opens a session, then answers `session/prompt` per `FAKE_ACP_PROMPT`:
/// `exit` ends the process under the prompt (process loss); `error` answers with a JSON-RPC error.
private enum ScriptedProcessLossACPAgent {
    static let script = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    behavior = os.environ.get("FAKE_ACP_PROMPT", "error")

    def send(payload):
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except Exception:
            continue
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"agentCapabilities": {"loadSession": False}, "authMethods": []}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": "process-loss-session"}})
        elif method == "session/prompt":
            if behavior == "exit":
                sys.exit(3)
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "model refused the request"}})
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    """#
}

// MARK: - O11 relocated saved input joins its execution turn

extension AgentRunTerminalCauseTests {
    /// The same user item A was attempted in its historical turn H (= A's ID, attempt P) and, after
    /// Send saved placed it at the end, executes in a distinct turn E (attempt R, its dispatch
    /// recording E). H joins P only; E joins R only, both as R's own turn and as a steer into an
    /// already-running R; R's latest turn is E. Without the recorded turn the steer would land on H.
    func testRelocatedSavedInputDispatchJoinsItsExecutionTurnNeverTheHistoricalOne() {
        let itemID = UUID()
        let executionTurnID = UUID()
        let instanceID = UUID()
        let historical = AgentTranscriptTurn(id: itemID, terminalState: .cancelled, startedAt: Date(timeIntervalSince1970: 10))
        let execution = AgentTranscriptTurn(id: executionTurnID, startedAt: Date(timeIntervalSince1970: 30))
        let priorAttempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: itemID,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10),
            appInstanceID: instanceID
        )
        let priorDispatch = AgentRecoveryAttempt(
            attemptID: UUID(), intentID: UUID(), userItemID: itemID, runAttemptID: priorAttempt.runAttemptID,
            transcriptTurnID: nil, appInstanceID: instanceID, dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 10)
        )

        // R started on E.
        let ownAttempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: executionTurnID,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 30),
            appInstanceID: instanceID
        )
        let ownDispatch = AgentRecoveryAttempt(
            attemptID: UUID(), intentID: priorDispatch.intentID, userItemID: itemID, runAttemptID: ownAttempt.runAttemptID,
            transcriptTurnID: executionTurnID, appInstanceID: instanceID, dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 30)
        )
        let own = AgentRecoveryRunTurnJoin(runAttempts: [priorAttempt, ownAttempt], intentAttempts: [priorDispatch, ownDispatch])
        XCTAssertEqual(own.attempt(for: historical)?.runAttemptID, priorAttempt.runAttemptID)
        XCTAssertEqual(own.attempt(for: execution)?.runAttemptID, ownAttempt.runAttemptID)
        XCTAssertEqual(own.latestTurnID(of: ownAttempt), executionTurnID)
        XCTAssertEqual(own.latestTurnID(of: priorAttempt), itemID)

        // R already running on another turn S; A's dispatch steered into it under E.
        let startTurnID = UUID()
        let runningAttempt = AgentRecoveryRunAttempt(
            runAttemptID: UUID(),
            transcriptResetGeneration: 0,
            processRunID: nil,
            transcriptTurnID: startTurnID,
            startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 20),
            appInstanceID: instanceID
        )
        let steer = AgentRecoveryAttempt(
            attemptID: UUID(), intentID: priorDispatch.intentID, userItemID: itemID, runAttemptID: runningAttempt.runAttemptID,
            transcriptTurnID: executionTurnID, appInstanceID: instanceID, dispatchedAt: AgentRecoveryTimestamp(millisecondsSince1970: 40)
        )
        let steered = AgentRecoveryRunTurnJoin(runAttempts: [priorAttempt, runningAttempt], intentAttempts: [priorDispatch, steer])
        XCTAssertEqual(steered.attempt(for: execution)?.runAttemptID, runningAttempt.runAttemptID, "E joins the attempt its dispatch recorded")
        XCTAssertEqual(steered.attempt(for: historical)?.runAttemptID, priorAttempt.runAttemptID, "H keeps its own attempt")
        XCTAssertEqual(steered.latestTurnID(of: runningAttempt), executionTurnID)

        // The transcript resolves A's execution turn to E (the last turn carrying it), else A's ID.
        let anchor = AgentTranscriptRequestAnchor(from: AgentChatItem.user("saved message", id: itemID))
        var placed = execution
        placed.request = anchor
        XCTAssertEqual(AgentTranscript(turns: [historical, placed]).executionTurnID(forUserItemID: itemID), executionTurnID)
        var unmoved = historical
        unmoved.request = anchor
        XCTAssertEqual(AgentTranscript(turns: [unmoved]).executionTurnID(forUserItemID: itemID), itemID)
        XCTAssertEqual(AgentTranscript(turns: [historical]).executionTurnID(forUserItemID: itemID), itemID)
    }
}
