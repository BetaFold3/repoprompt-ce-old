import CryptoKit
import Foundation

// Optional version-7 session member for provider-history reconciliation (lossless restart Phase 4,
// phase4-plan "History ledger"). It is the session-side half of one import transaction:
//
//   session rows + this native-ID ledger + the import receipt commit in ONE session save
//   (`AgentSessionDataService.commitProviderHistoryImport`) → the recovery cursor CAS follows.
//
// The ledger maps normalized native row keys (provider, native session, native entry, row kind,
// ordinal) to the local transcript items they were projected as, so replays, replacement rescans,
// and crash cuts between the two commits never duplicate rows. Absent when empty (no version bump):
// older builds ignore it; unknown members inside it round-trip.
//
// `dispatchBaselines` are the immutable pre-send history boundaries of individual durable
// dispatches (one per dispatch, never overwritten by a later run). Each captured one was committed
// as a zero-row import receipt BEFORE that dispatch's user bytes; the recovery cursor is only an
// optimization and never selects an interrupted attempt's starting boundary.

package struct AgentSessionProviderHistoryRecovery: Codable, Equatable {
    /// One imported native row (or a validated native entry that is intentionally not projected).
    package struct NativeItem: Codable, Equatable {
        package let providerRaw: String
        package let nativeSessionID: String
        package let nativeEntryID: String
        package let rowKindRaw: String
        package let ordinal: Int
        /// Local transcript item this row was projected as. `nil` = unassociated/not projected (a
        /// native user entry): never evidence that the entry is a known local user item.
        package let localItemID: UUID?
        /// Complete-envelope proof of the native entry this row came from (lowercase hex SHA-256 of
        /// the entry's ordered supported semantic payload; every row of one entry carries the same
        /// value). `nil` for legacy rows, providers without one (Codex), and a malformed stored value
        /// (kept verbatim in `extras`, never read as a proof): a Claude entry whose known rows lack a
        /// valid one never deduplicates and refuses as a ledger conflict.
        package let envelopeDigest: String?
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            providerRaw: String,
            nativeSessionID: String,
            nativeEntryID: String,
            rowKindRaw: String,
            ordinal: Int,
            localItemID: UUID?,
            envelopeDigest: String? = nil,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.providerRaw = providerRaw
            self.nativeSessionID = nativeSessionID
            self.nativeEntryID = nativeEntryID
            self.rowKindRaw = rowKindRaw
            self.ordinal = ordinal
            self.localItemID = localItemID
            self.envelopeDigest = envelopeDigest
            self.extras = extras
        }

        /// The normalized native row key (never API message ID, text, or tool name).
        package var key: String {
            AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: providerRaw,
                nativeSessionID: nativeSessionID,
                nativeEntryID: nativeEntryID,
                rowKindRaw: rowKindRaw,
                ordinal: ordinal
            )
        }

        private static let knownKeys: Set<String> = [
            "provider", "nativeSessionID", "nativeEntryID", "rowKind", "ordinal", "localItemID", "envelopeDigest"
        ]

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            providerRaw = try container.decode(String.self, forKey: HistoryDynamicKey("provider"))
            nativeSessionID = try container.decode(String.self, forKey: HistoryDynamicKey("nativeSessionID"))
            nativeEntryID = try container.decode(String.self, forKey: HistoryDynamicKey("nativeEntryID"))
            rowKindRaw = try container.decode(String.self, forKey: HistoryDynamicKey("rowKind"))
            ordinal = try container.decode(Int.self, forKey: HistoryDynamicKey("ordinal"))
            localItemID = try container.decodeIfPresent(UUID.self, forKey: HistoryDynamicKey("localItemID"))
            // Tolerant: a malformed proof never fails the session and is never read as a proof.
            envelopeDigest = HistoryDynamicKey.tolerantDigest(in: container, key: "envelopeDigest")
            extras = try HistoryDynamicKey.extras(
                in: container,
                excluding: envelopeDigest == nil ? Self.knownKeys.subtracting(["envelopeDigest"]) : Self.knownKeys
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            try HistoryDynamicKey.encode(extras, into: &container, overriddenBy: envelopeDigest == nil ? [] : ["envelopeDigest"])
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encode(nativeSessionID, forKey: HistoryDynamicKey("nativeSessionID"))
            try container.encode(nativeEntryID, forKey: HistoryDynamicKey("nativeEntryID"))
            try container.encode(rowKindRaw, forKey: HistoryDynamicKey("rowKind"))
            try container.encode(ordinal, forKey: HistoryDynamicKey("ordinal"))
            try container.encodeIfPresent(localItemID, forKey: HistoryDynamicKey("localItemID"))
            try container.encodeIfPresent(envelopeDigest, forKey: HistoryDynamicKey("envelopeDigest"))
        }
    }

    /// Receipt of the latest committed import. The recovery cursor follows this import ID.
    package struct ImportCommit: Codable, Equatable {
        package let importID: UUID
        package let providerRaw: String
        package let conversationID: String
        package let committedAt: Date
        /// Rows projected by this import (0 for a baseline or a no-op import).
        package let rowCount: Int
        /// The exact history target this receipt committed (Claude, Step 4d2): the file, complete
        /// offset and byte-prefix proof the import's rows and ledger were read from, bound in the
        /// same session save. It survives a lost cursor CAS, so the next import fences it. `nil` for
        /// Codex, legacy receipts (never backfilled), and a malformed stored value (kept verbatim).
        package let target: AgentRecoveryHistoryPrefixFence?
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            importID: UUID,
            providerRaw: String,
            conversationID: String,
            committedAt: Date,
            rowCount: Int,
            target: AgentRecoveryHistoryPrefixFence? = nil,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.importID = importID
            self.providerRaw = providerRaw
            self.conversationID = conversationID
            self.committedAt = committedAt
            self.rowCount = rowCount
            self.target = target
            self.extras = extras
        }

        private static let knownKeys: Set<String> = ["importID", "provider", "conversationID", "committedAt", "rowCount", "target"]

        /// The stored `target` object (all members known and well-formed, with a valid proof).
        private struct TargetCoding: Codable {
            let fileDevice: UInt64?
            let fileInode: UInt64?
            let fileBirthSeconds: Int64?
            let fileBirthNanoseconds: Int64?
            let completeLineOffset: UInt64
            let prefixSHA256: String

            static let memberNames: Set<String> = [
                "fileDevice", "fileInode", "fileBirthSeconds", "fileBirthNanoseconds", "completeLineOffset", "prefixSHA256"
            ]

            init(_ fence: AgentRecoveryHistoryPrefixFence, prefixSHA256: String) {
                fileDevice = fence.file?.device
                fileInode = fence.file?.inode
                fileBirthSeconds = fence.file?.birthSeconds
                fileBirthNanoseconds = fence.file?.birthNanoseconds
                completeLineOffset = fence.completeLineOffset
                self.prefixSHA256 = prefixSHA256
            }

            var fence: AgentRecoveryHistoryPrefixFence? {
                guard AgentSessionProviderHistoryRecovery.isSHA256Hex(prefixSHA256) else { return nil }
                let file: AgentRecoveryHistoryFileIdentity?
                switch (fileDevice, fileInode) {
                case let (device?, inode?):
                    file = AgentRecoveryHistoryFileIdentity(
                        device: device,
                        inode: inode,
                        birthSeconds: fileBirthSeconds,
                        birthNanoseconds: fileBirthNanoseconds
                    )
                case (nil, nil) where fileBirthSeconds == nil && fileBirthNanoseconds == nil:
                    file = nil
                default:
                    return nil
                }
                return AgentRecoveryHistoryPrefixFence(file: file, completeLineOffset: completeLineOffset, prefixSHA256: prefixSHA256)
            }
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            importID = try container.decode(UUID.self, forKey: HistoryDynamicKey("importID"))
            providerRaw = try container.decode(String.self, forKey: HistoryDynamicKey("provider"))
            conversationID = try container.decode(String.self, forKey: HistoryDynamicKey("conversationID"))
            committedAt = try container.decode(Date.self, forKey: HistoryDynamicKey("committedAt"))
            rowCount = try container.decode(Int.self, forKey: HistoryDynamicKey("rowCount"))
            // Tolerant and all-or-nothing: anything but a complete, well-formed target with a valid
            // proof is no target (fails closed) and stays verbatim in `extras`.
            let raw = try container.decodeIfPresent(AgentScheduledSendJSONValue.self, forKey: HistoryDynamicKey("target"))
            target = raw.flatMap { value -> AgentRecoveryHistoryPrefixFence? in
                guard case let .object(members) = value,
                      Set(members.keys).isSubset(of: TargetCoding.memberNames),
                      let data = try? JSONEncoder().encode(value),
                      let coding = try? JSONDecoder().decode(TargetCoding.self, from: data)
                else { return nil }
                return coding.fence
            }
            extras = try HistoryDynamicKey.extras(
                in: container,
                excluding: target == nil ? Self.knownKeys.subtracting(["target"]) : Self.knownKeys
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            let typedTarget = target.flatMap { fence in fence.prefixSHA256.map { TargetCoding(fence, prefixSHA256: $0) } }
            try HistoryDynamicKey.encode(extras, into: &container, overriddenBy: typedTarget == nil ? [] : ["target"])
            try container.encode(importID, forKey: HistoryDynamicKey("importID"))
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encode(conversationID, forKey: HistoryDynamicKey("conversationID"))
            try container.encode(committedAt, forKey: HistoryDynamicKey("committedAt"))
            try container.encode(rowCount, forKey: HistoryDynamicKey("rowCount"))
            try container.encodeIfPresent(typedTarget, forKey: HistoryDynamicKey("target"))
        }
    }

    /// Immutable pre-send history boundary of ONE durable dispatch (Phase 4 baseline producer).
    package struct DispatchBaseline: Codable, Equatable {
        package enum Status: Equatable {
            /// A validated complete-line boundary committed before the dispatch's user bytes.
            case captured
            /// No boundary could be captured before the bytes (missing identity or history
            /// location). Never backfilled: this dispatch has no history recovery.
            case unsupported(String)
        }

        /// Outbound caller-identity claim of a built-in Claude dispatch: recorded only by the admission
        /// that newly captured this baseline, before any bytes, as the instruction to encode `uuid` as
        /// the streamed user message's top-level `uuid`. It is NOT evidence of delivery, native
        /// persistence or fsync. Legacy baselines (and every non-qualified admission) have none and
        /// are never upgraded later.
        ///
        /// A claim may be committed while its UUID is NEVER encoded: an admission refused after the
        /// save whose pending receipt a retry then joins (that retry sends without the UUID), or a
        /// write superseded, cancelled or failed after the admission returned it. A missing native
        /// entry carrying `uuid` is therefore evidence of nothing: never of non-delivery, and never
        /// a reason to resend automatically.
        package struct OutboundUserMessage: Codable, Equatable {
            /// The dispatch's own `dispatchID`, stored explicitly (never inferred from it).
            package let uuid: UUID
            /// Lowercase hex SHA-256 of the exact provider-bound text's UTF-8 bytes.
            package let textSHA256: String
            /// Unknown members inside the claim, kept verbatim.
            package var extras: [String: AgentScheduledSendJSONValue]

            package init(uuid: UUID, textSHA256: String, extras: [String: AgentScheduledSendJSONValue] = [:]) {
                self.uuid = uuid
                self.textSHA256 = textSHA256
                self.extras = extras
            }

            /// The claim for `uuid` over exactly `providerBoundText` (the codec's text, unmodified).
            package init(uuid: UUID, providerBoundText: String) {
                self.init(uuid: uuid, textSHA256: AgentSessionProviderHistoryRecovery.sha256Hex(Data(providerBoundText.utf8)))
            }

            private static let knownKeys: Set<String> = ["uuid", "textSHA256"]

            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
                uuid = try container.decode(UUID.self, forKey: HistoryDynamicKey("uuid"))
                let digest = try container.decode(String.self, forKey: HistoryDynamicKey("textSHA256"))
                // Exactly 64 lowercase hex digits; anything else makes the whole baseline unreadable.
                guard AgentSessionProviderHistoryRecovery.isSHA256Hex(digest) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: HistoryDynamicKey("textSHA256"),
                        in: container,
                        debugDescription: "Malformed outbound user-message digest."
                    )
                }
                textSHA256 = digest
                extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
            }

            package func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: HistoryDynamicKey.self)
                try HistoryDynamicKey.encode(extras, into: &container)
                try container.encode(uuid, forKey: HistoryDynamicKey("uuid"))
                try container.encode(textSHA256, forKey: HistoryDynamicKey("textSHA256"))
            }
        }

        /// Existing durable dispatch identity (the first delivery attempt ID); idempotency key.
        package let dispatchID: UUID
        package let runAttemptID: UUID?
        package let transcriptResetGeneration: UInt64
        package let providerRaw: String
        /// Exact native conversation (`nil` only for an unsupported capture without one).
        package let conversationID: String?
        /// Ordered local user items of the dispatch's constituents.
        package let userItemIDs: [UUID]
        /// `nil` for verified absence (or an unsupported capture).
        package let file: AgentRecoveryHistoryFileIdentity?
        package let completeLineOffset: UInt64
        /// Byte-prefix proof of `[0, completeLineOffset)` (SHA-256 of the empty prefix for verified
        /// absence or an empty file). `nil` for legacy and unsupported baselines and a malformed
        /// stored value (kept verbatim in `extras`); never synthesized, so such a boundary fails closed.
        package let prefixSHA256: String?
        /// The zero-row import receipt that committed this boundary (`nil` when unsupported).
        package let baselineCommitID: UUID?
        package let profileName: String
        package let status: Status
        package let recordedAt: Date
        /// `nil` for legacy baselines and every admission that did not mint a claim.
        package let outboundUserMessage: OutboundUserMessage?
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            dispatchID: UUID,
            runAttemptID: UUID?,
            transcriptResetGeneration: UInt64,
            providerRaw: String,
            conversationID: String?,
            userItemIDs: [UUID],
            file: AgentRecoveryHistoryFileIdentity?,
            completeLineOffset: UInt64,
            prefixSHA256: String? = nil,
            baselineCommitID: UUID?,
            profileName: String,
            status: Status,
            recordedAt: Date,
            outboundUserMessage: OutboundUserMessage? = nil,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.dispatchID = dispatchID
            self.runAttemptID = runAttemptID
            self.transcriptResetGeneration = transcriptResetGeneration
            self.providerRaw = providerRaw
            self.conversationID = conversationID
            self.userItemIDs = userItemIDs
            self.file = file
            self.completeLineOffset = completeLineOffset
            self.prefixSHA256 = prefixSHA256
            self.baselineCommitID = baselineCommitID
            self.profileName = profileName
            self.status = status
            self.recordedAt = Self.millisecondDate(Self.milliseconds(recordedAt))
            self.outboundUserMessage = outboundUserMessage
            self.extras = extras
        }

        /// Millisecond precision, so the value survives its own encoding exactly.
        private static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1000).rounded())
        }

        private static func millisecondDate(_ milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }

        /// The import boundary a captured baseline represents (`nil` when unsupported).
        package var cursor: AgentRecoveryHistoryCursor? {
            guard status == .captured, let conversationID, let baselineCommitID else { return nil }
            return AgentRecoveryHistoryCursor(
                providerRaw: providerRaw,
                conversationID: conversationID,
                importID: baselineCommitID,
                file: file,
                completeLineOffset: completeLineOffset,
                prefixSHA256: prefixSHA256,
                committedAt: AgentRecoveryTimestamp(recordedAt)
            )
        }

        private static let knownKeys: Set<String> = [
            "dispatchID", "runAttemptID", "transcriptResetGeneration", "provider", "conversationID",
            "userItemIDs", "fileDevice", "fileInode", "fileBirthSeconds", "fileBirthNanoseconds",
            "completeLineOffset", "baselineCommitID", "profile", "status", "unsupportedReason", "recordedAtMs",
            "outboundUserMessage", "prefixSHA256"
        ]

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            func key(_ name: String) -> HistoryDynamicKey {
                HistoryDynamicKey(name)
            }
            dispatchID = try container.decode(UUID.self, forKey: key("dispatchID"))
            runAttemptID = try container.decodeIfPresent(UUID.self, forKey: key("runAttemptID"))
            transcriptResetGeneration = try container.decode(UInt64.self, forKey: key("transcriptResetGeneration"))
            providerRaw = try container.decode(String.self, forKey: key("provider"))
            conversationID = try container.decodeIfPresent(String.self, forKey: key("conversationID"))
            userItemIDs = try container.decodeIfPresent([UUID].self, forKey: key("userItemIDs")) ?? []
            if let device = try container.decodeIfPresent(UInt64.self, forKey: key("fileDevice")) {
                file = try AgentRecoveryHistoryFileIdentity(
                    device: device,
                    inode: container.decode(UInt64.self, forKey: key("fileInode")),
                    birthSeconds: container.decodeIfPresent(Int64.self, forKey: key("fileBirthSeconds")),
                    birthNanoseconds: container.decodeIfPresent(Int64.self, forKey: key("fileBirthNanoseconds"))
                )
            } else {
                file = nil
            }
            completeLineOffset = try container.decode(UInt64.self, forKey: key("completeLineOffset"))
            // Tolerant (unlike the claim): a malformed proof is no proof, kept verbatim.
            prefixSHA256 = HistoryDynamicKey.tolerantDigest(in: container, key: "prefixSHA256")
            baselineCommitID = try container.decodeIfPresent(UUID.self, forKey: key("baselineCommitID"))
            profileName = try container.decode(String.self, forKey: key("profile"))
            switch try container.decode(String.self, forKey: key("status")) {
            case "captured" where baselineCommitID != nil && conversationID != nil:
                status = .captured
            case "unsupported":
                status = try .unsupported(container.decodeIfPresent(String.self, forKey: key("unsupportedReason")) ?? "")
            default:
                // Not understood (or an incomplete capture): preserved verbatim as unreadable.
                throw DecodingError.dataCorruptedError(
                    forKey: key("status"),
                    in: container,
                    debugDescription: "Unrecognized or incomplete dispatch baseline."
                )
            }
            // Epoch milliseconds: independent of the enclosing encoder's date strategy.
            recordedAt = try Self.millisecondDate(container.decode(Int64.self, forKey: key("recordedAtMs")))
            // A malformed claim makes the whole baseline unreadable (kept verbatim), never a claim.
            outboundUserMessage = try container.decodeIfPresent(OutboundUserMessage.self, forKey: key("outboundUserMessage"))
            extras = try HistoryDynamicKey.extras(
                in: container,
                excluding: prefixSHA256 == nil ? Self.knownKeys.subtracting(["prefixSHA256"]) : Self.knownKeys
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            try HistoryDynamicKey.encode(extras, into: &container, overriddenBy: prefixSHA256 == nil ? [] : ["prefixSHA256"])
            try container.encode(dispatchID, forKey: HistoryDynamicKey("dispatchID"))
            try container.encodeIfPresent(runAttemptID, forKey: HistoryDynamicKey("runAttemptID"))
            try container.encode(transcriptResetGeneration, forKey: HistoryDynamicKey("transcriptResetGeneration"))
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encodeIfPresent(conversationID, forKey: HistoryDynamicKey("conversationID"))
            try container.encode(userItemIDs, forKey: HistoryDynamicKey("userItemIDs"))
            if let file {
                try container.encode(file.device, forKey: HistoryDynamicKey("fileDevice"))
                try container.encode(file.inode, forKey: HistoryDynamicKey("fileInode"))
                try container.encodeIfPresent(file.birthSeconds, forKey: HistoryDynamicKey("fileBirthSeconds"))
                try container.encodeIfPresent(file.birthNanoseconds, forKey: HistoryDynamicKey("fileBirthNanoseconds"))
            }
            try container.encode(completeLineOffset, forKey: HistoryDynamicKey("completeLineOffset"))
            try container.encodeIfPresent(prefixSHA256, forKey: HistoryDynamicKey("prefixSHA256"))
            try container.encodeIfPresent(baselineCommitID, forKey: HistoryDynamicKey("baselineCommitID"))
            try container.encode(profileName, forKey: HistoryDynamicKey("profile"))
            switch status {
            case .captured:
                try container.encode("captured", forKey: HistoryDynamicKey("status"))
            case let .unsupported(reason):
                try container.encode("unsupported", forKey: HistoryDynamicKey("status"))
                try container.encode(reason, forKey: HistoryDynamicKey("unsupportedReason"))
            }
            try container.encode(Self.milliseconds(recordedAt), forKey: HistoryDynamicKey("recordedAtMs"))
            try container.encodeIfPresent(outboundUserMessage, forKey: HistoryDynamicKey("outboundUserMessage"))
        }
    }

    package var nativeItems: [NativeItem]
    package var lastImportCommit: ImportCommit?
    /// Per-dispatch pre-send boundaries, in recording order (never replaced).
    package var dispatchBaselines: [DispatchBaseline]
    /// Baseline entries this build cannot read, kept verbatim (never usable as a boundary).
    package private(set) var unreadableDispatchBaselines: [AgentScheduledSendJSONValue] = []
    package var extras: [String: AgentScheduledSendJSONValue]

    package init(
        nativeItems: [NativeItem] = [],
        lastImportCommit: ImportCommit? = nil,
        dispatchBaselines: [DispatchBaseline] = [],
        extras: [String: AgentScheduledSendJSONValue] = [:]
    ) {
        self.nativeItems = nativeItems
        self.lastImportCommit = lastImportCommit
        self.dispatchBaselines = dispatchBaselines
        self.extras = extras
    }

    /// `nil` when nothing would be persisted.
    package var nilIfEmpty: AgentSessionProviderHistoryRecovery? {
        nativeItems.isEmpty && lastImportCommit == nil && dispatchBaselines.isEmpty
            && unreadableDispatchBaselines.isEmpty && extras.isEmpty ? nil : self
    }

    package func dispatchBaseline(dispatchID: UUID) -> DispatchBaseline? {
        dispatchBaselines.first { $0.dispatchID == dispatchID }
    }

    /// The starting boundary of one run attempt: its EARLIEST recorded dispatch (captured or not;
    /// a later dispatch never backfills an unsupported first one).
    package func firstDispatchBaseline(runAttemptID: UUID) -> DispatchBaseline? {
        dispatchBaselines.first { $0.runAttemptID == runAttemptID }
    }

    package func nativeItem(forKey key: String) -> NativeItem? {
        nativeItems.first { $0.key == key }
    }

    /// Whether `localItemID` is the local item of any Claude native row in this ledger (Step 4d3a),
    /// whatever that row's envelope digest (a missing or invalid digest still protects the item).
    package func associatesClaudeLocalItem(_ localItemID: UUID) -> Bool {
        nativeItems.contains {
            $0.providerRaw == AgentRecoveryHistoryProvider.claude.rawValue && $0.localItemID == localItemID
        }
    }

    /// Every local item associated to a Claude native row, whatever its digest (Step 4d5: the rows
    /// whose projected tool payload generic sweeps and replacements never rewrite).
    package var claudeLocalItemIDs: Set<UUID> {
        Set(nativeItems.lazy.filter { $0.providerRaw == AgentRecoveryHistoryProvider.claude.rawValue }.compactMap(\.localItemID))
    }

    /// Whether any Claude row of `nativeSessionID` lacks a valid envelope proof (invalidated, legacy
    /// or malformed). Step 4d3b never newly qualifies live output of such a conversation: a proof is
    /// never regenerated or healed from later output.
    package func hasProoflessClaudeItem(nativeSessionID: String) -> Bool {
        nativeItems.contains {
            $0.providerRaw == AgentRecoveryHistoryProvider.claude.rawValue
                && $0.nativeSessionID == nativeSessionID && $0.envelopeDigest == nil
        }
    }

    /// Step 4d3c: clears the envelope proof of the Claude rows whose exact key is in `keys` (the
    /// keys a refused producer newly inserted), both the typed value and a preserved raw
    /// `envelopeDigest` member, keeping its key, local item association and every other unknown
    /// member (rows, receipts and baselines are untouched). Every other row (imported, another
    /// producer's, Codex) keeps its proof. The reader refuses a known entry without a proof, so
    /// reconciliation of these rows refuses until a future requalification (none exists). An empty
    /// `keys` changes nothing. Returns whether anything changed.
    @discardableResult
    package mutating func invalidateClaudeEnvelopeProofs(forKeys keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        var changed = false
        nativeItems = nativeItems.map { item in
            guard item.providerRaw == AgentRecoveryHistoryProvider.claude.rawValue,
                  keys.contains(item.key),
                  item.envelopeDigest != nil || item.extras["envelopeDigest"] != nil
            else { return item }
            changed = true
            var extras = item.extras
            extras.removeValue(forKey: "envelopeDigest")
            return NativeItem(
                providerRaw: item.providerRaw,
                nativeSessionID: item.nativeSessionID,
                nativeEntryID: item.nativeEntryID,
                rowKindRaw: item.rowKindRaw,
                ordinal: item.ordinal,
                localItemID: item.localItemID,
                envelopeDigest: nil,
                extras: extras
            )
        }
        return changed
    }

    /// Exactly 64 lowercase hex digits (a SHA-256 rendered by `sha256Hex`).
    package static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }

    /// Lowercase hex SHA-256 of `data`.
    package static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Lowercase hex rendering of a SHA-256 digest.
    package static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Unambiguous length-prefixed encoding of a native row key.
    package static func rowKey(
        providerRaw: String,
        nativeSessionID: String,
        nativeEntryID: String,
        rowKindRaw: String,
        ordinal: Int
    ) -> String {
        [providerRaw, nativeSessionID, nativeEntryID, rowKindRaw, String(ordinal)]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static let knownKeys: Set<String> = ["nativeItems", "lastImportCommit", "dispatchBaselines"]

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
        nativeItems = try container.decodeIfPresent([NativeItem].self, forKey: HistoryDynamicKey("nativeItems")) ?? []
        lastImportCommit = try container.decodeIfPresent(ImportCommit.self, forKey: HistoryDynamicKey("lastImportCommit"))
        // Element-wise: one unreadable baseline never fails the session; it round-trips verbatim.
        var typed: [DispatchBaseline] = []
        var unreadable: [AgentScheduledSendJSONValue] = []
        let rawBaselines = try container.decodeIfPresent(
            [AgentScheduledSendJSONValue].self,
            forKey: HistoryDynamicKey("dispatchBaselines")
        ) ?? []
        for raw in rawBaselines {
            if let data = try? JSONEncoder().encode(raw),
               let value = try? JSONDecoder().decode(DispatchBaseline.self, from: data)
            {
                typed.append(value)
            } else {
                unreadable.append(raw)
            }
        }
        dispatchBaselines = typed
        unreadableDispatchBaselines = unreadable
        extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: HistoryDynamicKey.self)
        try HistoryDynamicKey.encode(extras, into: &container)
        if !nativeItems.isEmpty {
            try container.encode(nativeItems, forKey: HistoryDynamicKey("nativeItems"))
        }
        try container.encodeIfPresent(lastImportCommit, forKey: HistoryDynamicKey("lastImportCommit"))
        if !dispatchBaselines.isEmpty || !unreadableDispatchBaselines.isEmpty {
            var array = container.nestedUnkeyedContainer(forKey: HistoryDynamicKey("dispatchBaselines"))
            for baseline in dispatchBaselines {
                try array.encode(baseline)
            }
            for raw in unreadableDispatchBaselines {
                try array.encode(raw)
            }
        }
    }
}

