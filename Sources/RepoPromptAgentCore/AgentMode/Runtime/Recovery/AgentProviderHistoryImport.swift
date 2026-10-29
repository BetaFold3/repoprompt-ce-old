import Foundation

// History-only reconciliation planning (lossless restart Phase 4, phase4-plan "History ledger" and
// "Exact transaction boundary"). Pure value transforms: a validated provider candidate plus the
// session's current transcript and ledger produce exactly one import plan:
//
//   1. inert transcript rows to append (never live stream results, never dispatched input),
//   2. the updated native-ID ledger and its import receipt (`ImportCommit`), committed with the rows
//      in ONE session save (`AgentSessionDataService.commitProviderHistoryImport`),
//   3. the recovery cursor, advanced afterwards by compare-and-swap on the previous import ID.
//
// A crash between (2) and (3) leaves the rows and ledger committed; the next import's ledger dedup
// makes the replay a no-op. Rows already known to the ledger, or whose deterministic local ID is
// already in the transcript, are never appended again.
//
// Before planning a provider import into a live conversation, `AgentProviderHistoryAssociationPreflight`
// requires the interrupted dispatch's own pre-send baseline AND explicit associations between the
// native rows and the canonical transcript. The planner deduplicates only its own ledger and
// deterministic IDs; it cannot recognise live rows persisted under unrelated IDs, so importing
// without association evidence could duplicate or misattribute them.

/// One validated native row in provider-neutral form.
package struct AgentProviderHistoryRow: Equatable {
    package let nativeSessionID: String
    package let nativeEntryID: String
    package let rowKindRaw: String
    package let ordinal: Int
    /// The inert transcript item this row projects to (`nil` = recorded in the ledger only).
    package let item: AgentChatItem?
    /// The native entry's complete-envelope digest, recorded with the ledger row (`nil` = none, Codex).
    package let envelopeDigest: String?

    package init(
        nativeSessionID: String,
        nativeEntryID: String,
        rowKindRaw: String,
        ordinal: Int,
        item: AgentChatItem?,
        envelopeDigest: String? = nil
    ) {
        self.nativeSessionID = nativeSessionID
        self.nativeEntryID = nativeEntryID
        self.rowKindRaw = rowKindRaw
        self.ordinal = ordinal
        self.item = item
        self.envelopeDigest = envelopeDigest
    }
}

/// A native user message entry observed after the import frontier (Claude). Matched only against
/// recorded outbound claims; never projected.
package struct AgentProviderHistoryNativeUserEntry: Equatable {
    package let nativeEntryID: String
    /// Lowercase hex SHA-256 of the entry's plain string content (`nil` for any other content).
    package let textSHA256: String?

    package init(nativeEntryID: String, textSHA256: String?) {
        self.nativeEntryID = nativeEntryID
        self.textSHA256 = textSHA256
    }
}

/// A complete, validated provider observation ready to plan (built only from a whole validated
/// candidate; partial or unsupported candidates never reach this type).
package struct AgentProviderHistoryObservation: Equatable {
    package let provider: AgentRecoveryHistoryProvider
    package let conversationID: String
    package let rows: [AgentProviderHistoryRow]
    /// Transient (Step 4d3a): the whole validated projection in provider order, ledger-known and
    /// pre-frontier rows included (defaults to `rows`). Read only by the canonical payload check
    /// before overlap or deduplication is accepted; never appended, recorded or persisted.
    package let validationRows: [AgentProviderHistoryRow]
    package let file: AgentRecoveryHistoryFileIdentity?
    package let completeLineOffset: UInt64
    /// Byte-prefix proof of the observed `[0, completeLineOffset)` (Claude; `nil` for Codex).
    package let prefixSHA256: String?
    /// Whether the provider proved the expected turn finished (Claude: never).
    package let completionConfirmed: Bool
    /// Every native user message entry after the attempt's boundary, ledger-known ones included,
    /// in projection order (Claude outbound-claim matching; empty for Codex).
    package let nativeUserEntries: [AgentProviderHistoryNativeUserEntry]
    /// Transient (Step 4d5): local item IDs of `validationRows` that are a singleton O20 Read exchange
    /// (see `ClaudeSessionHistoryReader.storageComparableReadItemIDs`), the only rows whose stored
    /// projection the payload check may compare. Empty by default; never appended or persisted.
    package let storageComparableReadItemIDs: Set<UUID>

    package init(
        provider: AgentRecoveryHistoryProvider,
        conversationID: String,
        rows: [AgentProviderHistoryRow],
        validationRows: [AgentProviderHistoryRow]? = nil,
        file: AgentRecoveryHistoryFileIdentity?,
        completeLineOffset: UInt64,
        prefixSHA256: String? = nil,
        completionConfirmed: Bool,
        nativeUserEntries: [AgentProviderHistoryNativeUserEntry] = [],
        storageComparableReadItemIDs: Set<UUID> = []
    ) {
        self.provider = provider
        self.conversationID = conversationID
        self.rows = rows
        self.validationRows = validationRows ?? rows
        self.file = file
        self.completeLineOffset = completeLineOffset
        self.prefixSHA256 = prefixSHA256
        self.completionConfirmed = completionConfirmed
        self.nativeUserEntries = nativeUserEntries
        self.storageComparableReadItemIDs = storageComparableReadItemIDs
    }
}

package struct AgentProviderHistoryImportPlan: Equatable {
    package let importID: UUID
    package let previousImportID: UUID?
    /// New inert transcript items, in provider order (labelled by a leading system row when non-empty).
    package let appendedItems: [AgentChatItem]
    package let ledger: AgentSessionProviderHistoryRecovery
    package let importCommit: AgentSessionProviderHistoryRecovery.ImportCommit
    package let cursor: AgentRecoveryHistoryCursor
    package let completionConfirmed: Bool

    package var outcome: AgentRecoveryActionOutcomeKind {
        completionConfirmed ? .importedCompleted : .importedUnconfirmed
    }
}

