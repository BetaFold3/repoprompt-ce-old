import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Delegated `ask_user` escalation in `AgentModeViewModel` (plan §6): audience install, paused and
/// fallback timeouts, notice handoff de-duplication, idle next-turn staging, and legibility surfaces.
@MainActor
final class AgentModeViewModelDelegatedQuestionTests: XCTestCase {
    // MARK: - Audience install and timeout pause (§6.1, §6.4)

    func testQuestionAddressedToLiveParentPausesTimeoutAndRegistersNotice() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 0.05)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        XCTAssertNil(child.session.pendingAskUser?.timeoutStartedAt, "No countdown while the parent agent owns the question")
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.parentSessionID, parent.sessionID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)

        // Well past the child's own timeout, the question is still pending.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id)

        // Card activity never restarts a paused timeout.
        vm.noteAskUserCardActivity(tabID: child.tabID, interactionID: interaction.id)
        XCTAssertNil(child.session.pendingAskUser?.timeoutStartedAt)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        let response = try await task.value
        XCTAssertTrue(response.skipped)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty, "Resolving the question drops its notice")
    }

    func testParentClosingFallsBackToUserWithAFreshTimeout() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 0.2)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(child.session.pendingAskUser, "Paused: the original deadline passed without a timeout")

        let fallbackStart = Date()
        vm.test_removeLiveSession(tabID: parent.tabID)

        let pending = try XCTUnwrap(child.session.pendingAskUser)
        XCTAssertEqual(pending.delegatedRouting, .userFallback)
        let startedAt = try XCTUnwrap(pending.timeoutStartedAt)
        XCTAssertGreaterThanOrEqual(startedAt, fallbackStart, "The fallback timeout starts at the fallback, not at askedAt")
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[child.sessionID]?.ownQuestion, .needsUserAnswer)

        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "timeout")
    }

    func testMCPControlTeardownFallsBackToUserAndNeverRepauses() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        vm.test_setMCPControlledTabIDs([])
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .userFallback)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)

        // Control returning does not re-pause a question that already fell back.
        vm.test_setMCPControlledTabIDs([child.tabID])
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .userFallback)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testUnverifiedControlledRootFallsBackAndVerifiedExternalControllerIsUnchanged() async throws {
        let vm = makeViewModel()
        let connectionID = UUID()
        let root = makeSession(vm, parent: nil, originatingConnectionID: connectionID)
        vm.test_setMCPControlledTabIDs([root.tabID])

        XCTAssertEqual(vm.delegatedQuestionAudience(for: root.session, provenance: .unverified), .userFallback)
        XCTAssertEqual(
            vm.delegatedQuestionAudience(
                for: root.session,
                provenance: .init(verifiedNonAgentModeConnectionID: UUID())
            ),
            .userFallback,
            "Verification of a different connection never applies"
        )
        let verified = AgentDelegatedQuestionControllerProvenance(verifiedNonAgentModeConnectionID: connectionID)
        XCTAssertEqual(vm.delegatedQuestionAudience(for: root.session, provenance: verified), .externalController)

        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task {
            try await vm.askUser(tabID: root.tabID, interaction: interaction, controllerProvenance: verified)
        }
        try await waitUntil { root.session.askUserContinuation != nil }
        XCTAssertEqual(root.session.pendingAskUser?.delegatedRouting, .direct)
        XCTAssertNotNil(root.session.pendingAskUser?.timeoutStartedAt)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)

        vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testUncontrolledSessionKeepsDirectRouting() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID, controlled: false)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.askUserContinuation != nil }
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .direct)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Tool-result handoff (§6.2)

    func testHandoffDeliversOncePerNoticeAndNeverToTheSameOrALaterRunAgain() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runA = UUID()
        parent.session.runID = runA
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        // Idle (retaining its process run ID): not a tool-result destination yet.
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: []))
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.waitingForNextTurn])

        startParentRun(parent, runID: runA)
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: []))
        XCTAssertFalse(
            vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: [child.sessionID]),
            "A wait already covering the asking child is not woken for it"
        )
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: UUID(), excludingChildSessionIDs: []))
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.awaitingNextToolResult])
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.undeliveredChildQuestionCount, 1)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[child.sessionID]?.ownQuestion, .waitingOnParentAgent)

        let delivered = vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runA, coveredKeys: [])
        XCTAssertEqual(delivered.map(\.key.interactionID), [interaction.id])
        XCTAssertEqual(delivered.first?.childSessionName, "Agent Session")

        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runA, coveredKeys: []).isEmpty)
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: []))
        // A provider that reuses its process run ID for a new turn, or a later run, never sees an
        // acknowledged notice again (plan §6.2: acknowledged at handoff, no automatic re-arm).
        parent.session.beginRunAttempt(source: "test")
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runA, coveredKeys: []).isEmpty)
        let runB = startParentRun(parent)
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runB, coveredKeys: []).isEmpty)
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.delivered])
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.pendingChildQuestionCount, 1)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.undeliveredChildQuestionCount, 0)
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id, "Delivery never resolves the question")

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        XCTAssertTrue(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).isEmpty)
    }

    func testCoveredKeysAcknowledgeWithoutReturningAPayload() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: [key]).isEmpty)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        // The direct-commit path records the covered question once, as a persistence-only record.
        XCTAssertTrue(noticeNotes(parent).isEmpty, "A covered question is never recorded as a delivered notice")
        let records = coveredRecordNotes(parent)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first?.text.contains(interaction.id.uuidString) == true)
        XCTAssertTrue(records.first?.text.contains("1. [id `choice`] Which option?") == true)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testCoveredSnapshotQuestionsPersistCompleteContentThroughStorageAndReload() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let childA = makeSession(vm, parent: parent.sessionID)
        let childB = makeSession(vm, parent: parent.sessionID)
        let childC = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([childA.tabID, childB.tabID, childC.tabID])
        let runID = startParentRun(parent)
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }

        // Single snapshot: `agent_run` returns the asking child's question itself.
        let interactionA = makeDetailedInteraction(marker: "ALPHA")
        let taskA = Task { try await vm.askUser(tabID: childA.tabID, interaction: interactionA) }
        try await waitUntil { childA.session.pendingAskUser?.isAwaitingParentAgent == true }
        let single = agentRunQuestionSnapshot(child: childA, interaction: interactionA)
        let settledSingle = try await deliverAgentRunResult(single, vm: vm, parent: parent, runID: runID)
        XCTAssertEqual(settledSingle, single, "A covered question never adds notice output to the returned result")

        // Multi snapshot: one `agent_run` wait result carries two asking children.
        let interactionB = makeDetailedInteraction(marker: "BRAVO")
        let interactionC = makeDetailedInteraction(marker: "CHARLIE")
        let taskB = Task { try await vm.askUser(tabID: childB.tabID, interaction: interactionB) }
        try await waitUntil { childB.session.pendingAskUser?.isAwaitingParentAgent == true }
        let taskC = Task { try await vm.askUser(tabID: childC.tabID, interaction: interactionC) }
        try await waitUntil { childC.session.pendingAskUser?.isAwaitingParentAgent == true }
        let multi: Value = .object([
            "snapshots": .array([
                agentRunQuestionSnapshot(child: childB, interaction: interactionB),
                agentRunQuestionSnapshot(child: childC, interaction: interactionC)
            ])
        ])
        let settledMulti = try await deliverAgentRunResult(multi, vm: vm, parent: parent, runID: runID)
        XCTAssertEqual(settledMulti, multi, "Covered snapshots never add notice output to the returned result")

        for (child, interaction) in [(childA, interactionA), (childB, interactionB), (childC, interactionC)] {
            let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
            XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
            XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        }
        XCTAssertTrue(noticeNotes(parent).isEmpty, "Covered questions are never duplicated as delivered-notice notes")
        let inMemoryRecords = coveredRecordNotes(parent).map(\.text)
        XCTAssertEqual(inMemoryRecords.count, 2, "One persistence-only record per delivered result")

        // Actual storage path: canonical save (tool-result storage summaries), then reload.
        let service = AgentSessionDataService.shared
        let stored = AgentSession(
            id: parent.sessionID,
            workspaceID: workspace.id,
            composeTabID: parent.tabID,
            name: "Delegated Question Parent"
        ).withItems(parent.session.items)
        let fileURL = try await service.saveAgentSession(stored, for: workspace)
        let reloadedItems = try await service.loadAgentSession(from: fileURL).items.map { $0.toItem() }

        let reloadedRecords = reloadedItems.filter {
            $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.coveredRecordHeader)
        }.map(\.text)
        XCTAssertEqual(reloadedRecords, inMemoryRecords, "The records survive storage and reload verbatim")
        XCTAssertFalse(reloadedItems.contains {
            $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader)
        })
        let recordA = try XCTUnwrap(reloadedRecords.first)
        let recordBC = try XCTUnwrap(reloadedRecords.last)
        for fragment in expectedQuestionFragments(child: childA, interaction: interactionA) {
            XCTAssertTrue(recordA.contains(fragment), "Single-snapshot record lost: \(fragment)")
        }
        for (child, interaction) in [(childB, interactionB), (childC, interactionC)] {
            for fragment in expectedQuestionFragments(child: child, interaction: interaction) {
                XCTAssertTrue(recordBC.contains(fragment), "Multi-snapshot record lost: \(fragment)")
            }
        }
        XCTAssertEqual(recordBC.components(separatedBy: AgentDelegatedQuestionNoticeWire.coveredRecordHeader).count - 1, 2)
        // The storage summary of each `agent_run` result keeps only the interaction identity, so the
        // complete question content survives only in the records.
        for marker in ["ALPHA", "BRAVO", "CHARLIE"] {
            let longContext = "Context \(marker): " + Self.longContextBody
            let carriers = reloadedItems.filter {
                $0.text.contains(longContext) || $0.toolResultJSON?.contains(longContext) == true
            }
            XCTAssertFalse(carriers.isEmpty, marker)
            XCTAssertTrue(
                carriers.allSatisfy { $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.coveredRecordHeader) },
                marker
            )
        }

        for (child, interaction) in [(childA, interactionA), (childB, interactionB), (childC, interactionC)] {
            vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        }
        _ = try await taskA.value
        _ = try await taskB.value
        _ = try await taskC.value
    }

    /// Pins the production `ask_user` → `agent_run` snapshot mapping (`mcpSnapshot(for:)` →
    /// `mcpPendingInteraction`) to the formatter: the wire encoding `agent_run` poll/wait returns
    /// carries every structured field, and its formatted text hands the parent the complete
    /// question, including a token present only in an option the parent could not guess. The
    /// single-wait result is re-parsed by the service (`AgentRunMCPToolService.snapshot(from:)`)
    /// and re-encoded (`asObject()`) before formatting, so that conversion must be lossless too.
    func testAgentRunSnapshotOfPendingAskUserEncodesAndFormatsCompleteStructuredQuestion() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let unknownToken = "UNKNOWN-OPTION-TOKEN-91c4e7"
        let hiddenLabel = "Pinned build \(unknownToken)"
        let hiddenDescription = "Only the root controller knows \(unknownToken) is required."
        let strategyContext = "Strategy context: " + Self.longContextBody
        let targetContext = "Target context line one.\nTarget context line two with detail."
        let interaction = AgentAskUserInteraction(
            title: "Release decision",
            context: "Overall context: " + Self.longContextBody,
            timeoutSeconds: 60,
            questions: [
                AgentAskUserQuestion(
                    id: "strategy",
                    header: "Strategy",
                    question: "Which rollout strategies should run?",
                    context: strategyContext,
                    options: [
                        AgentAskUserOption(label: "Canary", description: "One percent first."),
                        AgentAskUserOption(label: hiddenLabel, description: hiddenDescription)
                    ],
                    allowsMultiple: true,
                    allowsCustom: false
                ),
                AgentAskUserQuestion(
                    id: "target",
                    header: "Target",
                    question: "Which environment receives the build?",
                    context: targetContext,
                    options: [AgentAskUserOption(label: "staging"), AgentAskUserOption(label: "production", description: "Live traffic.")],
                    allowsMultiple: false,
                    allowsCustom: true
                )
            ]
        )

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        // Wire encoding produced by the production snapshot builder, as agent_run poll/wait returns it.
        let snapshot = try XCTUnwrap(vm.mcpSnapshot(for: child.session))
        XCTAssertEqual(snapshot.status, .waitingForInput)
        let object = snapshot.asObject()
        let wireInteraction = try XCTUnwrap(object["interaction"]?.objectValue)
        XCTAssertEqual(wireInteraction["id"]?.stringValue, interaction.id.uuidString)
        XCTAssertEqual(wireInteraction["kind"]?.stringValue, "question")
        XCTAssertEqual(wireInteraction["title"]?.stringValue, interaction.title)
        XCTAssertEqual(wireInteraction["context"]?.stringValue, interaction.context)
        let fields = try XCTUnwrap(wireInteraction["fields"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(fields.map { $0["id"]?.stringValue }, ["strategy", "target"])
        for (field, question) in zip(fields, interaction.questions) {
            XCTAssertEqual(field["header"]?.stringValue, question.header, question.id)
            XCTAssertEqual(field["prompt"]?.stringValue, question.question, question.id)
            XCTAssertEqual(field["context"]?.stringValue, question.context, question.id)
            XCTAssertEqual(field["allows_multiple"]?.boolValue, question.allowsMultiple, question.id)
            XCTAssertEqual(field["allows_custom"]?.boolValue, question.allowsCustom, question.id)
            XCTAssertNil(field["allows_other"], "ask_user fields carry allows_custom, not allows_other: \(question.id)")
            let options = field["options"]?.arrayValue?.compactMap(\.objectValue) ?? []
            XCTAssertEqual(options.map { $0["label"]?.stringValue }, question.options.map(\.label), question.id)
            XCTAssertEqual(options.map { $0["description"]?.stringValue }, question.options.map(\.description), question.id)
        }

        // Single wait decorates the service-parsed snapshot of the raw wait value; per-question
        // context and selection semantics must survive that wire conversion unchanged.
        let converted = try XCTUnwrap(AgentRunMCPToolService.snapshot(from: object))
        XCTAssertEqual(converted.interaction, snapshot.interaction, "Service wire conversion must preserve the structured question")
        let convertedObject = converted.asObject()
        XCTAssertEqual(convertedObject["interaction"], object["interaction"], "Re-encoded interaction must match the production wire encoding")

        // Formatted agent_run text: the only copy of the question the parent model reads.
        for (path, value) in [("snapshot", object), ("service-converted", convertedObject)] {
            try assertFormattedAgentRunCarriesCompleteQuestion(
                value: value,
                path: path,
                interaction: interaction,
                hiddenLabel: hiddenLabel,
                hiddenDescription: hiddenDescription,
                strategyContext: strategyContext,
                targetContext: targetContext
            )
        }

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    private func assertFormattedAgentRunCarriesCompleteQuestion(
        value: [String: Value],
        path: String,
        interaction: AgentAskUserInteraction,
        hiddenLabel: String,
        hiddenDescription: String,
        strategyContext: String,
        targetContext: String
    ) throws {
        let blocks = ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: .object(value))
        guard case let .text(text, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected agent_run text output (\(path))")
        }
        for fragment in [
            "Title: Release decision",
            "Context: Overall context: " + Self.longContextBody,
            "1. [id `strategy`] Strategy: Which rollout strategies should run?",
            "   Context: \(strategyContext)",
            "   Selection: choose any number of options; custom answer not allowed",
            "   - Canary — One percent first.",
            "   - \(hiddenLabel) — \(hiddenDescription)",
            "2. [id `target`] Target: Which environment receives the build?",
            "   Context: \(targetContext)",
            "   Selection: choose one option; custom answer allowed",
            "   - staging\n",
            "   - production — Live traffic.",
            "- Interaction ID: `\(interaction.id.uuidString)`",
            "- Provide `answers` as an object keyed by question id (`strategy`, `target`), answering every question."
        ] {
            XCTAssertTrue(text.contains(fragment), "Formatted agent_run \(path) lost: \(fragment)")
        }
        XCTAssertFalse(text.contains("Provide the requested answers to continue."), "The derived generic prompt is replaced by the full questions (\(path))")
    }

    // MARK: - Idle parent: next turn's first input (§6.2)

    func testIdleParentNoticeIsStagedIntoProviderInputAndCommittedAsSystemNoteOnlyAfterSend() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let itemCountBefore = parent.session.items.count

        let staged = vm.stageDelegatedQuestionNoticesForTurnInput("user text", session: parent.session)
        XCTAssertTrue(staged.hasPrefix("<repoprompt_runtime_notice kind=\"delegated_child_questions\">\n"))
        XCTAssertTrue(staged.hasSuffix("</repoprompt_runtime_notice>\n\nuser text"))
        XCTAssertTrue(staged.contains(interaction.id.uuidString))
        XCTAssertEqual(parent.session.items.count, itemCountBefore, "Staging never writes to the transcript or user text")

        // Outcomes without this stage's identity never settle it.
        let firstStage = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: nil, didSend: true)
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: UUID(), didSend: true)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), firstStage)
        XCTAssertEqual(parent.session.items.count, itemCountBefore)

        // A failed send rolls the stage back; the notice stays deliverable.
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: firstStage, didSend: false)
        XCTAssertTrue(vm.delegatedQuestionNotices.stagedTurnNoticesByParentTabID.isEmpty)
        XCTAssertEqual(parent.session.items.count, itemCountBefore)
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)

        let restaged = vm.stageDelegatedQuestionNoticesForTurnInput("next", session: parent.session)
        XCTAssertTrue(restaged.hasSuffix("\n\nnext"))
        let restageID = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        XCTAssertNotEqual(restageID, firstStage)
        let runID = startParentRun(parent)
        // While staged, the tool-result path never double-delivers the same notice.
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []).isEmpty)
        // A late outcome of the superseded first stage never commits the newer stage.
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: firstStage, didSend: true)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), restageID)
        XCTAssertEqual(parent.session.items.count, itemCountBefore)

        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: restageID, didSend: true)
        XCTAssertEqual(parent.session.items.count, itemCountBefore + 1)
        let note = try XCTUnwrap(parent.session.items.last)
        XCTAssertEqual(note.kind, .system)
        XCTAssertTrue(note.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader))
        XCTAssertTrue(note.text.contains(child.sessionID.uuidString))
        XCTAssertTrue(note.text.contains(interaction.id.uuidString))
        XCTAssertTrue(parent.session.isDirty, "The note is saved with the parent transcript")
        // The persisted note reaches the parent's transcript projection as a labeled, ID-bearing row.
        vm.refreshDerivedTranscriptState(for: parent.session)
        let projected = try XCTUnwrap(parent.session.workingTranscriptProjection.workingRows.last)
        XCTAssertEqual(projected.kind, .system)
        XCTAssertTrue(projected.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader))
        XCTAssertTrue(projected.text.contains(child.sessionID.uuidString))
        XCTAssertTrue(projected.text.contains(interaction.id.uuidString))
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])

        XCTAssertEqual(
            vm.stageDelegatedQuestionNoticesForTurnInput("later", session: parent.session),
            "later",
            "An acknowledged notice is never staged again"
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Reserved tool-result handoff (§6.2: cancellation never consumes a notice)

    func testReservedNoticeIsNotConsumedUntilCommitAndReleaseRestoresDelivery() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        XCTAssertEqual(target.runAttemptID, parent.session.activeRunAttemptID)

        let first = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        XCTAssertEqual(first.payloads.map(\.key), [key])
        XCTAssertEqual(first.parentRunID, runID)
        XCTAssertEqual(first.target, target)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, "Reserving never acknowledges")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertNil(
            vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []),
            "A concurrent result never carries a notice already reserved by another result"
        )
        // A reserved notice is never also staged into a next-turn input.
        XCTAssertEqual(vm.stageDelegatedQuestionNoticesForTurnInput("text", session: parent.session), "text")
        XCTAssertNil(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID)

        // Cancelled or failed before handoff: the notice is deliverable again to the same run.
        vm.mcpReleaseDelegatedQuestionNoticeReservation(first.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.awaitingNextToolResult])

        // Handed off: committed exactly once.
        let second = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        XCTAssertEqual(second.payloads.map(\.key), [key])
        vm.mcpCommitDelegatedQuestionNoticeReservation(second.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertNil(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        // Late finishes of settled reservations are no-ops.
        vm.mcpReleaseDelegatedQuestionNoticeReservation(second.id)
        vm.mcpReleaseDelegatedQuestionNoticeReservation(first.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.delivered])

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testReconcileReleasesReservationWhoseRunStoppedAndCommitAfterResolutionIsNoOp() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))

        let stranded = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNotNil(vm.delegatedQuestionNotices.records[key]?.reservationID, "An active run keeps its in-flight reservation")

        parent.session.runState = .idle
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty, "A run that stopped can no longer receive the result")
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        vm.mcpCommitDelegatedQuestionNoticeReservation(stranded.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, "A released reservation never commits later")

        parent.session.runState = .running
        let pending = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        XCTAssertNil(vm.delegatedQuestionNotices.records[key])
        vm.mcpCommitDelegatedQuestionNoticeReservation(pending.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key], "Committing after the question resolved changes nothing")
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
    }

    // MARK: - Idle staging release on start/send failure (§6.2)

    func testStartThatNeverSentReleasesTheStagedTurnNotice() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let itemCount = parent.session.items.count

        // Refused or failed before the provider: the start's own outcome proves no handoff.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("one", session: parent.session)
        let refusedStage = vm.delegatedQuestionTurnStageID(forTabID: parent.tabID)
        XCTAssertNotNil(refusedStage)
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNotNil(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), "A start in flight keeps its stage")
        vm.settleDelegatedQuestionTurnStageAfterRunStart(refusedStage, session: parent.session, startDisposition: .notSent)
        assertReleased(vm, key: key, parentTabID: parent.tabID)

        // The start reported no send (stale, cancelled, or failed) even though a run is active.
        parent.session.runState = .running
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("two", session: parent.session)
        let failedStage = vm.delegatedQuestionTurnStageID(forTabID: parent.tabID)
        vm.settleDelegatedQuestionTurnStageAfterRunStart(failedStage, session: parent.session, startDisposition: .notSent)
        assertReleased(vm, key: key, parentTabID: parent.tabID)

        // Started; the run stopped without ever reporting a send outcome. That is not proof of
        // non-delivery: the stage is held unknown (never re-delivered, never acknowledged) until its
        // own late outcome, which here proves it was never written.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("three", session: parent.session)
        let startedStage = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        vm.settleDelegatedQuestionTurnStageAfterRunStart(UUID(), session: parent.session, startDisposition: .notSent)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage, "Settling never touches another stage")
        vm.settleDelegatedQuestionTurnStageAfterRunStart(startedStage, session: parent.session, startDisposition: nil)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage, "An active run awaits its send outcome")
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage)
        parent.session.runState = .failed
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNil(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), "No longer the tab's current stage")
        XCTAssertEqual(vm.delegatedQuestionNotices.heldTurnNoticesByStageID[startedStage]?.notice.phase, .deliveryUnknown)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID, parent.tabID, "Held: not deliverable again")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, "Held: not acknowledged")
        let heldRunID = startParentRun(parent)
        XCTAssertTrue(
            vm.mcpHandOffDelegatedQuestionNotices(parentRunID: heldRunID, coveredKeys: []).isEmpty,
            "A possibly delivered notice is never delivered a second time"
        )
        XCTAssertEqual(vm.stageDelegatedQuestionNoticesForTurnInput("four", session: parent.session), "four")
        XCTAssertTrue(child.session.pendingAskUser?.isAwaitingParentAgent == true, "The child question stays answerable")
        parent.session.runState = .completed
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: startedStage, disposition: .notSent)
        assertReleased(vm, key: key, parentTabID: parent.tabID)
        XCTAssertTrue(vm.delegatedQuestionNotices.heldTurnNoticesByStageID.isEmpty)

        XCTAssertEqual(parent.session.items.count, itemCount, "Released stages never write a transcript note")
        let nextRunID = startParentRun(parent)
        XCTAssertEqual(
            vm.mcpHandOffDelegatedQuestionNotices(parentRunID: nextRunID, coveredKeys: []).map(\.key),
            [key],
            "The released notice is still delivered later"
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testUncertainTurnNoticeSurvivesSupersedingInputAndCommitsOnceOnItsLateSentOutcome() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let firstInteraction = makeInteraction(timeoutSeconds: 60)
        let firstTask = Task { try await vm.askUser(tabID: child.tabID, interaction: firstInteraction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let firstKey = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: firstInteraction.id)
        let itemCount = parent.session.items.count

        // A start whose delivery is unknown holds its stage.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("one", session: parent.session)
        let uncertainStage = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        vm.settleDelegatedQuestionTurnStageAfterRunStart(uncertainStage, session: parent.session, startDisposition: .deliveryUnknown)
        XCTAssertNil(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        XCTAssertEqual(vm.delegatedQuestionNotices.heldTurnNoticesByStageID[uncertainStage]?.notice.phase, .deliveryUnknown)

        // The next input and attempt end never re-carry or release it.
        XCTAssertEqual(vm.stageDelegatedQuestionNoticesForTurnInput("two", session: parent.session), "two")
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNotNil(vm.delegatedQuestionNotices.heldTurnNoticesByStageID[uncertainStage])
        XCTAssertEqual(vm.delegatedQuestionNotices.records[firstKey]?.stagedParentTabID, parent.tabID)
        XCTAssertEqual(parent.session.items.count, itemCount)

        // Its late `sent` commits exactly once; a repeated outcome is a no-op. The run current at the
        // late outcome did not carry it (the carrier was never identified), so no run is stamped.
        startParentRun(parent)
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: uncertainStage, disposition: .sent)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[firstKey]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[firstKey]?.deliveredRunIDs, [], "Never a successor run")
        XCTAssertNil(vm.delegatedQuestionNotices.records[firstKey]?.stagedParentTabID)
        XCTAssertTrue(vm.delegatedQuestionNotices.heldTurnNoticesByStageID.isEmpty)
        XCTAssertEqual(noticeNotes(parent).count, 1, "One persisted note for the committed stage")
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: uncertainStage, disposition: .sent)
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: uncertainStage, disposition: .notSent)
        XCTAssertEqual(noticeNotes(parent).count, 1)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[firstKey]?.acknowledged, true, "Never downgraded")
        XCTAssertTrue(child.session.pendingAskUser?.isAwaitingParentAgent == true, "Acknowledged, still answerable")
        parent.session.runState = .completed

        vm.skipAskUser(tabID: child.tabID, interactionID: firstInteraction.id)
        _ = try await firstTask.value

        // A superseded in-flight stage is held, not rolled back: the newer stage carries only new
        // notices, and the earlier stage's late outcome never settles the newer one.
        let secondInteraction = makeInteraction(timeoutSeconds: 60)
        let secondTask = Task { try await vm.askUser(tabID: child.tabID, interaction: secondInteraction) }
        try await waitUntil { child.session.pendingAskUser?.interaction.id == secondInteraction.id && child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let secondKey = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: secondInteraction.id)
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("three", session: parent.session)
        let supersededStage = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        XCTAssertEqual(vm.stageDelegatedQuestionNoticesForTurnInput("four", session: parent.session), "four", "Nothing re-carried")
        XCTAssertEqual(vm.delegatedQuestionNotices.heldTurnNoticesByStageID[supersededStage]?.notice.keys, [secondKey])
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: supersededStage, disposition: .notSent)
        assertReleased(vm, key: secondKey, parentTabID: parent.tabID)

        vm.skipAskUser(tabID: child.tabID, interactionID: secondInteraction.id)
        _ = try await secondTask.value
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertTrue(vm.delegatedQuestionNotices.isEmpty)
    }

    func testLateOutcomeAfterSuccessorRunStampsOnlyTheCarryingRun() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)

        // Run A carries the stage: its start returns with the run active.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("one", session: parent.session)
        let stage = try XCTUnwrap(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID))
        let carryingRunID = startParentRun(parent)
        vm.settleDelegatedQuestionTurnStageAfterRunStart(stage, session: parent.session, startDisposition: nil)
        // Run A stops without an outcome; successor run B starts before A's late outcome arrives.
        parent.session.runState = .completed
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(vm.delegatedQuestionNotices.heldTurnNoticesByStageID[stage]?.notice.phase, .deliveryUnknown)
        let successorRunID = startParentRun(parent)
        XCTAssertNotEqual(successorRunID, carryingRunID)

        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, stageID: stage, disposition: .sent)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(
            vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs,
            [carryingRunID],
            "The late outcome is attributed to the run that carried it, never the successor"
        )
        XCTAssertEqual(noticeNotes(parent).count, 1)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testCodexQueuedFallbackDropsTheReleasedStageBlockAndLaterDispatchCarriesNoStaleNotice() async throws {
        for resolvesBeforeDispatch in [false, true] {
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            let vm = makeViewModel(codexController: controller)
            // A Codex fallback is queued only under a store-issued queue receipt: the parent is
            // bound to a real temporary recovery lane and its input is admitted through it.
            let recovery = try await RecoveryLaneFixture.make("DelegatedQuestionCodexFallback")
            defer { recovery.tearDown() }
            let parent = makeSession(vm, parent: nil, sessionID: recovery.sessionID)
            parent.session.recoveryLane = recovery.lane
            parent.session.selectedAgent = .codexExec
            let child = makeSession(vm, parent: parent.sessionID)
            vm.test_setMCPControlledTabIDs([child.tabID])
            let interaction = makeInteraction(timeoutSeconds: 60)

            let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
            try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
            let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
            XCTAssertFalse(parent.session.runState.isActive, "Precondition: an idle parent stages the notice")

            // The parent's run becomes active (without an authoritative Codex turn) after the
            // idle-turn stage was built and before the provider handoff, so Codex queues the staged
            // input as a fallback instead of sending it.
            let identity = try await recovery.queuedIdentity("user follow-up")
            let admittedQueueID = try XCTUnwrap(identity.intentID)
            let outcome = await vm.startAgentRun(
                tabID: parent.tabID,
                initialMessage: "user follow-up",
                inputConstituents: nil,
                codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext(
                    queueID: admittedQueueID,
                    providerText: "user follow-up",
                    images: [],
                    taggedFileAttachments: [],
                    draftText: "user follow-up",
                    identity: identity,
                    origin: .manual,
                    dispatchTicket: nil
                ),
                providerHandoffAuthorization: {
                    parent.session.runID = UUID()
                    parent.session.runState = .running
                    parent.session.beginRunAttempt(source: "test.activeBeforeHandoff")
                    return true
                }
            )
            guard case let .queuedFallback(receipt, .activeWithoutAuthoritativeIdentity)? = outcome else {
                XCTFail("Expected a queued Codex fallback, got \(String(describing: outcome))")
                vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
                _ = try await task.value
                return
            }
            let queueID = receipt.intent.intentID
            XCTAssertEqual(queueID, admittedQueueID, "The queue ID is the admitted intent ID")
            // Codex session setup binds the run it starts the thread for; the queued entry carries it.
            let runID = try XCTUnwrap(parent.session.runID)
            XCTAssertEqual(parent.session.codexFallbackQueue.first?.originRunID, runID)

            // The released stage's runtime block is gone from the queued copy; the user's text stays.
            let entry = try XCTUnwrap(parent.session.codexFallbackQueue.first)
            XCTAssertEqual(parent.session.codexFallbackQueue.map(\.id), [queueID])
            let queuedText = entry.providerText
            XCTAssertFalse(queuedText.contains(AgentDelegatedQuestionNoticeWire.runtimeNoticeTagName))
            XCTAssertFalse(queuedText.contains(AgentDelegatedQuestionNoticeWire.noticeHeader))
            XCTAssertFalse(queuedText.contains(interaction.id.uuidString))
            XCTAssertTrue(queuedText.contains("user follow-up"))
            XCTAssertEqual(entry.draftText, "user follow-up", "The admitted submission keeps its own original text")
            assertReleased(vm, key: key, parentTabID: parent.tabID)
            XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
            XCTAssertTrue(noticeNotes(parent).isEmpty, "A queued fallback never records the notice")
            XCTAssertTrue(controller.sentTexts.isEmpty, "Precondition: nothing reached the provider yet")
            XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))

            if resolvesBeforeDispatch {
                // The child's question resolves before the queued input is dispatched.
                vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
                _ = try await task.value
                XCTAssertNil(vm.delegatedQuestionNotices.records[key])
            } else {
                // An intervening tool result of the active run delivers the notice legitimately.
                let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
                let reservation = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
                XCTAssertEqual(reservation.payloads.map(\.key), [key])
                let original: Value = .object(["content": .string("tool body")])
                let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(reservation.payloads, to: original))
                let delivery = MCPToolResultDeliveryTransaction()
                MCPServerViewModel.registerDelegatedQuestionNoticeParticipant(
                    on: delivery,
                    viewModel: vm,
                    reservationID: reservation.id,
                    attachedKeys: reservation.attachedKeys
                )
                let settled = await delivery.settle(attached, handOff: true)
                XCTAssertEqual(settled, attached)
                XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
                XCTAssertEqual(noticeNotes(parent).count, 1)
            }

            // Eventual dispatch of the queued input carries no stale or duplicate notice.
            XCTAssertTrue(vm.test_codexCoordinator.test_claimCodexFallbackHead(
                session: parent.session,
                expectedQueueID: queueID,
                beginsSuccessorAttempt: false
            ))
            await vm.test_codexCoordinator.test_dispatchClaimedCodexFallback(session: parent.session)
            XCTAssertEqual(controller.sentTexts, [queuedText], "The dispatched input is exactly the queued text")
            XCTAssertEqual(noticeNotes(parent).count, resolvesBeforeDispatch ? 0 : 1, "Dispatch never records a notice")
            if !resolvesBeforeDispatch {
                XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
                XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
                vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
                _ = try await task.value
            }
        }
    }

    // MARK: - Active run-attempt binding and final handoff settlement (§6.2)

    func testIdleParentRetainingItsRunIDIsNeverADestinationAndWakesOncePerAttempt() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        // Claude keeps its process run ID while the parent is idle between turns.
        let runID = UUID()
        parent.session.runID = runID
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)

        XCTAssertNil(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []).isEmpty)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs, [], "An idle parent is never woken")

        // An active state without a run attempt is not a destination either.
        parent.session.runState = .running
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNil(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs, [])

        let firstAttempt = parent.session.beginRunAttempt(source: "test").attemptID
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(
            vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID),
            AgentDelegatedQuestionDeliveryTarget(parentRunID: runID, runAttemptID: firstAttempt)
        )
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs, [firstAttempt])
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs, [firstAttempt], "One wake per attempt")

        // A new turn under the same process run ID is a new attempt: still undelivered, woken again.
        let secondAttempt = parent.session.beginRunAttempt(source: "test").attemptID
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs, [firstAttempt, secondAttempt])

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testSettleForAReplacedAttemptStripsAndReleasesWhileTheCurrentAttemptCommits() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let original: Value = .object(["content": .string("body")])

        let staleTarget = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        let stale = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: staleTarget, coveredKeys: []))
        let staleValue = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(stale.payloads, to: original))
        // The parent's next turn begins under the same process run ID before the late result settles.
        parent.session.beginRunAttempt(source: "test")

        let settledStale = vm.mcpSettleDelegatedQuestionNoticeReservation(
            stale.id, attachedKeys: stale.attachedKeys, value: staleValue, handOff: true
        )
        XCTAssertEqual(settledStale, original, "A result for a replaced attempt never carries the notice")
        XCTAssertTrue(noticeNotes(parent).isEmpty, "A stripped notice is never recorded in the parent transcript")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertNil(
            vm.mcpReserveDelegatedQuestionNotices(target: staleTarget, coveredKeys: []),
            "A target captured by an earlier attempt never reserves"
        )
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))

        let currentTarget = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        XCTAssertNotEqual(currentTarget, staleTarget)
        let current = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: currentTarget, coveredKeys: []))
        let currentValue = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(current.payloads, to: original))
        let settledCurrent = vm.mcpSettleDelegatedQuestionNoticeReservation(
            current.id, attachedKeys: current.attachedKeys, value: currentValue, handOff: true
        )
        XCTAssertEqual(settledCurrent, currentValue, "Committed notices are handed off unchanged")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        // The commit step itself records exactly the handed-off notice text in the parent transcript.
        XCTAssertEqual(
            noticeNotes(parent).map(\.text),
            try [XCTUnwrap(AgentDelegatedQuestionNoticeWire.renderedText(for: current.payloads))]
        )
        XCTAssertTrue(noticeNotes(parent).first?.text.contains(interaction.id.uuidString) == true)
        // A second settle of the same reservation never hands the notice off again.
        XCTAssertEqual(
            vm.mcpSettleDelegatedQuestionNoticeReservation(
                current.id, attachedKeys: current.attachedKeys, value: currentValue, handOff: true
            ),
            original
        )
        XCTAssertEqual(noticeNotes(parent).count, 1, "A second settle never records the notice again")

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testCancelledSettleStripsAndReleasesAndResolutionBeforeHandoffStrips() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        let original: Value = .object(["content": .string("body")])

        // Cancelled before the final handoff: never both returned and left pending.
        let cancelled = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        let cancelledValue = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(cancelled.payloads, to: original))
        XCTAssertEqual(
            vm.mcpSettleDelegatedQuestionNoticeReservation(
                cancelled.id, attachedKeys: cancelled.attachedKeys, value: cancelledValue, handOff: false
            ),
            original
        )
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertTrue(noticeNotes(parent).isEmpty, "A cancelled handoff never records the notice")
        // A late abandon of the settled reservation changes nothing.
        vm.mcpReleaseDelegatedQuestionNoticeReservation(cancelled.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)

        // Resolved after reservation but before the final handoff: stripped, nothing acknowledged.
        let resolved = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        let resolvedValue = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(resolved.payloads, to: original))
        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        XCTAssertEqual(
            vm.mcpSettleDelegatedQuestionNoticeReservation(
                resolved.id, attachedKeys: resolved.attachedKeys, value: resolvedValue, handOff: true
            ),
            original
        )
        XCTAssertNil(vm.delegatedQuestionNotices.records[key])
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertTrue(noticeNotes(parent).isEmpty, "A notice resolved before the handoff is never recorded")
    }

    func testCancellationDuringTheMainActorSettlementHopStripsReleasesAndStaysRetryable() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        let original: Value = .object(["content": .string("body")])
        let reservation = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(reservation.payloads, to: original))

        // A gate participant registered first holds settlement after the live handler sampled
        // `handOff`, before the production participant's main-actor commit step runs.
        let delivery = MCPToolResultDeliveryTransaction()
        let gate = DelegatedQuestionSettlementGate()
        delivery.register(
            settle: { value, handOff in
                await gate.hold(handOff: handOff)
                return value
            },
            abandon: {}
        )
        MCPServerViewModel.registerDelegatedQuestionNoticeParticipant(
            on: delivery,
            viewModel: vm,
            reservationID: reservation.id,
            attachedKeys: reservation.attachedKeys
        )
        let handler = Task.detached { await delivery.settle(attached, handOff: !Task.isCancelled) }
        let held = await gate.waitUntilHeld()
        XCTAssertTrue(held, "Settlement must reach the gate")
        let sampledHandOff = await gate.heldHandOff
        XCTAssertEqual(sampledHandOff, true, "Precondition: the live handler requested a handoff")

        // Cancelled after settlement was requested, before the commit step.
        handler.cancel()
        await gate.release()
        let settled = await handler.value

        XCTAssertEqual(settled, original, "A handler cancelled before the commit never carries the notice")
        XCTAssertTrue(noticeNotes(parent).isEmpty, "A cancelled handoff never records the notice")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))

        // Retryable: the next live result delivers and records it exactly once.
        let retry = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))
        XCTAssertEqual(retry.payloads.map(\.key), [key])
        let retryAttached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(retry.payloads, to: original))
        let retryDelivery = MCPToolResultDeliveryTransaction()
        MCPServerViewModel.registerDelegatedQuestionNoticeParticipant(
            on: retryDelivery,
            viewModel: vm,
            reservationID: retry.id,
            attachedKeys: retry.attachedKeys
        )
        let retried = await retryDelivery.settle(retryAttached, handOff: true)
        XCTAssertEqual(retried, retryAttached)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        XCTAssertEqual(
            noticeNotes(parent).map(\.text),
            try [XCTUnwrap(AgentDelegatedQuestionNoticeWire.renderedText(for: retry.payloads))]
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testReconcileReleasesAReservationWhoseAttemptWasReplaced() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        _ = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: []))

        let nextAttempt = parent.session.beginRunAttempt(source: "test").attemptID
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertEqual(
            vm.delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs.contains(nextAttempt),
            true,
            "The released notice wakes the current attempt"
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Controller provenance fallback (§6.1)

    func testMCPControlledRootWithoutAnOriginatingConnectionFallsBackToTheUser() async throws {
        for installsControlContext in [false, true] {
            let vm = makeViewModel()
            let root = makeSession(vm, parent: nil, forceControlContext: installsControlContext)
            vm.test_setMCPControlledTabIDs([root.tabID])
            XCTAssertEqual(root.session.mcpControlContext != nil, installsControlContext)
            XCTAssertNil(root.session.mcpControlContext?.originatingConnectionID)

            XCTAssertEqual(vm.delegatedQuestionAudience(for: root.session, provenance: .unverified), .userFallback)
            XCTAssertEqual(
                vm.delegatedQuestionAudience(
                    for: root.session,
                    provenance: .init(verifiedNonAgentModeConnectionID: UUID())
                ),
                .userFallback,
                "No verification can match a controller without a connection"
            )

            let interaction = makeInteraction(timeoutSeconds: 60)
            let task = Task { try await vm.askUser(tabID: root.tabID, interaction: interaction) }
            try await waitUntil { root.session.askUserContinuation != nil }
            XCTAssertEqual(root.session.pendingAskUser?.delegatedRouting, .userFallback)
            XCTAssertNotNil(root.session.pendingAskUser?.timeoutStartedAt, "The user's normal timeout runs")
            XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
            XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[root.sessionID]?.ownQuestion, .needsUserAnswer)

            vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
            _ = try await task.value
        }
    }

    // MARK: - Steer while asking (§6.1: routing is not debounced; a steer never toggles control)

    func testParentSteerOfAnAskingChildIsRejectedAndKeepsParentRouting() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)

        do {
            _ = try await vm.mcpDispatchInstruction(
                sessionID: child.sessionID,
                text: "Use option B",
                allowStartingRun: true
            )
            XCTFail("A steer while the child asks must be rejected in favor of agent_run respond")
        } catch {
            let message = "\(error) \(error.localizedDescription)"
            XCTAssertTrue(message.contains("Use agent_run.respond instead"), message)
        }
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertTrue(vm.isMCPControlled(tabID: child.tabID), "A rejected steer never toggles MCP control")
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id)
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .awaitingParentAgent)
        XCTAssertNil(child.session.pendingAskUser?.timeoutStartedAt, "The paused timeout never starts")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.parentSessionID, parent.sessionID)

        // The supported parent action still answers the question.
        _ = try await vm.mcpResolvePendingInteraction(
            sessionID: child.sessionID,
            interactionID: interaction.id,
            payload: parentAnswer("B"),
            resolvedBy: "parent-agent"
        )
        let response = try await task.value
        XCTAssertEqual(response.answersByQuestionID["choice"]?.answers, ["B"])
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
    }

    // MARK: - Answer authority races (§6.7: existing first-wins paths, no new mechanism)

    func testUserAnswerInChildTabWinsOverALaterParentRespond() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = startParentRun(parent)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        // The parent already saw the notice.
        XCTAssertEqual(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []).count, 1)

        try vm.submitAskUserResponse(
            tabID: child.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["choice": AgentAskUserDraft(selectedOptionLabels: ["A"])]
        )
        do {
            _ = try await vm.mcpResolvePendingInteraction(
                sessionID: child.sessionID,
                interactionID: interaction.id,
                payload: parentAnswer("B"),
                resolvedBy: "parent-agent"
            )
            XCTFail("A respond for an already-answered question must be rejected")
        } catch {}

        let response = try await task.value
        XCTAssertEqual(response.answersByQuestionID["choice"]?.answers, ["A"])
        XCTAssertEqual(child.session.lastInteractionResolution?.interactionID, interaction.id)
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "user")
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
        XCTAssertTrue(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).isEmpty)
    }

    func testParentRespondWinsOverALaterUserSubmitAndStaleIDsAreRejected() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        do {
            _ = try await vm.mcpResolvePendingInteraction(
                sessionID: child.sessionID,
                interactionID: UUID(),
                payload: parentAnswer("B"),
                resolvedBy: "parent-agent"
            )
            XCTFail("A respond carrying a different interaction ID must be rejected")
        } catch {}
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id, "A rejected respond changes nothing")

        _ = try await vm.mcpResolvePendingInteraction(
            sessionID: child.sessionID,
            interactionID: interaction.id,
            payload: parentAnswer("B"),
            resolvedBy: "parent-agent"
        )
        // The user's late submit in the child tab is a no-op: the first resolution won.
        try vm.submitAskUserResponse(
            tabID: child.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["choice": AgentAskUserDraft(selectedOptionLabels: ["A"])]
        )

        let response = try await task.value
        XCTAssertEqual(response.answersByQuestionID["choice"]?.answers, ["B"])
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "parent-agent")
        XCTAssertNil(child.session.pendingAskUser)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
    }

    func testOpenChildActionRefusesOnceTheQuestionResolved() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let row = try XCTUnwrap(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).first)
        XCTAssertEqual(row.childTabID, child.tabID)
        let openError = await vm.openDelegatedQuestionChild(row)
        XCTAssertNil(openError)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        let staleError = await vm.openDelegatedQuestionChild(row)
        XCTAssertEqual(staleError, "That child question is no longer pending.")
    }

    // MARK: - Helpers

    private struct LiveSession {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentTabSession
    }

    private func makeViewModel(codexController: LifecycleNoopCodexController? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                codexController ?? LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )
    }

    /// Delegated-question runtime notes recorded in the parent transcript.
    private func noticeNotes(_ parent: LiveSession) -> [AgentChatItem] {
        parent.session.items.filter {
            $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader)
        }
    }

    /// Persistence-only records of covered questions recorded in the parent transcript.
    private func coveredRecordNotes(_ parent: LiveSession) -> [AgentChatItem] {
        parent.session.items.filter {
            $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.coveredRecordHeader)
        }
    }

    /// Long text with no surrounding whitespace (rendering trims each field).
    private static let longContextBody = String(
        repeating: "Every tenant stays online during the migration, and rollback must finish within five minutes. ",
        count: 30
    ) + "End of constraints."

    /// A question with long context, per-question context, described options, and constraints.
    private func makeDetailedInteraction(marker: String) -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            title: "Release plan \(marker)",
            context: "Context \(marker): " + Self.longContextBody,
            timeoutSeconds: 60,
            questions: [
                AgentAskUserQuestion(
                    id: "strategy",
                    header: "Strategy \(marker)",
                    question: "Which rollout strategies should the child combine for \(marker)?",
                    context: "Question context \(marker): " + Self.longContextBody,
                    options: [
                        AgentAskUserOption(
                            label: "Canary \(marker)",
                            description: "Ship to one percent first \(marker). " + Self.longContextBody
                        ),
                        AgentAskUserOption(label: "Blue-green \(marker)")
                    ],
                    allowsMultiple: true,
                    allowsCustom: false
                ),
                AgentAskUserQuestion(id: "notes", question: "Any other constraints for \(marker)?")
            ]
        )
    }

    private func expectedQuestionFragments(child: LiveSession, interaction: AgentAskUserInteraction) -> [String] {
        var fragments = [
            child.sessionID.uuidString,
            interaction.id.uuidString,
            "Title: \(interaction.title ?? "")",
            "Context: \(interaction.context ?? "")"
        ]
        for (index, question) in interaction.questions.enumerated() {
            let header = question.header.map { "\($0): " } ?? ""
            fragments.append("\(index + 1). [id `\(question.id)`] \(header)\(question.question)")
            if let context = question.context {
                fragments.append("   Context: \(context)")
            }
            for option in question.options {
                fragments.append(option.description.map { "   - \(option.label) — \($0)" } ?? "   - \(option.label)")
            }
        }
        fragments.append("   Selection: choose any number of options; custom answer not allowed")
        fragments.append("   Selection: free-form answer; custom answer allowed")
        return fragments
    }

    /// One `agent_run` snapshot of a child waiting on its `ask_user` question.
    private func agentRunQuestionSnapshot(child: LiveSession, interaction: AgentAskUserInteraction) -> Value {
        .object([
            "session_id": .string(child.sessionID.uuidString),
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string(interaction.id.uuidString),
                "kind": .string("question"),
                "prompt": .string(interaction.title ?? ""),
                "context": .string(interaction.context ?? ""),
                "questions": .array(interaction.questions.map { question in
                    .object([
                        "id": .string(question.id),
                        "question": .string(question.question),
                        "context": .string(question.context ?? ""),
                        "allows_multiple": .bool(question.allowsMultiple),
                        "allows_custom": .bool(question.allowsCustom),
                        "options": .array(question.options.map { option in
                            .object([
                                "label": .string(option.label),
                                "description": .string(option.description ?? "")
                            ])
                        })
                    ])
                })
            ])
        ])
    }

    /// Production final-handoff path for one `agent_run` result: completion observers record the
    /// unannotated result, then the delivery transaction settles the reservation.
    private func deliverAgentRunResult(
        _ value: Value,
        vm: AgentModeViewModel,
        parent: LiveSession,
        runID: UUID
    ) async throws -> Value {
        let coveredKeys = AgentRunMCPToolService.coveredDelegatedQuestionNoticeKeys(in: value)
        XCTAssertFalse(coveredKeys.isEmpty)
        let target = try XCTUnwrap(vm.mcpDelegatedQuestionDeliveryTarget(parentRunID: runID))
        let reservation = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: coveredKeys))
        XCTAssertTrue(reservation.payloads.isEmpty, "Covered questions are reserved without an attached payload")
        let attached = AgentDelegatedQuestionNoticeWire.attaching(reservation.payloads, to: value) ?? value
        let delivery = MCPToolResultDeliveryTransaction()
        MCPServerViewModel.registerDelegatedQuestionNoticeParticipant(
            on: delivery,
            viewModel: vm,
            reservationID: reservation.id,
            attachedKeys: reservation.attachedKeys
        )
        let resultJSON = try XCTUnwrap(String(data: JSONEncoder().encode(delivery.unannotated(attached)), encoding: .utf8))
        parent.session.appendItem(.toolResult(
            name: MCPWindowToolName.agentRun,
            resultJSON: resultJSON,
            sequenceIndex: parent.session.nextSequenceIndex
        ))
        return await delivery.settle(attached, handOff: true)
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeViewModelDelegatedQuestionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Delegated Question Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }

    /// Starts an active parent run attempt under `runID` (the delivery destination identity).
    @discardableResult
    private func startParentRun(_ parent: LiveSession, runID: UUID = UUID()) -> UUID {
        parent.session.runID = runID
        parent.session.runState = .running
        parent.session.beginRunAttempt(source: "test")
        return runID
    }

    private func makeSession(
        _ vm: AgentModeViewModel,
        parent: UUID?,
        sessionID: UUID = UUID(),
        controlled: Bool = true,
        originatingConnectionID: UUID? = nil,
        forceControlContext: Bool = false
    ) -> LiveSession {
        let tabID = UUID()
        let session = vm.session(for: tabID, createIfNeeded: true)!
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parent
        session.hasLoadedPersistedState = true
        if controlled, parent != nil || originatingConnectionID != nil || forceControlContext {
            session.mcpControlContext = AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: originatingConnectionID,
                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: originatingConnectionID),
                suppressUserNotifications: true,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: false,
                taskLabelKind: .engineer
            )
        }
        return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
    }

    private func makeInteraction(timeoutSeconds: TimeInterval) -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            timeoutSeconds: timeoutSeconds,
            questions: [
                AgentAskUserQuestion(
                    id: "choice",
                    question: "Which option?",
                    options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
                    allowsCustom: true
                )
            ]
        )
    }

    private func parentAnswer(_ text: String) -> AgentModeViewModel.MCPInteractionResponsePayload {
        AgentModeViewModel.MCPInteractionResponsePayload(
            text: text,
            skip: false,
            decisionRaw: nil,
            amendment: nil,
            answersByQuestionID: [:]
        )
    }

    private func assertReleased(
        _ vm: AgentModeViewModel,
        key: AgentDelegatedQuestionNoticeKey,
        parentTabID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(vm.delegatedQuestionTurnStageID(forTabID: parentTabID), file: file, line: line)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID, file: file, line: line)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, file: file, line: line)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Holds a delivery transaction's settlement after the handler sampled `handOff`, so a test can
/// cancel the handler between the settlement request and a later participant's commit step.
private actor DelegatedQuestionSettlementGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var heldHandOff: Bool?

    func hold(handOff: Bool) async {
        heldHandOff = handOff
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if heldHandOff != nil { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return heldHandOff != nil
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