package enum AgentSessionHistoryImportError: Error, Equatable {
    /// An ordinary save carried an older history receipt than the committed import (an older
    /// snapshot). Nothing was written.
    case staleHistorySnapshot
    /// An import commit whose payload does not carry exactly its own receipt. Nothing was written.
    case receiptMismatch
}

/// Dynamic member key that keeps unknown members of the history envelope.
private struct HistoryDynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }

    static func extras(
        in container: KeyedDecodingContainer<HistoryDynamicKey>,
        excluding known: Set<String>
    ) throws -> [String: AgentScheduledSendJSONValue] {
        var extras: [String: AgentScheduledSendJSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(AgentScheduledSendJSONValue.self, forKey: key)
        }
        return extras
    }

    /// Encodes unknown members, skipping any a typed member of the same name is about to replace
    /// (a valid typed proof overwrites a preserved invalid raw value; a `nil` one never erases it).
    static func encode(
        _ extras: [String: AgentScheduledSendJSONValue],
        into container: inout KeyedEncodingContainer<HistoryDynamicKey>,
        overriddenBy typed: Set<String> = []
    ) throws {
        for (key, value) in extras where !typed.contains(key) {
            try container.encode(value, forKey: HistoryDynamicKey(key))
        }
    }

    /// A tolerant optional SHA-256 proof: exactly 64 lowercase hex digits is typed; anything else
    /// (absent, `null`, another type, malformed) is `nil` and, when present, stays an unknown member.
    static func tolerantDigest(in container: KeyedDecodingContainer<HistoryDynamicKey>, key: String) -> String? {
        guard let value = try? container.decodeIfPresent(AgentScheduledSendJSONValue.self, forKey: HistoryDynamicKey(key)),
              case let .string(digest) = value,
              AgentSessionProviderHistoryRecovery.isSHA256Hex(digest)
        else { return nil }
        return digest
    }
}
