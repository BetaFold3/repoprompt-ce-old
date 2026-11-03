import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// `/compact` readiness after the controller was detached (Stop, restart): the saved thread is
/// resumed before compaction, a failed or contended reconnect is never reported as a missing
/// conversation, and compaction never overlaps a turn admitted while readiness was suspended.
@MainActor
final class CodexCompactReadinessTests: XCTestCase {
    private static let noConversationMessage = "Start a Codex conversation before using /compact."

    /// cycle9.K: a real `/compact` on an active thread, cancelled through the view model's Stop
    /// path, then `/compact` again. Stop detaches the controller and keeps the thread metadata; the
    /// second `/compact` resumes that same thread on a fresh controller and compacts once.
    func testCancelledCompactionThenCompactResumesSameThreadAndRequestsCompaction() async {
        let first = CompactReadinessController(label: "first")
        let fresh = CompactReadinessController(label: "fresh")
        let (viewModel, session) = makeSession(controllers: [first, fresh])

        let firstResult = await compact(viewModel, session)
        XCTAssertEqual(firstResult, .succeeded("Requested Codex context compaction."))
        XCTAssertEqual(first.compactCount, 1)
        XCTAssertTrue(session.runState.isActive, "the compaction is in flight")
        XCTAssertEqual(session.codexPendingTurnKind, .compact)

        await viewModel.cancelAgentRun(
            tabID: session.tabID,
            cause: .userCancel,
            completion: .terminalTeardownCompleted
        )

        XCTAssertFalse(session.runState.isActive)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexController, "Stop detaches the controller")
        XCTAssertTrue(session.codexNeedsReconnect)
        XCTAssertEqual(session.codexConversationID, "thread", "Stop keeps the saved thread")

        let result = await compact(viewModel, session)