package enum AgentProviderHistoryImportPlanner {
    package static let recoveredLabel = "Recovered from provider history after restart (completion unconfirmed)."
    package static let recoveredCompletedLabel = "Recovered from provider history after restart."

    /// Plans one import. `previousCursor` is the recovery record's current cursor for this
    /// conversation (its import ID is the CAS expectation).
    package static func plan(
        observation: AgentProviderHistoryObservation,
        existingItemIDs: Set<UUID>,
        ledger: AgentSessionProviderHistoryRecovery?,
        previousCursor: AgentRecoveryHistoryCursor?,
        importID: UUID,
        now: Date
    ) -> AgentProviderHistoryImportPlan {
        var ledger = ledger ?? AgentSessionProviderHistoryRecovery()
        var knownKeys = Set(ledger.nativeItems.map(\.key))
        var seenIDs = existingItemIDs
        var appended: [AgentChatItem] = []
        for row in observation.rows {
            let key = AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: observation.provider.rawValue,
                nativeSessionID: row.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.rowKindRaw,
                ordinal: row.ordinal
            )
            guard knownKeys.insert(key).inserted else { continue }
            var localItemID: UUID?
            if let item = row.item, seenIDs.insert(item.id).inserted {
                appended.append(item)
                localItemID = item.id
            } else if let item = row.item {
                // Already in the transcript under its deterministic ID: record, do not duplicate.
                localItemID = item.id
            }
            ledger.nativeItems.append(AgentSessionProviderHistoryRecovery.NativeItem(
                providerRaw: observation.provider.rawValue,
                nativeSessionID: row.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.rowKindRaw,
                ordinal: row.ordinal,
                localItemID: localItemID,
                envelopeDigest: row.envelopeDigest
            ))
        }
        if !appended.isEmpty {
            let label = AgentChatItem.system(
                observation.completionConfirmed ? recoveredCompletedLabel : recoveredLabel
            ).replacingID(ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "rpce-history-import-label-v1",
                components: [observation.provider.rawValue, observation.conversationID, importID.uuidString.lowercased()]
            ))
            appended.insert(label, at: 0)
        }
        // The receipt binds the exact target it was read from (same save as rows and ledger), so a
        // lost cursor CAS never loses the latest accepted prefix. Codex has none.
        let target = observation.prefixSHA256.map {
            AgentRecoveryHistoryPrefixFence(file: observation.file, completeLineOffset: observation.completeLineOffset, prefixSHA256: $0)
        }
        let commit = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: importID,
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            committedAt: now,
            rowCount: appended.count,
            target: target
        )
        ledger.lastImportCommit = commit
        let cursor = AgentRecoveryHistoryCursor(
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            importID: importID,
            file: observation.file,
            completeLineOffset: observation.completeLineOffset,
            prefixSHA256: observation.prefixSHA256,
            committedAt: AgentRecoveryTimestamp(now)
        )
        return AgentProviderHistoryImportPlan(
            importID: importID,
            previousImportID: previousCursor?.importID,
            appendedItems: appended,
            ledger: ledger,
            importCommit: commit,
            cursor: cursor,
            completionConfirmed: observation.completionConfirmed
        )
    }
}

// MARK: - Association preflight

/// Typed refusal of a canonical history import (lossless restart Phase 4). Zero transcript changes
/// and no cursor movement follow any refusal.
package enum AgentProviderHistoryAssociationRefusal: Equatable {
    /// The interrupted attempt has no captured pre-send baseline (none, unsupported, or unreadable).
    case baselineUnavailable
    /// The baseline belongs to another conversation, transcript generation, or attempt, or its
    /// dispatch's user items are not in this transcript.
    case baselineTargetMismatch
    /// A native user entry after the baseline has no explicit association to a local user item.
    case nativeUserAssociationUnavailable
    /// Canonical provider output after the dispatch is not explicitly associated to native rows
    /// (or cannot be enumerated because it was compacted).
    case canonicalOutputAssociationUnavailable
    /// 9-live r3 T1 (option B): every check passed and the attempt's outbound claims matched Claude's
    /// user entries exactly; only some enumerable canonical output after the dispatch (live output
    /// saved under its own IDs, such as a Bash call) has no association to native rows. The import is
    /// withheld in full (no row, ledger or cursor change); unlike the other cases a continuation may
    /// follow, because the exact claims rule out an unknown or replayed user message.
    case canonicalOutputImportWithheld
    /// The attempt's recorded outbound claims and the native user entries after its boundary do not
    /// match exactly (a claimed entry missing, an unclaimed or reordered entry, a text digest
    /// mismatch, duplicate claims, or constituents not in this transcript). A claim never proves a
    /// write, so a missing entry is never read as non-delivery.
    case outboundClaimUnmatched
    /// A ledger-mapped or already-present local row's canonical payload can't be compared (Step
    /// 4d3a): missing, ambiguous, in a compacted or summary-only turn or tool execution, or with an
    /// unavailable tool payload.
    case canonicalPayloadUnavailable
    /// A ledger-mapped or already-present local row's canonical payload differs from the provider's
    /// (text, kind or tool fields), or such rows appear in a different relative order (Step 4d3a).
    case canonicalPayloadMismatch
}

/// The canonical transcript an import would merge into: the persisted turns (including compacted
/// ones) plus the session's mutable working suffix.
package struct AgentProviderHistoryCanonicalView {
    package let transcript: AgentTranscript
    package let suffixItems: [AgentChatItem]

    package init(transcript: AgentTranscript, suffixItems: [AgentChatItem]) {
        self.transcript = transcript
        self.suffixItems = suffixItems
    }
}

