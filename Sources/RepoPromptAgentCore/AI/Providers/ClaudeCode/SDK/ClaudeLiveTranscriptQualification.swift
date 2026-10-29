import Foundation

// Step 4d3b (lossless restart Phase 4; inactive, default-off, no production caller): live identity
// for the one observed Claude output shape (O19: one dispatched turn whose single-text-block
// assistant envelope and success result are attributed to that dispatch's own outbound user message
// and agree). The app does not request user-message replay; a replay, when present, is only exact
// corroboration. Scope and boundaries:
// docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d3.md.
//
// The native controller classifies EVERY raw stdout payload of a qualified producer, from the exact
// bytes it fed the translator and before any translated result is suppressed. A positive
// classification only marks the one translated `content` result of a complete single-text assistant
// envelope with the deterministic row identity and complete-envelope proof the history reader
// derives (`ClaudeSessionHistoryReader.singleTextAssistantRow`); the canonical owner inserts that row
// and its ledger entry together. Any unrecognized, unsupported or contradicting payload disqualifies
// the producer for the rest of its launch, and the owner then invalidates its Claude proofs.
// Recognition is an allowlist of observed shapes; it is not a claim that other shapes are benign,
// and launch eligibility is not installed-profile qualification.
//
// Step 4d5 (inactive, default-off): additionally the one observed successful main-thread Read
// exchange (phase4d5 offline O20 shape inspection, replay-on capture; the app's no-replay profile is
// a fixture assumption, not qualification): the dispatch's attributed single `tool_use` Read call
// (exactly `{type, caller:{type:direct}, id, name:Read, input:{file_path}}`, `wire_tool_inputs` the
// singleton mapping of that id to that input), its linked string `tool_result` user (no `is_error`;
// exact `tool_use_result`/`tool_result_meta` linkage), the one-text final assistant (unattributed
// only in this chain state, bound by the uninterrupted dispatch, never a latest-message guess) and
// the attributed agreeing success. Each carries the reader's projection of its native entry
// (`ClaudeSessionHistoryReader.singleToolUseRow`/`singleToolResultRow`, the canonical input JSON
// from the raw stdout input) plus its predecessors as explicit prerequisites; the translator's
// random invocation ID is checked only for live call/result pairing and never becomes identity.

/// Why a producer stopped qualifying (diagnostic only; never persisted).
package enum ClaudeLiveTranscriptDisqualification: String, Equatable {
    case malformedPayload
    /// An undecodable stdout line (any recovery path may follow).
    case malformedLine
    case unsupportedPayload
    case semanticMarker
    case sessionMismatch
    case unsupportedLifecycle
    case unsupportedRateLimit
    case unsupportedUserReplay
    case unsupportedAssistant
    /// An assistant envelope outside an owned dispatch (or a second one in a turn).
    case unownedAssistant
    /// A consumed-user attribution that is not exactly the dispatch's outbound message.
    case attributionMismatch
    /// An unreplayed dispatch's assistant without affirmative consumed-user attribution.
    case unattributedAssistant
    /// The translated results do not carry exactly the envelope's one text.
    case translationMismatch
    case unsupportedResult
    case resultTextMismatch
    /// A user message written without a recorded outbound identity.
    case unidentifiedOutbound
    /// A user message written while an earlier dispatch had no success result yet.
    case overlappingOutbound
    /// A launch installed while an earlier launch's stdout EOF tail was still draining.
    case launchDuringDrain
    /// Step 4d5: a user payload in a Read chain that is not exactly the observed tool result.
    case unsupportedToolResult
    /// Step 4d5: a Read result whose tool-use ID, metadata or path does not link to the turn's call.
    case toolLinkMismatch
    /// Step 4d5: a Read chain's success result without both affirmative attributions.
    case unattributedResult
    /// Step 4d5: the translated result evidence would ride on is suppressed before delivery.
    case attachmentSuppressed
}

