import CryptoKit
import Darwin
import Foundation

// Claude exact-session history reader: the single built-in decoder subset `nativeEntriesSubsetV2`
// (lossless restart Phase 4, phase4-plan §D and its native-history amendment).
//
// "V2" versions OUR decoder subset, not Claude's format or CLI (V1 = before the Step 4d2 attachment,
// envelope-proof and prefix-fence predicates; V1 baselines are kept as recorded and never upgraded). Shapes follow the pinned official
// Python SDK fixtures (`claude-agent-sdk-python@3cb0c27eca8caccdc153471a1b19f97fce4ada03`,
// `tests/test_sessions.py` `_make_transcript_entry` / `_parallel_tool_turn`, and
// `_internal/sessions.py` `_build_conversation_chain` / `_recover_orphaned_parallel_tool_results`).
// That pin is reproducibility evidence, not an accepted CLI version or live qualification.
//
// Contract:
// - Exact session only: `<known projects dir>/<project>/<sessionID>.jsonl`. No match = unavailable;
//   more than one distinct file = ambiguous (never chosen by timestamp).
// - Absence is verified, never inferred from a failure: every authorized root must be enumerated
//   (a missing root is genuinely empty) and every listed candidate must report its identity.
//   Anything else is `inspectionFailed`, so a baseline is never `file: nil` because a directory
//   or candidate was unreadable.
// - One descriptor: identity (device, inode, birth time) and bytes come from the same open file.
// - Only complete lines are decoded; an incomplete trailing line waits (an import). A baseline
//   refuses non-whitespace bytes after the last newline (`partialTrailingRecord`): that pre-existing
//   record would otherwise look like a post-baseline entry later. The ENTIRE captured complete
//   candidate is validated before any row, cursor or ledger suppression is produced: an unsupported
//   entry type (including `file-history-snapshot`, `progress`, `system`), an attachment outside the
//   exact whitelist, an operational record carrying graph identity, unsupported content block
//   (`redacted_thinking` included), meaningful metadata (sidechain, meta, compaction, team/agent), a documented
//   retraction marker (`supersedes`, `aborted`, `retracted_message_uuids`), malformed line, session
//   mismatch, conflicting duplicate, missing parent, cycle, ambiguous branch, or ambiguous tool
//   association rejects the whole candidate.
// - Capture-qualified nonrendering nodes (Step 4d2, phase4d-claude-capture O19, CLI 2.1.302): the
//   exact observed `attachment.type` values are graph nodes that are never projected; only their
//   `uuid`/`parentUuid`/`sessionId` structure (and top-level metadata) is read, never their payload.
//   The exact observed operational record types carry no graph identity and are skipped unread
//   (any `uuid`/`parentUuid` key on one refuses). This qualifies a visible projection of that
//   observed shape only, not the native format, other attachment kinds, or activation.
// - Step 4d4 (phase4d-tool-resume-capture O20): one exact `mode` record is skipped as nonprojected
//   metadata only when it is precisely `{type:"mode", mode:"normal", sessionId:<this session>}`;
//   any other key (graph ID keys included, even null), mode value, or session refuses. `mode` is
//   deliberately not an operational type. Successful single-Read tool exchanges across a
//   same-session resume project through the existing tool association unchanged.
// - Owner-profile qualification (9-live round 2, S1; CLI 2.1.302, 200-file structural tally):
//   default-configuration sessions add context-listing attachments (MCP instructions, skills,
//   `CLAUDE.md` instructions, deferred tools, agent listing, remote session, thinking drop) and
//   title/name records (`ai-title`, `custom-title`, `agent-name`); they are accepted exactly like
//   the O19 shapes. Plain `thinking` blocks in ASSISTANT entries are validated (string `thinking`)
//   and skipped: never a row, an ordinal, or part of the envelope digest. A thinking-only entry is a
//   message graph node that projects nothing. `redacted_thinking`, compaction, hooks, file or
//   queued-command attachments, and every unobserved shape still refuse.
// - Attachment-only side branches carry no message and never count as a continuation; a branch
//   whose subtree holds any message still does. A direct chain projects in ancestor order (block
//   ordinals unchanged); a demonstrated tool fork keeps file order.
// - Every row carries its entry's complete-envelope digest. Before any ledger suppression, every
//   ledger-known entry must be present with exactly its observed row keys and the same digest;
//   otherwise the whole candidate refuses (`ledgerConflict`).
// - Byte-prefix fences (Step 4d2): every candidate carries the SHA-256 of its exact captured raw
//   bytes `[0, completeLineOffset)` (opaque integrity, unrelated to the semantic envelope digest).
//   The import boundary and every caller-supplied fence (the attempt's baselines, the latest
//   durably saved import target) are verified against the SAME captured buffer: complete boundary,
//   length at least the offset, exact digest. A missing or malformed proof refuses
//   (`prefixProofUnavailable`); truncation or any different prefix refuses (`rewrittenHistory`),
//   same inode or not. A replaced file is accepted only when every fence verifies byte-for-byte;
//   there is no rewind or ledger-based fallback. No entry before the boundary may descend from one
//   after it (`rewrittenHistory`).
// - Parent links come from `parentUuid` only (never `logicalParentUuid`). Branching is accepted only
//   for the demonstrated parallel-tool shape: an assistant tool-use entry may have one continuation
//   child plus tool-result entries associated to it by `tool_use_id` and `sourceToolAssistantUUID`.
//   Shared API `message.id` only groups parallel calls; it is never an identity or dedup key.
// - Rows are inert data with deterministic identities derived from (provider, native session,
//   native entry UUID, row kind, block ordinal). Native user rows are validated but never
//   projected: `localItemID == nil` means unassociated/not projected, NOT proven RepoPrompt input.
//   The only evidence relating a native user entry to local items is an exact match with the
//   attempt's recorded outbound claims (`userMessageEntries`, matched by
//   `AgentProviderHistoryAssociationPreflight`); live stream output has none, and canonical import
//   refuses rather than assume one.
// - Completion is always unconfirmed: no final answer, stop reason, or EOF proves a turn finished.
// - Import needs a cursor (a baseline or an earlier import): rows are produced only after it.

