import Foundation
import MCP

// SEARCH-HELPER: Claude, ToolTracking, ToolCorrelation, TrackerLifecycle, ProviderToolStream
/// Dedicated tool-tracking handler for Claude agent sessions.
///
/// Owns:
/// - Shared `AgentToolTrackingController` lifecycle management
/// - Dual-source provider/tracker tool correlation (the hardest provider-specific logic)
/// - Turn-scoped correlation state reset between Claude turns
/// - Provider-stream RepoPrompt tool call/result handling (slot reservation + enrichment)
/// - MCP tracker callback → transcript item mutation for RepoPrompt tools
///
/// Related:
/// - ClaudeAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Claude/ClaudeAgentModeCoordinator.swift
/// - AgentToolTrackingController: /RepoPrompt/Services/AI/Agents/AgentToolTracker.swift
/// - AgentToolTrackingContracts: /RepoPrompt/Services/AgentMode/ToolTracking/AgentToolTrackingContracts.swift
@MainActor
final class ClaudeAgentToolTrackingHandler {
    struct ExplicitProviderToolResultAckObservation: Equatable {
        let timestamp: Date
        let runID: UUID?
        let toolName: String
        let invocationID: UUID?
        let counted: Bool
        let reason: String
        let ackCountAfterEvent: Int
    }

    struct ExplicitProviderToolResultAckSnapshot: Equatable {
        let requestedRunID: UUID
        let trackedRunID: UUID?
        let ackCount: Int
        let ackedInvocationCount: Int
        let recentObservations: [ExplicitProviderToolResultAckObservation]
    }

    private struct AckWaiter {
        let runID: UUID
        let minimumAckCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    // MARK: - Tracker State

    private let trackingController: AgentToolTrackingController
    private let maxExplicitProviderAckObservationCount = 24

    // MARK: - Correlation State (moved from TabSession)

    private enum ToolEventSource {
        case provider
        case tracker
    }

    /// Source-aware identity of one transcript row, keyed by its stable `AgentChatItem.id` and never persisted.
    /// Provider and tracker invocation IDs are assigned independently, so provenance comes from the event path
    /// that bound the row, never from the shape or presence of the row's displayed `toolInvocationID`.
    private struct InvocationBinding {
        /// Last `toolInvocationID` written or observed on the row; the constant-work index lookup key.
        var rowInvocationID: UUID?
        /// A provider `tool_call` was associated with the row, including provider calls without an ID.
        var providerObserved = false
        var providerInvocationID: UUID?
        var trackerInvocationID: UUID?
        /// The tracker delivered the row's completion; its payload is authoritative and not replaced.
        var trackerCompleted = false
    }

    /// One-to-one bindings for rows in the session's active turn. Aliases survive completion so duplicate
    /// callbacks resolve to their original exchange instead of claiming a later same-signature invocation.
    private var invocationBindingsByItemID: [UUID: InvocationBinding] = [:]
    private var itemIDByProviderInvocationID: [UUID: UUID] = [:]
    private var itemIDByTrackerInvocationID: [UUID: UUID] = [:]
    /// Sequence boundary for new associations with completed rows within the active Claude turn.
    private var toolCorrelationStartSequenceIndex: Int = 0
    /// Tracker invocations whose pending rows an empty error completion removed. Duplicate callbacks for them are
    /// ignored instead of creating a row or claiming a later same-signature call. Scoped to the tracked run and capped.
    private var removedTrackerInvocationIDs: [UUID] = []
    private let maxRemovedTrackerInvocationCount = 64
    /// Currently tracked Claude run for explicit provider `tool_result` acknowledgements.
    private var trackedRunID: UUID?
    var currentTrackedRunID: UUID? {
        trackedRunID
    }

    /// Dedup set of explicit provider `tool_result` invocation IDs acknowledged for the tracked run.
    private var explicitProviderToolResultAckedInvocationIDs: Set<UUID> = []
    /// Monotonic count of deduped explicit provider `tool_result` acknowledgements for the tracked run.
    private var explicitProviderToolResultAckCount: Int = 0
    /// Continuation-based waiters parked until the tracked run reaches a minimum explicit provider ACK count.
    private var ackWaitersByID: [UUID: AckWaiter] = [:]
    /// Bounded ring buffer of recent explicit provider ACK observations for diagnostics.
    private var explicitProviderToolResultAckObservations: [ExplicitProviderToolResultAckObservation] = []

    var hooks: AgentToolTrackingHooks

    init(mcpHost: any AgentMCPHosting, hooks: AgentToolTrackingHooks = .noOp) {
        trackingController = AgentToolTrackingController(mcpHost: mcpHost)
        self.hooks = hooks
    }

    private func diagnosticLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            print("[ClaudeToolTracking] \(message())")
        #endif
    }

    private static func diagnosticID(_ id: UUID?) -> String {
        id?.uuidString ?? "nil"
    }

    private static func diagnosticSignature(_ signature: String) -> String {
        guard !signature.isEmpty else { return "empty" }
        let hash = signature.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return "hash=\(String(format: "%016llx", hash)) chars=\(signature.count)"
    }

