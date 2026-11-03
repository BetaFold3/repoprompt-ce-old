import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorLivenessTests: XCTestCase {
    func testActiveThreadSnapshotCountsAsWatchdogLivenessAndReconcilesWaitingFlags() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: ["waiting_for_user_input"]))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let waitingStatus = "Codex reports it is waiting for user input…"

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)

        try await waitUntil {
            controller.readSnapshotCountSync() > 0 && session.runningStatusText == waitingStatus
        }

        XCTAssertEqual(session.runningStatusText, waitingStatus)
        XCTAssertFalse(session.items.contains { item in
            item.kind == .error && item.text.contains("Repo Prompt thinks Codex has stalled")
        })
    }

    func testStructuredLivenessAdvancesLifecycleWithoutTranscriptRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineItems = session.items
        let previousSequence = session.activeRunLiveness?.lastAcceptedSequence ?? 0

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .livenessActivity(.init(
                kind: .mcpToolProgress,
                method: "item/mcpToolCall/progress",
                threadID: "fake",
                turnID: "turn",
                itemID: "item",
                activeFlags: ["waiting_for_user_input"],
                message: "progress"
            )),
            session: session
        )

        XCTAssertEqual(session.items, baselineItems)
        XCTAssertGreaterThan(session.activeRunLiveness?.lastAcceptedSequence ?? 0, previousSequence)
        XCTAssertEqual(session.activeRunLiveness?.stage, .running)
        XCTAssertEqual(session.runningStatusText, "Codex reports it is waiting for user input…")
        XCTAssertEqual(session.runState, .running)
    }

    func testUnmatchedCompletionOnlyWebResultPreservesArgsForPersistenceAndReplay() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let invocationID = UUID()
        let argsJSON = #"{"action":"find_in_page","url":"https://example.com/docs","pattern":"install"}"#
        let resultJSON = #"{"status":"completed","match_count":2}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "search",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: false
            ),
            session: session
        )

        let item = try XCTUnwrap(session.items.last)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.toolInvocationID, invocationID)
        XCTAssertEqual(item.toolArgsJSON, argsJSON)
        let livePresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "search")
        )
        XCTAssertEqual(livePresentation.title, "Find In Page")

        let persisted = AgentChatItemPersist(from: item)
        let restored = persisted.toItem()
        XCTAssertEqual(restored.toolInvocationID, invocationID)
        let restoredPresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: restored, normalizedToolName: "search")
        )
        XCTAssertEqual(restoredPresentation.title, "Find In Page")
        XCTAssertEqual(restoredPresentation.detailText, "2 matches")
    }

    func testStructuredRetryAndMissingMetadataFallbackRemainActiveWithoutRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "provider retry",
                willRetry: true,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.activeRunLiveness?.retryIntent, .providerManaged)
        XCTAssertEqual(session.items, baselineItems)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "Reconnecting... legacy payload",
                willRetry: nil,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testStructuredFailedCompletionUsesOneTerminalCommitAndPreservesTail() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineDrainGeneration = session.providerTerminalDrainGeneration

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("assistant tail"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "authoritative provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "duplicate provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .error("Codex transport closed unexpectedly."),
            session: session
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.activeRunOwnership)
        let revision = session.lastTerminalCommitRevision
        XCTAssertNotNil(revision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision?.providerDrainGeneration, session.providerTerminalDrainGeneration)
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .error }.map(\.kind),
            [.assistant, .error]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .error }.map(\.text),
            ["authoritative provider error"]
        )
    }

    func testTurnCompletionCoalescesBufferedAssistantTailBeforeTerminalSeal() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))
        let commandInvocationID = UUID()
        session.appendItem(.toolResult(
            name: "bash",
            invocationID: commandInvocationID,
            argsJSON: "{}",
            resultJSON: #"{"status":"completed"}"#,
            isError: false,
            sequenceIndex: session.nextSequenceIndex
        ))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        let streamingPrefix = try XCTUnwrap(session.items.last)
        XCTAssertEqual(streamingPrefix.kind, .assistant)
        XCTAssertEqual(streamingPrefix.text, "answer")
        XCTAssertTrue(streamingPrefix.isStreaming)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("."),
            session: session
        )
        XCTAssertEqual(session.pendingAssistantDelta, ".")
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        session.pendingCommandRunningByKey["terminal-test"] = .init(
            invocationID: commandInvocationID,
            processID: nil,
            appendedOutput: nil,
            sealsAssistantBoundary: false
        )
        session.pendingCommandRunningFlushTask = Task {}
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer."])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
        XCTAssertNil(session.pendingCommandRunningFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(revision.terminalState, .completed)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(revision.assistantDeltaFlushGeneration, session.assistantDeltaFlushGeneration)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
    }

    func testTurnCompletionWaitsForLateAssistantCompletionBeforeTerminalCommit() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "partial final summary is complete")),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final summary is complete"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
    }

    func testAssistantCompletionBeforeTurnCompletionUsesFastTerminalPath() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "partial final summary is complete")),
            session: session
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final summary is complete"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testTurnCompletionSettleTimeoutCommitsPartialAssistantWithoutHanging() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))

        await viewModel.test_codexCoordinator.test_forcePendingCodexTerminalSettleTimeout(session: session)

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testTurnStartedDuringAssistantSettleCommitsPendingTerminalBeforeNewTurn() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "next-turn"),
            session: session
        )

        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
    }

    func testDifferentTurnCompletionDuringAssistantSettleCommitsPendingTerminal() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let runID = try XCTUnwrap(session.runID)
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "next-turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        session.codexRoutingObservedTurnID = "next-turn"

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "next-turn", status: .completed),
            session: session
        )

        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
    }

    func testSettleScopeRejectsMatchingItemFromDifferentThread() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let previousSequence = session.activeRunLiveness?.lastAcceptedSequence ?? 0

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .livenessActivity(.init(
                kind: .mcpToolProgress,
                method: "item/mcpToolCall/progress",
                threadID: "different-thread",
                turnID: scope.turnID,
                itemID: scope.itemID,
                activeFlags: ["waiting_for_user_input"],
                message: "stale progress"
            )),
            session: session
        )

        XCTAssertEqual(session.activeRunLiveness?.lastAcceptedSequence ?? 0, previousSequence)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
    }

    func testInterruptedTurnCompletionBypassesAssistantSettle() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .interrupted),
            session: session
        )

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .cancelled)
    }

    func testCanonicalAssistantCompletionReconcilesNoDeltaExactPrefixUTF8DuplicateAndEmpty() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: noDeltaScope, text: "no delta")),
            session: session
        )

        let exactScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-exact"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "exact", scope: exactScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: exactScope, text: "exact")),
            session: session
        )

        let prefixScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-prefix"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "answer", scope: prefixScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: prefixScope, text: "answer.")),
            session: session
        )

        let utf8Scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-utf8"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "👨", scope: utf8Scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let utf8Completion = CodexNativeSessionController.AssistantCompletionPayload(
            scope: utf8Scope,
            text: "👨‍👩‍👧"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )

        let removedScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-empty"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "remove me", scope: removedScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: removedScope, text: "")),
            session: session
        )

        let assistants = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.map(\.text), ["no delta", "exact", "answer.", "👨‍👩‍👧"])
        XCTAssertTrue(assistants.allSatisfy { !$0.isStreaming })
        XCTAssertNil(session.codexAssistantRowIDByScope[removedScope])
    }

    func testCanonicalAssistantCompletionFlushesEarlierPendingScopeFirst() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let firstScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-first"
        )
        let secondScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-second"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "first", scope: firstScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: secondScope, text: "second")),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["first", "second"])
        XCTAssertTrue(assistantItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalAssistantNonPrefixCompletionReplacesMappedRowAcrossToolBoundary() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-tool"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "draft response", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let originalRowID = try XCTUnwrap(session.items.last?.id)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "final response")),
            session: session
        )

        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items[0].id, originalRowID)
        XCTAssertEqual(session.items[0].kind, .assistant)
        XCTAssertEqual(session.items[0].text, "final response")
        XCTAssertFalse(session.items[0].isStreaming)
        XCTAssertEqual(session.items[1].kind, .toolCall)
    }

    func testCanonicalMCPResultOnlyDoesNotOverwriteDifferentInvocation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let firstInvocationID = UUID()
        let resultOnlyInvocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(
                name: "lookup",
                invocationID: firstInvocationID,
                argsJSON: #"{"query":"first"}"#
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "lookup",
                invocationID: resultOnlyInvocationID,
                argsJSON: #"{"query":"second"}"#,
                resultJSON: #"{"content":"second result"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.map(\.kind), [.toolCall, .toolResult])
        XCTAssertEqual(toolItems.map(\.toolInvocationID), [firstInvocationID, resultOnlyInvocationID])
    }

    func testMismatchedBashMirrorInvocationStillReconcilesRunningRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let startedInvocationID = UUID()
        let completedInvocationID = UUID()
        let argsJSON = #"{"command":"printf probe"}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "bash", invocationID: startedInvocationID, argsJSON: argsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: startedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"inProgress","processId":"probe-1","delta":"running"}"#,
                isError: false
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: completedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"completed","processId":"probe-1","aggregatedOutput":"done"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.count, 1)
        XCTAssertEqual(toolItems.first?.toolInvocationID, completedInvocationID)
    }

    func testReasoningSealsEarlierPendingAssistantBeforeMaterializing() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let assistantScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-reasoning"
        )
        let reasoningScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-after-assistant"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "assistant first", scope: assistantScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "draft reasoning",
                kind: .summary,
                itemID: reasoningScope.itemID,
                groupID: "summary:\(reasoningScope.itemID):0",
                index: 0,
                scope: reasoningScope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: reasoningScope,
                summary: ["final reasoning"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.kind),
            [.assistant, .thinking]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.text),
            ["assistant first", "final reasoning"]
        )
    }

    func testCanonicalReasoningCompletionMaterializesReplacesAndRemovesSegments() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-item"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Draft summary",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):0",
                index: 0,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "orphan body",
                kind: .text,
                itemID: scope.itemID,
                groupID: "text:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        XCTAssertEqual(session.items.count(where: { $0.kind == .thinking }), 2)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["Final summary"],
                content: ["Final body"]
            )),
            session: session
        )

        var thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(thinkingItems.map(\.text), ["Final summary\n\nFinal body"])
        XCTAssertEqual(thinkingItems.map(\.isStreaming), [false])
        XCTAssertEqual(Set(session.codexReasoningSegmentsByKey.keys), ["reasoning:reasoning-item:0"])

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: noDeltaScope,
                summary: ["First", "Second"],
                content: ["Body one", "Body two"]
            )),
            session: session
        )

        thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(
            thinkingItems.map(\.text),
            ["Final summary\n\nFinal body", "First\n\nBody one", "Second\n\nBody two"]
        )
        XCTAssertTrue(thinkingItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalReasoningCompletionInsertsMissingLowerIndexBeforeStreamedRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-partial"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Second draft",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["First", "Second"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking }.map(\.text),
            ["First", "Second"]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking || $0.kind == .toolCall }.map(\.kind),
            [.thinking, .thinking, .toolCall]
        )
    }

    func testCancellationClearsCanonicalAssistantAndReasoningReconciliationState() {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-item"
        )
        let rowID = UUID()
        session.pendingCodexAssistantScope = scope
        session.codexAssistantRowIDByScope[scope] = rowID
        session.activeReasoningItemID = rowID
        session.reasoningItemIDsByGroupID["reasoning-group"] = rowID
        session.codexReasoningSegmentsByKey["reasoning:reasoning-item:0"] = .init(
            summaryMarkdown: "draft",
            transcriptItemID: rowID
        )

        viewModel.test_codexCoordinator.drainCodexTerminalBuffersForCancellation(session)

        XCTAssertNil(session.pendingCodexAssistantScope)
        XCTAssertTrue(session.codexAssistantRowIDByScope.isEmpty)
        XCTAssertNil(session.activeReasoningItemID)
        XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty)
        XCTAssertTrue(session.codexReasoningSegmentsByKey.isEmpty)
    }

    func testTurnCompletionClearsEmptyScheduledAssistantFlushBeforeBarrier() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))

        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("answer", session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("", session: session)

        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
    }

    func testStaleStructuredScopeIsIgnored() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineItems = session.items
        let baselineLiveness = session.activeRunLiveness

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "old-turn",
                itemID: "old-item"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness, baselineLiveness)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testScopedErrorWithoutAuthoritativeIdentityFailsClosed() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.codexAuthoritativeActiveTurn = nil
        let baselineItems = session.items
        let baselineOwnership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "untrusted-routing-turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, baselineOwnership)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testWatchdogPauseRemainsRunningAndDoesNotAppendTranscriptFailure() async throws {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            session.codexWatchdogState.isPausedAfterWarning
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.items.count, baselineItems.count + 1)
        XCTAssertEqual(session.items.last?.kind, .assistant)
        XCTAssertEqual(session.items.last?.text, "progress")
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertEqual(session.runningStatusText, "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume.")
    }

    func testWatchdogFlushesCachedExplicitErrorWhenProbeFindsNoActiveTurn() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            pendingTurnFailure: .init(message: "explicit watchdog error")
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("progress"),
            session: session
        )

        try await waitUntil {
            session.runState == .failed
        }

        XCTAssertEqual(session.items.filter { $0.kind == .error }.map(\.text), [
            "explicit watchdog error"
        ])
        let remainingFailure = await controller.pendingTurnFailure(turnID: "turn")
        XCTAssertNil(remainingFailure)
        XCTAssertNotEqual(
            session.runningStatusText,
            "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume."
        )
    }

    func testPendingRequestUserInputSuppressesWatchdogAndPreservesQueue() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let pending = makeUserInputRequest(id: "pending")
        let queued = makeUserInputRequest(id: "queued")
        session.pendingUserInputRequest = pending
        session.queuedUserInputRequests = [queued]

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.readSnapshotCountSync(), 0)
        XCTAssertEqual(session.pendingUserInputRequest?.requestID, pending.requestID)
        XCTAssertEqual(session.queuedUserInputRequests.map(\.requestID), [queued.requestID])
    }

    // MARK: Native question creation (plan §E; review A F02 / B F3, F11, F17)

    private enum NativeQuestionKind: String, CaseIterable {
        case userInput
        case elicitation
    }

    private struct NativeQuestion {
        let event: CodexNativeSessionController.Event
        let interactionID: UUID
    }

    private func nativeQuestion(_ kind: NativeQuestionKind, id: String, turnID: String = "turn") -> NativeQuestion {
        switch kind {
        case .userInput:
            let request = makeUserInputRequest(id: id, threadID: "fake", turnID: turnID)
            return NativeQuestion(event: .requestUserInput(request), interactionID: request.id)
        case .elicitation:
            let request = AgentMCPElicitationRequest(
                requestID: .string(id),
                method: "mcpServer/elicitation/request",
                threadID: "fake",
                turnID: turnID,
                itemID: id,
                serverName: "server",
                message: "Continue?",
                rawParamsJSON: "{}"
            )
            return NativeQuestion(event: .mcpElicitationRequest(request), interactionID: request.id)
        }
    }

    /// Shown (active) first, then queued, per kind.
    private func shownAndQueued(_ kind: NativeQuestionKind, _ session: AgentTabSession) -> (shown: UUID?, queued: [UUID]) {
        switch kind {
        case .userInput:
            (session.pendingUserInputRequest?.id, session.queuedUserInputRequests.map(\.id))
        case .elicitation:
            (session.pendingMCPElicitationRequest?.id, session.queuedMCPElicitationRequests.map(\.id))
        }
    }

    /// The actual Codex producers commit the snapshot before the request is shown or queued: while
    /// the creation write is held nothing is published; after it commits the stored snapshot exists
    /// and the request is queued behind the active one. No reply is sent.
    func testNativeQuestionIsCommittedBeforeItIsShownOrQueued() async throws {
        for kind in NativeQuestionKind.allCases {
            let writes = CodexQuestionWriteControl()
            let fixture = try await RecoveryLaneFixture.make("codex-question-order-\(kind.rawValue)", fileOperations: writes.fileOperations())
            defer { fixture.tearDown() }
            let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
            let viewModel = makeViewModel(controller: controller)
            guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
                return XCTFail("Expected the Codex test session to materialize")
            }
            let first = nativeQuestion(kind, id: "first-\(kind.rawValue)")
            let second = nativeQuestion(kind, id: "second-\(kind.rawValue)")

            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(first.event, session: session)
            XCTAssertEqual(shownAndQueued(kind, session).shown, first.interactionID, "\(kind)")

            writes.holdNextWrite()
            let handling = Task { @MainActor in
                await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(second.event, session: session)
            }
            try await waitUntil { writes.isHolding }
            XCTAssertEqual(shownAndQueued(kind, session).queued, [], "\(kind): not queued before its snapshot commits")
            writes.release()
            await handling.value

            XCTAssertEqual(shownAndQueued(kind, session).shown, first.interactionID, "\(kind)")
            XCTAssertEqual(shownAndQueued(kind, session).queued, [second.interactionID], "\(kind)")
            let stored = await fixture.store.read(sessionID: fixture.sessionID).record?.questions.map(\.interactionID) ?? []
            XCTAssertEqual(Set(stored), [first.interactionID, second.interactionID], "\(kind)")
            XCTAssertEqual(fixture.lane.questionPersistence.liveInteractionIDs, [first.interactionID, second.interactionID], "\(kind)")
            XCTAssertTrue(controller.serverResponseIDs.isEmpty, "\(kind)")
            XCTAssertTrue(session.runState.isActive, "\(kind): the run waits for the question")
        }
    }

    /// A failed creation write is never shown or queued and never answered: the snapshot is
    /// withdrawn, the lane surfaces a question save-failure catalog item, and the run takes the
    /// existing producer failure path with a generic error. An explicit Retry with nothing left
    /// unsaved settles the item.
    func testNativeQuestionCreationWriteFailureFailsRunWithoutShowingOrReplying() async throws {
        for kind in NativeQuestionKind.allCases {
            let writes = CodexQuestionWriteControl()
            let fixture = try await RecoveryLaneFixture.make("codex-question-fail-\(kind.rawValue)", fileOperations: writes.fileOperations())
            defer { fixture.tearDown() }
            let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
            let viewModel = makeViewModel(controller: controller)
            guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
                return XCTFail("Expected the Codex test session to materialize")
            }
            let question = nativeQuestion(kind, id: "fail-\(kind.rawValue)")
            let saveFailureItemID = AgentRecoveryCatalogProjection.questionSaveFailureItemID(sessionID: fixture.sessionID)
            writes.failNextWrite()

            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(question.event, session: session)

            XCTAssertTrue(AgentRecoveryLiveQuestions.liveInteractionIDs(of: session).isEmpty, "\(kind): never shown or queued")
            try await waitUntil { session.runState == .failed }
            XCTAssertTrue(
                session.items.contains { $0.kind == .error && $0.text == CodexAgentModeCoordinator.unsavedQuestionRunFailureMessage },
                "\(kind): the run fails with the generic message"
            )
            XCTAssertTrue(controller.serverResponseIDs.isEmpty, "\(kind): no reply is synthesized")
            try await waitUntil { !controller.interruptedTurnIDs.isEmpty }
            XCTAssertEqual(controller.interruptedTurnIDs, ["turn"], "\(kind): exactly the asking turn is interrupted")
            XCTAssertEqual(controller.cancelCurrentTurnCount, 0, "\(kind)")
            let questions = fixture.lane.questionPersistence
            XCTAssertNotNil(questions.lastWriteFailure, "\(kind)")
            XCTAssertFalse(questions.liveInteractionIDs.contains(question.interactionID), "\(kind)")
            XCTAssertFalse(questions.hasPendingWork, "\(kind): the withdrawn snapshot is not retried")
            let stored = await fixture.store.read(sessionID: fixture.sessionID).record?.questions ?? []
            XCTAssertTrue(stored.isEmpty, "\(kind)")
            XCTAssertTrue(fixture.coordinator.catalog.items.contains { $0.id == saveFailureItemID }, "\(kind): the save error is visible")

            let retried = await questions.flush()
            XCTAssertEqual(retried, .nothingPending)
            XCTAssertNil(questions.lastWriteFailure, "\(kind)")
            XCTAssertFalse(fixture.coordinator.catalog.items.contains { $0.id == saveFailureItemID }, "\(kind)")
        }
    }

    /// Review R2 (A F11-R2): a replacement run attempt starts during the failed run's finalization
    /// (inside the terminal publication, after the failed attempt ended), with no authoritative turn
    /// ID captured initially. Only the asking request's exact turn is interrupted, never the
    /// replacement's turn and never through an unscoped current-turn interrupt; with no known
    /// identity nothing is interrupted. The failure stays visible and the replacement keeps running.
    func testUnsavedQuestionFailureInterruptsOnlyTheAskingTurnWhenAReplacementStartsDuringFinalization() async throws {
        for kind in NativeQuestionKind.allCases {
            for askingTurnKnown in [true, false] {
                let label = "\(kind)/asking-turn-known:\(askingTurnKnown)"
                let writes = CodexQuestionWriteControl()
                let fixture = try await RecoveryLaneFixture.make("codex-question-finalize-\(kind.rawValue)-\(askingTurnKnown)", fileOperations: writes.fileOperations())
                defer { fixture.tearDown() }
                let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
                let viewModel = makeViewModel(controller: controller)
                guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
                    return XCTFail("Expected the Codex test session to materialize")
                }
                session.codexAuthoritativeActiveTurn = nil
                let replacementRunID = UUID()
                var replacementStarted = false
                viewModel.test_setTerminalPublicationOverride { _, _, published in
                    if !replacementStarted, published === session, !session.runState.isActive {
                        replacementStarted = true
                        session.runID = replacementRunID
                        session.runState = .running
                        let ownership = session.beginRunAttempt(source: "test.replacementDuringFinalization")
                        session.codexAuthoritativeActiveTurn = .init(
                            threadID: "fake",
                            turnID: "replacement-turn",
                            turnKind: .user,
                            controllerInstanceID: ObjectIdentifier(controller),
                            controllerGeneration: session.codexControllerGeneration,
                            runID: replacementRunID,
                            runAttemptID: ownership.attemptID
                        )
                    }
                    return .accepted(successorEpoch: nil)
                }
                let question = nativeQuestion(kind, id: "finalize-\(kind.rawValue)", turnID: askingTurnKnown ? "asking-turn" : "")
                writes.failNextWrite()

                await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(question.event, session: session)
                viewModel.test_setTerminalPublicationOverride(nil)

                XCTAssertTrue(replacementStarted, "\(label): the replacement started during finalization")
                XCTAssertEqual(session.runID, replacementRunID, label)
                XCTAssertTrue(session.runState.isActive, "\(label): the replacement keeps running")
                XCTAssertTrue(
                    session.items.contains { $0.kind == .error && $0.text == CodexAgentModeCoordinator.unsavedQuestionRunFailureMessage },
                    "\(label): the failure stays visible"
                )
                XCTAssertTrue(controller.serverResponseIDs.isEmpty, label)
                if askingTurnKnown {
                    try await waitUntil { !controller.interruptedTurnIDs.isEmpty }
                } else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertEqual(controller.interruptedTurnIDs, askingTurnKnown ? ["asking-turn"] : [], "\(label): only the asking turn")
                XCTAssertEqual(controller.cancelCurrentTurnCount, 0, "\(label): never an unscoped current-turn interrupt")
            }
        }
    }

    /// A replacement run attempt that takes the tab while the creation write is suspended (the run
    /// stays active, so an active-run-only fence would pass) must not receive the old request: it is
    /// neither shown nor queued nor answered, and its snapshot's exact removal is written.
    func testNativeQuestionSuspendedAcrossRunReplacementIsNotShownAndItsSnapshotEnds() async throws {
        for kind in NativeQuestionKind.allCases {
            let writes = CodexQuestionWriteControl()
            let fixture = try await RecoveryLaneFixture.make("codex-question-replaced-\(kind.rawValue)", fileOperations: writes.fileOperations())
            defer { fixture.tearDown() }
            let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
            let viewModel = makeViewModel(controller: controller)
            guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
                return XCTFail("Expected the Codex test session to materialize")
            }
            let question = nativeQuestion(kind, id: "replaced-\(kind.rawValue)")
            writes.holdNextWrite()
            let handling = Task { @MainActor in
                await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(question.event, session: session)
            }
            try await waitUntil { writes.isHolding }
            XCTAssertTrue(session.endCurrentRunAttempt(source: "test.replacement"))
            session.runID = UUID()
            session.beginRunAttempt(source: "test.replacement")
            XCTAssertTrue(session.runState.isActive)
            writes.release()
            await handling.value

            XCTAssertTrue(AgentRecoveryLiveQuestions.liveInteractionIDs(of: session).isEmpty, "\(kind): not shown in the replacement run")
            XCTAssertTrue(controller.serverResponseIDs.isEmpty, "\(kind)")
            XCTAssertEqual(session.runState, .running, "\(kind): the replacement run is untouched")
            XCTAssertTrue(controller.interruptedTurnIDs.isEmpty && controller.cancelCurrentTurnCount == 0, "\(kind): the replacement turn is not interrupted")
            let questions = fixture.lane.questionPersistence
            XCTAssertFalse(questions.liveInteractionIDs.contains(question.interactionID), "\(kind)")
            try await waitUntil { !questions.committedInteractionIDs.contains(question.interactionID) && questions.owedRemovals.isEmpty }
            let stored = await fixture.store.read(sessionID: fixture.sessionID).record?.questions ?? []
            XCTAssertTrue(stored.isEmpty, "\(kind): its exact removal is written")
            XCTAssertNil(questions.lastWriteFailure, "\(kind)")
        }
    }

    private enum LaneHandOver: String, CaseIterable {
        case release
        case successorClaim
    }

    /// Review R1-F2 (P2): the recovery lane is handed over while the same run waits on the creation
    /// write (no lifecycle teardown): released, or (review R2, B R2-F1) replaced by a real same-owner
    /// successor claim. The retired controller cannot keep the question live, so the request is never
    /// shown or answered, the successor never adopts the never-published creation, and the run is not
    /// left active and unanswered: it fails loudly with the generic message and exactly the asking
    /// provider turn is interrupted.
    func testNativeQuestionLaneHandOverDuringCreationFailsTheRunLoudlyAndInterruptsTheProvider() async throws {
        for kind in NativeQuestionKind.allCases {
            for handOver in LaneHandOver.allCases {
                try await assertNativeQuestionLaneHandOverDuringCreation(kind: kind, handOver: handOver)
            }
        }
    }

    private func assertNativeQuestionLaneHandOverDuringCreation(kind: NativeQuestionKind, handOver: LaneHandOver) async throws {
        let label = "\(kind)/\(handOver)"
        do {
            let writes = CodexQuestionWriteControl()
            let fixture = try await RecoveryLaneFixture.make("codex-question-handover-\(kind.rawValue)-\(handOver.rawValue)", fileOperations: writes.fileOperations())
            defer { fixture.tearDown() }
            let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
            let viewModel = makeViewModel(controller: controller)
            guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
                return XCTFail("Expected the Codex test session to materialize")
            }
            let question = nativeQuestion(kind, id: "handover-\(kind.rawValue)")
            let relocatedState = handOver == .successorClaim ? try await fixture.relocatedPersistenceState() : nil
            writes.holdNextWrite()
            let handling = Task { @MainActor in
                await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(question.event, session: session)
            }
            try await waitUntil { writes.isHolding }
            var successor: AgentRecoverySessionLane?
            switch handOver {
            case .release:
                fixture.coordinator.releaseLane(fixture.lane)
                XCTAssertNil(AgentRecoveryLiveQuestions.lane(for: session), "\(label): the session's lane was handed over")
            case .successorClaim:
                let claimed = try fixture.claimSuccessor(persistenceState: XCTUnwrap(relocatedState))
                XCTAssertFalse(claimed === fixture.lane, "\(label): a real successor lane")
                XCTAssertTrue(fixture.lane.isRetired, "\(label): the predecessor retires")
                session.recoveryLane = claimed
                successor = claimed
                XCTAssertFalse(
                    claimed.questionPersistence.liveInteractionIDs.contains(question.interactionID),
                    "\(label): a creation still in flight is not handed over"
                )
            }
            XCTAssertTrue(session.runState.isActive, "\(label): the same run still holds the session")
            XCTAssertNil(session.lifecycleTeardownCause, "\(label)")
            writes.release()
            await handling.value

            XCTAssertTrue(AgentRecoveryLiveQuestions.liveInteractionIDs(of: session).isEmpty, "\(label): never shown or queued")
            try await waitUntil { session.runState == .failed }
            XCTAssertTrue(
                session.items.contains { $0.kind == .error && $0.text == CodexAgentModeCoordinator.unsavedQuestionRunFailureMessage },
                "\(label): the run fails loudly with the generic message"
            )
            XCTAssertTrue(controller.serverResponseIDs.isEmpty, "\(label): no reply is synthesized")
            if let successor {
                XCTAssertFalse(
                    successor.questionPersistence.liveInteractionIDs.contains(question.interactionID),
                    "\(label): the successor never presents the request as live"
                )
            }
            try await waitUntil { !controller.interruptedTurnIDs.isEmpty }
            XCTAssertEqual(controller.interruptedTurnIDs, ["turn"], "\(label): exactly the asking turn is interrupted")
            XCTAssertEqual(controller.cancelCurrentTurnCount, 0, "\(label): never an unscoped current-turn interrupt")
        }
    }

    /// Review R2 (B R2-F1), through a real same-owner successor claim: a committed question's draft
    /// still unsaved (here carried by a held write) is handed over and preserved by the successor
    /// after the predecessor retires, while a creation still in flight is not adopted as live.
    func testSuccessorClaimAdoptsCommittedQuestionDraftButNotAnInFlightCreation() async throws {
        let writes = CodexQuestionWriteControl()
        let fixture = try await RecoveryLaneFixture.make("codex-question-successor-claim", fileOperations: writes.fileOperations())
        defer { fixture.tearDown() }
        let questions = fixture.lane.questionPersistence
        let committed = UUID()
        let creating = UUID()
        func snapshot(_ id: UUID, answer: String?) -> AgentRecoveryQuestionSnapshot {
            AgentRecoveryQuestionSnapshot(
                interactionID: id,
                kind: .userInput,
                runAttemptID: nil,
                transcriptResetGeneration: fixture.lane.binding.transcriptResetGeneration,
                appInstanceID: fixture.store.appInstanceID,
                askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
                title: "Deploy?",
                message: nil,
                items: [AgentRecoveryQuestionItem(
                    questionID: "target",
                    header: nil,
                    text: "Which environment?",
                    options: [],
                    isSecret: false,
                    answer: answer
                )]
            )
        }
        guard case .success = await questions.commitCreation(snapshot(committed, answer: nil)) else {
            return XCTFail("the first question's creation commits")
        }
        let relocatedState = try await fixture.relocatedPersistenceState()

        writes.holdNextWrite()
        questions.draftDidChange(snapshot(committed, answer: "unsaved draft"))
        let creation = Task { @MainActor in await questions.commitCreation(snapshot(creating, answer: nil)) }
        try await waitUntil { writes.isHolding }
        XCTAssertTrue(questions.needsPreservation(committed), "the draft is not durable yet")

        let successor = try fixture.claimSuccessor(persistenceState: relocatedState)
        XCTAssertFalse(successor === fixture.lane)
        XCTAssertTrue(fixture.lane.isRetired)
        let adopted = successor.questionPersistence
        XCTAssertEqual(adopted.liveInteractionIDs, [committed], "only the committed question is handed over")
        XCTAssertTrue(adopted.needsPreservation(committed), "its handed-over draft is pending in the successor")

        writes.release()
        _ = await creation.value
        try await waitUntil { !adopted.needsPreservation(committed) && !adopted.hasPendingWork }
        let stored = await fixture.store.read(sessionID: fixture.sessionID).record?.questions ?? []
        XCTAssertEqual(
            stored.first { $0.interactionID == committed }?.items.first?.answer,
            "unsaved draft",
            "the successor preserved the committed question's draft"
        )
        XCTAssertFalse(adopted.liveInteractionIDs.contains(creating), "the in-flight creation never becomes live in the successor")
    }

    func testInactiveCommandRunningOutputWithoutAnchorCreatesMinimalAnchorOnly() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        _ = try await viewModel.ensureSessionReady(tabID: activeTabID)
        let session = try await viewModel.ensureSessionReady(tabID: inactiveTabID)
        session.selectedAgent = .codexExec
        session.runState = .running
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: "inactive-123",
                appendedOutput: "inactive first chunk\n"
            )),
            session: session
        )

        try await waitUntil {
            session.bashLiveExecutionByKey.values.first?.parsedResult.output?.contains("inactive first chunk") == true
        }
        let bashItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
        XCTAssertFalse(bashItem.toolResultJSON?.contains("inactive first chunk") == true)
        XCTAssertFalse(bashItem.text.contains("inactive first chunk"))
    }

    /// Restart Step 7-minor: a command killed by an app quit is saved as a running row. After
    /// relaunch no Codex app-server is attached, so its vanished process means the command was
    /// interrupted; the liveness poll must not settle it as a success.
    func testRestoredRunningBashRowWithVanishedProcessSettlesAsInterruptedWithoutLiveProvider() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let (session, row) = try restoredSessionWithRunningBashRow(in: viewModel)
        XCTAssertNil(session.codexController)

        let settled = try await settledBashRow(id: row.id, in: session)
        try assertInterruptedWithoutInventedExitCode(settled)
    }

    /// Review MINOR-01 / M1: a controller attached after the restore does not own the restored
    /// command, so its vanished process still settles as interrupted, never as a success.
    func testRestoredRunningBashRowStaysUnownedWhenControllerAttachesAfterRebuild() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let (session, row) = try restoredSessionWithRunningBashRow(in: viewModel)
        XCTAssertFalse(session.bashLiveExecutionByKey.isEmpty, "restore re-arms the saved running row")
        session.codexController = controller

        let settled = try await settledBashRow(id: row.id, in: session)
        try assertInterruptedWithoutInventedExitCode(settled)
    }

    /// Control: an execution driven by the attached controller's events keeps its provisional
    /// `finished` settlement when its process vanishes (the real completion may still arrive).
    func testLiveProviderBashExecutionWithVanishedProcessStaysProvisionallyFinished() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = try XCTUnwrap(preparedCodexSession(in: viewModel, controller: controller))
        let rowID = try await startLiveBashExecution(
            processID: exitedProcessID(),
            invocationID: UUID(),
            viewModel: viewModel,
            session: session
        )

        let settled = try await settledBashRow(id: rowID, in: session)
        let persisted = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: settled))
        XCTAssertEqual(persisted.persistedStatusWord, "success")
    }

    /// Review MINOR-03 / M2: an authoritative completion recorded before the poll's grace
    /// expires is final. It removes the live execution, so the poll has nothing left to settle.
    func testAuthoritativeBashCompletionBeforePollSurvivesLivenessPoll() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = try XCTUnwrap(preparedCodexSession(in: viewModel, controller: controller))
        let processID = try exitedProcessID()
        let invocationID = UUID()
        let rowID = try await startLiveBashExecution(
            processID: processID,
            invocationID: invocationID,
            viewModel: viewModel,
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: Self.liveBashArgsJSON,
                resultJSON: #"{"type":"commandExecution","status":"failed","processId":""# + processID
                    + #"","exitCode":2,"aggregatedOutput":"boom"}"#,
                isError: true
            ),
            session: session
        )
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty, "no live execution is left for the poll")

        try assertFailedWithExitCode2(rowID: rowID, in: session)
    }

    /// Review R1-03: a real completion that arrives after the poll settled an unowned execution
    /// as interrupted replaces that settlement.
    func testAuthoritativeBashCompletionAfterInterruptedSettlementReplacesIt() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = try XCTUnwrap(preparedCodexSession(in: viewModel, controller: controller))
        let processID = try exitedProcessID()
        let invocationID = UUID()
        let rowID = try await startLiveBashExecution(
            processID: processID,
            invocationID: invocationID,
            viewModel: viewModel,
            session: session
        )
        // A replacement controller does not own the execution, so the poll settles it as interrupted.
        session.codexController = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let interrupted = try await settledBashRow(id: rowID, in: session)
        try assertInterruptedWithoutInventedExitCode(interrupted)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: Self.liveBashArgsJSON,
                resultJSON: #"{"type":"commandExecution","status":"failed","processId":""# + processID
                    + #"","exitCode":2,"aggregatedOutput":"boom"}"#,
                isError: true
            ),
            session: session
        )

        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
        XCTAssertEqual(session.items.count(where: { $0.toolName == "bash" }), 1, "the settled row is updated in place")
        try assertFailedWithExitCode2(rowID: rowID, in: session)
    }

    /// 9-live R3: a restored (args-less) interrupted Claude bash row keeps its saved outcome when a
    /// later turn's Claude bash result arrives. Claude results carry no args, so the Codex live-bash
    /// reconcile used to anchor the args-less signature to the restored row and save it as success.
    func testLaterClaudeBashResultDoesNotRewriteRestoredInterruptedBashRow() async throws {
        let viewModel = makeViewModel(controller: LivenessFakeCodexController(snapshot: .active(activeFlags: [])))
        let session = try XCTUnwrap(viewModel.session(for: UUID(), createIfNeeded: true))
        session.selectedAgent = .claudeCode
        session.appendItem(restoredInterruptedBashRow(toolName: "Bash"))
        let restored = try XCTUnwrap(session.items.last)
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.claudeRestoredBashRow")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        let invocationID = UUID()
        let argsJSON = #"{"command":"echo go; sleep 60; echo done"}"#

        await viewModel.test_handleStreamResult(
            AIStreamResult(
                type: "tool_call", text: nil, toolName: "Bash", toolArgs: argsJSON,
                toolInvocationID: invocationID, toolArgsJSON: argsJSON
            ),
            session: session, runID: runID, runAttemptID: runAttemptID
        )
        await viewModel.test_handleStreamResult(
            AIStreamResult(
                type: "tool_result", text: nil, toolName: "Bash", toolOutput: "go\ndone",
                toolInvocationID: invocationID, toolResultJSON: "go\ndone", toolIsError: false
            ),
            session: session, runID: runID, runAttemptID: runAttemptID
        )

        let current = try XCTUnwrap(session.items.first { $0.id == restored.id })
        XCTAssertEqual(current, restored, "the restored row is untouched")
        let persisted = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: current))
        XCTAssertEqual(persisted.persistedStatusWord, "cancelled")
        let live = try XCTUnwrap(session.items.first { $0.toolInvocationID == invocationID })
        XCTAssertNotEqual(live.id, restored.id)
        XCTAssertEqual(live.toolResultJSON, "go\ndone")
        XCTAssertEqual(live.toolIsError, false)
        XCTAssertEqual(
            session.items.map { $0.toolName?.lowercased() },
            ["bash", "bash"],
            "only the restored row and the new call's row; no extra anchor row"
        )
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
    }

    func testStaleCompletionBeforeObservedStartPreservesPendingTurnThenMatchingTurnFinalizes() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let ownership = session.activeRunOwnership
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "stale-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "current-turn"),
            session: session
        )

        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "current-turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "current-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedNonNilCompletionAfterStartPreservesCurrentCorrelation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let ownership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "different-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedStartCannotReplaceAuthoritativeIdentityAndDuplicateIsIdempotent() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let originalIdentity = session.codexAuthoritativeActiveTurn

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "different-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)
        XCTAssertEqual(session.runState, .running)
    }

    func testNilCompletionAfterIdentifiedStartCompletesCurrentTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        // Accounting (review R2, OracleA P1#2): the identified turn is dispatched and bound, and the
        // nil-ID completion that legitimately terminates it must close the known accounting turn.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn"), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "the correlated identified turn ended without usage: unmeasured now, not at some later teardown")
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.turnID, "turn")
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        // A provably owned late report for that turn still replaces its marker.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(codexUsageEvent(1, turn: "turn", codexTotal(1000, 100, 10)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 1)
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
    }

    func testNilStartFollowedByNilCompletionCompletesAnonymousTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user
        // Accounting (review R2): the dispatch behind an anonymous start can never be bound; its
        // nil-ID completion marks it unmeasured once, without a second "never bound" marker later.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexAnonymousActiveTurn?.turnKind, .user)
        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "dispatched work ended without any establishable identity")
        XCTAssertNil(session.usageAccounting?.record?.codexIntervals?.last?.turnID)
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredAnonymousTurnDiagnostic)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "the anonymous dispatch was consumed by its marker")
    }

    func testNilCompletionWithoutObservedStartIsRejectedAndPreservesPendingTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let ownership = session.activeRunOwnership
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user
        // Accounting (review R2): a completion the correlation rejects is not this session's turn,
        // so the still-pending dispatch keeps its pricing basis for the start that follows.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0, "a rejected completion leaves accounting untouched")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "late-turn"), session: session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(codexUsageEvent(1, turn: "late-turn", codexTotal(1000, 100, 10)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 1)
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.first?.turnID, "late-turn")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.amount, Decimal(string: "0.0017325"), "the pending basis survived the rejected completion and priced the bound turn")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
    }

    /// Review R3 (OracleA P1): dispatch registration precedes the provider send, but only the
    /// controller's typed local preflight error proves the request never reached the transport.
    /// That exact ticket is withdrawn without manufacturing an unmeasured marker.
    func testFailedCodexTurnStartWithdrawsItsUsageDispatchWithoutAnUnmeasuredMarker() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexTurnStartPreflightError.invalidInput("test fixture rejected before transport submission")
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0, "a proven pre-send failure is not unmeasured work")

        // The next dispatch on the same generation finds nothing pending to mark as "never bound",
        // and is itself tracked normally (bound, awaited, marked when it ends without usage).
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0)
        let coordinator = viewModel.test_codexCoordinator
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-2"), session: session)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "turn-2", status: .interrupted), session: session)
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.map(\.turnID), ["turn-2"])
        XCTAssertNil(accounting.record?.semanticViolation)
    }

    /// Review R3 (OracleA P1): an anonymous `turn/started` is acceptance evidence even though it
    /// cannot bind the dispatch to a turn identity. A later JSON-RPC request error must not erase
    /// the pending usage obligation; execution teardown records it as unmeasured.
    func testAnonymousStartBeforeRequestErrorPreservesUsageObligation() async throws {
        let rejection = CodexAppServerClient.RequestFailure(
            method: "turn/start",
            code: -32000,
            message: "server error after anonymous turn/start",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexAppServerClient.ClientError.requestFailed(rejection)
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)
        controller.setStartUserTurnBeforeResult {
            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
                .turnStarted(turnID: nil),
                session: session
            )
        }
        defer { controller.setStartUserTurnBeforeResult(nil) }

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        session.endCodexUsageExecution(reason: "test-anonymous-start-before-error")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    /// Review R3 (OracleA P1): cancellation can race after the request write, so a missing receipt
    /// is delivery-unknown rather than proof of rejection. Terminal teardown must retain the
    /// potentially incurred work as one unmeasured obligation.
    func testCancelledTurnStartWithoutReceiptPreservesUsageObligation() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CancellationError()
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .cancelled)
        session.endCodexUsageExecution(reason: "test-cancelled-start")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    /// Review R3 (OracleA P1): the app-server client synthesizes `requestFailed` for a local
    /// timeout, so method=turn/start without a receipt remains delivery-unknown. Execution teardown
    /// must retain one unmeasured obligation rather than treating the error as server rejection.
    func testTimedOutTurnStartWithoutReceiptPreservesUsageObligation() async throws {
        let timeout = CodexAppServerClient.RequestFailure(
            method: "turn/start",
            code: nil,
            message: "Request timed out after 1.0s",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexAppServerClient.ClientError.requestFailed(timeout)
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        session.endCodexUsageExecution(reason: "test-timed-out-start")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    func testActiveCodexNativeSendUsesRealAgentRunDrainBeforeSending() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let waitTask = harness.startWait()
            try await harness.waitUntilBlocked()

            let ordering = CodexDrainSendOrderingRecorder()
            let controller = LivenessFakeCodexController(
                snapshot: .active(activeFlags: []),
                onSendUserTurn: { ordering.recordSend() }
            )
            let viewModel = makeViewModel(controller: controller) { runID, source in
                XCTAssertEqual(runID, harness.parentRunID)
                XCTAssertEqual(source, "codex-native-active-send")
                let drained = await harness.drain(source: source)
                ordering.recordDrainCompletion(
                    succeeded: drained.isDrained,
                    activeScopeCount: harness.activeScopeCount()
                )
                return drained
            }
            guard let session = preparedCodexSession(
                in: viewModel,
                controller: controller,
                runID: harness.parentRunID
            ) else {
                return XCTFail("Expected the Codex test session to materialize")
            }
            session.codexRoutingObservedTurnID = "routing-hint-only"

            let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
            let interruptedValue = try await waitTask.value
            let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
            let completions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            let orderingSnapshot = ordering.snapshot()

            XCTAssertEqual(outcome, .sent)
            XCTAssertEqual(
                interruptedObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertEqual(controller.startUserTurnCountSync(), 0)
            XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
            XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
            XCTAssertTrue(orderingSnapshot.drainSucceeded)
            XCTAssertEqual(orderingSnapshot.activeScopeCountAtDrainCompletion, 0)
            XCTAssertTrue(orderingSnapshot.sendObservedAfterDrain)
            XCTAssertEqual(harness.activeScopeCount(), 0)
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(completions.first?.result, "interrupted_by_steering")
            XCTAssertTrue(registrationRemainsActive)
        }
    }

    func testActiveCodexNativeSendFailsWithoutSendingWhenAgentRunDrainFails() async {
        let blockers = AgentRunWaitDrainBlockers(
            childAgentRunWaitCount: 1,
            oldestChildAgentRunWaitAgeSeconds: 12,
            oracleInvocationCount: 0,
            oldestOracleInvocationAgeSeconds: nil
        )
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _ in .timedOut(blockers) }
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertEqual(
            message,
            "Codex did not send because 1 child agent_run.wait scope (oldest 12s) did not finish after steering wake."
        )
        XCTAssertFalse(message.contains("ask_oracle"))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
    }

    func testActiveCodexNativeSendAttributesOracleOnlyDrainFailure() async {
        let blockers = AgentRunWaitDrainBlockers(
            childAgentRunWaitCount: 0,
            oldestChildAgentRunWaitAgeSeconds: nil,
            oracleInvocationCount: 2,
            oldestOracleInvocationAgeSeconds: 806
        )
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _ in .timedOut(blockers) }
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertEqual(
            message,
            "Codex did not send because 2 ask_oracle invocations (oldest 806s) did not finish after steering wake."
        )
        XCTAssertFalse(message.contains("agent_run.wait"), "an Oracle-only blocker must not be attributed to child waits")
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(
            CodexAgentModeCoordinator.activeSendDrainFailureMessage(AgentRunWaitDrainBlockers(
                childAgentRunWaitCount: 2,
                oldestChildAgentRunWaitAgeSeconds: 3,
                oracleInvocationCount: 1,
                oldestOracleInvocationAgeSeconds: 4
            )),
            "Codex did not send because 2 child agent_run.wait scopes (oldest 3s) and 1 ask_oracle invocation (oldest 4s) did not finish after steering wake."
        )
    }

    func testActiveCodexNativeSendTreatsCancelledDrainAsCancelledWithoutSending() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _ in .cancelled }
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
    }

    func testInactiveCodexNativeSendStartsTurnWithoutInstallingLifecycleIdentity() async {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
    }

    func testActiveCodexNativeSendWithoutExactIdentityQueuesWithoutStarting() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-liveness-missing-identity")
        defer { fixture.tearDown() }
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = "routing-only-turn"

        let outcome = try await sendDurably("hello", viewModel: viewModel, session: session, fixture: fixture)

        guard case .queuedFallback(_, .activeWithoutAuthoritativeIdentity) = outcome else {
            return XCTFail("Expected missing-identity fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    /// 9-live R2: a user turn that becomes authoritative records its native turn ID on the session's
    /// run attempt through the recovery lane (event handling never awaits the write); a steer Codex
    /// accepted into a different turn rewrites it (last-wins); a compaction turn records nothing, and
    /// clears a recorded user turn so an older, finished turn is never named.
    func testAuthoritativeUserTurnRecordsItsNativeTurnIDOnTheRunAttempt() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-provider-turn-record")
        defer { fixture.tearDown() }
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let ownership = try XCTUnwrap(session.activeRunOwnership)
        _ = try await fixture.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: nil, providerKindRaw: session.selectedAgent.rawValue
        ).get()
        func recordedTurn() async -> String? {
            // Drain the session's chained writes, then reload the record.
            await session.codexProviderTurnWriteTask?.value
            return await fixture.store.read(sessionID: fixture.sessionID).record?
                .runAttempts.first { $0.runAttemptID == ownership.attemptID }?.recordedProviderTurnID
        }
        func startFreshTurn(_ turnID: String, kind: AgentTabSession.CodexTurnKind) async {
            session.codexAuthoritativeActiveTurn = nil
            session.codexRoutingObservedTurnID = nil
            session.codexPendingTurnKind = kind
            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: turnID), session: session)
            XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, turnID, "\(turnID) became authoritative")
        }

        await startFreshTurn("compact-turn", kind: .compact)
        let afterCompaction = await recordedTurn()
        XCTAssertNil(afterCompaction, "a compaction turn is never recorded")

        await startFreshTurn("user-turn-1", kind: .user)
        let afterUserTurn = await recordedTurn()
        XCTAssertEqual(afterUserTurn, "user-turn-1", "the authoritative user turn is recorded on the run attempt")

        let prior = try XCTUnwrap(session.codexAuthoritativeActiveTurn)
        session.codexPendingSteerLifecycleReconciliation = .init(priorIdentity: prior, acceptedDispatchTurnID: "user-turn-2")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "user-turn-2"), session: session)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "user-turn-2", "the accepted steer's turn is reinstalled")
        let afterSteer = await recordedTurn()
        XCTAssertEqual(afterSteer, "user-turn-2", "the steer-mismatch reinstall rewrites the recorded turn (last-wins)")

        await startFreshTurn("compact-after-user", kind: .compact)
        let afterLaterCompaction = await recordedTurn()
        XCTAssertNil(afterLaterCompaction, "user turn, then compaction turn: the record is cleared")
    }

    /// 9-live R2 (review A P1, B F3): provider-turn writes commit in authoritative-install order. T1's
    /// write is held before it enters the lane while T2 becomes authoritative; T2's write enters the
    /// lane only after T1's committed, and T2 is the recorded turn once both drain.
    func testProviderTurnWritesCommitInAuthoritativeInstallOrder() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-provider-turn-order")
        defer { fixture.tearDown() }
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let ownership = try XCTUnwrap(session.activeRunOwnership)
        _ = try await fixture.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: nil, providerKindRaw: session.selectedAgent.rawValue
        ).get()
        func storedTurn() async -> String? {
            await fixture.store.read(sessionID: fixture.sessionID).record?
                .runAttempts.first { $0.runAttemptID == ownership.attemptID }?.recordedProviderTurnID
        }
        let hold = ProviderTurnWriteHold()
        var entered: [String] = []
        var storedWhenEnteringLane: [String: String?] = [:]
        viewModel.test_codexCoordinator.testProviderTurnWriteWillEnterLane = { turnID in
            guard let turnID else { return }
            entered.append(turnID)
            storedWhenEnteringLane[turnID] = await storedTurn()
            if turnID == "user-turn-1" { await hold.hold() }
        }

        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "user-turn-1"), session: session)
        let firstWrite = try XCTUnwrap(session.codexProviderTurnWriteTask)
        await hold.waitUntilArrived()

        let prior = try XCTUnwrap(session.codexAuthoritativeActiveTurn)
        session.codexPendingSteerLifecycleReconciliation = .init(priorIdentity: prior, acceptedDispatchTurnID: "user-turn-2")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "user-turn-2"), session: session)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "user-turn-2")
        let secondWrite = try XCTUnwrap(session.codexProviderTurnWriteTask)
        // Give an unchained T2 write every chance to run ahead of the held T1 (main-actor FIFO).
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(entered, ["user-turn-1"], "T2 has not started toward the lane while T1 is held")
        hold.release()
        await firstWrite.value
        await secondWrite.value

        XCTAssertEqual(entered, ["user-turn-1", "user-turn-2"])
        XCTAssertEqual(storedWhenEnteringLane["user-turn-2"], .some("user-turn-1"), "T2 entered the lane after T1 committed")
        let recorded = await storedTurn()
        XCTAssertEqual(recorded, "user-turn-2", "the later authoritative turn is the recorded one")
    }

    func testTypedSteerRejectionReturnsFallbackWithoutReplacingAuthoritativeIdentity() async throws {
        let fixture = try await RecoveryLaneFixture.make("codex-liveness-typed-rejection")
        defer { fixture.tearDown() }
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: fixture.lane) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let identity = session.codexAuthoritativeActiveTurn

        let outcome = try await sendDurably("hello", viewModel: viewModel, session: session, fixture: fixture)

        guard case .queuedFallback(_, .noActiveTurn(failure: failure)) = outcome else {
            return XCTFail("Expected no-active fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
        XCTAssertEqual(session.codexAuthoritativeActiveTurn, identity)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    func testManualTypedFallbackKeepsOptimisticBubbleAndDraft() async throws {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        // Mandatory durable admission through a real temporary lane: the VM commits the composer
        // input before the optimistic bubble, so the typed fallback queues under its receipt.
        let recovery = try await RecoveryLaneFixture.make("ManualTypedFallbackKeepsBubble")
        defer { recovery.tearDown() }
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller, recoveryLane: recovery.lane) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.recoveryLane = recovery.lane
        session.recoveryAdmissionMode = .mandatory
        viewModel.storeDraftText(for: session.tabID, "restore me")

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "restore me",
            tabID: session.tabID,
            origin: .composer
        )

        XCTAssertEqual(result, .submitted)
        // The durable path performs real store writes (admission, dispatch, queue receipt), so the
        // budget allows parallel-runner load; the awaited condition is unchanged.
        try await waitUntil(timeout: 10) {
            controller.steerUserTurnIDsSync() == ["turn"]
                && session.codexFallbackQueue.count == 1
        }
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["restore me"])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "restore me")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        // One identity end to end: committed intent == bubble item == queue entry.
        let bubble = try XCTUnwrap(session.items.last { $0.kind == .user })
        let entry = try XCTUnwrap(session.codexFallbackQueue.first)
        let record = await recovery.store.read(sessionID: recovery.sessionID).record
        let intent = try XCTUnwrap(record?.intent(id: entry.id))
        XCTAssertEqual(intent.userItemID, bubble.id)
        XCTAssertEqual(intent.origin, .composer)
        XCTAssertEqual(intent.payload.text, "restore me")
        XCTAssertEqual(intent.deliveryState, .queued)
    }

    func testAcceptedSteerRemainsSentWhenMatchingTurnCompletesBeforeReceiptResumes() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerDelayNanos: 50_000_000
        )
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }
        try await waitUntil {
            controller.steerUserTurnIDsSync() == ["turn"]
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(session.runState, .completed)
    }

    // MARK: - Usage accounting lifecycle (plan §4.1)

    /// Coordinator lifecycle: a dispatched turn that ends (interrupted) without any usage
    /// notification is unmeasured work, a provably owned late notification still lands, and
    /// session shutdown marks a still-open dispatched turn before the controller generation rotates.
    func testDispatchedCodexTurnEndingWithoutUsageIsUnmeasuredAcrossInterruptLateUsageAndShutdown() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        guard let session = preparedCodexSession(in: viewModel, controller: controller) else {
            return XCTFail("Expected the Codex test session to materialize")
        }
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID()))
        session.codexPricingProvider = OpenAIPricingStore.transient(
            transport: NoNetworkPricingTransport(),
            isNetworkPermitted: { false }
        )
        // The fixture pre-assigns the thread identity the fake controller reports. For accounting
        // this generation must be the one that created the thread (verified zero baseline); a
        // thread that already existed would be resumed and its first checkpoint only prospective.
        let preparedThreadID = session.codexConversationID
        session.codexConversationID = nil
        session.beginCodexUsageExecutionIfNeeded()
        session.codexConversationID = preparedThreadID
        let coordinator = viewModel.test_codexCoordinator
        func total(_ input: Int, _ cached: Int, _ output: Int) -> CodexUsageObservation.Counters {
            .init(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0, totalTokens: input + output)
        }
        func usage(_ ordinal: Int, turn: String, _ counters: CodexUsageObservation.Counters) -> CodexNativeSessionController.Event {
            .usageObservation(.init(threadID: "fake", turnID: turn, turnAttribution: .notified, ordinal: ordinal, last: counters, total: counters, modelContextWindow: 258_400))
        }

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn"), session: session)
        await coordinator.test_handleCodexNativeEvent(usage(1, turn: "turn", total(1000, 100, 10)), session: session)
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexSessionCostEstimate?.coverage, .complete)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 0)

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-2"), session: session)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "turn-2", status: .interrupted), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .partial)
        // Bundled seed rates for gpt-5.3-codex ($1.75 / $0.175 / $14.00 per million):
        // 900 ordinary × 1.75 + 100 cached × 0.175 + 10 output × 14 = 1732.5 → $0.0017325.
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.amount, Decimal(string: "0.0017325"), "accepted amounts are retained")

        await coordinator.test_handleCodexNativeEvent(usage(2, turn: "turn-2", total(2000, 200, 20)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0, "a provably owned late observation replaces the marker")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 2)

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-3"), session: session)
        let generationBeforeShutdown = session.codexControllerGeneration
        await coordinator.shutdownCodexSession(session)
        XCTAssertNotEqual(session.codexControllerGeneration, generationBeforeShutdown)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "shutdown marks the still-open dispatched turn before the generation rotates")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertNil(session.usageAccounting?.record?.semanticViolation)
        let projection = AgentProviderUsageSnapshot.projected(
            selectedAgent: .codexExec,
            accounting: session.usageAccounting,
            expectedOwnerSessionID: session.activeAgentSessionID
        )
        XCTAssertEqual(projection.costEstimate?.coverage, .partial)
        XCTAssertFalse(projection.presentation.readoutText.contains("partial"), "coverage lives in the details, not the value")
        XCTAssertTrue(projection.presentation.detailText.contains("Accumulated session cost: <$0.01 (partial coverage)"))
        XCTAssertTrue(
            try XCTUnwrap(projection.coverageDetail)
                .contains(AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        )
    }

    /// Enables fixture-local Codex usage accounting without mutating the prepared run's persistent
    /// binding, with offline pricing and a fresh-thread origin for the generation the fixture
    /// pre-assigned its thread to (an existing thread would start prospectively).
    private func enableCodexUsageAccounting(_ session: AgentTabSession) {
        // Install accounting directly so this focused fixture does not mutate the persistent binding
        // after `beginRunAttempt`; doing so would intentionally stale the run ownership under test.
        session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: UUID(),
            persisted: nil,
            hasPriorHistory: false,
            qualification: .productionClaude
        )
        session.codexPricingProvider = OpenAIPricingStore.transient(
            transport: NoNetworkPricingTransport(),
            isNetworkPermitted: { false }
        )
        let preparedThreadID = session.codexConversationID
        session.codexConversationID = nil
        session.beginCodexUsageExecutionIfNeeded()
        session.codexConversationID = preparedThreadID
    }

    private func codexTotal(_ input: Int, _ cached: Int, _ output: Int) -> CodexUsageObservation.Counters {
        .init(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0, totalTokens: input + output)
    }

    private func codexUsageEvent(_ ordinal: Int, turn: String, _ counters: CodexUsageObservation.Counters) -> CodexNativeSessionController.Event {
        .usageObservation(.init(threadID: "fake", turnID: turn, turnAttribution: .notified, ordinal: ordinal, last: counters, total: counters, modelContextWindow: 258_400))
    }

    /// Sends `text` as real durable input: a `queued` intent admitted through `fixture`'s lane
    /// (installed on `session`), its intent ID reused as the fallback queue ID.
    private func sendDurably(
        _ text: String,
        viewModel: AgentModeViewModel,
        session: AgentTabSession,
        fixture: RecoveryLaneFixture
    ) async throws -> CodexAgentModeCoordinator.NativeSendOutcome {
        session.recoveryLane = fixture.lane
        let identity = try await fixture.queuedIdentity(text)
        let intentID = try XCTUnwrap(identity.intentID)
        let context = AgentTabSession.CodexFallbackSubmissionContext(
            queueID: intentID,
            providerText: text,
            images: [],
            taggedFileAttachments: [],
            draftText: text,
            identity: identity,
            origin: .manual,
            dispatchTicket: nil
        )
        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: text,
            attachments: [],
            fallbackContext: context
        )
        if let receipt = outcome.durableQueueReceipt {
            XCTAssertEqual(receipt.intent.intentID, identity.intentID, "The queue ack is this intent's store receipt")
        }
        return outcome
    }

    private func makeViewModel(
        controller: LivenessFakeCodexController,
        drain: AgentCodexAgentRunWaitDrain? = nil
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexActiveAgentRunWaitDrain: drain,
            testCodexStallWatchdogPollIntervalNanos: 10_000_000,
            testCodexStallWatchdogProbeThreshold: 0.02,
            testCodexStallWatchdogRecoveryThreshold: 0.02
        )
        viewModel.test_initializeRunService()
        return viewModel
    }

    /// A running Codex session with an active run attempt. Durable-input tests pass `recoveryLane`:
    /// the tab is then bound to that lane's persistent session before the run attempt begins, as
    /// production does (`startAgentRun` binds before the runner creates ownership), so the attempt's
    /// ownership is compatible with the lane (R07).
    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: LivenessFakeCodexController,
        runID: UUID = UUID(),
        recoveryLane: AgentRecoverySessionLane? = nil
    ) -> AgentTabSession? {
        guard let session = viewModel.session(for: UUID(), createIfNeeded: true) else {
            XCTFail("Expected the Codex test session to materialize")
            return nil
        }
        if let recoveryLane {
            _ = viewModel.test_installPersistentSessionBinding(sessionID: recoveryLane.sessionID, on: session)
            session.recoveryLane = recoveryLane
        }
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexLiveness")
        session.codexController = controller
        session.codexConversationID = "fake"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        return session
    }

    private func makeUserInputRequest(id: String, threadID: String = "thread", turnID: String = "turn") -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string(id),
            method: "request_user_input",
            threadID: threadID,
            turnID: turnID,
            itemID: id,
            questions: [
                AgentRequestUserInputQuestion(
                    id: "question",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: [AgentRequestUserInputOption(label: "Yes", description: "Continue")]
                )
            ]
        )
    }

    private static let liveBashArgsJSON = #"{"command":"printf probe"}"#

    /// A Codex session restored from a saved session whose last command row is still running.
    private func restoredSessionWithRunningBashRow(
        in viewModel: AgentModeViewModel
    ) throws -> (AgentTabSession, AgentChatItem) {
        let session = try XCTUnwrap(viewModel.session(for: UUID(), createIfNeeded: true))
        session.selectedAgent = .codexExec
        let row = try runningBashRow(processID: exitedProcessID())
        session.appendItem(row)
        viewModel.test_codexCoordinator.restoreCodexMetadata(
            from: AgentSession(id: UUID(), name: "Restored"),
            session: session
        )
        return (session, row)
    }

    /// Starts a bash execution through the attached controller's events; returns its row ID.
    private func startLiveBashExecution(
        processID: String,
        invocationID: UUID,
        viewModel: AgentModeViewModel,
        session: AgentTabSession
    ) async throws -> UUID {
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "bash", invocationID: invocationID, argsJSON: Self.liveBashArgsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: Self.liveBashArgsJSON,
                resultJSON: #"{"type":"commandExecution","status":"inProgress","processId":""# + processID + #""}"#,
                isError: false
            ),
            session: session
        )
        let execution = try XCTUnwrap(session.bashLiveExecutionByKey.values.first)
        XCTAssertEqual(execution.ownerControllerGeneration, session.codexControllerGeneration)
        return execution.transcriptItemID
    }

    private func assertFailedWithExitCode2(
        rowID: UUID,
        in session: AgentTabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(session.items.first { $0.id == rowID }, file: file, line: line)
        let metadata = BashToolResultParser.parseLivenessMetadata(raw: row.toolResultJSON)
        XCTAssertEqual(metadata.statusWord, "failed", file: file, line: line)
        XCTAssertEqual(metadata.exitCode, 2, file: file, line: line)
        let persisted = try XCTUnwrap(
            AgentToolResultPersistencePolicy.sanitizedToolResult(for: row),
            file: file,
            line: line
        )
        XCTAssertEqual(persisted.persistedStatusWord, "failed", file: file, line: line)
        XCTAssertEqual(persisted.exitCode, 2, file: file, line: line)
    }

    /// The unknown outcome is settled as `interrupted`, which the save stores as its normalized
    /// word `cancelled`, and carries no exit code it never observed.
    private func assertInterruptedWithoutInventedExitCode(
        _ settled: AgentChatItem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let object = try XCTUnwrap(ToolRawJSON.object(from: settled.toolResultJSON), file: file, line: line)
        XCTAssertEqual(
            AgentTranscriptToolStatusSemantics.normalizedStatusWord(ToolRawJSON.string(object, key: "status")),
            "cancelled",
            file: file,
            line: line
        )
        XCTAssertNil(ToolRawJSON.int(object, key: "exitCode"), file: file, line: line)
        // Bash rows carry no error flag once settled (`persistedToolIsError`); never an error.
        XCTAssertNotEqual(settled.toolIsError, true, file: file, line: line)
        let persisted = try XCTUnwrap(
            AgentToolResultPersistencePolicy.sanitizedToolResult(for: settled),
            file: file,
            line: line
        )
        XCTAssertEqual(persisted.persistedStatusWord, "cancelled", file: file, line: line)
        XCTAssertEqual(persisted.transcriptStatus, .cancelled, file: file, line: line)
    }

    /// A bash row as a cold restore leaves an interrupted command: saved rows keep no args.
    private func restoredInterruptedBashRow(toolName: String) -> AgentChatItem {
        let resultJSON = #"{"status":"cancelled","summary_only":true,"summary_text":"bash • cancelled","type":"commandExecution"}"#
        return AgentChatItem(
            timestamp: Date().addingTimeInterval(-3600),
            kind: .toolResult,
            text: resultJSON,
            toolName: toolName,
            toolInvocationID: UUID(),
            toolArgsJSON: nil,
            toolResultJSON: resultJSON,
            toolIsError: true
        )
    }

    /// A saved running Codex command row, older than the liveness poll's quiet-signal grace.
    private func runningBashRow(processID: String) -> AgentChatItem {
        let resultJSON = #"{"type":"commandExecution","status":"running","processId":""# + processID + #""}"#
        return AgentChatItem(
            timestamp: Date().addingTimeInterval(-60),
            kind: .toolResult,
            text: resultJSON,
            toolName: "bash",
            toolInvocationID: UUID(),
            toolArgsJSON: #"{"command":"while true; do sleep 1; done"}"#,
            toolResultJSON: resultJSON,
            toolIsError: false
        )
    }

    /// The PID of a process that already exited and was reaped.
    private func exitedProcessID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return String(process.processIdentifier)
    }

    /// Waits past the poll's unobserved-process grace (1.2 s) for the row to stop running.
    private func settledBashRow(id: UUID, in session: AgentTabSession) async throws -> AgentChatItem {
        func row() -> AgentChatItem? {
            session.items.first { $0.id == id }
        }
        try await waitUntil(timeout: 10) {
            guard let item = row() else { return false }
            return !BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON).isRunning
        }
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
        return try XCTUnwrap(row())
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class CodexDrainSendOrderingRecorder: @unchecked Sendable {
    struct Snapshot {
        let drainSucceeded: Bool
        let activeScopeCountAtDrainCompletion: Int?
        let sendObservedAfterDrain: Bool
    }

    private let lock = NSLock()
    private var drainSucceeded = false
    private var activeScopeCountAtDrainCompletion: Int?
    private var sendObservedAfterDrain = false

    func recordDrainCompletion(succeeded: Bool, activeScopeCount: Int) {
        lock.lock()
        drainSucceeded = succeeded
        activeScopeCountAtDrainCompletion = activeScopeCount
        lock.unlock()
    }

    func recordSend() {
        lock.lock()
        sendObservedAfterDrain = drainSucceeded && activeScopeCountAtDrainCompletion == 0
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            drainSucceeded: drainSucceeded,
            activeScopeCountAtDrainCompletion: activeScopeCountAtDrainCompletion,
            sendObservedAfterDrain: sendObservedAfterDrain
        )
        lock.unlock()
        return snapshot
    }
}