package enum ClaudeSessionHistoryReader {
    package static let profileName = "nativeEntriesSubsetV2"
    package static let providerRaw = AgentRecoveryHistoryProvider.claude.rawValue
    package static let defaultMaximumBytes = 64 << 20

    // MARK: Values

    package enum RowKind: String, CaseIterable {
        case userText
        case assistantText
        case toolCall
        case toolResult
    }

    /// One validated native row. `localItemID` is `nil` for rows that are never projected.
    package struct Row: Equatable {
        package let nativeEntryID: String
        package let kind: RowKind
        package let ordinal: Int
        package let localItemID: UUID?
        package let text: String?
        package let toolName: String?
        /// Native tool-use ID (shared by a call and its result).
        package let toolUseID: String?
        /// Deterministic local invocation ID pairing a call and its result.
        package let toolInvocationID: UUID?
        package let toolInputJSON: String?
        package let toolIsError: Bool?
        /// The entry's complete-envelope digest (identical for every row of one entry).
        package let envelopeDigest: String
    }

    package enum Completion: Equatable {
        /// This profile never proves completion.
        case unconfirmed
    }

    package struct Candidate: Equatable {
        package let nativeSessionID: String
        /// `nil` when the session file does not exist yet (a baseline before the first turn).
        package let file: AgentRecoveryHistoryFileIdentity?
        package let completeLineOffset: UInt64
        /// Lowercase hex SHA-256 of the exact captured bytes `[0, completeLineOffset)` (the empty
        /// prefix for verified absence). Opaque byte integrity; never the semantic envelope digest.
        package let prefixSHA256: String
        /// New rows in projection order (already deduplicated against the ledger, entry by entry).
        package let rows: [Row]
        /// Transient (Step 4d3a): the WHOLE validated capture's rows in projection order, known and
        /// pre-frontier entries included, before any suppression. Used only to compare canonical
        /// payloads before overlap or deduplication is accepted; never appended or persisted. Empty
        /// for a baseline.
        package let validationRows: [Row]
        /// Native user message entries at or after the import frontier, ledger-known ones included,
        /// in projection order (outbound-claim matching only; never projected). Empty for a baseline.
        package let userMessageEntries: [AgentProviderHistoryNativeUserEntry]
        package let completion: Completion
        /// The boundary's file was replaced by one whose fenced prefix verified byte-for-byte.
        package let isRescan: Bool
    }

    package enum Unavailable: Equatable {
        case invalidSessionID
        case notFound
        case ambiguous(count: Int)
        case unreadable(String)
        case tooLarge
        /// The file changed identity between resolution and capture.
        case unstableFile
        /// A root, project directory, or listed candidate could not be inspected: absence is not
        /// established (never treated as "not written yet").
        case inspectionFailed(String)
        /// A baseline whose captured bytes end in an incomplete record.
        case partialTrailingRecord
        /// No cursor exists yet: a baseline must be recorded before rows can be imported.
        case baselineRequired
    }

    package enum Unsupported: Error, Equatable {
        case malformedLine(line: Int)
        case entryType(String, line: Int)
        case fileHistorySnapshot(line: Int)
        case metadata(String, line: Int)
        case contentBlock(String, line: Int)
        case sessionMismatch(line: Int)
        case conflictingDuplicate(String)
        case missingParent(String)
        case multipleRoots
        case cycle
        case ambiguousBranch(String)
        case toolAssociation(String)
        /// An attachment outside the exact whitelist, or a malformed one. `type` is its `attachment.type`
        /// only when that is a short structural identifier (`[A-Za-z0-9_.-]`, at most 48 characters);
        /// the payload is never named.
        case attachment(type: String?, line: Int)
        /// An operational or exact-metadata record carrying `uuid`/`parentUuid` graph identity.
        case operationalRecord(String, line: Int)
        /// A documented retraction/supersession marker (`supersedes`, `aborted`, `retracted_message_uuids`).
        case semanticMarker(String, line: Int)
        /// A ledger-known entry is missing, or its observed row keys or envelope digest differ.
        case ledgerConflict(String)
        /// A fenced prefix no longer matches (truncated, not on a record boundary, or different
        /// bytes), or the history before the boundary descends from history after it.
        case rewrittenHistory
        /// A fence has no usable byte-prefix proof (legacy or malformed): never trusted.
        case prefixProofUnavailable
    }

    package enum Result: Equatable {
        case candidate(Candidate)
        case unavailable(Unavailable)
        case unsupported(Unsupported)
    }

    package enum Mode: Equatable {
        /// Records the current complete-line boundary (validated) as the import baseline; no rows.
        case baseline
        /// Produces rows after the cursor.
        case importAfter(AgentRecoveryHistoryCursor)
    }

    // MARK: File access (the only injected boundary)

    package struct Capture: Equatable {
        package let identity: AgentRecoveryHistoryFileIdentity
        package let bytes: Data

        package init(identity: AgentRecoveryHistoryFileIdentity, bytes: Data) {
            self.identity = identity
            self.bytes = bytes
        }
    }

    package enum CaptureError: Error, Equatable {
        case unreadable(String)
        case tooLarge
    }

    /// Result of listing the exact candidates under every authorized root.
    package enum CandidateListing: Equatable {
        /// Every root was enumerated; these candidates exist (empty = verified absence).
        case listed([URL])
        /// A root or project directory could not be inspected.
        case inspectionFailed(String)
    }

    package struct FileAccess {
        /// Exact candidate files `<dir>/<project>/<fileName>` under each projects directory.
        package var candidates: @Sendable (_ projectsDirectories: [URL], _ fileName: String) -> CandidateListing
        /// Identity of one candidate (for distinct-file counting), without reading it.
        package var identity: @Sendable (URL) -> AgentRecoveryHistoryFileIdentity?
        /// Opens one file once and captures identity and bytes from that descriptor.
        package var capture: @Sendable (URL, _ maximumBytes: Int) throws -> Capture

        package init(
            candidates: @escaping @Sendable ([URL], String) -> CandidateListing,
            identity: @escaping @Sendable (URL) -> AgentRecoveryHistoryFileIdentity?,
            capture: @escaping @Sendable (URL, Int) throws -> Capture
        ) {
            self.candidates = candidates
            self.identity = identity
            self.capture = capture
        }
    }

    // MARK: Entry point

    /// Reads one exact Claude session's history. Synchronous file I/O: call off the main actor.
    /// Never mutates any session or recovery state.
    /// `fences` are verified against the same captured bytes in addition to the import boundary.
    package static func read(
        nativeSessionID: String,
        projectsDirectories: [URL],
        mode: Mode,
        ledger: AgentSessionProviderHistoryRecovery?,
        fences: [AgentRecoveryHistoryPrefixFence] = [],
        fileAccess: FileAccess = .live,
        maximumBytes: Int = defaultMaximumBytes
    ) -> Result {
        guard let canonical = UUID(uuidString: nativeSessionID), canonical.uuidString.lowercased() == nativeSessionID else {
            return .unavailable(.invalidSessionID)
        }
        guard !projectsDirectories.isEmpty else {
            return .unavailable(.inspectionFailed("no history location"))
        }
        let fileName = "\(nativeSessionID).jsonl"
        let urls: [URL]
        switch fileAccess.candidates(projectsDirectories, fileName) {
        case let .listed(listed):
            urls = listed
        case let .inspectionFailed(reason):
            return .unavailable(.inspectionFailed(reason))
        }
        var distinct: [(URL, AgentRecoveryHistoryFileIdentity)] = []
        for url in urls {
            guard let identity = fileAccess.identity(url) else {
                return .unavailable(.inspectionFailed("a candidate's identity couldn't be read"))
            }
            if !distinct.contains(where: { $0.1.device == identity.device && $0.1.inode == identity.inode }) {
                distinct.append((url, identity))
            }
        }
        if distinct.count > 1 {
            return .unavailable(.ambiguous(count: distinct.count))
        }
        guard let (url, resolvedIdentity) = distinct.first else {
            if case .baseline = mode {
                // Verified absence (every root enumerated, nothing listed): the conversation has
                // not been written yet, so everything later is new. Its prefix is the empty one,
                // and any earlier fence must hold for no bytes at all.
                let prefix: String
                switch verifyFences(fences, bytes: [], completeEnd: 0) {
                case let .success(value):
                    prefix = value
                case let .failure(unsupported):
                    return .unsupported(unsupported)
                }
                return .candidate(Candidate(
                    nativeSessionID: nativeSessionID,
                    file: nil,
                    completeLineOffset: 0,
                    prefixSHA256: prefix,
                    rows: [],
                    validationRows: [],
                    userMessageEntries: [],
                    completion: .unconfirmed,
                    isRescan: false
                ))
            }
            return .unavailable(.notFound)
        }
        let capture: Capture
        do {
            capture = try fileAccess.capture(url, maximumBytes)
        } catch CaptureError.tooLarge {
            return .unavailable(.tooLarge)
        } catch let CaptureError.unreadable(reason) {
            return .unavailable(.unreadable(reason))
        } catch {
            return .unavailable(.unreadable(String(describing: error)))
        }
        guard capture.identity.device == resolvedIdentity.device, capture.identity.inode == resolvedIdentity.inode else {
            return .unavailable(.unstableFile)
        }
        return decode(capture: capture, nativeSessionID: nativeSessionID, mode: mode, ledger: ledger, fences: fences)
    }

    // MARK: Decoder (pure; exercised directly by fixture tests through `read`)

    private enum EntryKind: String {
        case user
        case assistant
        /// A whitelisted nonrendering graph node: no blocks, never projected.
        case attachment
    }

    private struct Entry {
        let line: Int
        let lineStart: Int
        let uuid: String
        let parentUUID: String?
        let kind: EntryKind
        let messageID: String?
        let sourceToolAssistantUUID: String?
        let blocks: [Block]
        /// SHA-256 of a user entry's plain string content, or of the text of content that is exactly
        /// one `{type, text}` block (outbound-claim matching only).
        let userStringContentSHA256: String?
        /// The decoded line, kept in memory only for the duplicate comparison (never persisted,
        /// logged or hashed).
        let raw: NSDictionary

        var isAssistant: Bool {
            kind == .assistant
        }

        var isMessage: Bool {
            kind != .attachment
        }
    }

    private enum Block {
        case text(String)
        case toolUse(id: String, name: String, inputJSON: String)
        case toolResult(toolUseID: String, text: String, isError: Bool?)
    }

    private static let rejectedWhenTrue = ["isSidechain", "isMeta", "isCompactSummary", "isApiErrorMessage", "isVisibleInTranscriptOnly"]
    private static let rejectedWhenPresent = ["logicalParentUuid", "teamName", "agentId", "compactMetadata", "subtype"]
    /// A refused record's type name when it is a short structural identifier, else `nil`, so a
    /// diagnostic never carries free text.
    static func structuralTypeName(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 48,
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) })
        else { return nil }
        return name
    }

    /// Exact `attachment.type` values observed in the O19 capture, plus the context-listing metadata
    /// observed in the owner's default-configuration sessions (S1). Nonrendering graph nodes.
    static let attachmentTypes: Set<String> = [
        "budget_usd", "credential_org", "date", "environment", "model", "prompt_snapshot", "session_context",
        "total_tokens_reminder",
        // S1: what the session can use (MCP instructions, skills, tools, agents), which `CLAUDE.md`
        // files were loaded, the repo/PR metadata, and the thinking-retention report.
        "mcp_instructions_delta", "skill_listing", "instructions", "deferred_tools_delta", "agent_listing_delta",
        "remote_session_change", "thinking_drop"
    ]
    /// Exact operational record types observed in the O19 capture, plus the session title/name
    /// records observed in the owner's sessions (S1). No graph identity, never read.
    static let operationalTypes: Set<String> = [
        "queue-operation", "atis-latch", "api-request-shape", "api-request-blob", "api-request", "last-prompt",
        "cost-state", "ai-title", "custom-title", "agent-name"
    ]
    /// Documented retraction/supersession markers (SDK assistant `supersedes`/`aborted`, refusal
    /// fallback `retracted_message_uuids`), checked only at the entry and `message` levels.
    private static let semanticMarkers = ["supersedes", "aborted", "retracted_message_uuids"]

    static func decode(
        capture: Capture,
        nativeSessionID: String,
        mode: Mode,
        ledger: AgentSessionProviderHistoryRecovery?,
        fences: [AgentRecoveryHistoryPrefixFence] = []
    ) -> Result {
        let bytes = [UInt8](capture.bytes)
        // Complete lines only: everything after the last newline waits.
        let completeEnd = (bytes.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? 0
        if case .baseline = mode,
           bytes[completeEnd...].contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D })
        {
            return .unavailable(.partialTrailingRecord)
        }
        var entries: [Entry] = []
        var byUUID: [String: Int] = [:]
        var lineNumber = 0
        var lineStart = 0
        while lineStart < completeEnd {
            guard let newline = bytes[lineStart ..< completeEnd].firstIndex(of: UInt8(ascii: "\n")) else { break }
            lineNumber += 1
            let lineBytes = bytes[lineStart ..< newline]
            defer { lineStart = newline + 1 }
            if lineBytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                continue
            }
            switch parseEntry(Data(lineBytes), line: lineNumber, lineStart: lineStart, nativeSessionID: nativeSessionID) {
            case let .failure(unsupported):
                return .unsupported(unsupported)
            case .success(nil):
                // An operational or exact mode-metadata record: no graph identity, never projected.
                continue
            case let .success(entry?):
                if let existing = byUUID[entry.uuid] {
                    guard entries[existing].raw.isEqual(entry.raw) else {
                        return .unsupported(.conflictingDuplicate(entry.uuid))
                    }
                    continue
                }
                byUUID[entry.uuid] = entries.count
                entries.append(entry)
            }
        }
        if let failure = validateGraph(entries, byUUID: byUUID) {
            return .unsupported(failure)
        }
        // Byte-prefix fences over the SAME captured buffer (the import boundary included).
        var allFences = fences
        if case let .importAfter(cursor) = mode {
            allFences.insert(cursor.prefixFence, at: 0)
        }
        let prefixSHA256: String
        switch verifyFences(allFences, bytes: bytes, completeEnd: completeEnd) {
        case let .success(value):
            prefixSHA256 = value
        case let .failure(unsupported):
            return .unsupported(unsupported)
        }
        let completeOffset = UInt64(completeEnd)

        // Every parse, graph and fence validation ran above for both modes; only an import projects
        // rows (review B P2-04: a baseline never computes rows it would discard).
        switch mode {
        case .baseline:
            return .candidate(Candidate(
                nativeSessionID: nativeSessionID,
                file: capture.identity,
                completeLineOffset: completeOffset,
                prefixSHA256: prefixSHA256,
                rows: [],
                validationRows: [],
                userMessageEntries: [],
                completion: .unconfirmed,
                isRescan: false
            ))
        case let .importAfter(cursor):
            let order = chainOrder(entries) ?? Array(entries.indices)
            let rows = project(order.map { entries[$0] }, entries: entries, nativeSessionID: nativeSessionID)
            // Complete-envelope proof BEFORE any ledger suppression: a known entry must still exist
            // with exactly its known row keys, every one carrying the observed digest.
            if let conflict = ledgerConflict(rows: rows, ledger: ledger, nativeSessionID: nativeSessionID) {
                return .unsupported(.ledgerConflict(conflict))
            }
            let knownEntryIDs = Set(ledger?.nativeItems.filter {
                $0.providerRaw == providerRaw && $0.nativeSessionID == nativeSessionID
            }.map(\.nativeEntryID) ?? [])
            // The boundary's prefix verified byte-for-byte above, so its offset is exact even in a
            // replaced file (no rewind, no ledger-based resume).
            let rescan = cursor.file.map { $0 != capture.identity } ?? false
            let frontier = Int(cursor.completeLineOffset)
            // History before the frontier never descends from history after it (an in-place
            // rewrite can't move post-boundary output behind the cursor unnoticed).
            for entry in entries where entry.lineStart < frontier {
                if let parentID = entry.parentUUID, let parent = byUUID[parentID], entries[parent].lineStart >= frontier {
                    return .unsupported(.rewrittenHistory)
                }
            }
            let entryStart = Dictionary(uniqueKeysWithValues: entries.map { ($0.uuid, $0.lineStart) })
            func isNew(_ entryID: String) -> Bool {
                (entryStart[entryID] ?? 0) >= frontier
            }
            // Whole entries only: a known entry (proven complete above) contributes no row.
            let newRows = rows.filter { isNew($0.nativeEntryID) && !knownEntryIDs.contains($0.nativeEntryID) }
            let userEntries = order.map { entries[$0] }.filter { entry in
                entry.kind == .user && toolResultIDs(entry).isEmpty && isNew(entry.uuid)
            }.map { AgentProviderHistoryNativeUserEntry(nativeEntryID: $0.uuid, textSHA256: $0.userStringContentSHA256) }
            return .candidate(Candidate(
                nativeSessionID: nativeSessionID,
                file: capture.identity,
                completeLineOffset: completeOffset,
                prefixSHA256: prefixSHA256,
                rows: newRows,
                validationRows: rows,
                userMessageEntries: userEntries,
                completion: .unconfirmed,
                isRescan: rescan
            ))
        }
    }

    /// Verifies every fence against the same captured bytes in one incremental pass and returns the
    /// prefix digest of `[0, completeEnd)`. A fence needs a valid proof, an offset within the
    /// complete lines on a record boundary, and the exact digest of the bytes before it.
    private static func verifyFences(
        _ fences: [AgentRecoveryHistoryPrefixFence],
        bytes: [UInt8],
        completeEnd: Int
    ) -> Swift.Result<String, Unsupported> {
        var offsets: Set<Int> = [completeEnd]
        for fence in fences {
            guard let proof = fence.prefixSHA256, AgentSessionProviderHistoryRecovery.isSHA256Hex(proof) else {
                return .failure(.prefixProofUnavailable)
            }
            guard fence.completeLineOffset <= UInt64(completeEnd) else { return .failure(.rewrittenHistory) }
            let offset = Int(fence.completeLineOffset)
            guard offset == 0 || bytes[offset - 1] == UInt8(ascii: "\n") else { return .failure(.rewrittenHistory) }
            offsets.insert(offset)
        }
        var hasher = SHA256()
        var position = 0
        var digests: [Int: String] = [:]
        for offset in offsets.sorted() {
            bytes[position ..< offset].withUnsafeBytes { hasher.update(bufferPointer: $0) }
            position = offset
            digests[offset] = AgentSessionProviderHistoryRecovery.hex(hasher.finalize())
        }
        for fence in fences where digests[Int(fence.completeLineOffset)] != fence.prefixSHA256 {
            return .failure(.rewrittenHistory)
        }
        return .success(digests[completeEnd] ?? AgentSessionProviderHistoryRecovery.sha256Hex(Data()))
    }

    /// The first ledger-known entry (of this provider and session) that is absent from the
    /// observation, or whose known row keys or envelope digests differ from the observed entry.
    private static func ledgerConflict(
        rows: [Row],
        ledger: AgentSessionProviderHistoryRecovery?,
        nativeSessionID: String
    ) -> String? {
        var observed: [String: (keys: Set<String>, digest: String)] = [:]
        for row in rows {
            observed[row.nativeEntryID, default: ([], row.envelopeDigest)].keys.insert(ledgerKey(row, nativeSessionID: nativeSessionID))
        }
        var knownOrder: [String] = []
        var known: [String: [AgentSessionProviderHistoryRecovery.NativeItem]] = [:]
        for item in ledger?.nativeItems ?? [] where item.providerRaw == providerRaw && item.nativeSessionID == nativeSessionID {
            if known[item.nativeEntryID] == nil { knownOrder.append(item.nativeEntryID) }
            known[item.nativeEntryID, default: []].append(item)
        }
        for entryID in knownOrder {
            let items = known[entryID] ?? []
            guard let entry = observed[entryID],
                  items.count == entry.keys.count,
                  Set(items.map(\.key)) == entry.keys,
                  items.allSatisfy({ $0.envelopeDigest == entry.digest })
            else { return entryID }
        }
        return nil
    }

    /// The ledger key of a row (normalized native row key).
    package static func ledgerKey(_ row: Row, nativeSessionID: String) -> String {
        AgentSessionProviderHistoryRecovery.rowKey(
            providerRaw: providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: row.nativeEntryID,
            rowKindRaw: row.kind.rawValue,
            ordinal: row.ordinal
        )
    }

    /// The first documented retraction marker present in `object` (an explicit `aborted: false` is
    /// not one). Only these exact keys at this level: no recursive search, no unknown-field guess.
    /// Also applied to live stdout envelopes (Step 4d3b `ClaudeLiveTranscriptProducerState`).
    static func semanticMarker(in object: NSDictionary) -> String? {
        for key in semanticMarkers {
            switch object[key] {
            case nil, is NSNull:
                continue
            case let flag as Bool where key == "aborted" && !flag:
                continue
            default:
                return key
            }
        }
        return nil
    }

    /// Step 4d4 (phase4d-tool-resume-capture O20, CLI 2.1.302): the single exact observed `mode`
    /// record is nonprojected metadata, NOT a generic operational type. Its whole shape is checked:
    /// no `uuid`/`parentUuid` key (even null), `sessionId` exactly this session, no other key, and
    /// `mode == "normal"`. Anything else refuses with the existing typed cases.
    private static func parseModeRecord(
        _ object: NSDictionary,
        line: Int,
        nativeSessionID: String
    ) -> Swift.Result<Entry?, Unsupported> {
        guard object["uuid"] == nil, object["parentUuid"] == nil else {
            return .failure(.operationalRecord("mode", line: line))
        }
        guard (object["sessionId"] as? String) == nativeSessionID else {
            return .failure(.sessionMismatch(line: line))
        }
        let allowed = ["type", "mode", "sessionId"]
        let keys = object.allKeys.map { "\($0)" }
        if let extra = keys.filter({ !allowed.contains($0) }).sorted().first {
            return .failure(.metadata(extra, line: line))
        }
        guard (object["mode"] as? String) == "normal" else {
            return .failure(.metadata("mode", line: line))
        }
        return .success(nil)
    }

    /// `nil` = an operational or exact mode-metadata record (no graph identity, never projected).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parseEntry(
        _ data: Data,
        line: Int,
        lineStart: Int,
        nativeSessionID: String
    ) -> Swift.Result<Entry?, Unsupported> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            return .failure(.malformedLine(line: line))
        }
        guard let type = object["type"] as? String else {
            return .failure(.malformedLine(line: line))
        }
        let kind: EntryKind
        switch type {
        case "user":
            kind = .user
        case "assistant":
            kind = .assistant
        case "attachment":
            kind = .attachment
        case "file-history-snapshot":
            return .failure(.fileHistorySnapshot(line: line))
        case "mode":
            return parseModeRecord(object, line: line, nativeSessionID: nativeSessionID)
        case _ where operationalTypes.contains(type):
            // Never a graph node: any `uuid`/`parentUuid` key (even null) refuses; a present
            // `sessionId` must be this session. Nothing else in it is read.
            guard object["uuid"] == nil, object["parentUuid"] == nil else {
                return .failure(.operationalRecord(type, line: line))
            }
            if let session = object["sessionId"], (session as? String) != nativeSessionID {
                return .failure(.sessionMismatch(line: line))
            }
            return .success(nil)
        default:
            return .failure(.entryType(type, line: line))
        }
        for key in rejectedWhenTrue where (object[key] as? Bool) == true {
            return .failure(.metadata(key, line: line))
        }
        for key in rejectedWhenPresent where object[key] != nil && !(object[key] is NSNull) {
            return .failure(.metadata(key, line: line))
        }
        if let marker = semanticMarker(in: object) {
            return .failure(.semanticMarker(marker, line: line))
        }
        guard let uuid = object["uuid"] as? String, !uuid.isEmpty else {
            return .failure(.malformedLine(line: line))
        }
        let parentUUID: String?
        switch object["parentUuid"] {
        case nil, is NSNull:
            parentUUID = nil
        case let value as String where !value.isEmpty:
            parentUUID = value
        default:
            return .failure(.malformedLine(line: line))
        }
        guard (object["sessionId"] as? String) == nativeSessionID else {
            return .failure(.sessionMismatch(line: line))
        }
        let source: String?
        switch object["sourceToolAssistantUUID"] {
        case nil, is NSNull: source = nil
        case let value as String: source = value
        default: return .failure(.malformedLine(line: line))
        }
        if kind == .attachment {
            // Only the exact whitelisted `attachment.type` is read; the payload never is.
            guard object["message"] == nil, source == nil,
                  let attachment = object["attachment"] as? NSDictionary,
                  let attachmentType = attachment["type"] as? String,
                  attachmentTypes.contains(attachmentType)
            else {
                let type = (object["attachment"] as? NSDictionary)?["type"] as? String
                return .failure(.attachment(type: type.flatMap(Self.structuralTypeName), line: line))
            }
            return .success(Entry(
                line: line,
                lineStart: lineStart,
                uuid: uuid,
                parentUUID: parentUUID,
                kind: .attachment,
                messageID: nil,
                sourceToolAssistantUUID: nil,
                blocks: [],
                userStringContentSHA256: nil,
                raw: object
            ))
        }
        guard let message = object["message"] as? NSDictionary, (message["role"] as? String) == type else {
            return .failure(.malformedLine(line: line))
        }
        if let marker = semanticMarker(in: message) {
            return .failure(.semanticMarker(marker, line: line))
        }
        let isAssistant = kind == .assistant
        var blocks: [Block] = []
        var stringContentSHA256: String?
        switch message["content"] {
        case let text as String:
            blocks = [.text(text)]
            if !isAssistant {
                stringContentSHA256 = AgentSessionProviderHistoryRecovery.sha256Hex(Data(text.utf8))
            }
        case let array as [Any]:
            for element in array {
                guard let block = element as? NSDictionary, let blockType = block["type"] as? String else {
                    return .failure(.malformedLine(line: line))
                }
                switch (blockType, isAssistant) {
                case ("text", _):
                    guard let text = block["text"] as? String else { return .failure(.malformedLine(line: line)) }
                    blocks.append(.text(text))
                case ("thinking", true):
                    // S1: assistant reasoning is validated and skipped (no row, ordinal or digest).
                    guard block["thinking"] is String else { return .failure(.malformedLine(line: line)) }
                case ("tool_use", true):
                    guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String,
                          let input = block["input"] as? NSDictionary,
                          let inputJSON = canonicalToolInputJSON(input)
                    else { return .failure(.malformedLine(line: line)) }
                    blocks.append(.toolUse(id: id, name: name, inputJSON: inputJSON))
                case ("tool_result", false):
                    guard let toolUseID = block["tool_use_id"] as? String, !toolUseID.isEmpty else {
                        return .failure(.malformedLine(line: line))
                    }
                    let text: String
                    switch block["content"] {
                    case let value as String:
                        text = value
                    case let parts as [Any]:
                        var collected: [String] = []
                        for part in parts {
                            guard let part = part as? NSDictionary, (part["type"] as? String) == "text",
                                  let partText = part["text"] as? String
                            else {
                                return .failure(.contentBlock("tool_result.content", line: line))
                            }
                            collected.append(partText)
                        }
                        text = collected.joined(separator: "\n")
                    case nil:
                        text = ""
                    default:
                        return .failure(.malformedLine(line: line))
                    }
                    let isError: Bool?
                    switch block["is_error"] {
                    case nil, is NSNull: isError = nil
                    case let value as Bool: isError = value
                    default: return .failure(.malformedLine(line: line))
                    }
                    blocks.append(.toolResult(toolUseID: toolUseID, text: text, isError: isError))
                default:
                    return .failure(.contentBlock(blockType, line: line))
                }
            }
        default:
            return .failure(.malformedLine(line: line))
        }
        // S1 round 0: the CLI writes RepoPrompt's outbound message as exactly one `{type, text}` block,
        // so that form carries the claim digest too (any other array never matches a claim).
        if !isAssistant, let array = message["content"] as? [Any], array.count == 1,
           let block = array.first as? NSDictionary, Set(block.allKeys.compactMap { $0 as? String }) == ["type", "text"],
           block.count == 2, (block["type"] as? String) == "text", let text = block["text"] as? String
        {
            stringContentSHA256 = AgentSessionProviderHistoryRecovery.sha256Hex(Data(text.utf8))
        }
        if !isAssistant, source != nil, !blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) {
            return .failure(.toolAssociation("source without tool result at line \(line)"))
        }
        return .success(Entry(
            line: line,
            lineStart: lineStart,
            uuid: uuid,
            parentUUID: parentUUID,
            kind: kind,
            messageID: isAssistant ? (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
            sourceToolAssistantUUID: source,
            blocks: blocks,
            userStringContentSHA256: stringContentSHA256,
            raw: object
        ))
    }

    private static func toolUseIDs(_ entry: Entry) -> [String] {
        entry.blocks.compactMap { if case let .toolUse(id, _, _) = $0 { id } else { nil } }
    }

    private static func toolResultIDs(_ entry: Entry) -> [String] {
        entry.blocks.compactMap { if case let .toolResult(id, _, _) = $0 { id } else { nil } }
    }

    /// Whether `child` is a tool-result entry associated to `parent` (demonstrated relationship:
    /// the result's parent is its call entry, its `tool_use_id` names a call in that entry, and its
    /// `sourceToolAssistantUUID`, when present, is that entry).
    private static func isAssociatedResult(_ child: Entry, of parent: Entry) -> Bool {
        guard !child.isAssistant, parent.isAssistant else { return false }
        let results = toolResultIDs(child)
        guard !results.isEmpty, results.count == child.blocks.count else { return false }
        let calls = Set(toolUseIDs(parent))
        return results.allSatisfy(calls.contains) && (child.sourceToolAssistantUUID ?? parent.uuid) == parent.uuid
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func validateGraph(_ entries: [Entry], byUUID: [String: Int]) -> Unsupported? {
        var children: [String: [Int]] = [:]
        var roots: [Int] = []
        for (index, entry) in entries.enumerated() {
            if let parent = entry.parentUUID {
                guard byUUID[parent] != nil else { return .missingParent(entry.uuid) }
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        guard entries.isEmpty || roots.count == 1 else { return .multipleRoots }
        // Reachability from the single root (a cycle leaves entries unreachable).
        var preorder: [Int] = []
        var stack = roots
        var visited = Set<Int>()
        while let next = stack.popLast() {
            guard visited.insert(next).inserted else { return .cycle }
            preorder.append(next)
            stack.append(contentsOf: children[entries[next].uuid] ?? [])
        }
        guard preorder.count == entries.count else { return .cycle }
        let bearing = messageBearing(entries, preorder: preorder, children: children)

        // Tool results: every result names a call of its parent entry exactly once overall.
        var resolvedToolUseIDs: Set<String> = []
        for entry in entries where entry.kind == .user {
            let results = toolResultIDs(entry)
            guard !results.isEmpty else { continue }
            guard results.count == entry.blocks.count else {
                return .toolAssociation("mixed tool result entry \(entry.uuid)")
            }
            guard let parentID = entry.parentUUID, let parentIndex = byUUID[parentID],
                  isAssociatedResult(entry, of: entries[parentIndex])
            else {
                return .toolAssociation("unassociated tool result \(entry.uuid)")
            }
            for id in results {
                guard resolvedToolUseIDs.insert(id).inserted else {
                    return .toolAssociation("tool use \(id) resolved more than once")
                }
            }
        }
        // Tool-use IDs are unique across calls.
        var callIDs: Set<String> = []
        for entry in entries where entry.isAssistant {
            for id in toolUseIDs(entry) {
                guard callIDs.insert(id).inserted else { return .toolAssociation("duplicate tool use \(id)") }
            }
        }

        // Branching: at most one non-associated (continuation) child per entry. An attachment-only
        // side branch (no message anywhere below it) is not a continuation; any message is.
        var forkLeaves: Set<Int> = []
        for (parentID, childIndexes) in children {
            guard let parentIndex = byUUID[parentID] else { continue }
            let parent = entries[parentIndex]
            let associated = childIndexes.filter { isAssociatedResult(entries[$0], of: parent) }
            let continuations = childIndexes.filter { bearing[$0] && !associated.contains($0) }
            guard continuations.count <= 1 else { return .ambiguousBranch(parentID) }
            // A forked associated result must name its source explicitly (demonstrated shape). Only
            // message-bearing children make a fork: an attachment-only sibling never turns a
            // sequential result into a parallel one (review A R2).
            if childIndexes.count(where: { bearing[$0] }) > 1 {
                for index in associated where entries[index].sourceToolAssistantUUID == nil {
                    return .toolAssociation("forked tool result without source \(entries[index].uuid)")
                }
            }
            forkLeaves.formUnion(associated)
        }
        // Leaves: exactly one conversation tip, plus tool-result leaves of a parallel call group
        // (assistant tool-use entries sharing a non-empty API message ID and chained by parent).
        // A tip is a message with no message below it (a trailing attachment is not a tip).
        var tips = 0
        var groupLeaves = 0
        for (index, entry) in entries.enumerated()
            where entry.isMessage && !(children[entry.uuid] ?? []).contains(where: { bearing[$0] })
        {
            if forkLeaves.contains(index), let parentID = entry.parentUUID, let parentIndex = byUUID[parentID],
               isInParallelGroup(entries[parentIndex], entries: entries, byUUID: byUUID, children: children)
            {
                groupLeaves += 1
                continue
            }
            tips += 1
        }
        // A conversation whose last turn is a parallel tool group (no continuation yet, e.g. an
        // interrupted run) ends on those group results only.
        guard !entries.contains(where: \.isMessage) || tips == 1 || (tips == 0 && groupLeaves > 0) else {
            return .ambiguousBranch("conversation has \(tips) tips")
        }
        return nil
    }

    /// Whether each entry is a message or has one below it (children first: reversed preorder).
    private static func messageBearing(_ entries: [Entry], preorder: [Int], children: [String: [Int]]) -> [Bool] {
        var bearing = entries.map(\.isMessage)
        for index in preorder.reversed() where !bearing[index] {
            bearing[index] = (children[entries[index].uuid] ?? []).contains { bearing[$0] }
        }
        return bearing
    }

    /// Ancestor order of a direct chain: from the single root, each entry's only message-bearing
    /// child (attachment-only side branches skipped; they project nothing). `nil` when any entry has
    /// more than one message-bearing child (a demonstrated tool fork), which keeps file order.
    /// Called only on a validated graph.
    private static func chainOrder(_ entries: [Entry]) -> [Int]? {
        var children: [String: [Int]] = [:]
        var root: Int?
        for (index, entry) in entries.enumerated() {
            if let parent = entry.parentUUID {
                children[parent, default: []].append(index)
            } else {
                root = index
            }
        }
        guard let root else { return entries.isEmpty ? [] : nil }
        var preorder: [Int] = []
        var stack = [root]
        while let next = stack.popLast() {
            preorder.append(next)
            stack.append(contentsOf: children[entries[next].uuid] ?? [])
        }
        let bearing = messageBearing(entries, preorder: preorder, children: children)
        var order: [Int] = []
        var current: Int? = root
        while let index = current {
            order.append(index)
            let next = (children[entries[index].uuid] ?? []).filter { bearing[$0] }
            guard next.count <= 1 else { return nil }
            current = next.first
        }
        return order
    }

    private static func isInParallelGroup(
        _ call: Entry,
        entries: [Entry],
        byUUID: [String: Int],
        children: [String: [Int]]
    ) -> Bool {
        guard let messageID = call.messageID, !toolUseIDs(call).isEmpty else { return false }
        if let parentID = call.parentUUID, let parentIndex = byUUID[parentID],
           entries[parentIndex].messageID == messageID, !toolUseIDs(entries[parentIndex]).isEmpty
        {
            return true
        }
        return (children[call.uuid] ?? []).contains { index in
            entries[index].messageID == messageID && !toolUseIDs(entries[index]).isEmpty
        }
    }

    /// Complete-envelope digest of one entry: SHA-256 over the length-prefixed ordered supported
    /// semantic payload (entry type, block count, then per block its kind, ordinal and text / tool
    /// name, use ID and canonical input / tool use ID, result text and error flag). No metadata and
    /// no skipped `thinking` block.
    private static func envelopeDigest(_ entry: Entry) -> String {
        var components = ["rpce-claude-history-envelope-v1", entry.kind.rawValue, String(entry.blocks.count)]
        for (ordinal, block) in entry.blocks.enumerated() {
            switch block {
            case let .text(text):
                components += ["text", String(ordinal), text]
            case let .toolUse(id, name, inputJSON):
                components += ["tool_use", String(ordinal), name, id, inputJSON]
            case let .toolResult(toolUseID, text, isError):
                components += ["tool_result", String(ordinal), toolUseID, text, isError.map { $0 ? "true" : "false" } ?? "none"]
            }
        }
        let encoded = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return AgentSessionProviderHistoryRecovery.sha256Hex(Data(encoded.utf8))
    }

    /// Rows of `projected` (projection order); `entries` (all) only names tool calls.
    private static func project(_ projected: [Entry], entries: [Entry], nativeSessionID: String) -> [Row] {
        var toolNames: [String: String] = [:]
        for entry in entries {
            for block in entry.blocks {
                if case let .toolUse(id, name, _) = block { toolNames[id] = name }
            }
        }
        var rows: [Row] = []
        for entry in projected where !entry.blocks.isEmpty {
            let digest = envelopeDigest(entry)
            for (ordinal, block) in entry.blocks.enumerated() {
                func localID(_ kind: RowKind) -> UUID {
                    deterministicUUID(
                        namespace: "rpce-claude-history-row-v1",
                        components: [providerRaw, nativeSessionID, entry.uuid, kind.rawValue, String(ordinal)]
                    )
                }
                func invocationID(_ toolUseID: String) -> UUID {
                    deterministicUUID(namespace: "rpce-claude-history-tool-v1", components: [providerRaw, nativeSessionID, toolUseID])
                }
                switch block {
                case let .text(text):
                    let kind: RowKind = entry.isAssistant ? .assistantText : .userText
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: kind,
                        ordinal: ordinal,
                        localItemID: entry.isAssistant ? localID(kind) : nil,
                        text: text,
                        toolName: nil,
                        toolUseID: nil,
                        toolInvocationID: nil,
                        toolInputJSON: nil,
                        toolIsError: nil,
                        envelopeDigest: digest
                    ))
                case let .toolUse(id, name, inputJSON):
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: .toolCall,
                        ordinal: ordinal,
                        localItemID: localID(.toolCall),
                        text: nil,
                        toolName: name,
                        toolUseID: id,
                        toolInvocationID: invocationID(id),
                        toolInputJSON: inputJSON,
                        toolIsError: nil,
                        envelopeDigest: digest
                    ))
                case let .toolResult(toolUseID, text, isError):
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: .toolResult,
                        ordinal: ordinal,
                        localItemID: localID(.toolResult),
                        text: text,
                        toolName: toolNames[toolUseID],
                        toolUseID: toolUseID,
                        toolInvocationID: invocationID(toolUseID),
                        toolInputJSON: nil,
                        toolIsError: isError,
                        envelopeDigest: digest
                    ))
                }
            }
        }
        return rows
    }

    /// Step 4d3b: the row a native assistant entry holding exactly one text block `text` projects to,
    /// with its deterministic local ID and complete-envelope digest. Same `project`/`envelopeDigest`
    /// derivation as a read, so a live row's identity and proof are exactly those its native entry
    /// must later match. `nil` only for an empty projection (never for one block).
    package static func singleTextAssistantRow(nativeSessionID: String, nativeEntryID: String, text: String) -> Row? {
        let entry = Entry(
            line: 0,
            lineStart: 0,
            uuid: nativeEntryID,
            parentUUID: nil,
            kind: .assistant,
            messageID: nil,
            sourceToolAssistantUUID: nil,
            blocks: [.text(text)],
            userStringContentSHA256: nil,
            raw: NSDictionary()
        )
        return project([entry], entries: [entry], nativeSessionID: nativeSessionID).first
    }

    /// The one canonical serialization of a native `tool_use.input` (compact, sorted keys): the
    /// reader's row payload and every live Read call's identity input (Step 4d5) use it, never the
    /// translator's pretty-printed arguments.
    package static func canonicalToolInputJSON(_ input: NSDictionary) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Step 4d5: the row a native assistant entry holding exactly one `tool_use` block projects to
    /// (`inputJSON` already canonical), with its deterministic local and invocation IDs and its
    /// complete-envelope digest. Same `project`/`envelopeDigest` derivation as a read.
    package static func singleToolUseRow(
        nativeSessionID: String,
        nativeEntryID: String,
        toolUseID: String,
        name: String,
        inputJSON: String
    ) -> Row? {
        let entry = syntheticEntry(nativeEntryID, kind: .assistant, block: .toolUse(id: toolUseID, name: name, inputJSON: inputJSON))
        return project([entry], entries: [entry], nativeSessionID: nativeSessionID).first
    }

    /// Step 4d5: the row a native user entry holding exactly one `tool_result` block (string
    /// content, `is_error` absent) projects to. `toolName` is supplied by the matching call exactly
    /// as a read resolves it; the call entry only names it and is never projected here.
    package static func singleToolResultRow(
        nativeSessionID: String,
        nativeEntryID: String,
        toolUseID: String,
        toolName: String,
        text: String
    ) -> Row? {
        let entry = syntheticEntry(nativeEntryID, kind: .user, block: .toolResult(toolUseID: toolUseID, text: text, isError: nil))
        let naming = syntheticEntry("", kind: .assistant, block: .toolUse(id: toolUseID, name: toolName, inputJSON: "{}"))
        return project([entry], entries: [naming, entry], nativeSessionID: nativeSessionID).first
    }

    private static func syntheticEntry(_ uuid: String, kind: EntryKind, block: Block) -> Entry {
        Entry(
            line: 0,
            lineStart: 0,
            uuid: uuid,
            parentUUID: nil,
            kind: kind,
            messageID: nil,
            sourceToolAssistantUUID: nil,
            blocks: [block],
            userStringContentSHA256: nil,
            raw: NSDictionary()
        )
    }

    /// Fixed, documented derivation (not Swift's randomized `Hasher`): SHA-256 over the namespace and
    /// the length-prefixed components, first 16 bytes, with RFC 9562 version 8 and variant bits.
    package static func deterministicUUID(namespace: String, components: [String]) -> UUID {
        let encoded = ([namespace] + components).map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        var digest = Array(SHA256.hash(data: Data(encoded.utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x80
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

// MARK: - Live file access

package extension ClaudeSessionHistoryReader.FileAccess {
    static let live = ClaudeSessionHistoryReader.FileAccess(
        candidates: { directories, fileName in
            var urls: [URL] = []
            let manager = FileManager.default
            for directory in directories {
                let projects: [URL]
                do {
                    projects = try manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // A missing projects root holds no conversation (genuine absence).
                    continue
                } catch {
                    return .inspectionFailed("a history directory couldn't be listed")
                }
                for project in projects {
                    let candidate = project.appendingPathComponent(fileName, isDirectory: false)
                    var info = stat()
                    if lstat(candidate.path, &info) == 0 {
                        // Any entry is listed; its identity decides (a non-regular file fails).
                        urls.append(candidate)
                    } else if errno == ENOENT || errno == ENOTDIR {
                        continue
                    } else {
                        return .inspectionFailed("a history candidate couldn't be inspected (\(errno))")
                    }
                }
            }
            return .listed(urls)
        },
        identity: { url in
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return ClaudeSessionHistoryReader.fileIdentity(info)
        },
        capture: { url, maximumBytes in
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ClaudeSessionHistoryReader.CaptureError.unreadable("open failed (\(errno))")
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw ClaudeSessionHistoryReader.CaptureError.unreadable("not a regular file")
            }
            // A finite boundary: the size at capture time. Bytes appended later are a later import.
            let size = Int(info.st_size)
            guard size <= maximumBytes else { throw ClaudeSessionHistoryReader.CaptureError.tooLarge }
            var bytes = [UInt8](repeating: 0, count: size)
            var filled = 0
            while filled < size {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress!.advanced(by: filled), size - filled)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ClaudeSessionHistoryReader.CaptureError.unreadable("read failed (\(errno))")
                }
                if count == 0 { break }
                filled += count
            }
            return ClaudeSessionHistoryReader.Capture(
                identity: ClaudeSessionHistoryReader.fileIdentity(info),
                bytes: Data(bytes.prefix(filled))
            )
        }
    )
}

extension ClaudeSessionHistoryReader {
    static func fileIdentity(_ info: stat) -> AgentRecoveryHistoryFileIdentity {
        AgentRecoveryHistoryFileIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }
}