        XCTAssertEqual(result, .succeeded("Requested Codex context compaction."))
        XCTAssertEqual(fresh.resumedConversationIDs, ["thread"], "the same saved thread is resumed")
        XCTAssertEqual(fresh.compactCount, 1)
        XCTAssertEqual(first.compactCount, 1)
        XCTAssertFalse(session.codexNeedsReconnect)
    }

    /// Persisted thread with no controller and a delayed reconnect: nothing is compacted while
    /// the resume is pending, then compaction is requested exactly once on the resumed thread.
    func testDelayedReconnectCompactsOnceAfterResume() async {
        let gate = CompactReadinessGate()
        let fresh = CompactReadinessController(label: "fresh", resumeGate: gate)
        let (viewModel, session) = makeSession(controllers: [fresh])

        let task = Task { await compact(viewModel, session) }
        await gate.waitUntilWaiting()
        XCTAssertEqual(fresh.compactCount, 0)
        XCTAssertFalse(session.runState.isActive, "readiness does not mark a run")

        await gate.release()
        let result = await task.value

        XCTAssertEqual(result, .succeeded("Requested Codex context compaction."))
        XCTAssertEqual(fresh.resumedConversationIDs, ["thread"])
        XCTAssertEqual(fresh.compactCount, 1)
    }

    /// A reconnect that fails keeps the saved thread and reports a reconnect failure, not
    /// "Start a Codex conversation".
    func testFailedReconnectReportsReconnectFailureNotMissingConversation() async {
        let fresh = CompactReadinessController(label: "fresh", resumeErrors: [CompactReadinessTestError.resumeFailed])
        let (viewModel, session) = makeSession(controllers: [fresh])

        let result = await compact(viewModel, session)

        guard case let .failed(message) = result else {
            return XCTFail("Expected /compact to fail, got \(result)")
        }
        XCTAssertNotEqual(message, Self.noConversationMessage)
        XCTAssertEqual(message, CodexAgentModeCoordinator.compactReconnectFailedMessage)
        XCTAssertEqual(fresh.compactCount, 0)
        XCTAssertEqual(session.codexConversationID, "thread", "the saved thread is kept")
        XCTAssertFalse(session.runState.isActive)

        // The retry the message promises: the next /compact resumes the same thread and compacts.
        let retry = await compact(viewModel, session)
        XCTAssertEqual(retry, .succeeded("Requested Codex context compaction."))
        XCTAssertEqual(fresh.resumedConversationIDs, ["thread", "thread"])
        XCTAssertEqual(fresh.compactCount, 1)
    }

    /// Controller replacement during readiness: while `/compact`'s resume is suspended, an MCP-style
    /// permission change makes another readiness replace the controller and start its own resume.
    /// `/compact`'s late success is discarded and it reports that the reconnect is still in
    /// progress (the observed live text was "Start a Codex conversation"), without compacting.
    func testControllerReplacedDuringReadinessReportsReconnectInProgress() async {
        let firstGate = CompactReadinessGate()
        let successorGate = CompactReadinessGate()
        let first = CompactReadinessController(label: "first", resumeGate: firstGate)
        let successor = CompactReadinessController(label: "successor", resumeGate: successorGate)
        let (viewModel, session) = makeSession(controllers: [first, successor])

        let compactTask = Task { await compact(viewModel, session) }
        await firstGate.waitUntilWaiting()
        session.permissionProfile = .mcpSafeDefaults
        let replacementTask = Task {
            await viewModel.test_codexCoordinator.ensureCodexNativeSession(session: session)
        }
        await successorGate.waitUntilWaiting()
        XCTAssertTrue(session.codexController === successor, "the replacement owns the slot")
        await firstGate.release()
        let result = await compactTask.value

        guard case let .failed(message) = result else {
            return XCTFail("Expected /compact to be refused, got \(result)")
        }
        XCTAssertNotEqual(message, Self.noConversationMessage)
        XCTAssertEqual(message, CodexAgentModeCoordinator.compactReconnectInProgressMessage)
        XCTAssertEqual(first.compactCount, 0)
        XCTAssertEqual(successor.compactCount, 0)
        XCTAssertTrue(session.codexController === successor, "the late success never takes the slot back")
        XCTAssertFalse(session.runState.isActive)

        await successorGate.release()
        await replacementTask.value
        XCTAssertTrue(successor.hasActiveThread)
        XCTAssertEqual(successor.resumedConversationIDs, ["thread"], "the replacement resumes the same thread")
        XCTAssertEqual(session.codexConversationID, "thread")
        // Once the replacement settled, /compact compacts on it.
        let retry = await compact(viewModel, session)
        XCTAssertEqual(retry, .succeeded("Requested Codex context compaction."))
        XCTAssertEqual(successor.compactCount, 1)
        XCTAssertEqual(first.compactCount, 0)
    }

    /// A concurrent submission admitted while `/compact` waits for the shared reconnect: the turn
    /// starts on the resumed thread and compaction is not requested over it.
    /// The factory offers two distinct controllers sharing one gate. Production readiness creates a
    /// controller only for an empty slot (`prepareCodexController`), so the send reuses the slot's
    /// controller and the second one is never requested.
    func testConcurrentSubmissionDuringReadinessIsNotOverlappedByCompaction() async {
        let gate = CompactReadinessGate()
        let fresh = CompactReadinessController(label: "fresh", resumeGate: gate)
        let other = CompactReadinessController(label: "other", resumeGate: gate)
        let (viewModel, session) = makeSession(controllers: [fresh, other])

        let compactTask = Task { await compact(viewModel, session) }
        await gate.waitUntilWaiting(count: 1)
        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "K3",
                attachments: []
            )
        }
        await gate.waitUntilWaiting(count: 2)
        await gate.release()
        let compactResult = await compactTask.value
        _ = await sendTask.value

        guard case let .failed(message) = compactResult else {
            return XCTFail("Expected /compact to yield to the admitted turn, got \(compactResult)")
        }
        XCTAssertEqual(message, CodexAgentModeCoordinator.compactTurnStartedDuringReconnectMessage)
        XCTAssertEqual(fresh.compactCount, 0, "compaction never overlaps the admitted turn")
        XCTAssertEqual(other.compactCount, 0)
        XCTAssertEqual(fresh.startedTurnTexts, ["K3"], "the send started on the slot's controller")
        XCTAssertEqual(other.startedTurnTexts, [])
        XCTAssertEqual(other.resumedConversationIDs, [], "no second controller was created")
        XCTAssertTrue(session.codexController === fresh)
        XCTAssertNotEqual(session.codexPendingTurnKind, .compact)
    }

    /// A run attempt that starts and finishes while `/compact` waits for the reconnect leaves the
    /// run idle again; the generation still supersedes `/compact`.
    func testRunStartedAndFinishedDuringReadinessRefusesCompaction() async {
        let gate = CompactReadinessGate()
        let fresh = CompactReadinessController(label: "fresh", resumeGate: gate)
        let (viewModel, session) = makeSession(controllers: [fresh])

        let task = Task { await compact(viewModel, session) }
        await gate.waitUntilWaiting()
        let intervening = session.beginRunAttempt(source: "test.compact.intervening")
        session.runState = .running
        session.runState = .idle
        XCTAssertTrue(session.endRunAttempt(ifCurrent: intervening, source: "test.compact.intervening"))
        XCTAssertFalse(session.runState.isActive)
        await gate.release()
        let result = await task.value

        XCTAssertEqual(result, .failed(CodexAgentModeCoordinator.compactTurnStartedDuringReconnectMessage))
        XCTAssertEqual(fresh.compactCount, 0)
        XCTAssertNotEqual(session.codexPendingTurnKind, .compact)
    }

    /// The tab is rebound to another agent session while `/compact` waits for the reconnect.
    func testAgentSessionRebindDuringReadinessRefusesCompaction() async {
        let gate = CompactReadinessGate()
        let fresh = CompactReadinessController(label: "fresh", resumeGate: gate)
        let (viewModel, session) = makeSession(controllers: [fresh])
        let originalSessionID = session.activeAgentSessionID

        let task = Task { await compact(viewModel, session) }
        await gate.waitUntilWaiting()
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        XCTAssertNotEqual(session.activeAgentSessionID, originalSessionID)
        await gate.release()
        let result = await task.value

        guard case let .failed(message) = result else {
            return XCTFail("Expected /compact to be refused, got \(result)")
        }
        XCTAssertEqual(message, CodexAgentModeCoordinator.compactSessionChangedDuringReconnectMessage)
        XCTAssertEqual(fresh.compactCount, 0)
        XCTAssertFalse(session.runState.isActive)
    }

    /// No thread metadata at all keeps the existing "no conversation" guidance.
    func testNoThreadMetadataKeepsNoConversationMessage() async {
        let fresh = CompactReadinessController(label: "fresh")
        let (viewModel, session) = makeSession(controllers: [fresh])
        session.codexConversationID = nil
        session.codexRolloutPath = nil

        let result = await compact(viewModel, session)

        XCTAssertEqual(result, .failed(Self.noConversationMessage))
        XCTAssertEqual(fresh.resumedConversationIDs, [])
        XCTAssertEqual(fresh.compactCount, 0)
    }

    // MARK: - Helpers

    /// An idle Codex session with a persisted thread and no controller (after Stop or a restart).
    private func makeSession(
        controllers: [CompactReadinessController]
    ) -> (AgentModeViewModel, AgentTabSession) {
        let factory = CompactReadinessControllerFactory(controllers: controllers)
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in factory.next() }
        )
        viewModel.test_initializeRunService()
        let session = viewModel.session(for: UUID(), createIfNeeded: true)!
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.codexConversationID = "thread"
        session.codexNeedsReconnect = true
        return (viewModel, session)
    }

    private func compact(
        _ viewModel: AgentModeViewModel,
        _ session: AgentTabSession
    ) async -> CodexAgentModeCoordinator.NativeSlashCommandExecutionResult {
        await viewModel.test_codexCoordinator.executeNativeSlashCommand(
            .compact,
            argumentsText: "",
            session: session
        )
    }
}