/// Step 4d5: the identity and proof of one qualified Read call or result row, exactly what the
/// history reader projects for the same native entry (row ID, invocation ID, digest, payload).
package struct ClaudeLiveTranscriptToolRow: Equatable {
    package let nativeSessionID: String
    package let nativeEntryID: String
    /// `.toolCall` or `.toolResult`.
    package let kind: ClaudeSessionHistoryReader.RowKind
    package let toolUseID: String
    package let toolName: String
    /// The canonical input JSON (a call) or the result text (a result).
    package let payload: String
    package let localItemID: UUID
    package let invocationID: UUID
    package let envelopeDigest: String

    /// The reader's projection of this row (`nil` for any other kind).
    package var projectedRow: ClaudeSessionHistoryReader.Row? {
        Self.project(nativeSessionID: nativeSessionID, nativeEntryID: nativeEntryID, kind: kind, toolUseID: toolUseID, toolName: toolName, payload: payload)
    }

    /// The row the reader projects for these native facts, or `nil` when it projects none.
    package static func projecting(
        nativeSessionID: String,
        nativeEntryID: String,
        kind: ClaudeSessionHistoryReader.RowKind,
        toolUseID: String,
        toolName: String,
        payload: String
    ) -> Self? {
        guard let row = project(
            nativeSessionID: nativeSessionID, nativeEntryID: nativeEntryID, kind: kind, toolUseID: toolUseID, toolName: toolName, payload: payload
        ), row.kind == kind, let localItemID = row.localItemID, let invocationID = row.toolInvocationID
        else { return nil }
        return Self(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            kind: kind,
            toolUseID: toolUseID,
            toolName: toolName,
            payload: payload,
            localItemID: localItemID,
            invocationID: invocationID,
            envelopeDigest: row.envelopeDigest
        )
    }

    private static func project(
        nativeSessionID: String,
        nativeEntryID: String,
        kind: ClaudeSessionHistoryReader.RowKind,
        toolUseID: String,
        toolName: String,
        payload: String
    ) -> ClaudeSessionHistoryReader.Row? {
        switch kind {
        case .toolCall:
            ClaudeSessionHistoryReader.singleToolUseRow(
                nativeSessionID: nativeSessionID, nativeEntryID: nativeEntryID, toolUseID: toolUseID, name: toolName, inputJSON: payload
            )
        case .toolResult:
            ClaudeSessionHistoryReader.singleToolResultRow(
                nativeSessionID: nativeSessionID, nativeEntryID: nativeEntryID, toolUseID: toolUseID, toolName: toolName, text: payload
            )
        case .userText, .assistantText:
            nil
        }
    }

    package var ledgerKey: String {
        AgentSessionProviderHistoryRecovery.rowKey(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: kind.rawValue,
            ordinal: 0
        )
    }

    package var ledgerItem: AgentSessionProviderHistoryRecovery.NativeItem {
        AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: kind.rawValue,
            ordinal: 0,
            localItemID: localItemID,
            envelopeDigest: envelopeDigest
        )
    }

    /// Whether the stored IDs and digest are exactly the reader's projection of these facts.
    package var matchesProjection: Bool {
        guard let row = projectedRow else { return false }
        return row.kind == kind && row.localItemID == localItemID && row.toolInvocationID == invocationID
            && row.envelopeDigest == envelopeDigest
    }

    /// The canonical row, built by the same projection an import uses.
    package var canonicalItem: AgentChatItem? {
        projectedRow.flatMap(ClaudeSessionHistoryReader.item(for:))
    }
}

/// The identity and proof of one qualified complete assistant text: exactly what the history reader
/// projects for the same native entry.
package struct ClaudeLiveTranscriptCompleteText: Equatable {
    package let nativeSessionID: String
    package let nativeEntryID: String
    package let localItemID: UUID
    package let text: String
    package let envelopeDigest: String

    /// Step 4d7: the complete text the reader projects for exactly these native facts (its ID and
    /// digest derived by the same projection), or `nil` when it projects none. Used only to compare
    /// against a stored ledger entry; never stored as a replacement proof.
    package static func projecting(nativeSessionID: String, nativeEntryID: String, text: String) -> Self? {
        guard let row = ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            text: text
        ), row.kind == .assistantText, row.ordinal == 0, let localItemID = row.localItemID
        else { return nil }
        return Self(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            localItemID: localItemID,
            text: text,
            envelopeDigest: row.envelopeDigest
        )
    }

    /// The ledger key (normalized native row key) of this row.
    package var ledgerKey: String {
        AgentSessionProviderHistoryRecovery.rowKey(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: ClaudeSessionHistoryReader.RowKind.assistantText.rawValue,
            ordinal: 0
        )
    }

    /// The ledger entry recording this row's identity and proof (no import receipt or cursor).
    package var ledgerItem: AgentSessionProviderHistoryRecovery.NativeItem {
        AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: ClaudeSessionHistoryReader.RowKind.assistantText.rawValue,
            ordinal: 0,
            localItemID: localItemID,
            envelopeDigest: envelopeDigest
        )
    }

    /// Whether the stored ID and digest are exactly the history reader's projection of this native
    /// entry and text, so the row and its ledger entry can never disagree.
    package var matchesProjection: Bool {
        guard let row = ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            text: text
        ) else { return false }
        return row.localItemID == localItemID && row.envelopeDigest == envelopeDigest
    }

    /// The canonical row, built by the same projection an import uses (complete, never streaming).
    package var canonicalItem: AgentChatItem? {
        ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            text: text
        ).flatMap(ClaudeSessionHistoryReader.item(for:))
    }
}