    // MARK: - Tracking Lifecycle

    func startTracking(
        runID: UUID,
        session: AgentTabSession,
        clientNameHint: String?
    ) async {
        if trackedRunID != runID {
            beginTrackingExplicitProviderToolResultAcks(for: runID)
            removedTrackerInvocationIDs.removeAll()
        }
        await trackingController.startTracking(
            runID: runID,
            clientNameHint: clientNameHint,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleTrackerToolCall(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    session: session
                )
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleTrackerToolResult(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError,
                    session: session
                )
            }
        )
    }

    func stopTracking(
        for session: AgentTabSession
    ) async {
        await trackingController.stopTracking()
        resetCorrelationState(session)
        removedTrackerInvocationIDs.removeAll()
        stopTrackingExplicitProviderToolResultAcks()
    }

    func resetTurnState(
        for session: AgentTabSession
    ) {
        resetCorrelationState(session)
    }

    // MARK: - Provider Stream Event Handling

    @discardableResult
    func handleProviderToolEvent(
        _ event: AgentToolStreamEvent,
        session: AgentTabSession
    ) -> Bool {
        switch event {
        case let .toolCall(call):
            handleProviderToolCall(call, session: session)
        case let .toolResult(result):
            handleProviderToolResult(result, session: session)
        case .legacyEvent:
            // Claude doesn't use legacy "Using tool:" events; not consumed.
            false
        }
    }

    // MARK: - Provider-Stream Tool Call Handling

    /// Handles `tool_call` events from the Claude provider stream.
    /// Returns `true` when the event was consumed (either processed or suppressed).
    private func handleProviderToolCall(
        _ call: AgentToolStreamEvent.ToolCall,
        session: AgentTabSession
    ) -> Bool {
        let toolName = call.toolName

        // Suppress orphan placeholder tool names.
        if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
           let invocationID = call.invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }

        // Explicit RepoPrompt tools: handle as provider-sourced slot reservation.
        if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
        {
            hooks.addToolInputTokens(call.argsJSON, session)
            handleClaudeProviderRepoPromptToolCall(
                invocationID: call.invocationID,
                toolName: toolName,
                argsJSON: call.argsJSON,
                session: session
            )
            return true
        }

        // Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
        if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
            toolName: toolName,
            invocationID: call.invocationID
        ) {
            return true
        }

        return false
    }

    /// Handles `tool_result` events from the Claude provider stream.
    /// Returns `true` when the event was consumed (either processed or suppressed).
    private func handleProviderToolResult(
        _ result: AgentToolStreamEvent.ToolResult,
        session: AgentTabSession
    ) -> Bool {
        let toolName = result.toolName
        let outputJSON = result.resultJSON

        recordExplicitProviderToolResultAckIfNeeded(
            toolName: toolName,
            invocationID: result.invocationID
        )

        // Claude Code emits `<tool_use_error>Error: No such tool available: …</tool_use_error>`
        // when the model invokes a tool the CLI doesn't know (e.g. a bare `mcp__RepoPrompt`
        // server prefix with no trailing tool segment). Drop both this error row and the
        // paired placeholder tool_call so the transcript stays clean.
        // See: ClaudeInvalidToolErrorFilter.swift
        if ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
            resultText: outputJSON,
            isError: result.isError
        ) {
            retractInvalidToolPlaceholder(
                toolName: toolName,
                invocationID: result.invocationID,
                session: session
            )
            hooks.requestUIRefresh(session.tabID, false)
            return true
        }

        // Suppress orphan placeholder tool results.
        if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
           let invocationID = result.invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }

        // Explicit RepoPrompt tool results are consumed from the provider stream. When Claude
        // supplies a provider invocation ID that exactly matches a provider-created slot,
        // terminalize that slot in place so the UI does not stay pending while waiting for
        // the MCP tracker completion. Do not fall back by nil ID, name, or signature here.
        if shouldSuppressClaudeProviderToolResult(
            toolName: toolName,
            argsJSON: result.argsJSON,
            outputJSON: outputJSON,
            isError: result.isError,
            invocationID: result.invocationID,
            session: session
        ) {
            if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
               !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
            {
                hooks.addToolOutputTokens(outputJSON, session)
            }
            return true
        }

        // Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
        if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
            toolName: toolName,
            invocationID: result.invocationID
        ) {
            return true
        }

        return false
    }

    /// Remove the placeholder tool_call row paired with a Claude `tool_use_error` that
    /// reported an unknown tool. The tool_call was already appended when the provider
    /// emitted `tool_use`, so this drops it retroactively using the invocation id
    /// (or tool-name fallback) to find the matching row. Both lookups are scoped to
    /// the current correlation turn so an invalid call in this turn cannot retract a
    /// legitimate placeholder left over from a prior turn.
    private func retractInvalidToolPlaceholder(
        toolName: String,
        invocationID: UUID?,
        session: AgentTabSession
    ) {
        let turnStart = toolCorrelationStartSequenceIndex
        func isEligible(_ item: AgentChatItem) -> Bool {
            item.kind == .toolCall && item.sequenceIndex >= turnStart && item.codeModeParentInvocationID == nil
        }
        let placeholderIndex: Int? = {
            if let invocationID {
                let indexed = session.indexedToolItemIndices(invocationID: invocationID)
                if let byInvocation = indexed.last(where: { isEligible(session.items[$0]) }) {
                    return byInvocation
                }
                let fallback = session.activeTurnToolItemIndices(where: {
                    isEligible($0) && $0.toolInvocationID == invocationID
                })
                if let byInvocation = fallback.lastIndex {
                    return byInvocation
                }
            }
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
            let indexed = session.indexedNilInvocationToolItemIndices(
                normalizedToolName: normalizedToolName
            )
            if let byName = indexed.last(where: { index in
                let item = session.items[index]
                return isEligible(item) && item.toolName == toolName
            }) {
                return byName
            }
            return session.activeTurnToolItemIndices(where: { item in
                isEligible(item)
                    && item.toolName == toolName
                    && item.toolInvocationID == nil
            }).lastIndex
        }()
        guard let placeholderIndex else { return }
        let removedItemID = session.items[placeholderIndex].id
        session.removeItem(at: placeholderIndex)
        forgetBinding(itemID: removedItemID)
    }

    // MARK: - Explicit Provider ACK Waiting (Steering Safety)

    func awaitExplicitProviderToolResultAcks(
        for runID: UUID,
        atLeast minimumAckCount: Int
    ) async throws {
        guard minimumAckCount > 0 else { return }
        if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
            return
        }

        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
                    continuation.resume()
                    return
                }
                ackWaitersByID[waiterID] = AckWaiter(
                    runID: runID,
                    minimumAckCount: minimumAckCount,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let waiter = ackWaitersByID.removeValue(forKey: waiterID) {
                    waiter.continuation.resume()
                }
            }
        }

        try Task.checkCancellation()
    }

    func explicitProviderToolResultAckSnapshot(
        for runID: UUID
    ) -> ExplicitProviderToolResultAckSnapshot {
        let isTrackedRun = trackedRunID == runID
        return ExplicitProviderToolResultAckSnapshot(
            requestedRunID: runID,
            trackedRunID: trackedRunID,
            ackCount: isTrackedRun ? explicitProviderToolResultAckCount : 0,
            ackedInvocationCount: isTrackedRun ? explicitProviderToolResultAckedInvocationIDs.count : 0,
            recentObservations: isTrackedRun ? explicitProviderToolResultAckObservations : []
        )
    }

    // MARK: - Provider-Sourced RepoPrompt Tool Handling (Correlation)

    func handleClaudeProviderRepoPromptToolCall(
        invocationID: UUID?,
        toolName: String,
        argsJSON: String?,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }

        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        // Same provider invocation (duplicate or late event): enrich its own row only.
        if let index = establishedItemIndex(
            source: .provider,
            invocationID: invocationID,
            toolName: toolName,
            session: session
        ).index {
            enrichFromProviderCall(
                at: index,
                invocationID: invocationID,
                storedToolName: storedToolName,
                argsJSON: argsJSON,
                session: session
            )
            return
        }

        // A tracker-observed invocation awaiting its provider call. A completed tracker row is eligible only
        // as a unique last resort: the provider stream orders each call before later calls, so an unpaired
        // completed tracker row's own provider call has not been delivered yet. Adoption never rewrites it.
        let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
        if let index = uniqueUnclaimedCandidate(
            for: .provider,
            signature: signature,
            session: session
        ).index {
            bind(.provider, invocationID: invocationID, to: session.items[index])
            enrichFromProviderCall(
                at: index,
                invocationID: invocationID,
                storedToolName: storedToolName,
                argsJSON: argsJSON,
                session: session
            )
            return
        }

        let toolItem = AgentChatItem.toolCall(
            name: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(toolItem)
        bind(.provider, invocationID: invocationID, to: toolItem)
    }

    private func enrichFromProviderCall(
        at index: Int,
        invocationID: UUID?,
        storedToolName: String,
        argsJSON: String?,
        session: AgentTabSession
    ) {
        let current = session.items[index]
        var updated = current
        if let invocationID, updated.kind == .toolCall || updated.toolInvocationID == nil {
            // The provider ID owns a pending slot so an exact provider tool_result can terminalize it.
            updated.toolInvocationID = invocationID
        }
        updated.toolName = storedToolName
        // Tracker arguments take precedence; provider arguments fill gaps or refresh a provider-only pending call.
        let trackerBound = invocationBindingsByItemID[current.id]?.trackerInvocationID != nil
        if Self.hasContent(argsJSON),
           !Self.hasContent(updated.toolArgsJSON) || (updated.kind == .toolCall && !trackerBound)
        {
            updated.toolArgsJSON = argsJSON
        }
        replaceBoundItem(at: index, current: current, updated: updated, session: session)
    }

    func shouldSuppressClaudeProviderToolResult(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        isError: Bool? = nil,
        invocationID: UUID?,
        session: AgentTabSession
    ) -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
        if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName)
        {
            let terminalizedExactProviderSlot = terminalizeExplicitProviderToolResultIfExactProviderSlot(
                toolName: toolName,
                argsJSON: argsJSON,
                outputJSON: outputJSON,
                isError: isError,
                invocationID: invocationID,
                session: session
            )
            let matchingProviderItemCount = invocationID.map { providerInvocationID in
                session.indexedToolItemIndices(invocationID: providerInvocationID).count
            } ?? 0
            diagnosticLog(
                "suppressing explicit RepoPrompt provider tool_result tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) providerInvocation=\(Self.diagnosticID(invocationID)) " +
                    "matchingItems=\(matchingProviderItemCount) exactProviderSlotTerminalized=\(terminalizedExactProviderSlot) " +
                    "bindings=\(invocationBindingsByItemID.count)"
            )
            return true
        }
        if !AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
           AgentToolTrackingSupport.isRepoPromptTool(toolName),
           outputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           argsJSON == nil,
           let invocationID,
           session.indexedToolItemIndices(invocationID: invocationID).isEmpty
        {
            return true
        }
        return false
    }

    private func terminalizeExplicitProviderToolResultIfExactProviderSlot(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        isError: Bool?,
        invocationID: UUID?,
        session: AgentTabSession
    ) -> Bool {
        guard let providerInvocationID = invocationID else { return false }
        let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
        let indexedCandidates = session.indexedToolItemIndices(invocationID: providerInvocationID)
        let indexedMatch = indexedCandidates.last(where: { index in
            let item = session.items[index]
            return item.kind == .toolCall
                && MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
        })
        let fallbackMatch = indexedMatch == nil
            ? session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && item.toolInvocationID == providerInvocationID
                    && MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
            }).lastIndex
            : nil
        guard let index = indexedMatch ?? fallbackMatch else { return false }

        let current = session.items[index]
        var updated = current
        updated.kind = .toolResult
        updated.toolName = Self.canonicalTranscriptToolName(toolName)
        updated.toolResultJSON = outputJSON
        if !Self.hasContent(updated.toolArgsJSON) {
            updated.toolArgsJSON = argsJSON
        }
        updated.toolIsError = isError
        updated.text = outputJSON
        replaceBoundItem(at: index, current: current, updated: updated, session: session)
        hooks.requestUIRefresh(session.tabID, false)
        return true
    }

    // MARK: - Tracker Callbacks (MCP observer)

    func handleTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        guard !ignoresRemovedTrackerInvocation(invocationID, toolName: toolName) else { return }
        // Flush buffered assistant content before inserting tool card to preserve interleaving order.
        hooks.flushPendingAssistantDelta(session)
        hooks.endActiveAssistantSegment(session)
        hooks.endActiveReasoningSegment(session)
        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        if let linkage = AgentToolEventLinkage.current {
            appendCodeModeChildToolCall(
                invocationID: invocationID,
                storedToolName: storedToolName,
                argsJSON: argsJSON,
                linkage: linkage,
                session: session
            )
            return
        }

        // Same tracker invocation (duplicate callback): enrich its own row only.
        let established = establishedItemIndex(
            source: .tracker,
            invocationID: invocationID,
            toolName: toolName,
            session: session
        )
        var inspectedItemCount = established.inspectedItemCount
        if let index = established.index {
            let current = session.items[index]
            var updated = current
            updated.toolName = storedToolName
            if Self.hasContent(argsJSON), updated.kind == .toolCall || !Self.hasContent(updated.toolArgsJSON) {
                updated.toolArgsJSON = argsJSON
            }
            replaceBoundItem(at: index, current: current, updated: updated, session: session)
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: "invocation_id",
                scannedItemCount: inspectedItemCount
            )
            return
        }

        // A unique pending provider call with this signature that no tracker invocation has claimed.
        let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
        let candidate = uniqueUnclaimedCandidate(for: .tracker, signature: signature, session: session)
        inspectedItemCount += candidate.inspectedItemCount
        if let index = candidate.index {
            diagnosticLog(
                "tracker call bound unclaimed provider call tab=\(session.tabID.uuidString) " +
                    "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                    "row=\(Self.diagnosticID(session.items[index].toolInvocationID)) signature=\(Self.diagnosticSignature(signature))"
            )
            let current = session.items[index]
            bind(.tracker, invocationID: invocationID, to: current)
            var updated = current
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if updated.toolInvocationID == nil {
                updated.toolInvocationID = invocationID
            }
            replaceBoundItem(at: index, current: current, updated: updated, session: session)
            hooks.requestUIRefresh(session.tabID, false)
            MCPToolObserverAttributionContext.record(
                correlationPath: "signature",
                scannedItemCount: inspectedItemCount
            )
            return
        }

        let toolItem = AgentChatItem.toolCall(
            name: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(toolItem)
        bind(.tracker, invocationID: invocationID, to: toolItem)
        hooks.requestUIRefresh(session.tabID, false)
        MCPToolObserverAttributionContext.record(
            correlationPath: "new_item",
            scannedItemCount: inspectedItemCount
        )
    }

    func handleTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        guard !ignoresRemovedTrackerInvocation(invocationID, toolName: toolName) else { return }
        // Flush buffered assistant content before inserting tool result to preserve interleaving order.
        hooks.flushPendingAssistantDelta(session)
        hooks.endActiveAssistantSegment(session)
        hooks.endActiveReasoningSegment(session)
        let storedToolName = Self.canonicalTranscriptToolName(toolName)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        if let linkage = AgentToolEventLinkage.current {
            finalizeCodeModeChildToolResult(
                invocationID: invocationID,
                storedToolName: storedToolName,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                linkage: linkage,
                session: session
            )
            return
        }

        // Established tracker identity first (aliases survive completion), then a unique unclaimed pending
        // provider call. Completed rows are never claimed by signature, and missing arguments never match by name.
        var correlationPath = "none"
        let established = establishedItemIndex(
            source: .tracker,
            invocationID: invocationID,
            toolName: toolName,
            session: session
        )
        var inspectedItemCount = established.inspectedItemCount
        var targetIndex = established.index
        if targetIndex != nil {
            correlationPath = "invocation_id"
        } else {
            let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
            let candidate = uniqueUnclaimedCandidate(for: .tracker, signature: signature, session: session)
            inspectedItemCount += candidate.inspectedItemCount
            if let index = candidate.index {
                diagnosticLog(
                    "tracker result bound unclaimed provider call tab=\(session.tabID.uuidString) " +
                        "tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
                        "row=\(Self.diagnosticID(session.items[index].toolInvocationID)) signature=\(Self.diagnosticSignature(signature))"
                )
                bind(.tracker, invocationID: invocationID, to: session.items[index])
                targetIndex = index
                correlationPath = "signature"
            }
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: correlationPath,
            scannedItemCount: inspectedItemCount
        )

        let trimmedResult = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if isError, trimmedResult.isEmpty {
            if let index = targetIndex, session.items[index].kind == .toolCall {
                let removedItemID = session.items[index].id
                session.removeItem(at: index)
                forgetBinding(itemID: removedItemID)
                rememberRemovedTrackerInvocation(invocationID)
                hooks.requestUIRefresh(session.tabID, false)
            }
            return
        }

        if let index = targetIndex {
            let current = session.items[index]
            var updated = current
            if current.kind == .toolResult,
               invocationBindingsByItemID[current.id]?.trackerCompleted == true
            {
                // Duplicate completion of an exchange the tracker already finalized: keep the accepted
                // payload and only fill arguments that are still missing.
                if !Self.hasContent(updated.toolArgsJSON), Self.hasContent(argsJSON) {
                    updated.toolArgsJSON = argsJSON
                }
            } else {
                updated.toolName = storedToolName
                updated.kind = .toolResult
                updated.toolResultJSON = resultJSON
                updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                updated.toolIsError = isError
                updated.text = resultJSON
                if updated.toolInvocationID == nil {
                    updated.toolInvocationID = invocationID
                }
            }
            replaceBoundItem(at: index, current: current, updated: updated, session: session)
            invocationBindingsByItemID[current.id]?.trackerCompleted = true
        } else {
            let toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolResultItem)
            bind(.tracker, invocationID: invocationID, to: toolResultItem)
            invocationBindingsByItemID[toolResultItem.id]?.trackerCompleted = true
        }
        hooks.requestUIRefresh(session.tabID, false)
    }

    // MARK: - code_mode Child Cards (plan §6 D3)

    /// The parent card's transcript invocation: the displayed invocation of the row the parent's tracker
    /// invocation is bound to (the provider-stream ID once a provider call owns that row), else the tracker
    /// invocation itself.
    private func transcriptParentInvocationID(for linkage: AgentToolEventLinkage) -> UUID {
        let trackerInvocationID = linkage.codeModeParentInvocationID
        guard let itemID = itemIDByTrackerInvocationID[trackerInvocationID],
              let rowInvocationID = invocationBindingsByItemID[itemID]?.rowInvocationID
        else {
            return trackerInvocationID
        }
        return rowInvocationID
    }

    /// A child is never correlated with provider-stream slots (the provider never sees it) and never
    /// bound: it always gets its own flat canonical card, keyed by its own tracker invocation, and an
    /// unbound row is never claimed by another invocation's signature or identity.
    private func appendCodeModeChildToolCall(
        invocationID: UUID,
        storedToolName: String,
        argsJSON: String?,
        linkage: AgentToolEventLinkage,
        session: AgentTabSession
    ) {
        var toolItem = AgentChatItem.toolCall(
            name: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        toolItem.codeModeParentInvocationID = transcriptParentInvocationID(for: linkage)
        session.appendItem(toolItem)
        hooks.requestUIRefresh(session.tabID, false)
        MCPToolObserverAttributionContext.record(correlationPath: "code_mode_child", scannedItemCount: 0)
    }

    /// Finalizes a child card by its exact invocation ID only; no signature or name fallback.
    private func finalizeCodeModeChildToolResult(
        invocationID: UUID,
        storedToolName: String,
        argsJSON: String?,
        resultJSON: String,
        isError: Bool,
        linkage: AgentToolEventLinkage,
        session: AgentTabSession
    ) {
        let parentInvocationID = transcriptParentInvocationID(for: linkage)
        let isChildCard: (AgentChatItem) -> Bool = { item in
            item.toolInvocationID == invocationID && item.codeModeParentInvocationID != nil
        }
        let indexed = session.indexedToolItemIndices(invocationID: invocationID)
        let targetIndex = indexed.last(where: { isChildCard(session.items[$0]) })
            ?? session.activeTurnToolItemIndices(where: isChildCard).lastIndex
        MCPToolObserverAttributionContext.record(correlationPath: "code_mode_child", scannedItemCount: indexed.count)

        if isError, resultJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let targetIndex, session.items[targetIndex].kind == .toolCall {
                session.removeItem(at: targetIndex)
                hooks.requestUIRefresh(session.tabID, false)
            }
            return
        }

        if let targetIndex {
            var updated = session.items[targetIndex]
            updated.toolName = storedToolName
            updated.kind = .toolResult
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
            updated.codeModeParentInvocationID = parentInvocationID
            session.replaceItem(at: targetIndex, with: updated)
        } else {
            var toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            toolResultItem.codeModeParentInvocationID = parentInvocationID
            session.appendItem(toolResultItem)
        }
        hooks.requestUIRefresh(session.tabID, false)
    }

    /// A bound parent row whose displayed invocation changed (a provider call claimed a tracker-created
    /// `code_mode` row) carries its active-turn children along, so persisted linkage names the final card.
    private func relinkCodeModeChildren(from oldInvocationID: UUID, to newInvocationID: UUID, session: AgentTabSession) {
        let children = session.activeTurnToolItemIndices(where: {
            $0.codeModeParentInvocationID == oldInvocationID
        }).indices
        for index in children {
            var updated = session.items[index]
            updated.codeModeParentInvocationID = newInvocationID
            session.replaceItem(at: index, with: updated)
        }
    }

    // MARK: - Correlation Helpers

    /// Advances the fence for new completed-row associations and drops bindings whose rows left the session's
    /// active turn. Bindings for rows still in the active turn survive: Claude native dispatch, including a
    /// steering send while a question waits, resets turn state while tool invocations are still in flight.
    private func resetCorrelationState(_ session: AgentTabSession) {
        let previousBindingCount = invocationBindingsByItemID.count
        for itemID in Array(invocationBindingsByItemID.keys)
            where liveIndex(ofItemID: itemID, session: session).index == nil
        {
            forgetBinding(itemID: itemID)
        }
        if previousBindingCount > 0 {
            diagnosticLog(
                "reset Claude tool correlation turn tab=\(session.tabID.uuidString) " +
                    "bindings=\(previousBindingCount) retainedActiveTurnBindings=\(invocationBindingsByItemID.count) " +
                    "nextSequenceIndex=\(session.nextSequenceIndex)"
            )
        }
        toolCorrelationStartSequenceIndex = session.nextSequenceIndex
    }

    /// Resolves a bound row by stable item identity: constant work through the invocation index, with an
    /// active-turn scan only when the row's invocation ID changed outside this handler.
    private func liveIndex(
        ofItemID itemID: UUID,
        session: AgentTabSession
    ) -> (index: Int?, inspectedItemCount: Int) {
        guard let binding = invocationBindingsByItemID[itemID] else { return (nil, 0) }
        var inspectedItemCount = 0
        if let rowInvocationID = binding.rowInvocationID {
            let indexed = session.indexedToolItemIndices(invocationID: rowInvocationID)
            inspectedItemCount += indexed.count
            if let index = indexed.last(where: { session.items[$0].id == itemID }) {
                return (index, inspectedItemCount)
            }
        }
        let scan = session.activeTurnToolItemIndices(where: { $0.id == itemID })
        return (scan.lastIndex, inspectedItemCount + scan.scannedItemCount)
    }

    /// Established identity for an incoming source invocation: its retained alias, else an exact transcript
    /// invocation ID on a row that no other invocation from the same source has claimed.
    private func establishedItemIndex(
        source: ToolEventSource,
        invocationID: UUID?,
        toolName: String,
        session: AgentTabSession
    ) -> (index: Int?, inspectedItemCount: Int) {
        guard let invocationID else { return (nil, 0) }
        var inspectedItemCount = 0
        let aliasedItemID = switch source {
        case .provider: itemIDByProviderInvocationID[invocationID]
        case .tracker: itemIDByTrackerInvocationID[invocationID]
        }
        if let aliasedItemID {
            let live = liveIndex(ofItemID: aliasedItemID, session: session)
            inspectedItemCount += live.inspectedItemCount
            if let index = live.index {
                return (index, inspectedItemCount)
            }
            forgetBinding(itemID: aliasedItemID)
        }

        let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(toolName)
        let indexed = session.indexedToolItemIndices(invocationID: invocationID)
        inspectedItemCount += indexed.count
        let exactIndex = indexed.last { index in
            let item = session.items[index]
            // `code_mode` children stay outside ordinary correlation (plan §6 D3).
            guard item.codeModeParentInvocationID == nil,
                  AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
            else {
                return false
            }
            guard let binding = invocationBindingsByItemID[item.id] else { return true }
            switch source {
            case .provider:
                return !binding.providerObserved
            case .tracker:
                return binding.trackerInvocationID == nil
            }
        }
        guard let exactIndex else { return (nil, inspectedItemCount) }
        bind(source, invocationID: invocationID, to: session.items[exactIndex])
        return (exactIndex, inspectedItemCount)
    }

    /// Signature association is a heuristic limited to exactly one opposite-source row that no invocation from
    /// the incoming source has claimed. Completed unclaimed rows compete with pending ones: a delayed event may
    /// belong to an exchange that already finished from the other source, so any ambiguity keeps observations
    /// separate rather than guessing. Only a provider call may adopt the single completed candidate (see
    /// `handleClaudeProviderRepoPromptToolCall`); that row must have arguments, a tracker completion, and sit after
    /// the turn-reset fence.
    private func uniqueUnclaimedCandidate(
        for source: ToolEventSource,
        signature: String,
        session: AgentTabSession
    ) -> (index: Int?, inspectedItemCount: Int) {
        func isUnclaimed(_ item: AgentChatItem) -> Bool {
            // Unbound rows have unknown provenance and are never claimed by signature.
            guard let binding = invocationBindingsByItemID[item.id] else { return false }
            switch source {
            case .provider:
                return binding.trackerInvocationID != nil && !binding.providerObserved
            case .tracker:
                return binding.providerObserved && binding.trackerInvocationID == nil
            }
        }

        let pending = session.indexedToolItemIndices(signature: signature, pendingCallsOnly: true)
        let all = session.indexedToolItemIndices(signature: signature)
        let inspectedItemCount = pending.count + all.count
        let pendingMatches = pending.filter { isUnclaimed(session.items[$0]) }
        let completedMatches = all.filter { index in
            session.items[index].kind == .toolResult && isUnclaimed(session.items[index])
        }
        guard pendingMatches.count + completedMatches.count == 1 else {
            if pendingMatches.count + completedMatches.count > 1 {
                diagnosticLog(
                    "ambiguous unclaimed signature matches pending=\(pendingMatches.count) " +
                        "completed=\(completedMatches.count) signature=\(Self.diagnosticSignature(signature)); " +
                        "keeping observations separate"
                )
            }
            return (nil, inspectedItemCount)
        }
        if let index = pendingMatches.first {
            return (index, inspectedItemCount)
        }
        guard source == .provider, let index = completedMatches.first else { return (nil, inspectedItemCount) }
        let item = session.items[index]
        guard item.sequenceIndex >= toolCorrelationStartSequenceIndex,
              Self.hasContent(item.toolArgsJSON),
              invocationBindingsByItemID[item.id]?.trackerCompleted == true
        else { return (nil, inspectedItemCount) }
        return (index, inspectedItemCount)
    }

    private func ignoresRemovedTrackerInvocation(_ invocationID: UUID, toolName: String) -> Bool {
        guard removedTrackerInvocationIDs.contains(invocationID) else { return false }
        diagnosticLog(
            "ignoring duplicate callback for removed tracker invocation tool=\(toolName) " +
                "trackerInvocation=\(invocationID.uuidString)"
        )
        MCPToolObserverAttributionContext.record(correlationPath: "removed_invocation", scannedItemCount: 0)
        return true
    }

    private func rememberRemovedTrackerInvocation(_ invocationID: UUID) {
        guard !removedTrackerInvocationIDs.contains(invocationID) else { return }
        removedTrackerInvocationIDs.append(invocationID)
        if removedTrackerInvocationIDs.count > maxRemovedTrackerInvocationCount {
            removedTrackerInvocationIDs.removeFirst(removedTrackerInvocationIDs.count - maxRemovedTrackerInvocationCount)
        }
    }

    private func bind(_ source: ToolEventSource, invocationID: UUID?, to item: AgentChatItem) {
        var binding = invocationBindingsByItemID[item.id] ?? InvocationBinding(rowInvocationID: item.toolInvocationID)
        switch source {
        case .provider:
            binding.providerObserved = true
            if let invocationID {
                assert(
                    (itemIDByProviderInvocationID[invocationID] ?? item.id) == item.id
                        && (binding.providerInvocationID ?? invocationID) == invocationID,
                    "provider invocation bindings must stay one-to-one"
                )
                binding.providerInvocationID = invocationID
                itemIDByProviderInvocationID[invocationID] = item.id
            }
        case .tracker:
            if let invocationID {
                assert(
                    (itemIDByTrackerInvocationID[invocationID] ?? item.id) == item.id
                        && (binding.trackerInvocationID ?? invocationID) == invocationID,
                    "tracker invocation bindings must stay one-to-one"
                )
                binding.trackerInvocationID = invocationID
                itemIDByTrackerInvocationID[invocationID] = item.id
            }
        }
        invocationBindingsByItemID[item.id] = binding
    }

    private func replaceBoundItem(
        at index: Int,
        current: AgentChatItem,
        updated: AgentChatItem,
        session: AgentTabSession
    ) {
        guard updated != current else { return }
        session.replaceItem(at: index, with: updated)
        invocationBindingsByItemID[current.id]?.rowInvocationID = updated.toolInvocationID
        if let oldInvocationID = current.toolInvocationID,
           let newInvocationID = updated.toolInvocationID,
           oldInvocationID != newInvocationID,
           MCPIntegrationHelper.normalizedRepoPromptToolName(current.toolName ?? "") == MCPWindowToolName.codeMode
        {
            relinkCodeModeChildren(from: oldInvocationID, to: newInvocationID, session: session)
        }
    }

    private func forgetBinding(itemID: UUID) {
        guard let binding = invocationBindingsByItemID.removeValue(forKey: itemID) else { return }
        if let providerInvocationID = binding.providerInvocationID,
           itemIDByProviderInvocationID[providerInvocationID] == itemID
        {
            itemIDByProviderInvocationID.removeValue(forKey: providerInvocationID)
        }
        if let trackerInvocationID = binding.trackerInvocationID,
           itemIDByTrackerInvocationID[trackerInvocationID] == itemID
        {
            itemIDByTrackerInvocationID.removeValue(forKey: trackerInvocationID)
        }
    }

    private func beginTrackingExplicitProviderToolResultAcks(for runID: UUID) {
        resumeAckWaiters(matching: { $0.runID != runID })
        trackedRunID = runID
        explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
        explicitProviderToolResultAckCount = 0
        explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
        resumeEligibleAckWaiters()
    }

    private func stopTrackingExplicitProviderToolResultAcks() {
        trackedRunID = nil
        explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
        explicitProviderToolResultAckCount = 0
        explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
        resumeAckWaiters(matching: { _ in true })
    }

    private func recordExplicitProviderToolResultAckIfNeeded(
        toolName: String,
        invocationID: UUID?
    ) {
        guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
        guard let invocationID else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: nil,
                counted: false,
                reason: "missing_invocation_id"
            )
            return
        }
        guard trackedRunID != nil else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: invocationID,
                counted: false,
                reason: "no_tracked_run"
            )
            return
        }
        let inserted = explicitProviderToolResultAckedInvocationIDs.insert(invocationID).inserted
        guard inserted else {
            appendExplicitProviderAckObservation(
                toolName: toolName,
                invocationID: invocationID,
                counted: false,
                reason: "duplicate_invocation"
            )
            return
        }

        explicitProviderToolResultAckCount += 1
        appendExplicitProviderAckObservation(
            toolName: toolName,
            invocationID: invocationID,
            counted: true,
            reason: "acked"
        )
        resumeEligibleAckWaiters()
    }

    private func appendExplicitProviderAckObservation(
        toolName: String,
        invocationID: UUID?,
        counted: Bool,
        reason: String
    ) {
        explicitProviderToolResultAckObservations.append(
            ExplicitProviderToolResultAckObservation(
                timestamp: Date(),
                runID: trackedRunID,
                toolName: toolName,
                invocationID: invocationID,
                counted: counted,
                reason: reason,
                ackCountAfterEvent: explicitProviderToolResultAckCount
            )
        )
        if explicitProviderToolResultAckObservations.count > maxExplicitProviderAckObservationCount {
            explicitProviderToolResultAckObservations.removeFirst(
                explicitProviderToolResultAckObservations.count - maxExplicitProviderAckObservationCount
            )
        }
    }

    private func resumeEligibleAckWaiters() {
        guard let trackedRunID else { return }
        resumeAckWaiters(matching: {
            $0.runID == trackedRunID && explicitProviderToolResultAckCount >= $0.minimumAckCount
        })
    }

    private func resumeAckWaiters(matching predicate: (AckWaiter) -> Bool) {
        let matchingIDs = ackWaitersByID.compactMap { waiterID, waiter in
            predicate(waiter) ? waiterID : nil
        }
        for waiterID in matchingIDs {
            guard let waiter = ackWaitersByID.removeValue(forKey: waiterID) else { continue }
            waiter.continuation.resume()
        }
    }

    // MARK: - Static Helpers

    private static func hasContent(_ json: String?) -> Bool {
        json?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func canonicalTranscriptToolName(_ toolName: String) -> String {
        MCPIntegrationHelper.canonicalRepoPromptAskUserToolName(toolName) ?? toolName
    }

    private static func repoPromptInvocationSignature(toolName: String, argsJSON: String?) -> String {
        AgentTabSession.canonicalToolInvocationSignature(
            toolName: toolName,
            argsJSON: argsJSON
        )
    }
}