package enum AgentProviderHistoryAssociationPreflight {
    static let outputKinds: Set<AgentChatItemKind> = [.assistant, .assistantInline, .toolCall, .toolResult, .thinking]

    /// A fence whose proof is unavailable: verification always fails closed (never backfilled).
    static let unavailablePrefixFence = AgentRecoveryHistoryPrefixFence(file: nil, completeLineOffset: 0, prefixSHA256: nil)

    /// The latest durably saved Claude target this conversation must still match, or `nil` when
    /// none applies. Only one latest receipt is kept (no per-conversation target history), so when
    /// Claude rows of this conversation were imported but the latest receipt is absent, belongs to
    /// another provider or conversation, or has no valid target, that last target is no longer
    /// available and the result is a proofless fence: conservative refusal, never a quiet omission.
    static func latestSavedClaudeTargetFence(
        ledger: AgentSessionProviderHistoryRecovery?,
        conversationID: String
    ) -> AgentRecoveryHistoryPrefixFence? {
        let hasImportedHistory = ledger?.nativeItems.contains {
            $0.providerRaw == ClaudeSessionHistoryReader.providerRaw && $0.nativeSessionID == conversationID
        } ?? false
        if let receipt = ledger?.lastImportCommit,
           receipt.providerRaw == ClaudeSessionHistoryReader.providerRaw,
           receipt.conversationID == conversationID
        {
            // A matching receipt without a valid target (legacy or malformed) is never trusted.
            return receipt.target ?? unavailablePrefixFence
        }
        return hasImportedHistory ? unavailablePrefixFence : nil
    }

    /// Byte-prefix fences a Claude import verifies besides its boundary (Step 4d2), all against the
    /// same captured buffer: every captured baseline of the source attempt's dispatch window, and
    /// the latest durably saved Claude target of this conversation, even when the record cursor is
    /// older (a lost CAS). An unavailable target contributes a proofless fence, so the import fails
    /// closed. The caller adds the record cursor's own fence. Only window baselines of this provider
    /// and conversation fence this file (review B P3-01): a foreign one is left to the preflight's
    /// `baselineTargetMismatch` instead of masking it as rewritten history.
    package static func claudePrefixFences(
        window: [AgentSessionProviderHistoryRecovery.DispatchBaseline],
        ledger: AgentSessionProviderHistoryRecovery?,
        conversationID: String
    ) -> [AgentRecoveryHistoryPrefixFence] {
        window
            .filter { $0.providerRaw == ClaudeSessionHistoryReader.providerRaw && $0.conversationID == conversationID }
            .compactMap { $0.cursor?.prefixFence }
            + [latestSavedClaudeTargetFence(ledger: ledger, conversationID: conversationID)].compactMap(\.self)
    }

    /// The fence a new Claude baseline verifies before it may become the latest receipt: the latest
    /// saved target of this conversation. An unavailable one (imported history whose last target is
    /// lost or unproven) is proofless, so the baseline is recorded unsupported (no claim) and never
    /// mints a fresh proof over it. A legacy target-less zero-row receipt with nothing imported
    /// fences nothing (a fresh first baseline stays allowed).
    package static func claudeBaselineFences(
        ledger: AgentSessionProviderHistoryRecovery?,
        conversationID: String
    ) -> [AgentRecoveryHistoryPrefixFence] {
        let hasImportedHistory = ledger?.nativeItems.contains {
            $0.providerRaw == ClaudeSessionHistoryReader.providerRaw && $0.nativeSessionID == conversationID
        } ?? false
        guard let fence = latestSavedClaudeTargetFence(ledger: ledger, conversationID: conversationID),
              fence.prefixSHA256 != nil || hasImportedHistory
        else { return [] }
        return [fence]
    }

    /// Checks whether `observation` (read after `baseline`) may be planned into `canonical`.
    /// `nil` = the explicit associations exist; otherwise the import must not run.
    ///
    /// `dispatchWindow` (Claude, Step 4d2): every recorded dispatch of the attempt, earliest (the
    /// boundary) first. When every one carries an outbound claim, those claims are the user
    /// association evidence and must match the native user entries after the boundary exactly;
    /// when any lacks one, there is no claim association (legacy) and the ledger alone decides.
    /// Only with exact claims does unassociated canonical output become `.canonicalOutputImportWithheld`,
    /// and only once every other check passed; without them it stays `.canonicalOutputAssociationUnavailable`.
    package static func check(
        observation: AgentProviderHistoryObservation,
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        hasUnreadableBaselines: Bool,
        expectedRunAttemptID: UUID?,
        transcriptResetGeneration: UInt64,
        canonical: AgentProviderHistoryCanonicalView,
        ledger: AgentSessionProviderHistoryRecovery?,
        dispatchWindow: [AgentSessionProviderHistoryRecovery.DispatchBaseline]? = nil
    ) -> AgentProviderHistoryAssociationRefusal? {
        if let refusal = baselineRefusal(
            baseline: baseline,
            hasUnreadableBaselines: hasUnreadableBaselines,
            expectedRunAttemptID: expectedRunAttemptID,
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            transcriptResetGeneration: transcriptResetGeneration
        ) {
            return refusal
        }
        guard let baseline else { return .baselineUnavailable }
        // Canonical output after the dispatch's first user item, across compacted turns and suffix
        // (`nil` = the dispatch's user items are not in this transcript).
        guard let canonicalOutputIDs = outputItemIDs(after: Set(baseline.userItemIDs), in: canonical) else {
            return .baselineTargetMismatch
        }
        var claimed: ClaimAssociation?
        if let dispatchWindow {
            switch claimAssociation(
                window: dispatchWindow,
                boundary: baseline,
                observation: observation,
                canonical: canonical
            ) {
            case .legacy:
                claimed = nil
            case let .refused(refusal):
                return refusal
            case let .associated(association):
                claimed = association
            }
        }
        // Positive association of EVERY user constituent of the dispatch (review A P1-05), checked
        // independently of the (possibly ledger-filtered) observation: each local user item must be
        // the explicit `localItemID` of a native user row of this conversation in the ledger, or a
        // constituent of an exactly matched outbound claim. A nil `localItemID` is unassociated; no
        // empty-output or user-filter shortcut exists.
        let associatedUserItemIDs = Set((ledger?.nativeItems ?? []).compactMap { native -> UUID? in
            guard native.providerRaw == observation.provider.rawValue,
                  native.nativeSessionID == observation.conversationID,
                  native.rowKindRaw == userRowKindRaw(observation.provider)
            else { return nil }
            return native.localItemID
        }).union(claimed?.userItemIDs ?? [])
        guard Set(baseline.userItemIDs).isSubset(of: associatedUserItemIDs) else {
            return .nativeUserAssociationUnavailable
        }
        // Native user rows: `localItemID == nil` in the ledger is NOT an association. Only a native
        // entry an outbound claim matched exactly is consumed (recorded, never re-created as a row).
        if observation.rows.contains(where: { $0.item == nil && !(claimed?.nativeUserEntryIDs.contains($0.nativeEntryID) ?? false) }) {
            return .nativeUserAssociationUnavailable
        }
        guard case let .enumerated(ids) = canonicalOutputIDs else {
            return .canonicalOutputAssociationUnavailable
        }
        let associated = Set((ledger?.nativeItems ?? []).compactMap(\.localItemID))
            .union(observation.rows.compactMap { $0.item?.id })
        let outputUncovered = !ids.isSubset(of: associated)
        // Without exact claims (ledger-only), uncovered output refuses at once, as before.
        if outputUncovered, claimed == nil {
            return .canonicalOutputAssociationUnavailable
        }
        // With exact claims, the gap is classified only after the known associations were validated:
        // any independent refusal wins over a withheld import.
        if let refusal = canonicalPayloadRefusal(
            observation: observation,
            canonical: canonical,
            ledger: ledger,
            claimedUserConstituents: claimed?.userItemIDsByNativeEntryID ?? [:]
        ) {
            return refusal
        }
        return outputUncovered ? .canonicalOutputImportWithheld : nil
    }

    /// One canonical item as the payload check reads it.
    private struct CanonicalPayload {
        let position: Int
        let item: AgentChatItem
        /// `false` in a non-full or structurally compacted turn, or for a summary-only tool execution.
        let isComplete: Bool
        /// Read from a persisted turn (not the suffix): the transcript builder stored its tool name
        /// normalized (`AgentTranscriptToolNormalizer.toolExecution`).
        let isTurnCopy: Bool
    }

    /// Canonical items by ID in canonical order (Step 4d3a). Source anchor:
    /// `AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix` keeps the existing non-full
    /// turns and rebuilds the full working turns from `AgentTabSession.items` (this suffix), merged in
    /// place by `transcriptByReplacingWorkingTurns`. So the suffix is the authoritative copy of every
    /// item it holds (a turn copy of it is not read), and a turn-only item has a determined place only
    /// in a turn before the first turn holding any suffix item; it then precedes every suffix item.
    /// A turn-only item in or after a suffix-bearing turn has no determined place, and an ID that
    /// occurs twice in the turns (outside the suffix) or twice in the suffix is ambiguous: both refuse
    /// when compared, never guessed.
    private static func canonicalPayloads(
        _ canonical: AgentProviderHistoryCanonicalView
    ) -> (payloads: [UUID: CanonicalPayload], ambiguous: Set<UUID>) {
        var payloads: [UUID: CanonicalPayload] = [:]
        var ambiguous = Set<UUID>()
        let suffixIDs = Set(canonical.suffixItems.map(\.id))
        var position = 0
        func record(_ item: AgentChatItem, isComplete: Bool, isTurnCopy: Bool = true) {
            if payloads[item.id] != nil { ambiguous.insert(item.id) }
            payloads[item.id] = CanonicalPayload(position: position, item: item, isComplete: isComplete, isTurnCopy: isTurnCopy)
            position += 1
        }
        var reachedSuffixTurns = false
        for turn in canonical.transcript.turns {
            let turnComplete = turn.retentionTier == .full && !turn.isStructurallyCompacted
            let activities = turn.allActivities
            if turn.request.map({ suffixIDs.contains($0.id) }) ?? false || activities.contains(where: { suffixIDs.contains($0.id) }) {
                reachedSuffixTurns = true
            }
            if let request = turn.request, !suffixIDs.contains(request.id) {
                if reachedSuffixTurns { ambiguous.insert(request.id) }
                record(request.toItem(), isComplete: turnComplete)
            }
            for activity in activities where !suffixIDs.contains(activity.id) {
                if reachedSuffixTurns { ambiguous.insert(activity.id) }
                record(activity.toItem(), isComplete: turnComplete && !(activity.toolExecution?.summaryOnly ?? false))
            }
        }
        for item in canonical.suffixItems {
            record(item, isComplete: true, isTurnCopy: false)
        }
        return (payloads, ambiguous)
    }

    /// Canonical payload and relative-order check (Step 4d3a), run before any overlap or
    /// deduplication is accepted. Every projected (non-user) ledger row of this conversation with a
    /// local item, and every observation row whose deterministic item is already in the canonical
    /// transcript, must match the provider's row as projected from the whole validated capture:
    /// same kind, text and exact tool fields (timestamps, sequence and streaming ignored).
    ///
    /// User rows are order anchors only (their provider-bound text may differ from the local text;
    /// the exact claim match is the text authority): each ledger-mapped native user row's local
    /// item, and each claimed native user entry's ordered local constituents
    /// (`claimedUserConstituents`, from `claimAssociation`), must exist unambiguously.
    ///
    /// Relative order is checked within two independent sequences: compared output rows keep the
    /// native projection's order among themselves, and user anchors keep it among themselves. Output
    /// is NOT ordered against user anchors: the importer appends recovered rows at the end (after a
    /// claimed steer that natively follows them), and its own unchanged replay must not refuse
    /// (review A R1 / B F1, option a). `nil` = all compared equal; nothing is changed either way.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func canonicalPayloadRefusal(
        observation: AgentProviderHistoryObservation,
        canonical: AgentProviderHistoryCanonicalView,
        ledger: AgentSessionProviderHistoryRecovery?,
        claimedUserConstituents: [String: [UUID]] = [:]
    ) -> AgentProviderHistoryAssociationRefusal? {
        let providerRaw = observation.provider.rawValue
        func rowKey(_ row: AgentProviderHistoryRow) -> String {
            AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: providerRaw,
                nativeSessionID: row.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.rowKindRaw,
                ordinal: row.ordinal
            )
        }
        var validationIndex: [String: Int] = [:]
        for (index, row) in observation.validationRows.enumerated() where validationIndex.updateValue(index, forKey: rowKey(row)) != nil {
            return .canonicalPayloadUnavailable
        }
        let (payloads, ambiguous) = canonicalPayloads(canonical)
        // One local item to check: at its native projection `index` (`rank` orders a claimed entry's
        // constituents), with the provider's item to compare, or `nil` for a user order anchor.
        struct Compared {
            let index: Int
            let rank: Int
            let id: UUID
            let expected: AgentChatItem?
            /// Step 4d5: the authorized stored representations of `expected`, only for a uniquely
            /// proven singleton Read row.
            var stored: [AgentTranscriptActivity]?
        }
        var compared: [Compared] = []
        var comparedIndexByID: [UUID: Int] = [:]
        func include(_ entry: Compared) -> Bool {
            if let existing = comparedIndexByID[entry.id] { return existing == entry.index }
            comparedIndexByID[entry.id] = entry.index
            compared.append(entry)
            return true
        }
        let userKind = userRowKindRaw(observation.provider)
        let applicableLedger = (ledger?.nativeItems ?? []).filter {
            $0.providerRaw == providerRaw && $0.nativeSessionID == observation.conversationID
        }
        // Step 4d5: a lossy comparison needs one applicable ledger entry for the key and one for the
        // local item; a repeated or competing mapping never lends its proof, whatever its digest.
        var ledgerKeyCounts: [String: Int] = [:]
        var ledgerLocalItemCounts: [UUID: Int] = [:]
        for native in applicableLedger {
            ledgerKeyCounts[native.key, default: 0] += 1
            if let localItemID = native.localItemID {
                ledgerLocalItemCounts[localItemID, default: 0] += 1
            }
        }
        // Step 4d5: each exchange's representations, generated at most once per preflight.
        var storedImagesByInvocation: [UUID: [UUID: [AgentTranscriptActivity]]?] = [:]
        for native in applicableLedger {
            guard let localItemID = native.localItemID else { continue }
            guard let index = validationIndex[native.key] else { return .canonicalPayloadUnavailable }
            if native.rowKindRaw == userKind {
                guard include(Compared(index: index, rank: 0, id: localItemID, expected: nil)) else {
                    return .canonicalPayloadUnavailable
                }
                continue
            }
            guard let expected = observation.validationRows[index].item else { return .canonicalPayloadUnavailable }
            guard expected.id == localItemID else { return .canonicalPayloadMismatch }
            // Step 4d5: only a row this ledger entry alone proves (unique key and local item, a valid
            // digest equal to the native entry's) of a singleton Read exchange may be compared in its
            // stored representations.
            var stored: [AgentTranscriptActivity]?
            if observation.storageComparableReadItemIDs.contains(localItemID),
               ledgerKeyCounts[native.key] == 1,
               ledgerLocalItemCounts[localItemID] == 1,
               let digest = native.envelopeDigest,
               digest == observation.validationRows[index].envelopeDigest,
               let invocationID = expected.toolInvocationID
            {
                let images = storedImagesByInvocation[invocationID]
                    ?? storedReadImages(invocationID: invocationID, in: observation.validationRows)
                storedImagesByInvocation[invocationID] = images
                stored = images?[localItemID]
            }
            guard include(Compared(index: index, rank: 0, id: localItemID, expected: expected, stored: stored)) else {
                return .canonicalPayloadUnavailable
            }
        }
        for (entryID, constituents) in claimedUserConstituents {
            let indices = observation.validationRows.indices.filter {
                observation.validationRows[$0].nativeEntryID == entryID && observation.validationRows[$0].rowKindRaw == userKind
            }
            guard indices.count == 1 else { return .canonicalPayloadUnavailable }
            for (rank, id) in constituents.enumerated() {
                guard include(Compared(index: indices[0], rank: rank, id: id, expected: nil)) else {
                    return .canonicalPayloadUnavailable
                }
            }
        }
        for row in observation.rows {
            guard let expected = row.item, payloads[expected.id] != nil else { continue }
            guard let index = validationIndex[rowKey(row)] else { return .canonicalPayloadUnavailable }
            guard include(Compared(index: index, rank: 0, id: expected.id, expected: expected)) else {
                return .canonicalPayloadUnavailable
            }
        }
        var storageBackings: StorageBackings?
        var previousOutputPosition = -1
        var previousAnchorPosition = -1
        for entry in compared.sorted(by: { ($0.index, $0.rank) < ($1.index, $1.rank) }) {
            guard !ambiguous.contains(entry.id), let payload = payloads[entry.id] else {
                return .canonicalPayloadUnavailable
            }
            guard let expected = entry.expected else {
                // A user order anchor: position among anchors only, never its text.
                guard payload.position > previousAnchorPosition else { return .canonicalPayloadMismatch }
                previousAnchorPosition = payload.position
                continue
            }
            var comparison = comparePayload(payload, expected: expected)
            if comparison == .unavailable, let stored = entry.stored {
                let backings = storageBackings ?? Self.storageBackings(canonical)
                storageBackings = backings
                comparison = compareStoredProjection(payload, id: entry.id, stored: stored, backings: backings)
            }
            switch comparison {
            case .unavailable:
                return .canonicalPayloadUnavailable
            case .mismatch:
                return .canonicalPayloadMismatch
            case .match:
                break
            }
            guard payload.position > previousOutputPosition else { return .canonicalPayloadMismatch }
            previousOutputPosition = payload.position
        }
        return nil
    }

    private enum PayloadComparison {
        case match
        case unavailable
        case mismatch
    }

    /// One canonical copy against the provider's projected item: same kind, text and exact tool
    /// fields (timestamps, sequence and streaming ignored).
    private static func comparePayload(_ payload: CanonicalPayload, expected: AgentChatItem) -> PayloadComparison {
        guard payload.isComplete else { return .unavailable }
        let actual = payload.item
        // A tool payload the canonical copy no longer carries (dropped, or compacted to its
        // summary) can't be compared.
        let resultSummarized = actual.toolResultJSON != expected.toolResultJSON
            && AgentTranscriptToolNormalizer.isSummaryOnly(raw: actual.toolResultJSON)
        if (expected.toolArgsJSON != nil && actual.toolArgsJSON == nil)
            || (expected.toolResultJSON != nil && actual.toolResultJSON == nil)
            || resultSummarized
        {
            return .unavailable
        }
        // A turn copy's tool name is the builder's normalization of the provider's (review B
        // F3); a suffix copy keeps it verbatim. Only that exact transform is accepted.
        let toolNameMatches = actual.toolName == expected.toolName
            || (payload.isTurnCopy && actual.toolName == AgentTranscriptToolNormalizer.normalizedToolName(expected.toolName))
        guard actual.kind == expected.kind,
              actual.text == expected.text,
              toolNameMatches,
              actual.toolInvocationID == expected.toolInvocationID,
              actual.toolArgsJSON == expected.toolArgsJSON,
              actual.toolResultJSON == expected.toolResultJSON,
              actual.toolIsError == expected.toolIsError
        else { return .mismatch }
        return .match
    }

    /// Step 4d5: every turn activity by ID with whether its turn is full and structurally intact;
    /// an ID occurring in more than one activity is ambiguous.
    private struct StorageBackings {
        var activities: [UUID: (activity: AgentTranscriptActivity, isComplete: Bool)] = [:]
        var ambiguous: Set<UUID> = []
    }

    private static func storageBackings(_ canonical: AgentProviderHistoryCanonicalView) -> StorageBackings {
        var backings = StorageBackings()
        for turn in canonical.transcript.turns {
            let isComplete = turn.retentionTier == .full && !turn.isStructurallyCompacted
            for activity in turn.allActivities {
                if backings.activities.updateValue((activity, isComplete), forKey: activity.id) != nil {
                    backings.ambiguous.insert(activity.id)
                }
            }
        }
        return backings
    }

    /// Step 4d5: the stored representations of one exchange's rows (call then result, as the
    /// persisted summary pairs them), by item ID; `nil` when generation does not keep every row.
    private static func storedReadImages(
        invocationID: UUID,
        in validationRows: [AgentProviderHistoryRow]
    ) -> [UUID: [AgentTranscriptActivity]]? {
        let exchange = validationRows.compactMap(\.item).filter {
            $0.toolInvocationID == invocationID && ($0.kind == .toolCall || $0.kind == .toolResult)
        }
        let ordered = exchange.filter { $0.kind == .toolCall } + exchange.filter { $0.kind == .toolResult }
        return AgentTranscriptPolicyPipeline.storageComparisonActivities(ordered)
    }

    /// Step 4d5 import-only comparison, after the exact comparison found the copy unavailable: the
    /// canonical copy is an authorized stored representation of a proven row. It needs exactly one
    /// backing activity in a full, intact turn that equals one generated representation completely
    /// (kind, text, the whole tool execution, and its projected tool fields); a suffix copy must
    /// independently carry one representation's complete projected fields. Membership is per whole
    /// representation, never a union of allowed field values. A summarized copy without such backing
    /// is unavailable; a backed copy outside the set is a mismatch. Never a raw proof: it is used
    /// only when the ledger already uniquely proves the row.
    private static func compareStoredProjection(
        _ payload: CanonicalPayload,
        id: UUID,
        stored: [AgentTranscriptActivity],
        backings: StorageBackings
    ) -> PayloadComparison {
        guard !backings.ambiguous.contains(id), let backing = backings.activities[id], backing.isComplete else {
            return .unavailable
        }
        func sameProjectedTool(_ actual: AgentChatItem, _ image: AgentTranscriptActivity) -> Bool {
            let expected = image.toItem()
            return actual.kind == expected.kind
                && actual.text == expected.text
                && actual.toolName == expected.toolName
                && actual.toolInvocationID == expected.toolInvocationID
                && actual.toolArgsJSON == expected.toolArgsJSON
                && actual.toolResultJSON == expected.toolResultJSON
                && actual.toolIsError == expected.toolIsError
        }
        let backingMatches = stored.contains { image in
            backing.activity.itemKind == image.itemKind
                && backing.activity.text == image.text
                && backing.activity.toolExecution == image.toolExecution
                && sameProjectedTool(backing.activity.toItem(), image)
        }
        let suffixMatches = payload.isTurnCopy || stored.contains { sameProjectedTool(payload.item, $0) }
        guard backingMatches, suffixMatches else { return .mismatch }
        return .match
    }

    /// Step 4d5 prerequisite check: whether the canonical transcript (persisted turns plus suffix)
    /// holds exactly one complete, non-streaming copy of `expected` (by ID) with its projected payload,
    /// by the preflight's own comparison. Ambiguous, missing, summarized or changed copies never hold.
    package static func holdsCanonicalPayload(_ expected: AgentChatItem, in canonical: AgentProviderHistoryCanonicalView) -> Bool {
        let (payloads, ambiguous) = canonicalPayloads(canonical)
        guard !ambiguous.contains(expected.id), let payload = payloads[expected.id], !payload.item.isStreaming else { return false }
        return comparePayload(payload, expected: expected) == .match
    }

    /// Native user entries and local user items proven by the attempt's outbound claims.
    struct ClaimAssociation: Equatable {
        let nativeUserEntryIDs: Set<String>
        let userItemIDs: Set<UUID>
        /// Each claimed native entry ID to its dispatch's ordered local user constituents.
        let userItemIDsByNativeEntryID: [String: [UUID]]
    }

    enum ClaimAssociationResult: Equatable {
        /// Some dispatch of the attempt has no claim: no claim association exists.
        case legacy
        case refused(AgentProviderHistoryAssociationRefusal)
        case associated(ClaimAssociation)
    }

    /// Exact association of the attempt's claims (`window`, earliest first) to the native user
    /// entries after the boundary: one entry per claim, the claim's own UUID (lowercase) as the
    /// entry ID, in dispatch order, with an equal plain-text digest, and no other native user entry;
    /// every dispatch's complete ordered constituents are in `canonical` in that order. A claimed
    /// UUID never proves a write: a missing entry refuses and is never read as non-delivery.
    static func claimAssociation(
        window: [AgentSessionProviderHistoryRecovery.DispatchBaseline],
        boundary: AgentSessionProviderHistoryRecovery.DispatchBaseline,
        observation: AgentProviderHistoryObservation,
        canonical: AgentProviderHistoryCanonicalView
    ) -> ClaimAssociationResult {
        guard window.first == boundary,
              window.allSatisfy({
                  $0.providerRaw == boundary.providerRaw
                      && $0.conversationID == boundary.conversationID && $0.runAttemptID == boundary.runAttemptID
                      && $0.transcriptResetGeneration == boundary.transcriptResetGeneration
              })
        else { return .refused(.baselineTargetMismatch) }
        // A same-attempt dispatch recorded unsupported (e.g. a steer read mid-write) belongs to this
        // conversation and run but carries no usable claim: no claim association (review B P2-03),
        // never a false target mismatch. The ledger-only checks then decide (and fail closed).
        guard window.allSatisfy({ $0.status == .captured }) else { return .legacy }
        let claims = window.compactMap(\.outboundUserMessage)
        guard claims.count == window.count else { return .legacy }
        let claimedIDs = claims.map { $0.uuid.uuidString.lowercased() }
        let constituents = window.flatMap(\.userItemIDs)
        guard zip(window, claims).allSatisfy({ $0.dispatchID == $1.uuid }),
              Set(claimedIDs).count == claimedIDs.count,
              observation.nativeUserEntries.map(\.nativeEntryID) == claimedIDs,
              zip(observation.nativeUserEntries, claims).allSatisfy({ $0.textSHA256 == $1.textSHA256 }),
              window.allSatisfy({ !$0.userItemIDs.isEmpty }),
              Set(constituents).count == constituents.count,
              isOrderedSubsequence(constituents, of: canonicalItemIDs(canonical))
        else { return .refused(.outboundClaimUnmatched) }
        return .associated(ClaimAssociation(
            nativeUserEntryIDs: Set(claimedIDs),
            userItemIDs: Set(constituents),
            userItemIDsByNativeEntryID: Dictionary(uniqueKeysWithValues: zip(claimedIDs, window.map(\.userItemIDs)))
        ))
    }

    /// Every canonical item ID in transcript order (persisted turns, requests included, then the
    /// suffix). Also the existing-ID set a Claude import plans against (Step 4d3a), so a row already
    /// held only by a persisted turn is recorded, never appended again.
    package static func canonicalItemIDs(_ canonical: AgentProviderHistoryCanonicalView) -> [UUID] {
        var ids: [UUID] = []
        for turn in canonical.transcript.turns {
            if let request = turn.request { ids.append(request.id) }
            ids.append(contentsOf: turn.allActivities.map(\.id))
        }
        ids.append(contentsOf: canonical.suffixItems.map(\.id))
        return ids
    }

    private static func isOrderedSubsequence(_ wanted: [UUID], of ids: [UUID]) -> Bool {
        var remaining = wanted[...]
        for id in ids where id == remaining.first {
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty
    }

    /// The baseline half of the preflight (checked before any history read).
    package static func baselineRefusal(
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        hasUnreadableBaselines: Bool,
        expectedRunAttemptID: UUID?,
        providerRaw: String,
        conversationID: String,
        transcriptResetGeneration: UInt64
    ) -> AgentProviderHistoryAssociationRefusal? {
        // An unreadable entry might be this attempt's earliest one: never select a later boundary.
        guard let baseline, baseline.status == .captured, baseline.cursor != nil, !hasUnreadableBaselines else {
            return .baselineUnavailable
        }
        guard baseline.providerRaw == providerRaw,
              baseline.conversationID == conversationID,
              baseline.transcriptResetGeneration == transcriptResetGeneration,
              expectedRunAttemptID != nil, baseline.runAttemptID == expectedRunAttemptID,
              !baseline.userItemIDs.isEmpty
        else {
            return .baselineTargetMismatch
        }
        return nil
    }

    /// Codex canonical overlap (review A P1-04 / B F1). Live Codex output is persisted under its own
    /// IDs, and this build has no native → canonical mapping for live Codex items, so projected
    /// observation rows may be planned only when the canonical transcript provably holds no
    /// unassociated provider output at or after the interrupted turn's user item (compacted turns
    /// included, plus the suffix). Output already associated through the ledger (an earlier import)
    /// or carried by this observation's own deterministic rows does not overlap. `nil` = no overlap;
    /// otherwise the rows are withheld (zero rows; a confirmed completion stays honest).
    package static func codexOverlapRefusal(
        observation: AgentProviderHistoryObservation,
        turnUserItemIDs: Set<UUID>,
        canonical: AgentProviderHistoryCanonicalView,
        ledger: AgentSessionProviderHistoryRecovery?
    ) -> AgentProviderHistoryAssociationRefusal? {
        guard observation.rows.contains(where: { $0.item != nil }) else { return nil }
        guard !turnUserItemIDs.isEmpty, let output = outputItemIDs(after: turnUserItemIDs, in: canonical) else {
            return .baselineTargetMismatch
        }
        guard case let .enumerated(ids) = output else { return .canonicalOutputAssociationUnavailable }
        let associated = Set((ledger?.nativeItems ?? []).compactMap(\.localItemID))
            .union(observation.rows.compactMap { $0.item?.id })
        return ids.isSubset(of: associated) ? nil : .canonicalOutputAssociationUnavailable
    }

    /// The native row kind of a provider's user message.
    static func userRowKindRaw(_ provider: AgentRecoveryHistoryProvider) -> String {
        switch provider {
        case .claude: ClaudeSessionHistoryReader.RowKind.userText.rawValue
        case .codex: CodexRecoveryObservation.Item.Kind.userMessage.rawValue
        }
    }

    enum CanonicalOutput: Equatable {
        case enumerated(Set<UUID>)
        /// The dispatch lies in (or before) a compacted turn whose rows are not stored.
        case notEnumerable
    }

    /// Provider-output item IDs at or after the first of `userItemIDs`; `nil` when that user item is
    /// in neither the persisted turns nor the suffix. Only the turn holding that first user item is
    /// filtered (output before it is excluded); every later turn counts in full, whatever its own
    /// request (review A R1: a later turn's live output is never skipped).
    static func outputItemIDs(after userItemIDs: Set<UUID>, in canonical: AgentProviderHistoryCanonicalView) -> CanonicalOutput? {
        var ids = Set<UUID>()
        var found = false
        var enumerable = true
        for turn in canonical.transcript.turns {
            let passedInEarlierTurn = found
            let requestMatches = turn.request.map { userItemIDs.contains($0.id) } ?? false
            let activityMatches = turn.allActivities.contains { userItemIDs.contains($0.id) }
            if !found, requestMatches || activityMatches {
                found = true
            }
            guard found else { continue }
            if turn.retentionTier != .full || turn.isStructurallyCompacted {
                enumerable = false
            }
            var afterUser = passedInEarlierTurn || requestMatches
            for activity in turn.allActivities {
                if userItemIDs.contains(activity.id) { afterUser = true }
                if afterUser, outputKinds.contains(activity.itemKind) { ids.insert(activity.id) }
            }
        }
        var afterUserInSuffix = found
        for item in canonical.suffixItems {
            if userItemIDs.contains(item.id) {
                found = true
                afterUserInSuffix = true
            }
            if afterUserInSuffix, outputKinds.contains(item.kind) { ids.insert(item.id) }
        }
        guard found else { return nil }
        return enumerable ? .enumerated(ids) : .notEnumerable
    }
}