/// Transient evidence a qualified Claude producer attaches to a core stream result. Never encoded,
/// logged or persisted; `nil` on every result of a disabled or ineligible producer.
package struct ClaudeLiveTranscriptEvidence: Equatable {
    package enum Kind: Equatable {
        /// Rides on the envelope's one translated `content` result (never a second copy).
        case completeText(ClaudeLiveTranscriptCompleteText)
        /// A success result whose text equals the turn's qualified assistant text: the owner must
        /// hold exactly that identified row with a valid proof.
        case resultAgreement(localItemID: UUID, text: String)
        /// Step 4d5: rides on the Read call envelope's one translated `tool_call` result.
        case readToolCall(ClaudeLiveTranscriptToolRow)
        /// Step 4d5: rides on the linked result's one translated `tool_result`; the owner must hold
        /// `call` (its canonical row and valid proof) before inserting it.
        case readToolResult(ClaudeLiveTranscriptToolRow, call: ClaudeLiveTranscriptToolRow)
        /// Step 4d5: the chain's final text, riding on its one translated `content` result; the owner
        /// must hold `call` and `result` before inserting it.
        case readAnswer(ClaudeLiveTranscriptCompleteText, call: ClaudeLiveTranscriptToolRow, result: ClaudeLiveTranscriptToolRow)
        /// Step 4d5: the attributed success agreeing with the chain: the owner must hold all three
        /// rows with their exact canonical payloads and valid proofs.
        case readAgreement(call: ClaudeLiveTranscriptToolRow, result: ClaudeLiveTranscriptToolRow, answer: ClaudeLiveTranscriptCompleteText)
        /// The producer no longer qualifies (sticky for its launch).
        case disqualified(ClaudeLiveTranscriptDisqualification)
    }

    /// The process launch whose stdout carried the payload.
    package let producerLaunchToken: UUID
    package let kind: Kind
}

extension AIStreamResult {
    /// A metadata-only carrier for evidence with no translated result to ride on (or none that
    /// survives suppression): lifecycle type, no text, no usage, never a turn boundary.
    static func claudeLiveTranscriptEvidenceCarrier(_ evidence: ClaudeLiveTranscriptEvidence) -> AIStreamResult {
        var result = AIStreamResult(type: lifecycleType, text: nil)
        result.claudeLiveTranscriptEvidence = evidence
        return result
    }
}

/// What one classified payload contributes.
package enum ClaudeLiveTranscriptOutcome: Equatable {
    /// Recognized and benign: nothing to carry.
    case benign
    /// Attach to the translated result at `index` (its one `content` result).
    case attach(index: Int, ClaudeLiveTranscriptEvidence)
    /// Emit once as a metadata-only carrier, before the payload's translated results.
    case standalone(ClaudeLiveTranscriptEvidence)
}

