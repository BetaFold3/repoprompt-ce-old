import Foundation

/// Recognizes a successful `present_rich` tool result in a transcript tool execution and captures
/// its reference onto the owning turn (docs/context/specs/2026-11-04-rich-presentation-spec.md,
/// Step 4).
///
/// Providers deliver the tool's one text block in a closed set of verified wrappers, each produced
/// by a production normalizer in this repository (no speculative adapters, no generic search):
///
/// - the canonical text itself (`{"presentation": Reference}`): Claude's joined text blocks
///   (`ClaudeSDKNDJSONTranslator.serializeToolResultContent`), an ACP `rawOutput` string or the
///   extracted ACP content text (`ACPDefaultSessionUpdateNormalizer`), or a `rawOutput` object that
///   is the tool's own JSON object;
/// - an MCP `CallToolResult` `{content: [one text block], isError?, structuredContent?: null}`:
///   Codex's canonical `mcpToolCall` item `result` (`parseCanonicalMCPToolLifecycleEvent`) and an
///   ACP `rawOutput` MCP envelope. `structuredContent` is never read;
/// - Codex's legacy `{"Ok": CallToolResult}` (`parseRawMCPToolLifecycleEvent`; `Err` rejects);
/// - the serialized ACP `content` array `[{type: "content", content: {type: "text", text}}]`
///   (`ACPDefaultSessionUpdateNormalizer` when `rawOutput` is absent);
/// - Cursor's terminal wrapper `{status: "success", acp_status: "completed", rawOutput?, content?, …}`
///   (`CursorACPEventNormalizer.terminalResultPayload`), whose `rawOutput` (authoritative when
///   present) or `content` is one of the forms above.
///
/// Anything else yields no reference, so the activity stays ordinary tool evidence: an error flag
/// or failed/cancelled status at any wrapper level, a second content block, different references
/// in one wrapper, unknown keys or nesting, prose, and objects that merely contain text.
///
/// Capture runs at every boundary that can destructively rewrite activities (runtime and
/// persistent sanitization, compaction, historical truncation) BEFORE that rewrite, so the
/// turn-owned reference survives any later tier downshift, archive or structural trim.
package enum AgentRichPresentationResultNormalizer {
    /// The canonical reference text (a direct body, a text block or a `rawOutput` string/object) is
    /// never scanned above this size: a reference is at most a few KiB (title, 2 KiB fallback and
    /// at most four warnings, even fully escaped).
    static let maxReferenceTextBytes = 64 * 1024

    /// Cursor's terminal wrapper is the one verified wrapper that also carries the call's input
    /// (`rawInput`), so it may be far larger than its reference. This admits the largest accepted
    /// input (`RichPresentationLimits.maxSerializedInputBytes`) re-serialized with worst-case
    /// escaping (4×: ASCII-only `\uXXXX` escaping is at most 3× the admitted JSONEncoder bytes, and
    /// a string-encoded `rawInput` adds at most one more escape level), plus the reference and the
    /// wrapper's own fields. Every other wrapper stays at `maxReferenceTextBytes`, and the
    /// extracted reference text is still held to `maxReferenceTextBytes`.
    static let maxCursorTerminalWrapperBytes = 4 * RichPresentationLimits.maxSerializedInputBytes + maxReferenceTextBytes

    /// Only RepoPrompt's own tool: the plain name or a verified RepoPrompt server prefix
    /// (`MCPIntegrationHelper.canonicalRepoPromptToolName`). Another MCP server's `present_rich`
    /// (`mcp__<other>__present_rich`) and loose spellings are ordinary tool evidence.
    package static func isPresentRichToolName(_ raw: String?) -> Bool {
        guard let raw, raw.range(of: AgentRichPresentationToolPolicy.toolName, options: .caseInsensitive) != nil else {
            return false
        }
        return MCPIntegrationHelper.canonicalRepoPromptToolName(raw) == AgentRichPresentationToolPolicy.toolName
    }

    /// The reference of a successful `present_rich` execution, or nil.
    package static func reference(from execution: AgentTranscriptToolExecution?) -> RichPresentationReference? {
        guard let execution,
              isPresentRichToolName(execution.toolName),
              execution.toolIsError != true,
              execution.status != .failed,
              execution.status != .cancelled,
              let raw = execution.resultJSON
        else { return nil }
        return reference(fromResultText: raw)
    }

    /// The validated reference carried by a result body in one verified wrapper, or nil.
    package static func reference(fromResultText raw: String) -> RichPresentationReference? {
        let byteCount = raw.utf8.count
        guard byteCount <= maxCursorTerminalWrapperBytes else { return nil }
        let data = Data(raw.utf8)
        let withinReferenceBound = byteCount <= maxReferenceTextBytes
        if withinReferenceBound, let canonical = canonicalReference(data) {
            return canonical
        }
        guard let node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = node as? [String: Any], object.keys.contains("acp_status") {
            return cursorTerminalReference(object)
        }
        // Only Cursor's wrapper may exceed the reference bound (it carries `rawInput`).
        guard withinReferenceBound else { return nil }
        if let array = node as? [Any] {
            return acpContentReference(array)
        }
        guard let object = node as? [String: Any] else { return nil }
        if object.count == 1, let ok = object["Ok"] {
            return callToolResultReference(ok)
        }
        return callToolResultReference(object)
    }

    /// The canonical text body for a recognized reference (`{"presentation": Reference}`).
    package static func canonicalResultJSON(for reference: RichPresentationReference) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(RichPresentationResult(presentation: reference)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Verified wrappers (closed set; see the type comment)

    /// The canonical `{"presentation": Reference}` body (strict validator: unknown keys reject).
    private static func canonicalReference(_ data: Data) -> RichPresentationReference? {
        (try? RichPresentationValidator.decodeResult(data: data))?.presentation
    }

    private static func canonicalReference(text value: Any?) -> RichPresentationReference? {
        guard let text = value as? String, text.utf8.count <= maxReferenceTextBytes else { return nil }
        return canonicalReference(Data(text.utf8))
    }

    private static func canonicalReference(object value: Any?) -> RichPresentationReference? {
        guard let object = value as? [String: Any], object.keys.contains("presentation"),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= maxReferenceTextBytes
        else { return nil }
        return canonicalReference(data)
    }

    private static func isAbsentOrNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// One MCP text content block `{type: "text", text, annotations?: null}` carrying the canonical body.
    private static func textBlockReference(_ value: Any?) -> RichPresentationReference? {
        guard let block = value as? [String: Any],
              Set(block.keys).isSubset(of: ["type", "text", "annotations"]),
              block["type"] as? String == "text",
              isAbsentOrNull(block["annotations"])
        else { return nil }
        return canonicalReference(text: block["text"])
    }

    /// MCP `CallToolResult` with exactly one text block, not an error, and no structured content.
    private static func callToolResultReference(_ value: Any?) -> RichPresentationReference? {
        guard let result = value as? [String: Any],
              Set(result.keys).isSubset(of: ["content", "isError", "structuredContent"]),
              result["isError"] == nil || (result["isError"] as? Bool) == false,
              isAbsentOrNull(result["structuredContent"]),
              let content = result["content"] as? [Any], content.count == 1
        else { return nil }
        return textBlockReference(content[0])
    }

    /// Serialized ACP tool-call content: exactly one `{type: "content", content: <text block>}`.
    private static func acpContentReference(_ value: Any?) -> RichPresentationReference? {
        guard let content = value as? [Any], content.count == 1,
              let entry = content[0] as? [String: Any],
              Set(entry.keys) == ["type", "content"],
              entry["type"] as? String == "content"
        else { return nil }
        return textBlockReference(entry["content"])
    }

    /// An ACP `rawOutput` as delivered: the canonical text, the tool's own JSON object, or an MCP
    /// `CallToolResult` envelope.
    private static func acpRawOutputReference(_ value: Any?) -> RichPresentationReference? {
        if value is String {
            return canonicalReference(text: value)
        }
        return canonicalReference(object: value) ?? callToolResultReference(value)
    }

    /// Cursor's terminal result wrapper. Its own status must be the successful completion; the
    /// wrapped `rawOutput` is authoritative when present (production ACP precedence), otherwise the
    /// ACP `content`. A `content` that carries a different reference rejects.
    private static func cursorTerminalReference(_ wrapper: [String: Any]) -> RichPresentationReference? {
        let allowedKeys: Set = ["status", "acp_status", "title", "kind", "rawOutput", "content", "rawInput"]
        guard Set(wrapper.keys).isSubset(of: allowedKeys),
              wrapper["status"] as? String == "success",
              wrapper["acp_status"] as? String == "completed"
        else { return nil }
        let fromContent = wrapper["content"].flatMap { acpContentReference($0) }
        guard let rawOutput = wrapper["rawOutput"] else { return fromContent }
        guard let reference = acpRawOutputReference(rawOutput) else { return nil }
        if let fromContent, fromContent != reference { return nil }
        return reference
    }

    // MARK: - Capture

    /// Appends the reference of every successful `present_rich` activity to its owning turn,
    /// ordered by the activity's session-wide sequence index. Idempotent: an artifact already owned
    /// by any turn is never added again. A turn whose stored references are unreadable is left
    /// unchanged (one representation per turn; the opaque value may already hold the reference),
    /// so its activity stays ordinary evidence. Returns whether anything was added.
    @discardableResult
    package static func captureRichPresentations(in transcript: inout AgentTranscript) -> Bool {
        var candidates: [(turn: Int, entry: AgentTranscriptRichPresentation)] = []
        for (turnIndex, turn) in transcript.turns.enumerated() where turn.unreadableRichPresentations == nil {
            for span in turn.responseSpans {
                for activity in span.activities {
                    guard let reference = reference(from: activity.toolExecution) else { continue }
                    candidates.append((turnIndex, AgentTranscriptRichPresentation(
                        reference: reference, activityID: activity.id, activityOrder: activity.sequenceIndex
                    )))
                }
            }
        }
        guard !candidates.isEmpty else { return false }
        var owned = Set(transcript.turns.flatMap { $0.richPresentations.map(\.reference.artifactID) })
        var touched = Set<Int>()
        for candidate in candidates.sorted(by: { $0.entry.activityOrder < $1.entry.activityOrder }) {
            guard owned.insert(candidate.entry.reference.artifactID).inserted else { continue }
            transcript.turns[candidate.turn].richPresentations.append(candidate.entry)
            touched.insert(candidate.turn)
        }
        for index in touched {
            transcript.turns[index].richPresentations = ordered(transcript.turns[index].richPresentations)
        }
        return !touched.isEmpty
    }

    /// Captures into a single turn (incremental paths that rewrite only the final turn). The
    /// artifacts owned by other turns are passed in so the transcript-wide idempotence holds.
    @discardableResult
    package static func captureRichPresentations(
        in turn: inout AgentTranscriptTurn,
        artifactsOwnedElsewhere: Set<UUID> = []
    ) -> Bool {
        guard turn.unreadableRichPresentations == nil else { return false }
        var owned = artifactsOwnedElsewhere.union(turn.richPresentations.map(\.reference.artifactID))
        var added = false
        let entries = turn.responseSpans.flatMap(\.activities).compactMap { activity -> AgentTranscriptRichPresentation? in
            guard let reference = reference(from: activity.toolExecution) else { return nil }
            return AgentTranscriptRichPresentation(
                reference: reference, activityID: activity.id, activityOrder: activity.sequenceIndex
            )
        }
        for entry in entries.sorted(by: { $0.activityOrder < $1.activityOrder })
            where owned.insert(entry.reference.artifactID).inserted
        {
            turn.richPresentations.append(entry)
            added = true
        }
        if added {
            turn.richPresentations = ordered(turn.richPresentations)
        }
        return added
    }

    static func ordered(_ entries: [AgentTranscriptRichPresentation]) -> [AgentTranscriptRichPresentation] {
        entries.enumerated().sorted { lhs, rhs in
            lhs.element.activityOrder == rhs.element.activityOrder
                ? lhs.offset < rhs.offset
                : lhs.element.activityOrder < rhs.element.activityOrder
        }.map(\.element)
    }
}

/// Capture seams for transcript rewrites that may drop or summarize tool activities.
package enum AgentRichPresentationCapture {
    /// `transcript` with every successful `present_rich` activity captured onto its turn.
    package static func captured(_ transcript: AgentTranscript) -> AgentTranscript {
        var result = transcript
        AgentRichPresentationResultNormalizer.captureRichPresentations(in: &result)
        return result
    }

    /// `target` (a rewrite of `source` that keeps turn identities) with the turn-owned references
    /// captured from `source`'s activities merged in by turn ID. Never removes a reference the
    /// target already holds; an unreadable source value is carried unchanged (one representation
    /// per turn). Cheap when no turn holds or produces a reference.
    package static func attaching(from source: AgentTranscript, to target: AgentTranscript) -> AgentTranscript {
        let capturedSource = captured(source)
        let sourceOwners = capturedSource.turns.filter {
            !$0.richPresentations.isEmpty || $0.unreadableRichPresentations != nil
        }
        guard !sourceOwners.isEmpty else { return target }
        let byID = Dictionary(sourceOwners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = target
        for index in result.turns.indices {
            guard let owner = byID[result.turns[index].id] else { continue }
            merge(owner, into: &result.turns[index])
        }
        return result
    }

    /// Merges `owner`'s references into `turn` without dropping any the turn already holds.
    package static func merge(_ owner: AgentTranscriptTurn, into turn: inout AgentTranscriptTurn) {
        if let unreadable = owner.unreadableRichPresentations {
            turn.richPresentations = []
            turn.unreadableRichPresentations = unreadable
            return
        }
        guard turn.unreadableRichPresentations == nil else { return }
        guard owner.richPresentations != turn.richPresentations else { return }
        var seen = Set(turn.richPresentations.map(\.reference.artifactID))
        var merged = turn.richPresentations
        for entry in owner.richPresentations where seen.insert(entry.reference.artifactID).inserted {
            merged.append(entry)
        }
        turn.richPresentations = AgentRichPresentationResultNormalizer.ordered(merged)
    }
}

/// The rich references a rendered block list shows, and which `present_rich` result rows they make
/// redundant. A successful result row's body is suppressed (a compact card is shown instead)
/// whenever its reference is shown anywhere in the list: its own owning activity, or a duplicate
/// call that returned the same artifact, in working or revealed archived blocks. Errors and
/// in-progress rows always keep their ordinary cards.
package struct AgentRichPresentationShownReferences: Equatable {
    package private(set) var activityIDs: Set<UUID> = []
    package private(set) var artifactIDs: Set<UUID> = []

    package static let empty = AgentRichPresentationShownReferences()

    private init() {}

    package init(blocks: [AgentTranscriptRenderBlock]) {
        var pending = blocks[...]
        var nested: [AgentTranscriptRenderBlock] = []
        while let block = pending.popFirst() ?? nested.popLast() {
            if let presentation = block.richPresentation {
                activityIDs.insert(presentation.activityID)
                artifactIDs.insert(presentation.reference.artifactID)
            }
            nested.append(contentsOf: block.groupedHistory?.sections.flatMap(\.childBlocks) ?? [])
        }
    }

    package func suppressesSuccessBody(of item: AgentChatItem) -> Bool {
        guard !artifactIDs.isEmpty,
              item.kind == .toolResult,
              item.toolIsError != true,
              AgentRichPresentationResultNormalizer.isPresentRichToolName(item.toolName),
              !Self.isInProgress(item.toolResultJSON)
        else { return false }
        if activityIDs.contains(item.id) {
            return true
        }
        guard let reference = item.toolResultJSON.flatMap(AgentRichPresentationResultNormalizer.reference(fromResultText:)) else {
            return false
        }
        return artifactIDs.contains(reference.artifactID)
    }

    /// The ACP durable lifecycle progress body (`{"status": "running" | "pending", …}`).
    private static func isInProgress(_ resultJSON: String?) -> Bool {
        guard let resultJSON, resultJSON.utf8.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any],
              let status = (object["status"] as? String)?.lowercased()
        else { return false }
        return ["running", "pending", "in_progress"].contains(status)
    }
}