// MARK: - Claude projection

extension ClaudeSessionHistoryReader {
    /// Converts a validated candidate to the provider-neutral observation. Rows carry inert items
    /// with their deterministic identities; native user rows carry no item (unassociated, never
    /// projected, and never assumed to be a local user item).
    package static func observation(_ candidate: Candidate) -> AgentProviderHistoryObservation {
        let convert = { (row: Row) -> AgentProviderHistoryRow in
            AgentProviderHistoryRow(
                nativeSessionID: candidate.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.kind.rawValue,
                ordinal: row.ordinal,
                item: item(for: row),
                envelopeDigest: row.envelopeDigest
            )
        }
        return AgentProviderHistoryObservation(
            provider: .claude,
            conversationID: candidate.nativeSessionID,
            rows: candidate.rows.map(convert),
            validationRows: candidate.validationRows.map(convert),
            file: candidate.file,
            completeLineOffset: candidate.completeLineOffset,
            prefixSHA256: candidate.prefixSHA256,
            completionConfirmed: false,
            nativeUserEntries: candidate.userMessageEntries,
            storageComparableReadItemIDs: storageComparableReadItemIDs(candidate.validationRows, nativeSessionID: candidate.nativeSessionID)
        )
    }

    /// Step 4d5: the local item IDs of the whole validated capture's singleton Read exchanges. A call
    /// qualifies when its entry projects to exactly this one row and the row equals
    /// `singleToolUseRow` of `Read` with input exactly `{file_path: non-empty String}` (identity,
    /// payload and digest, so a multiblock or otherwise different entry never does). A result
    /// qualifies likewise against `singleToolResultRow` (string content, `is_error` absent). The
    /// exchange qualifies together: one such call and at most one result for its tool-use ID, each
    /// entry its tool-use ID's only row of that kind. Errors, other tools and shapes never qualify.
    static func storageComparableReadItemIDs(_ rows: [Row], nativeSessionID: String) -> Set<UUID> {
        var rowsPerEntry: [String: Int] = [:]
        for row in rows {
            rowsPerEntry[row.nativeEntryID, default: 0] += 1
        }
        func singleton(_ row: Row) -> Bool {
            row.ordinal == 0 && rowsPerEntry[row.nativeEntryID] == 1 && row.localItemID != nil
        }
        func eligibleCall(_ row: Row) -> Bool {
            guard singleton(row), row.toolName == "Read", let toolUseID = row.toolUseID, let inputJSON = row.toolInputJSON,
                  let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any],
                  input.count == 1, let path = input["file_path"] as? String, !path.isEmpty,
                  canonicalToolInputJSON(input as NSDictionary) == inputJSON
            else { return false }
            return singleToolUseRow(
                nativeSessionID: nativeSessionID, nativeEntryID: row.nativeEntryID, toolUseID: toolUseID, name: "Read", inputJSON: inputJSON
            ) == row
        }
        func eligibleResult(_ row: Row) -> Bool {
            guard singleton(row), row.toolName == "Read", row.toolIsError == nil, let toolUseID = row.toolUseID, let text = row.text
            else { return false }
            return singleToolResultRow(
                nativeSessionID: nativeSessionID, nativeEntryID: row.nativeEntryID, toolUseID: toolUseID, toolName: "Read", text: text
            ) == row
        }
        var eligible = Set<UUID>()
        let toolRows = Dictionary(grouping: rows.filter { $0.toolUseID != nil && ($0.kind == .toolCall || $0.kind == .toolResult) }) { $0.toolUseID ?? "" }
        for exchange in toolRows.values {
            let calls = exchange.filter { $0.kind == .toolCall }
            let results = exchange.filter { $0.kind == .toolResult }
            guard calls.count == 1, results.count <= 1, eligibleCall(calls[0]), results.allSatisfy(eligibleResult) else { continue }
            for row in exchange {
                if let id = row.localItemID { eligible.insert(id) }
            }
        }
        return eligible
    }

    static func item(for row: Row) -> AgentChatItem? {
        guard let localID = row.localItemID else { return nil }
        let item: AgentChatItem? = switch row.kind {
        case .userText:
            nil
        case .assistantText:
            row.text.map { AgentChatItem.assistant($0) }
        case .toolCall:
            AgentChatItem.toolCall(
                name: row.toolName ?? "tool",
                invocationID: row.toolInvocationID,
                argsJSON: row.toolInputJSON
            )
        case .toolResult:
            AgentChatItem.toolResult(
                name: row.toolName ?? "tool",
                invocationID: row.toolInvocationID,
                resultJSON: row.text ?? "",
                isError: row.toolIsError
            )
        }
        return item?.replacingID(localID)
    }
}