/// Qualification state of one producer (process launch). Owned by the native controller; created
/// only when that launch's stdout reader is installed, so a consumer reset, a new turn, `system/init`
/// or a router change never resets it. Monotonic: once disqualified it never qualifies again.
package struct ClaudeLiveTranscriptProducerState {
    package enum Eligibility: Equatable {
        /// The launch identity is not known yet: payloads are classified (disqualification sticks)
        /// but nothing is emitted and nothing qualifies.
        case pending
        case eligible
    }

    private enum Turn: Equatable {
        case idle
        /// An identified outbound message was written; `replayed` once its exact replay was seen.
        case dispatched(uuid: UUID, text: String, replayed: Bool)
        /// The dispatch's qualified answer (the outbound identity is kept for its result).
        case answered(ClaudeLiveTranscriptCompleteText, outbound: UUID)
        /// Step 4d5: the dispatch's qualified Read call (`translatedInvocationID`: the translator's
        /// pairing ID, checked against the result's translation only).
        case readCalled(call: ClaudeLiveTranscriptToolRow, filePath: String, outbound: UUID, translatedInvocationID: UUID)
        case readReturned(call: ClaudeLiveTranscriptToolRow, result: ClaudeLiveTranscriptToolRow, outbound: UUID)
        case readAnswered(
            call: ClaudeLiveTranscriptToolRow,
            result: ClaudeLiveTranscriptToolRow,
            answer: ClaudeLiveTranscriptCompleteText,
            outbound: UUID
        )
    }

    package let launchToken: UUID
    package private(set) var eligibility: Eligibility = .pending
    package private(set) var disqualification: ClaudeLiveTranscriptDisqualification?
    /// The first native session ID this producer reported; every later one must equal it.
    private var nativeSessionID: String?
    private var turn: Turn = .idle

    /// Payload types after which a disqualified producer repeats its refusal, so an owner whose
    /// consumer missed the first carrier (a reset events stream) still hears it before any later
    /// turn's output.
    private static let stickyTypes: Set<String> = ["user", "assistant", "result"]
    private static let lifecycleKeys: Set<String> = ["command_uuid", "session_id", "state", "type", "uuid"]
    private static let initKeys: Set<String> = [
        "additional_directories", "agents", "analytics_disabled", "apiKeySource", "capabilities", "claude_code_version",
        "cwd", "fast_mode_disabled_reason", "fast_mode_state", "mcp_servers", "messaging_socket_path", "model",
        "original_cwd", "output_style", "per_turn_effort_active", "permissionMode", "plugins", "product_feedback_disabled",
        "session_id", "skills", "slash_commands", "subtype", "tools", "type", "user_message_uuids", "uuid", "view_mode"
    ]
    private static let resultKeys: Set<String> = [
        "api_error_status", "duration_api_ms", "duration_ms", "fast_mode_disabled_reason", "fast_mode_state",
        "first_content_frame_ms", "first_request_input_tokens", "is_error", "modelUsage", "num_turns", "permission_denials",
        "queued_turn_count", "request_sent_wall_ms", "result", "result_index", "safety_stops", "session_id", "stop_reason",
        "subagent_stats", "subtype", "terminal_reason", "time_to_request_ms", "total_cost_usd", "ttft_ms", "ttft_stream_ms",
        "type", "usage", "user_message_uuid", "user_message_uuids", "uuid"
    ]
    private static let lifecycleStates: Set<String> = ["queued", "started", "completed"]
    private static let rateLimitKeys: Set<String> = ["type", "session_id", "uuid", "rate_limit_info"]
    private static let rateLimitInfoKeys: Set<String> = [
        "status", "rateLimitType", "overageStatus", "overageDisabledReason", "isUsingOverage", "resetsAt",
        "unifiedWindows"
    ]
    private static let replayKeys: Set<String> = [
        "isReplay", "message", "parent_tool_use_id", "session_id", "timestamp", "type", "uuid"
    ]
    private static let assistantKeys: Set<String> = [
        "message", "parent_tool_use_id", "request_id", "session_id", "timestamp", "type", "user_message_uuid",
        "user_message_uuids", "uuid"
    ]
    private static let assistantMessageKeys: Set<String> = [
        "content", "id", "model", "role", "type", "usage", "input_transformations", "container",
        "context_management", "diagnostics", "stop_details", "stop_reason", "stop_sequence"
    ]
    /// Observed only as `null`; any value is an unrecognized semantic shape.
    private static let assistantMessageNullKeys = [
        "container", "context_management", "diagnostics", "stop_details", "stop_reason", "stop_sequence"
    ]
    /// S1 round 1 (observed on the real CLI's thinking envelopes only): the display mode and the
    /// thinking duration. Neither is part of any row; both are type-checked in `classifyThinking`.
    private static let thinkingKeys = assistantKeys.union(["thinking_display", "thinking_duration_ms"])
    /// Step 4d5 (O20): the Read call envelope adds only `wire_tool_inputs` to the assistant keys.
    private static let readCallKeys = assistantKeys.union(["wire_tool_inputs"])
    private static let readCallBlockKeys: Set<String> = ["type", "caller", "id", "name", "input"]
    private static let readResultKeys: Set<String> = [
        "message", "parent_tool_use_id", "session_id", "timestamp", "tool_result_meta", "tool_use_result", "type", "uuid"
    ]
    private static let readResultFileKeys: Set<String> = ["content", "filePath", "numLines", "startLine", "totalLines"]
    private static let readToolName = "Read"

    package init(launchToken: UUID) {
        self.launchToken = launchToken
    }

    /// The launch identity was resolved eligible (automatic or configured command, default backend, no routing
    /// overrides) with the injected qualification enabled.
    package mutating func markEligible() {
        eligibility = .eligible
    }

    package mutating func disqualify(_ reason: ClaudeLiveTranscriptDisqualification) {
        if disqualification == nil { disqualification = reason }
    }

    /// A user message was successfully written. Only a message carrying its recorded outbound UUID,
    /// sent while no earlier dispatch is open, can own a qualified answer.
    package mutating func noteOutbound(uuid: UUID?, text: String) {
        guard disqualification == nil else { return }
        guard let uuid else {
            disqualify(.unidentifiedOutbound)
            return
        }
        guard turn == .idle else {
            disqualify(.overlappingOutbound)
            return
        }
        turn = .dispatched(uuid: uuid, text: text, replayed: false)
    }

    /// Classifies one raw stdout payload (`envelope`: the exact bytes fed to the translator) against
    /// its translated results. `turnInFlight`: the controller owns an outstanding dispatch.
    package mutating func classify(
        envelope: Data,
        translated: [AIStreamResult],
        turnInFlight: Bool
    ) -> ClaudeLiveTranscriptOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? NSDictionary,
              let type = object["type"] as? String
        else { return disqualified(.malformedPayload) }
        if let existing = disqualification {
            return Self.stickyTypes.contains(type) ? .standalone(evidence(.disqualified(existing))) : .benign
        }
        if ClaudeSessionHistoryReader.semanticMarker(in: object) != nil
            || (object["message"] as? NSDictionary).flatMap(ClaudeSessionHistoryReader.semanticMarker(in:)) != nil
        {
            return disqualified(.semanticMarker)
        }
        if let value = object["session_id"] {
            guard let session = value as? String, !session.isEmpty, nativeSessionID == nil || nativeSessionID == session
            else { return disqualified(.sessionMismatch) }
            nativeSessionID = session
        }
        switch type {
        case "command_lifecycle":
            return isRecognizedLifecycle(object) ? .benign : disqualified(.unsupportedLifecycle)
        case "system":
            return isRecognizedInit(object) ? .benign : disqualified(.unsupportedPayload)
        case "rate_limit_event":
            return isAllowedRateLimit(object) ? .benign : disqualified(.unsupportedRateLimit)
        case "user":
            if case .readCalled = turn {
                return classifyReadResult(object, translated: translated, turnInFlight: turnInFlight)
            }
            return classifyReplay(object)
        case "assistant":
            return classifyAssistant(object, translated: translated, turnInFlight: turnInFlight)
        case "result":
            return classifyResult(object)
        default:
            return disqualified(.unsupportedPayload)
        }
    }

    // MARK: Shapes

    private func isRecognizedLifecycle(_ object: NSDictionary) -> Bool {
        guard Self.keys(object).isSubset(of: Self.lifecycleKeys),
              let state = object["state"] as? String, Self.lifecycleStates.contains(state)
        else { return false }
        return ["command_uuid", "uuid"].allSatisfy { object[$0] == nil || object[$0] is String }
    }

    /// `system/init` with only its known keys (values are ordinary metadata, not validated further).
    private func isRecognizedInit(_ object: NSDictionary) -> Bool {
        (object["subtype"] as? String) == "init" && Self.keys(object).isSubset(of: Self.initKeys)
    }

    private func isAllowedRateLimit(_ object: NSDictionary) -> Bool {
        guard Self.keys(object).isSubset(of: Self.rateLimitKeys),
              let info = object["rate_limit_info"] as? NSDictionary,
              Self.keys(info).isSubset(of: Self.rateLimitInfoKeys)
        else { return false }
        return (info["status"] as? String) == "allowed"
    }

    /// Optional corroboration: an exact replay of the open dispatch's outbound message.
    private mutating func classifyReplay(_ object: NSDictionary) -> ClaudeLiveTranscriptOutcome {
        guard case let .dispatched(outboundUUID, outboundText, replayed: false) = turn,
              Self.keys(object).isSubset(of: Self.replayKeys),
              (object["isReplay"] as? Bool) == true,
              Self.isNull(object["parent_tool_use_id"]),
              object["timestamp"] == nil || object["timestamp"] is String,
              let replayUUID = (object["uuid"] as? String).flatMap(UUID.init(uuidString:)),
              replayUUID == outboundUUID,
              let message = object["message"] as? NSDictionary,
              Self.keys(message).isSubset(of: ["role", "content"]),
              (message["role"] as? String) == "user",
              (message["content"] as? String) == outboundText
        else { return disqualified(.unsupportedUserReplay) }
        turn = .dispatched(uuid: outboundUUID, text: outboundText, replayed: true)
        return .benign
    }

    /// Consumed-user attribution of an envelope: `nil` when it carries none; `true` only when every
    /// provided attribute names exactly `outbound` (`user_message_uuids` exactly that singleton).
    private static func attribution(_ object: NSDictionary, outbound: UUID) -> Bool? {
        let single = object["user_message_uuid"]
        let list = object["user_message_uuids"]
        guard single != nil || list != nil else { return nil }
        if let single {
            guard let value = single as? String, UUID(uuidString: value) == outbound else { return false }
        }
        if let list {
            guard let values = list as? [Any], values.count == 1, let value = values[0] as? String,
                  UUID(uuidString: value) == outbound
            else { return false }
        }
        return true
    }

    private mutating func classifyAssistant(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        turnInFlight: Bool
    ) -> ClaudeLiveTranscriptOutcome {
        guard eligibility == .eligible, turnInFlight, let nativeSessionID else {
            return disqualified(.unownedAssistant)
        }
        // S1: a thinking-only envelope before the dispatch's answer (or a Read chain's final answer).
        let thinkingOwner: UUID? = switch turn {
        case let .dispatched(outbound, _, _): outbound
        case let .readReturned(_, _, outbound): outbound
        default: nil
        }
        if let thinkingOwner, Self.isSingleBlockEnvelope(object, type: "thinking") {
            return classifyThinking(object, translated: translated, outbound: thinkingOwner)
        }
        switch turn {
        case let .dispatched(outbound, _, replayed):
            if Self.isSingleToolUseEnvelope(object) {
                return classifyReadCall(object, translated: translated, outbound: outbound, nativeSessionID: nativeSessionID)
            }
            // Ownership is the recorded outbound identity: provided attribution must name exactly it,
            // and without a replay it must be provided (never a latest-message guess).
            switch Self.attribution(object, outbound: outbound) {
            case false?:
                return disqualified(.attributionMismatch)
            case nil where !replayed:
                return disqualified(.unattributedAssistant)
            default:
                break
            }
            guard let complete = completeText(object, translated: translated, nativeSessionID: nativeSessionID) else {
                return disqualified(disqualification ?? .unsupportedAssistant)
            }
            turn = .answered(complete.text, outbound: outbound)
            return .attach(index: complete.carrier, evidence(.completeText(complete.text)))
        case let .readReturned(call, result, outbound):
            // Step 4d5: the chain's final answer. It may omit attribution only here, bound by the
            // uninterrupted dispatch whose attributed call it follows; provided attribution must agree.
            if Self.attribution(object, outbound: outbound) == false {
                return disqualified(.attributionMismatch)
            }
            guard let complete = completeText(object, translated: translated, nativeSessionID: nativeSessionID) else {
                return disqualified(disqualification ?? .unsupportedAssistant)
            }
            turn = .readAnswered(call: call, result: result, answer: complete.text, outbound: outbound)
            return .attach(index: complete.carrier, evidence(.readAnswer(complete.text, call: call, result: result)))
        default:
            return disqualified(.unownedAssistant)
        }
    }

    /// The qualified complete single text of an assistant envelope and the index of its one
    /// translated `content` result; `nil` after recording the refusal reason.
    private mutating func completeText(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        nativeSessionID: String
    ) -> (text: ClaudeLiveTranscriptCompleteText, carrier: Int)? {
        guard case let (entryID, block)? = Self.assistantBlock(object, topLevelKeys: Self.assistantKeys),
              Self.keys(block) == ["type", "text"],
              (block["type"] as? String) == "text",
              let text = block["text"] as? String, !text.isEmpty
        else {
            disqualify(.unsupportedAssistant)
            return nil
        }
        // The envelope's one translated `content` result, carrying exactly its text; only its usage
        // companion may accompany it.
        let carriers = translated.indices.filter { translated[$0].type != "usage" }
        guard carriers.count == 1, translated[carriers[0]].type == "content", translated[carriers[0]].text == text else {
            disqualify(.translationMismatch)
            return nil
        }
        guard let row = ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            text: text
        ), let localItemID = row.localItemID
        else {
            disqualify(.unsupportedAssistant)
            return nil
        }
        let complete = ClaudeLiveTranscriptCompleteText(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            localItemID: localItemID,
            text: text,
            envelopeDigest: row.envelopeDigest
        )
        return (complete, carriers[0])
    }

    /// The entry ID and single content block of an assistant envelope with only `topLevelKeys` and
    /// the observed message shape (exactly one content block).
    private static func assistantBlock(_ object: NSDictionary, topLevelKeys: Set<String>) -> (String, NSDictionary)? {
        guard keys(object).isSubset(of: topLevelKeys),
              object["session_id"] is String,
              isNull(object["parent_tool_use_id"]),
              ["request_id", "timestamp"].allSatisfy({ object[$0] == nil || object[$0] is String }),
              let entryID = object["uuid"] as? String, !entryID.isEmpty,
              let message = object["message"] as? NSDictionary,
              keys(message).isSubset(of: assistantMessageKeys),
              (message["role"] as? String) == "assistant",
              let messageID = message["id"] as? String, !messageID.isEmpty,
              ["model", "type"].allSatisfy({ message[$0] == nil || message[$0] is String }),
              message["usage"] == nil || message["usage"] is NSDictionary,
              message["input_transformations"] == nil || (message["input_transformations"] as? [Any])?.isEmpty == true,
              assistantMessageNullKeys.allSatisfy({ isNull(message[$0]) }),
              let content = message["content"] as? [Any], content.count == 1,
              let block = content[0] as? NSDictionary
        else { return nil }
        return (entryID, block)
    }

    /// Whether an assistant envelope's message holds exactly one `tool_use` block (routing only;
    /// its shape is validated by `classifyReadCall`).
    private static func isSingleToolUseEnvelope(_ object: NSDictionary) -> Bool {
        isSingleBlockEnvelope(object, type: "tool_use")
    }

    /// Whether an assistant envelope's message holds exactly one block of `type` (routing only).
    private static func isSingleBlockEnvelope(_ object: NSDictionary, type: String) -> Bool {
        guard let content = (object["message"] as? NSDictionary)?["content"] as? [Any], content.count == 1,
              let block = content[0] as? NSDictionary
        else { return false }
        return (block["type"] as? String) == type
    }

    /// S1 (9-live round 2): one assistant `thinking` block in the observed envelope shape is benign
    /// and changes no state, exactly as the history reader skips it (no row, no ordinal, outside the
    /// envelope digest). It must translate to no visible result (reasoning extraction is off), and
    /// any attribution it carries must name the open dispatch. `redacted_thinking`, extra block keys
    /// or a translated row still refuse.
    private mutating func classifyThinking(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        outbound: UUID
    ) -> ClaudeLiveTranscriptOutcome {
        guard case let (_, block)? = Self.assistantBlock(object, topLevelKeys: Self.thinkingKeys),
              object["thinking_display"] == nil || object["thinking_display"] is String,
              object["thinking_duration_ms"] == nil
              || (Self.isNumber(object["thinking_duration_ms"]) && ((object["thinking_duration_ms"] as? NSNumber)?.doubleValue ?? -1) >= 0),
              Self.keys(block).isSubset(of: ["type", "thinking", "signature"]),
              block["thinking"] is String,
              block["signature"] == nil || block["signature"] is String
        else { return disqualified(.unsupportedAssistant) }
        if Self.attribution(object, outbound: outbound) == false {
            return disqualified(.attributionMismatch)
        }
        guard translated.allSatisfy({ $0.type == "usage" }) else {
            return disqualified(.translationMismatch)
        }
        return .benign
    }

    /// Step 4d5: the dispatch's one Read call. Exact observed shape first (anything else is an
    /// unsupported assistant), then BOTH attribution fields naming exactly the outbound (required even
    /// when replayed), then `wire_tool_inputs` and translation equivalence.
    private mutating func classifyReadCall(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        outbound: UUID,
        nativeSessionID: String
    ) -> ClaudeLiveTranscriptOutcome {
        guard case let (entryID, block)? = Self.assistantBlock(object, topLevelKeys: Self.readCallKeys),
              Self.keys(block) == Self.readCallBlockKeys,
              (block["type"] as? String) == "tool_use",
              let caller = block["caller"] as? NSDictionary, Self.keys(caller) == ["type"],
              (caller["type"] as? String) == "direct",
              let toolUseID = block["id"] as? String, !toolUseID.isEmpty,
              (block["name"] as? String) == Self.readToolName,
              let input = block["input"] as? NSDictionary, Self.keys(input) == ["file_path"],
              let filePath = input["file_path"] as? String, !filePath.isEmpty,
              let inputJSON = ClaudeSessionHistoryReader.canonicalToolInputJSON(input)
        else { return disqualified(.unsupportedAssistant) }
        guard object["user_message_uuid"] != nil, object["user_message_uuids"] != nil else {
            return disqualified(.unattributedAssistant)
        }
        guard Self.attribution(object, outbound: outbound) == true else { return disqualified(.attributionMismatch) }
        guard let wire = object["wire_tool_inputs"] as? NSDictionary, Self.keys(wire) == [toolUseID],
              let wireInput = wire[toolUseID] as? NSDictionary, wireInput.isEqual(input)
        else { return disqualified(.unsupportedAssistant) }
        // Exactly one translated `tool_call` (plus at most its usage companion): Read, a pairing
        // invocation ID, and arguments semantically equal to the raw input (never compared as text).
        let carriers = translated.indices.filter { translated[$0].type != "usage" }
        guard carriers.count == 1 else { return disqualified(.translationMismatch) }
        let call = translated[carriers[0]]
        guard call.type == "tool_call", call.toolName == Self.readToolName,
              let translatedInvocationID = call.toolInvocationID,
              let arguments = (call.toolArgsJSON ?? call.toolArgs)?.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: arguments) as? NSDictionary,
              parsed.isEqual(input)
        else { return disqualified(.translationMismatch) }
        guard let row = ClaudeLiveTranscriptToolRow.projecting(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            kind: .toolCall,
            toolUseID: toolUseID,
            toolName: Self.readToolName,
            payload: inputJSON
        ) else { return disqualified(.unsupportedAssistant) }
        turn = .readCalled(call: row, filePath: filePath, outbound: outbound, translatedInvocationID: translatedInvocationID)
        return .attach(index: carriers[0], evidence(.readToolCall(row)))
    }

    /// Step 4d5: the user payload that must follow a qualified Read call: exactly the observed tool
    /// result (own fresh UUID, no replay or attribution keys), linked by tool-use ID, metadata ID and
    /// path, and its one translated `tool_result` paired by the translator's call invocation ID.
    private mutating func classifyReadResult(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        turnInFlight: Bool
    ) -> ClaudeLiveTranscriptOutcome {
        guard eligibility == .eligible, turnInFlight,
              case let .readCalled(call, filePath, outbound, translatedInvocationID) = turn,
              let nativeSessionID
        else { return disqualified(.unsupportedToolResult) }
        guard Self.keys(object) == Self.readResultKeys,
              Self.isNull(object["parent_tool_use_id"]),
              object["session_id"] is String,
              object["timestamp"] is String,
              let entryID = object["uuid"] as? String, !entryID.isEmpty,
              entryID.lowercased() != outbound.uuidString.lowercased(), entryID != call.nativeEntryID,
              let message = object["message"] as? NSDictionary, Self.keys(message) == ["role", "content"],
              (message["role"] as? String) == "user",
              let content = message["content"] as? [Any], content.count == 1,
              let block = content[0] as? NSDictionary, Self.keys(block) == ["type", "tool_use_id", "content"],
              (block["type"] as? String) == "tool_result",
              let toolUseID = block["tool_use_id"] as? String,
              let text = block["content"] as? String,
              let toolUseResult = object["tool_use_result"] as? NSDictionary, Self.keys(toolUseResult) == ["type", "file"],
              (toolUseResult["type"] as? String) == "text",
              let file = toolUseResult["file"] as? NSDictionary, Self.keys(file) == Self.readResultFileKeys,
              let fileContent = file["content"] as? String,
              let resultPath = file["filePath"] as? String,
              ["numLines", "startLine", "totalLines"].allSatisfy({ Self.isNumber(file[$0]) }),
              let meta = object["tool_result_meta"] as? [Any], meta.count == 1,
              let metaEntry = meta[0] as? NSDictionary, Self.keys(metaEntry) == ["id", "permission_decision"],
              let metaID = metaEntry["id"] as? String,
              let decision = metaEntry["permission_decision"] as? NSDictionary,
              Self.keys(decision) == ["decision", "source", "reason_type"],
              (decision["decision"] as? String) == "accept",
              (decision["source"] as? String) == "config",
              (decision["reason_type"] as? String) == "mode"
        else { return disqualified(.unsupportedToolResult) }
        guard toolUseID == call.toolUseID, metaID == call.toolUseID, resultPath == filePath, text.contains(fileContent) else {
            return disqualified(.toolLinkMismatch)
        }
        let carriers = translated.indices.filter { translated[$0].type != "usage" }
        guard carriers.count == 1 else { return disqualified(.translationMismatch) }
        let translatedResult = translated[carriers[0]]
        guard translatedResult.type == "tool_result", translatedResult.toolName == Self.readToolName,
              translatedResult.toolInvocationID == translatedInvocationID,
              (translatedResult.toolResultJSON ?? translatedResult.toolOutput) == text,
              translatedResult.toolIsError == nil
        else { return disqualified(.translationMismatch) }
        guard let row = ClaudeLiveTranscriptToolRow.projecting(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            kind: .toolResult,
            toolUseID: toolUseID,
            toolName: call.toolName,
            payload: text
        ), row.invocationID == call.invocationID
        else { return disqualified(.toolLinkMismatch) }
        turn = .readReturned(call: call, result: row, outbound: outbound)
        return .attach(index: carriers[0], evidence(.readToolResult(row, call: call)))
    }

    private mutating func classifyResult(_ object: NSDictionary) -> ClaudeLiveTranscriptOutcome {
        guard Self.keys(object).isSubset(of: Self.resultKeys),
              (object["subtype"] as? String) == "success",
              (object["is_error"] as? Bool) == false,
              object["session_id"] is String,
              let text = object["result"] as? String,
              Self.isNull(object["api_error_status"]),
              object["permission_denials"] == nil || (object["permission_denials"] as? [Any])?.isEmpty == true,
              object["terminal_reason"] == nil || (object["terminal_reason"] as? String) == "completed",
              object["stop_reason"] == nil || (object["stop_reason"] as? String) == "end_turn",
              object["safety_stops"] == nil || Self.isZero(object["safety_stops"])
        else { return disqualified(.unsupportedResult) }
        // Exact agreement with this turn's qualified assistant, whatever the translator forwards.
        switch turn {
        case let .answered(complete, outbound) where complete.text == text:
            if Self.attribution(object, outbound: outbound) == false {
                return disqualified(.attributionMismatch)
            }
            turn = .idle
            return .standalone(evidence(.resultAgreement(localItemID: complete.localItemID, text: text)))
        case let .readAnswered(call, result, answer, outbound) where answer.text == text:
            // Step 4d5: the chain's owner is affirmed again at its end (both fields, exactly it).
            guard object["user_message_uuid"] != nil, object["user_message_uuids"] != nil else {
                return disqualified(.unattributedResult)
            }
            guard Self.attribution(object, outbound: outbound) == true else { return disqualified(.attributionMismatch) }
            turn = .idle
            return .standalone(evidence(.readAgreement(call: call, result: result, answer: answer)))
        default:
            return disqualified(.resultTextMismatch)
        }
    }

    // MARK: Helpers

    private mutating func disqualified(_ reason: ClaudeLiveTranscriptDisqualification) -> ClaudeLiveTranscriptOutcome {
        disqualify(reason)
        return .standalone(evidence(.disqualified(disqualification ?? reason)))
    }

    private func evidence(_ kind: ClaudeLiveTranscriptEvidence.Kind) -> ClaudeLiveTranscriptEvidence {
        ClaudeLiveTranscriptEvidence(producerLaunchToken: launchToken, kind: kind)
    }

    private static func keys(_ object: NSDictionary) -> Set<String> {
        Set(object.allKeys.compactMap { $0 as? String })
    }

    private static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// A JSON number (never a boolean).
    private static func isNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// A JSON integer zero (never a boolean).
    private static func isZero(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 0 && number.doubleValue == 0
    }
}