private enum CompactReadinessTestError: LocalizedError {
    case resumeFailed

    var errorDescription: String? {
        "resume failed"
    }
}

/// Hands out controllers in order; later requests reuse the last one.
private final class CompactReadinessControllerFactory: @unchecked Sendable {
    private var controllers: [CompactReadinessController]

    init(controllers: [CompactReadinessController]) {
        self.controllers = controllers
    }

    func next() -> CompactReadinessController {
        controllers.count > 1 ? controllers.removeFirst() : controllers[0]
    }
}

/// Suspends every resume until released (multiple waiters).
private actor CompactReadinessGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var waitingCount = 0

    func wait() async {
        guard !released else { return }
        waitingCount += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilWaiting(count: Int = 1, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while waitingCount < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(waitingCount, count, "Timed out waiting for a suspended resume")
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A controller whose thread becomes active only once `startOrResume` returns, like the real one.
private final class CompactReadinessController: CodexSessionControlling {
    let label: String
    private let resumeGate: CompactReadinessGate?
    /// Thrown by successive resumes, in order; later resumes succeed.
    private var resumeErrors: [Error]
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    private(set) var hasActiveThread: Bool
    private(set) var resumedConversationIDs: [String?] = []
    private(set) var compactCount = 0
    private(set) var startedTurnTexts: [String] = []

    init(
        label: String,
        hasActiveThread: Bool = false,
        resumeGate: CompactReadinessGate? = nil,
        resumeErrors: [Error] = []
    ) {
        self.label = label
        self.hasActiveThread = hasActiveThread
        self.resumeGate = resumeGate
        self.resumeErrors = resumeErrors
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
    }

    deinit {
        eventContinuation.finish()
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(existing: existing, baseInstructions: baseInstructions, model: nil, reasoningEffort: nil, serviceTier: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(existing: existing, baseInstructions: baseInstructions, model: model, reasoningEffort: reasoningEffort, serviceTier: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        resumedConversationIDs.append(existing?.conversationID)
        await resumeGate?.wait()
        if !resumeErrors.isEmpty {
            throw resumeErrors.removeFirst()
        }
        hasActiveThread = true
        return .init(
            conversationID: existing?.conversationID ?? "new-thread",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startedTurnTexts.append(text)
        return .init(provisionalSubmissionID: "\(label)-submission-\(startedTurnTexts.count)")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async {
        compactCount += 1
    }

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