/// Pricing transport that must never be reached: the lifecycle test disables network use.
private struct NoNetworkPricingTransport: OpenAIPricingDocumentTransport {
    func fetch(_ request: URLRequest, maximumBodyBytes: Int) async throws -> OpenAIPricingTransportResponse {
        throw OpenAIPricingTransportError.networkNotPermitted
    }
}

private final class LivenessFakeCodexController: CodexSessionControlling {
    private var readSnapshotCount = 0
    private var startUserTurnCount = 0
    private var steerUserTurnIDs: [String] = []
    private let snapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]
    private let onSendUserTurn: (() -> Void)?
    private let startError: Error?
    private var startUserTurnBeforeResult: (() async -> Void)?
    private let steerError: Error?
    private let steerDelayNanos: UInt64
    private var pendingTurnFailure: CodexNativeSessionController.TurnFailure?

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"],
        onSendUserTurn: (() -> Void)? = nil,
        startError: Error? = nil,
        steerError: Error? = nil,
        steerDelayNanos: UInt64 = 0,
        pendingTurnFailure: CodexNativeSessionController.TurnFailure? = nil
    ) {
        snapshotStatus = snapshot
        snapshotActiveTurnIDs = activeTurnIDs
        self.onSendUserTurn = onSendUserTurn
        self.startError = startError
        self.steerError = steerError
        self.steerDelayNanos = steerDelayNanos
        self.pendingTurnFailure = pendingTurnFailure
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func readSnapshotCountSync() -> Int {
        readSnapshotCount
    }

    func startUserTurnCountSync() -> Int {
        startUserTurnCount
    }

    func setStartUserTurnBeforeResult(_ operation: (() async -> Void)?) {
        startUserTurnBeforeResult = operation
    }

    func steerUserTurnIDsSync() -> [String] {
        steerUserTurnIDs
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        readSnapshotCount += 1
        return CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshotStatus,
            currentTurnID: snapshotActiveTurnIDs.first,
            activeTurnIDs: snapshotActiveTurnIDs,
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {
        recordSendUserTurn()
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        recordSendUserTurn()
        startUserTurnCount += 1
        if let startUserTurnBeforeResult {
            await startUserTurnBeforeResult()
        }
        if let startError {
            throw startError
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "liveness-submission-\(startUserTurnCount)")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        recordSendUserTurn()
        steerUserTurnIDs.append(expectedTurnID)
        if let steerError {
            throw steerError
        }
        if steerDelayNanos > 0 {
            try await Task.sleep(nanoseconds: steerDelayNanos)
        }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        interruptedTurnIDs.append(expectedTurnID)
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    /// Every provider interrupt requested (expected turn ID, or the current turn's cancellation).
    private(set) var interruptedTurnIDs: [String] = []
    private(set) var cancelCurrentTurnCount = 0

    private func recordSendUserTurn() {
        onSendUserTurn?()
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func pendingTurnFailure(
        turnID _: String?
    ) async -> CodexNativeSessionController.TurnFailure? {
        pendingTurnFailure
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure: CodexNativeSessionController.TurnFailure
    ) async {
        if pendingTurnFailure == failure {
            pendingTurnFailure = nil
        }
    }

    func cancelCurrentTurn() async {
        cancelCurrentTurnCount += 1
    }

    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {
        serverResponseIDs.append(id)
    }

    /// Every server-request reply sent (a native question's reply is never synthesized).
    private(set) var serverResponseIDs: [CodexAppServerRequestID] = []
}

/// Store file operations that fail the next write, or hold the next write until released (the
/// native question creation write, here). Later writes (terminal evidence) are unaffected.
private final class CodexQuestionWriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var failNext = false
    private var holdArmed = false
    private var holding = false

    func failNextWrite() {
        lock.withLock { failNext = true }
    }

    var isHolding: Bool {
        lock.withLock { holding }
    }

    func holdNextWrite() {
        lock.withLock { holdArmed = true }
    }

    func release() {
        let wasHolding = lock.withLock { () -> Bool in
            holdArmed = false
            defer { holding = false }
            return holding
        }
        if wasHolding { gate.signal() }
    }

    func fileOperations() -> AgentRecoveryStore.FileOperations {
        AgentRecoveryStore.FileOperations(
            writeAtomically: { [self] data, url in
                let (fail, hold) = lock.withLock { () -> (Bool, Bool) in
                    if failNext {
                        failNext = false
                        return (true, false)
                    }
                    guard holdArmed else { return (false, false) }
                    holdArmed = false
                    holding = true
                    return (false, true)
                }
                if fail { throw CocoaError(.fileWriteUnknown) }
                if hold { gate.wait() }
                try data.write(to: url, options: .atomic)
            },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
    }
}

/// Holds one provider-turn record write before it enters the recovery lane (9-live R2 ordering).
@MainActor
private final class ProviderTurnWriteHold {
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
