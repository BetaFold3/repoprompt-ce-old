# Claude identity resolution — OracleB planning

Scope: read when the task touches implementation of the Claude history-identity prerequisite under owner O15.
Authority: Reference
Last-verified: 2026-10-23

Exact preset: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; chat `claude-identity-resoluti-DCE5EB`; operation `CA5AFAFF-8AF9-4D31-919A-13CCE3D28A57`. Full independent response retained below. These are recommendations, not owner Decisions; main dispositions are in [resolution evidence](phase4-prerequisite-resolution.md).

# Oracle Plan



# Plan: native Claude history identity for lossless restart (Phase 4 prerequisite)

## 1. Summary

Today a Claude history import into a live conversation is always refused. Nothing ties a native JSONL entry to a local transcript item. Live output gets random item and invocation IDs, the outbound user message carries no UUID, and the preflight looks for ledger user associations that nothing in this build ever writes.

The smallest complete fix makes identity deterministic on both sides, using functions that already exist:

1. **Outbound user message.** Every gated Claude dispatch sends its existing `dispatchID` as the streamed user message's `uuid`. The dispatch's immutable `DispatchBaseline.userItemIDs` already lists all of its local user items in order, so a single-item send and a multi-item send associate the same way. No new persisted field is needed.
2. **Live output.** Complete `assistant`/`user` envelopes carry a native-row identity carrier (session, entry UUID, block ordinal, row kind, raw tool-use ID) through the existing translator → bridge → `AIStreamResult` path. A small reducer step in `applyStreamResult` assigns each live row the same deterministic ID that `ClaudeSessionHistoryReader` gives the matching JSONL row.
3. **Preflight.** The ledger-`localItemID` user check is replaced by an exact entry-UUID ↔ dispatch-baseline match. The suffix/compaction refusals, the owner-save transaction and the cursor CAS stay as they are.
4. **Reader.** The decoder subset grows only by what the pinned SDK chain model needs: graph-only `system`/`progress`/`attachment` nodes, ignored `file-history-snapshot` lines, and validated but never-projected `thinking` blocks. Compaction, sidechains, `isMeta` and API-error messages stay real refusals.

Every unproven assumption fails closed as a typed refusal: no duplicated rows, no misattribution. Everything that changes production behavior sits behind the existing `capturesDispatchBaselines` gate, which stays OFF. The one exception is the deterministic tool invocation ID for built-in Claude, justified in §3.C.

This is a targeted change, not a refactor. The architecture (owner-operation TaskLocals, provider-owned translator DTOs, one owner save followed by a cursor CAS) already has the right extension points.

---

## 2. Current-state analysis

### Outbound path
`ClaudeAgentModeCoordinator` (lines 2053–2130):
- computes `handoff.dispatchBaselineIdentity`, which yields `dispatchID` = first receipt `attemptID`, plus `runAttemptID` and the ordered `userItemIDs`;
- binds `AgentRuntimeOperationOwner.$session` and `.$writeAdmission`;
- calls `controller.sendUserMessage(providerBoundText)`.

`ClaudeNativeProcessSessionController.sendUserMessage`:
- fences;
- runs `writeAdmission`, which calls `admitClaudeDispatchBaseline` → `captureClaudeDispatchBaseline`. That commits the zero-row receipt and baseline before any bytes;
- encodes with `ClaudeSDKProtocolCodec.encodeUserMessage(text:sessionID:)`, which sends no `uuid`.

### Baseline
`captureClaudeDispatchBaseline` (RecoveryActions 846–959) returns early when the gate `recoveryActionRunner.capturesDispatchBaselines` is off or the agent isn't `.claudeCode`. It records a `DispatchBaseline` (captured or unsupported) keyed by `dispatchID`, and returns `.alreadyRecorded` for a dispatch that already has one.

### History read
`ClaudeSessionHistoryReader.decode`:
- validates the whole complete-line candidate, refusing any entry type other than `user`/`assistant`, any `subtype`, and any content block other than `text`/`tool_use`/`tool_result`;
- derives row IDs as `deterministicUUID("rpce-claude-history-row-v1", [provider, session, entryUUID, kind, ordinal])` and tool invocation IDs as `deterministicUUID("rpce-claude-history-tool-v1", [provider, session, toolUseID])`;
- filters out ledger-known rows before returning, so known rows never reach the planner.

### Preflight
`AgentProviderHistoryAssociationPreflight.check`:
- requires every `baseline.userItemIDs` to be the `localItemID` of a ledger userText row. Nothing writes that, so it always refuses (by design today);
- refuses any observation row with `item == nil`;
- requires canonical output after the dispatch ⊆ ledger `localItemID`s ∪ observation item IDs;
- refuses compacted turns (`.notEnumerable`).

### Planner and commit
`AgentProviderHistoryImportPlanner.plan`:
- dedups by ledger key, then by `existingItemIDs` (suffix only, at the RecoveryActions call site);
- appends new items behind a label.

The commit goes through the owner save (`pendingHistoryImportCommit` → `saveAgentSession(committingHistoryImport:)`), and the cursor CAS runs afterwards.

### Live stream
`handleStreamPayload` → translator `parseAssistantMessage`/`parseUserMessage` flattens each envelope into `ClaudeProviderStreamResult`s. The top-level `uuid`, `session_id`, block index and `tool_use_id` are lost. `resolveInvocationID` assigns a random `UUID()` per `tool_use_id`. Then `ClaudeCompatibleProviderRuntimeBridge.streamResult(from:)` produces an `AIStreamResult`, which reaches `AgentModeViewModel.applyStreamResult`:
- `content` → `enqueueAssistantDelta`, which merges into a streaming row. Consecutive text blocks become one item, so a row-level identity is impossible.
- background content → `applyBackgroundAssistantDelta`.

### Reusable pieces
- `dispatchID` and `DispatchBaseline.userItemIDs`
- the TaskLocal owner pattern
- `AgentChatItem.replacingID`
- `deterministicUUID`
- the owner-save transaction and `outputItemIDs`/`.notEnumerable`
- `recordBackgroundRows` (records whatever is appended after the delivery starts)

### What blocks import today
- no outbound UUID;
- no identity on live rows;
- content merging in the reducer;
- the preflight's unwritable user-association requirement;
- the reader refusing chain metadata and `thinking`, which ordinary histories plausibly contain.

---

## 3. Design

### A. Outbound user-message identity (answers Q1 and Q2)

**Decision: reuse `dispatchID` as the outbound `uuid`, and associate through the baseline. No new ledger or baseline field.**
- `DispatchBaseline.dispatchID` already *is* the outbound UUID, and `userItemIDs` already holds the ordered constituents. A native userText entry whose `uuid` parses to a recorded baseline's `dispatchID` therefore associates **all** of that baseline's `userItemIDs`, all-or-nothing. Multi-item sends are covered exactly like single-item sends.
- `NativeItem` keeps its single `localItemID` (still `nil` for user rows, still meaning "not projected"). The association can be recomputed from `nativeEntryID` (observation or ledger) plus `dispatchBaselines` every time, so nothing extra is persisted and there is no new authority.

**At most one write carries a given UUID.** A new view-model helper (in `AgentModeViewModel+RecoveryActions.swift`):

```swift
func claudeOutboundUserMessageUUID(_ identity: AgentDispatchBaselineIdentity?, session: AgentTabSession) -> UUID?
// returns identity.dispatchID only if:
//   recoveryActionRunner.capturesDispatchBaselines && session.selectedAgent == .claudeCode
//   && identity != nil
//   && session.providerHistoryRecovery?.dispatchBaseline(dispatchID:) == nil   // first admission only
```

The "no baseline recorded yet" rule handles retries:
- If an earlier admission recorded a baseline, its bytes may have been written, so a retry sends **no** UUID. Its native entry then has no association, and the import refuses (fails closed). This matters because a duplicate UUID with different raw content would make the reader refuse the whole file (`conflictingDuplicate`) for good.
- If the earlier attempt never reached admission, no bytes were written, so binding again is safe.

**Plumbing: a TaskLocal next to `writeAdmission`.** Add to `AgentRuntimeOperationOwner` (`AgentRuntimeLaunch.swift`):

```swift
/// Caller-supplied native identity for the ONE user message this owner operation writes.
@TaskLocal package static var outboundUserMessageUUID: UUID?
```

Why a TaskLocal:
- It is the existing owner-operation mechanism.
- It is immutable for the binding's scope and has the same lifetime as `writeAdmission`.
- It leaves the controller protocol, Codex/ACP controllers and test fakes untouched.

A `sendUserMessage(_:messageUUID:)` parameter would widen every provider and fake.

Rules:
- The coordinator binds it in the same `withValue` nest only when the helper returns non-nil.
- `ClaudeNativeProcessSessionController.sendUserMessage` reads it **once at entry**, before the fence, into a `let`, and passes it to the codec. Other controllers never read it.
- Per the existing doc comment, `Task.detached` re-binding applies if the send path ever detaches. It does not today.

**Codec:** `encodeUserMessage(text:sessionID:uuid: String? = nil)`. When non-nil, add a top-level `"uuid"` (lowercased UUID string). When nil, the payload is byte-identical to today's.

**Unknown to settle before landing (blocks Slice 1):** the exact streamed-input key name. Quote it from the pinned SDK v0.2.173 `types.py`/transport source into evidence. If the pinned source doesn't name the key, Slice 1 is blocked rather than guessed.

Acknowledgement is never treated as proof that the native entry exists. If the entry is missing, the import refuses.

### B. Native reader profile (answers Q5)

The rule: support only what the pinned chain model needs to accept *ordinary* histories, and keep a real refusal for anything that changes meaning. `profileName` becomes `"nativeEntriesSubsetV2"`. It is recorded in new baselines and is not a gate; V1 baselines stay importable because the cursor is a complete-line boundary.

**Entry roles.** Replace `Entry.isAssistant` with `role: .user | .assistant | .graphOnly`.

| Input | Handling |
|---|---|
| `user`, `assistant` | Unchanged validation. `subtype` still refused on these. |
| `system`, `progress`, `attachment` | **Graph-only node**: requires `uuid`, parentUuid rules and `sessionId` match. Content ignored, no rows. `rejectedWhenTrue` still applies (sidechain/meta). `logicalParentUuid`, `compactMetadata`, `teamName` and `agentId` still refused. `system` with a `subtype` containing `compact` → `.metadata("compact", line)`. |
| `file-history-snapshot` | **Ignored line**: valid JSON object, no graph role. The `.fileHistorySnapshot` refusal case is no longer produced; keep the case for source compatibility or remove it if unused. |
| Any other type (`summary`, `queue-operation`, …) | Still `.entryType`. Extend only with pinned evidence. |
| `thinking` block (assistant only, string `thinking`, optional string `signature`) | New `RowKind.thinking`, deterministic `localItemID`, never projected. |
| `redacted_thinking` block (assistant only, string `data`) | `RowKind.thinking`, `text = nil`, never projected. |
| Empty or whitespace-only assistant text | Row kept with `localItemID`. `item(for:)` returns `nil`, matching the live path, which skips empty text. |
| Unknown top-level keys | Still accepted, consistent with the pinned SDK ignoring unknown keys. A uniform refusal would reject every history as the CLI adds fields. |

**Graph rule.** Effective children are a node's children minus graph-only subtrees that contain no user/assistant entry. Apply the existing branching, tip and parallel-group rules to effective children, and count only user/assistant entries as tips. A graph-only node whose subtree does contain messages must have exactly one effective child (pass-through).

This accepts:
- a trailing `turn_duration`-style system leaf;
- a progress side leaf;
- a system or attachment entry between two messages.

A graph-only node that opens a second message branch is still `.ambiguousBranch`. Tool-result association still requires the result's parent to be the call entry; a progress node in between is still refused. Complexity stays O(n) with one post-order pass.

**Before landing (blocks Slice 2):** quote the pinned `sessions.py` v0.2.173 transcript-entry type set and visibility filter into evidence. If it differs from `{user, assistant, progress, system, attachment}`, use exactly the pinned set. The `thinking`/`redacted_thinking` block shapes come from the public Messages API docs, not the SDK fixtures; cite that separately.

**Extracted shared identity functions** (in `ClaudeSessionHistoryReader`, used by both `project` and the live path):

```swift
package static func rowLocalItemID(nativeSessionID: String, nativeEntryID: String, kind: RowKind, ordinal: Int) -> UUID
package static func toolInvocationID(nativeSessionID: String, toolUseID: String) -> UUID
package static func payloadDigest(_ row: Row) -> String   // SHA-256 hex, length-prefixed [kind, text, toolName, toolUseID, inputJSON, isError]
```

**Ledger conflict check.** A new `Unsupported.ledgerConflict(String)`. In `.importAfter`, **before** the known-row filter, build a key → digest map from the ledger once. Any row whose key is known and whose ledger `payloadDigest` is non-nil and differs from the row's digest refuses the whole candidate. Old ledger items with no digest are not compared. Within one file, the existing `conflictingDuplicate` still applies; this covers replacement/rescan.

**Still refused, and it is the real format limit (stated, not hidden):**
- any session that has ever compacted (`compact_boundary`, `isCompactSummary`, `logicalParentUuid`);
- `isMeta` user entries (harness-injected model input);
- `isApiErrorMessage` assistant entries;
- sidechain markers;
- `queue-operation`/`summary` lines;
- image or other non-text `tool_result.content`;
- assistant-side `tool_result` blocks;
- a progress node between a call and its result.

So the claim is "ordinary short, uncompacted, subagent-free histories", not "complete ordinary support". Whether `-p --output-format stream-json` histories actually contain these classes is a live-qualification question and stays blocked.

### C. Live native-row identity carrier and reducer seam (answers Q3)

**Package DTO** (`ClaudeProviderStreamResult.swift`, additive):

```swift
public struct ClaudeProviderNativeRowIdentity: Sendable, Equatable {
    public enum Kind: String, Sendable { case assistantText, toolCall, toolResult, thinking }
    public let sessionID: String      // envelope top-level session_id
    public let entryUUID: String      // envelope top-level uuid
    public let kind: Kind
    public let ordinal: Int           // RAW index in message.content (skipped blocks still count)
    public let toolUseID: String?     // raw tool_use id / tool_result tool_use_id
}
// ClaudeProviderStreamResult gains: public let nativeRow: ClaudeProviderNativeRowIdentity?  (init default nil)
```

**Translator (`ClaudeSDKNDJSONTranslator`).** Attach `nativeRow` only when all of these hold:
- top-level `type` is `assistant` or `user` (never `message` or `stream_event`);
- non-empty string `uuid` and `session_id`;
- `parent_tool_use_id` absent or null. Sidechain envelopes get no carrier because their entries live in another file.

Carriers:
- assistant `text` → `.assistantText`, block index. A string-content fallback uses ordinal 0, matching the reader's `[.text(text)]`.
- assistant `tool_use` → `.toolCall` + id.
- assistant `thinking` → `.thinking`, only where a `reasoning` result is already emitted.
- user `tool_result` → `.toolResult` + `tool_use_id`, ordinal = raw index in the user content array.
- Assistant-side `tool_result`, `usage`, `message_stop` and `stream_event` results never get a carrier.

`contentMessageID` and `usageObservation` are unchanged.

**Deterministic invocation IDs, single-sourced in the translator.**
- Add an init parameter `invocationIDDeriver: (@Sendable (_ sessionID: String, _ toolUseID: String) -> UUID)? = nil`.
- `resolveInvocationID` uses the deriver when a session ID is known (the envelope's `session_id`, tracked on the translator) and caches the result in `invocationIDByToolUseID` as today. Otherwise it falls back to random, as today.
- Core injects `ClaudeSessionHistoryReader.toolInvocationID` for the built-in variant only.

This is deliberately ungated: it only changes opaque IDs, and calls, results and approval lookups keep reading the same translator map, so pairing can't diverge. Deriving in the reducer instead would split the source of truth from the approval linkage.

**Unknown:** the translator's construction site (controller vs bridge) and the built-in variant enum case (the one alongside `.glm`) must be located; neither is in the provided source.

**Bridge and core.**
- New core value `AgentProviderNativeRowIdentity { nativeSessionID, nativeEntryID, rowKindRaw, ordinal, toolUseID }`, defined next to `AIStreamResult` in `AIProviderFactory.swift`.
- `AIStreamResult.nativeRow` (init default nil).
- `ClaudeCompatibleProviderRuntimeBridge.streamResult(from:)` maps `Kind` → `ClaudeSessionHistoryReader.RowKind.rawValue` with an exhaustive switch, plus a type alias for the package DTO.

**View-model reducer seam (`applyStreamResult`, MainActor).** It runs after the delivery guard and before `switch result.type`:

1. `identityOn = recoveryActionRunner.capturesDispatchBaselines && session.selectedAgent == .claudeCode`, captured once per call.
2. If `identityOn` and `result.nativeRow` is set:
   - `nativeItemID = rowLocalItemID(...)`;
   - **Idempotency:** if `nativeItemID` is already in `session.items` or in any transcript turn's request/activity IDs, return. A replayed complete envelope changes nothing, and nothing is appended, so the background defer is a no-op.
3. Branches:
   - **`content` with `nativeItemID`:** do the existing pre-steps (clear reasoning status on an active run), call `flushPendingAssistantDelta`, end streaming on the delivery's current streaming assistant row through the existing segment-end path, then append a **complete, non-streaming** `.assistant(text).replacingID(nativeItemID)`. Never enqueue into the merge buffer.
     - Background: append through the background row-start path so the row becomes this source's current background row and later `final_content` still finds it. Refactor `applyBackgroundAssistantDelta` into "start row (optional ID)" + "append text".
   - **`tool_call` / `tool_result` / `reasoning`:** the existing branches build the item as today and apply `.replacingID(nativeItemID)` **only when they append a new item**. If a branch updates an existing row (for example an MCP-side result placeholder), it is never re-IDed; the import then refuses honestly.
   - **`final_content`, `usage`, finalization, active/background routing, `recordBackgroundRows`, notification provenance:** unchanged. `final_content` may rewrite the tail row's text; identity is kept, and text is deliberately not compared.
4. With the gate off, or no carrier, the existing path runs byte-for-byte. Results without a carrier (`stream_event` deltas, sidechains, rows created by `final_content`) keep random IDs, and an import that meets them refuses with `canonicalOutputAssociationUnavailable`.

**Unknowns (helper names, to locate in `AgentModeViewModel.swift`):**
- the background current-row registration inside `applyBackgroundAssistantDelta`;
- the streaming-segment-end helper;
- whether the `tool_result` branch appends a distinct `.toolResult` item or upserts.

If it upserts, document it and leave it; do not re-ID.

**Ordering, duplicates, drops.** One stream is strictly ordered. Duplicates are idempotent. A dropped envelope leaves a missing live row, which the import later appends as a recovered row. Live persistence is sequential, so persisted live rows are a prefix of the dispatch's output, and appended history rows are a correct-order suffix.

### D. Association preflight and atomic import (answers Q4)

**`AgentProviderHistoryRow`** gains two additive init parameters with defaults, so the Codex projection is unaffected:
- `localItemID: UUID?` (default `item?.id`): the deterministic identity even when not projected (thinking, empty text);
- `payloadDigest: String?` (default nil).

`ClaudeSessionHistoryReader.observation(_:)` fills both.

**`NativeItem`** gains `payloadDigest: String?` (known key `"payloadDigest"`, `encodeIfPresent`). Old JSON decodes it as nil; old builds carry it through `extras`. The planner stores `row.payloadDigest`.

**`check(...)`.** The signature is unchanged; it reads `ledger?.dispatchBaselines`. The new user/association section:

```
baselineRefusal (unchanged) → canonicalOutputIDs (unchanged; nil → .baselineTargetMismatch)
recorded = ledger.dispatchBaselines filtered to (providerRaw, conversationID, transcriptResetGeneration)
nativeUserEntryIDs = observation userText rows' nativeEntryID ∪ ledger userText NativeItems' nativeEntryID (this conversation)
1. start: some id in nativeUserEntryIDs with UUID(id) == baseline.dispatchID   else .nativeUserAssociationUnavailable
   (the reader dedups an entry UUID, so a match is unique; all baseline.userItemIDs are associated together)
2. every OBSERVATION userText row: UUID(nativeEntryID) == some recorded.dispatchID whose userItemIDs are non-empty
   and all present in canonical (turn requests/activities or suffix)              else .nativeUserAssociationUnavailable
   (steering dispatches qualify only if they recorded a baseline; otherwise refuse)
3. delete the blanket `rows.contains { $0.item == nil }` check (user rows handled by 1–2; other nil-item rows carry localItemID)
4. .notEnumerable → .canonicalOutputAssociationUnavailable (unchanged)
5. associated = ledger localItemIDs ∪ observation rows' localItemID; canonical output ⊆ associated else refusal (unchanged rule)
```

How the specific failure cases resolve:
- **Retraction:** a live row the provider later dropped from history is absent from the observation, so step 5 refuses.
- **Live vs history mismatch:** kind is part of the hash, and invocation IDs are derived from the same function on both sides. So a live-vs-history structural mismatch can only appear as a non-associated ID, which step 5 already refuses. No separate check is added.
- **Compacted dispatch:** refused through `.notEnumerable`.
- **Suffix replacement:** never touches compacted backing.

**Planner call site (RecoveryActions ~1096).** `existingItemIDs` becomes the suffix IDs ∪ every transcript turn's `request?.id` and `allActivities` IDs, so a live row stored outside the suffix is recorded, not duplicated. `plan(...)` keeps its signature. Live rows already in the transcript take the existing "record, do not duplicate" branch, which writes a `NativeItem` with `localItemID` (completed materialization). Ledger rows are written **only** by the import commit; the live item ID is the only identity hint and never suppresses anything.

**Transaction:** unchanged. Rows, ledger and receipt go in one owner save (`pendingHistoryImportCommit`), then `commitHistoryCursor` CAS. A crash between the two replays as a no-op through ledger dedup.

**Refusal text:** the reader's `.unsupported` is already mapped generically in reconcile ("records this version doesn't support"). The new `ledgerConflict` case flows through that mapping. Exhaustive switches over `Unsupported` and `RowKind` will be flagged by the compiler; update each.

### E. Provider scope (answers Q6)

- **Source scope:** the outbound UUID and the identity reducer require `.claudeCode` and the gate. The deriver is injected for the built-in variant only. Import is already `.claudeCode`-only. GLM, Kimi and custom runtimes receive passive carriers but no behavior change.
- **Wrappers:** whether a user-overridden CLI executable is distinguishable at the launch resolver is unknown. If `ClaudeCodeLaunchEnvironmentResolver` exposes an override signal, also exclude it in the helper; otherwise record `assumed: built-in agent selection is the source qualification boundary`.
- **What is source-complete:** codec, TaskLocal, carrier, parity of deterministic projection, preflight, reader subset, and fixture tests.
- **What is not qualified:** whether the installed CLI honors a supplied `uuid`; whether live `AssistantMessage.uuid` and user tool-result envelope `uuid` equal the JSONL `uuid` for every block; which metadata classes `-p stream-json` actually writes; `--resume` session-ID continuity; dangling `tool_use` on resume. Each of these, if false, produces a refusal, never duplication.

---

## 4. File-by-file impact

| File | Change | Why / dependencies |
|---|---|---|
| `Packages/.../ClaudeSDKProtocolCodec.swift` | `encodeUserMessage(text:sessionID:uuid: String? = nil)`; top-level `"uuid"` when non-nil | A. Independent. |
| `Sources/.../Recovery/AgentRuntimeLaunch.swift` | `@TaskLocal package static var outboundUserMessageUUID: UUID?` on `AgentRuntimeOperationOwner` | A. Independent. |
| `Sources/.../SDK/ClaudeNativeProcessSessionController.swift` | `sendUserMessage` reads the TaskLocal once at entry and passes it to the codec. Translator construction injects `invocationIDDeriver` for the built-in variant (locate site). | A, C. After codec, TaskLocal and reader helpers. |
| `Sources/.../Claude/ClaudeAgentModeCoordinator.swift` | Compute `outboundUUID` from the VM helper; bind `$outboundUserMessageUUID` in the existing `withValue` nest when non-nil | A. After the VM helper. |
| `Sources/RepoPrompt/.../AgentModeViewModel+RecoveryActions.swift` | Add `claudeOutboundUserMessageUUID(_:session:)`; widen planner `existingItemIDs` to transcript IDs | A, D. |
| `Sources/.../SDK/ClaudeSessionHistoryReader.swift` | Entry roles; graph-only nodes; ignored `file-history-snapshot`; `RowKind.thinking`; effective-children graph rule; `rowLocalItemID`/`toolInvocationID`/`payloadDigest` statics (and `project` uses them); `Unsupported.ledgerConflict`; ledger digest check before the known filter; profile `V2` | B, D. Pure; first. |
| `Sources/.../Recovery/AgentProviderHistoryImport.swift` | `AgentProviderHistoryRow.localItemID`/`payloadDigest`; preflight steps 1–5; planner stores the digest; `item(for:)` returns nil for empty assistant text and for `.thinking` | D. After reader. |
| `Sources/.../Models/AgentSessionProviderHistoryRecovery.swift` | `NativeItem.payloadDigest` (known key, optional) | D. |
| `Packages/.../ClaudeProviderStreamResult.swift` | `ClaudeProviderNativeRowIdentity`; `nativeRow` field | C. |
| `Packages/.../ClaudeSDKNDJSONTranslator.swift` | Carriers with raw ordinals; session tracking; `invocationIDDeriver` | C. After DTO. |
| `Sources/.../ClaudeCompatibleProviderRuntimeBridge.swift` | Alias and map `nativeRow`; expose the deriver closure | C. |
| `Sources/.../AI/Providers/AIProviderFactory.swift` | `AgentProviderNativeRowIdentity`; `AIStreamResult.nativeRow` | C. |
| `Sources/RepoPrompt/.../AgentModeViewModel.swift` | Pre-switch identity step, idempotency, non-merging identified content, `replacingID` on new tool/reasoning items, background row-start refactor | C. After bridge and reader statics. |
| Tests (`RepoPromptClaudeCompatibleProviderTests`, `Tests/RepoPromptTests/AgentMode/{ClaudeCompatible,Recovery,History}`) | See §6 | Per slice. |
| `docs/architecture/provider-plugins.md` | Optional, deferrable: one paragraph on `nativeRow` | Docs only. |

**Not changed:** `AgentSessionDataService`, `AgentTabSession`, `AgentTranscriptServices`, `AgentProviderHandoff` (its `dispatchBaselineIdentity` is reused), and the plan body.

---

## 5. Risks and migration

- **Schema:** only additive. `NativeItem.payloadDigest` is optional; the ledger stores `rowKindRaw "thinking"` as a plain string. The session stays at version 7, and older builds round-trip unknown members. No migration.
- **Production behavior with the gate OFF:**
  - outbound bytes unchanged (helper returns nil);
  - reducer unchanged;
  - carriers passive;
  - **only** visible change: built-in Claude tool invocation IDs become deterministic UUIDv8.

  Risk: something assumes v4 or cross-session uniqueness. Mitigation: a pairing/approval regression test. Reversible by not injecting the deriver.
- **Duplicate-UUID poisoning:** prevented by the first-admission rule. If it happens anyway, the reader refuses (fails closed).
- **Gated code paths:** while the gate exists there are two content reducers (identified vs merged). When the gate retires, the merged path for built-in Claude should go too. Record that as deferred, not as a new flag.

---

## 6. Implementation order (slices, each independently compilable and testable)

**Slice 1: outbound identity.** Codec, TaskLocal, controller read, VM helper, coordinator bind. Blocked until the pinned key-name quote is in evidence.
- Tests:
  - the codec emits lowercase `uuid` only when given, and nil is byte-identical;
  - the controller payload carries the bound UUID and has none when unbound;
  - admission refusal writes zero bytes;
  - the coordinator doesn't bind when the gate is off, the dispatch is untracked, or a baseline already exists, and binds `dispatchID` otherwise.

**Slice 2: reader subset V2 and shared identity statics** (pure; can run in parallel with Slice 1).
- Accept fixtures:
  - system leaf, progress side leaf, attachment pass-through, `file-history-snapshot`;
  - `thinking`/`redacted_thinking` rows with deterministic IDs;
  - empty text row.
- Refuse fixtures:
  - `compact_boundary`, `isMeta`, `queue-operation`;
  - graph-only node opening a second message branch;
  - progress between a call and its result.
- Other tests:
  - a user entry with `uuid` = X yields a userText row with `nativeEntryID` X;
  - `project` output is unchanged for V1 fixtures, with identical IDs.

**Slice 3: live carrier and reducer seam** (needs the Slice 2 statics).
- Translator tests:
  - raw ordinals across [thinking, empty text, text, tool_use];
  - sidechain, missing `uuid` and `stream_event` produce no carrier;
  - user `tool_result` carrier;
  - string-content ordinal 0;
  - usage unchanged.
- Deriver tests: call and result share an ID equal to `toolInvocationID`; with no deriver, behavior is legacy.
- Bridge mapping test.
- **Parity contract test:** the same native JSON sent as a live envelope (translator → bridge → `rowLocalItemID`) and as a JSONL line (reader) yields identical item and invocation IDs for every kind.
- VM tests (gate on):
  - consecutive identified texts produce two items;
  - a replayed envelope is a no-op;
  - tool items carry deterministic IDs;
  - background rows are recorded and `final_content` replaces the identified row;
  - finalization and usage are unchanged.
- VM golden test (gate off): output identical to today's.

**Slice 4: association, conflict, import** (needs 1–3; land the preflight and planner-call-site edits together, atomically).
- Preflight tests:
  - single-item and **multi-item** dispatch match → passes and associates every `userItemID`;
  - foreign user UUID → `nativeUserAssociationUnavailable`;
  - steering entry matching another recorded baseline → passes; without a baseline → refuses;
  - random-ID canonical output → refuses;
  - retraction → refuses;
  - compacted → refuses;
  - live thinking associated through `localItemID`.
- Reader tests: digest conflict on rescan → `ledgerConflict`; no digest → accepted.
- Planner tests: live rows recorded, not appended; missing suffix appended in order behind the label; digest persisted; transcript-only IDs deduped.
- VM end-to-end (fixture `FileAccess`, gate on): baseline → identified live rows saved → a truncated save simulates a crash → reconcile imports only the missing suffix → a second reconcile is a no-op → a crash between save and CAS replays as a no-op.
- Persistence tests: `payloadDigest` round-trips; legacy JSON decodes; unknown keys survive.

Per the review policy, each slice gets OracleA/OracleB review. Evidence goes in the plan's evidence directory, and fixture results are labeled as fixtures, never as live.

---

## Recommendations

1. **Q1:** Use `dispatchID` as the outbound `uuid`, bound only on a dispatch's first admission. Associate the whole ordered `DispatchBaseline.userItemIDs` by exact entry-UUID match. This needs no new ledger or baseline field, and multi-item sends are covered rather than excluded.
2. **Q2:** Use a TaskLocal (`outboundUserMessageUUID`) next to `writeAdmission`, read once at the top of `sendUserMessage`, with an optional codec parameter. Don't widen the controller protocol.
3. **Q3:**
   - The minimum seam is one optional `nativeRow` carrier attached at envelope parse, before flattening, using raw block ordinals.
   - Tool invocation IDs are derived deterministically inside the translator.
   - One pre-switch reducer step assigns IDs, stays idempotent, and stops merging only identified content. Usage, `final_content`, finalization and routing stay untouched.
   - The parity test is the core contract.
4. **Q4:**
   - Keep the existing single owner save and cursor CAS.
   - Ledger rows are written only by that commit; the live item ID is the only hint.
   - Payload conflicts are checked in the reader before ledger dedup (digest).
   - Retractions and identity mismatches are caught by the canonical ⊆ associated rule.
   - Compacted backing refuses through `.notEnumerable`.
5. **Q5:** Accept graph-only `system`/`progress`/`attachment`, ignored `file-history-snapshot`, and never-projected `thinking`. Keep compaction, `isMeta`, API-error, sidechain, `queue-operation` and image results as real refusals, and state plainly that compacted or subagent-using sessions remain non-importable.
6. **Q6:** Restrict the contract to built-in `.claudeCode` behind the existing gate. GLM, Kimi, custom runtimes and wrappers are excluded. Source completeness ≠ qualification: every live identity assumption stays blocked and fails closed.

**Can safely stay blocked:**
- live CLI qualification (UUID honoring, live/native UUID equality, metadata classes in `-p` histories, `--resume` session continuity, dangling `tool_use`);
- compaction support;
- `isMeta`/`queue-operation` support;
- steering without baselines;
- `final_content`-created rows;
- unverified TS 0.3.309 `user_message_uuid(s)`/supersedes leads (no code until the types are verified);
- production gate activation.

**Record under `assumed:`** (reversible, so proceeding on these; owner may override):
- (a) deterministic invocation IDs ship ungated for built-in Claude;
- (b) profile bump to V2 with no gate;
- (c) the wrapper boundary is "built-in agent selection" unless the resolver exposes an override signal.

**Still to locate before or while implementing, not invented here:**
- the streamed-user `uuid` key quote and the `sessions.py` type set (these block Slices 1 and 2);
- the translator construction site and the built-in variant case;
- the VM background row-start and segment-end helpers;
- whether the `tool_result` branch appends or upserts.

## Targeted continuation after pinned TS verification

Operation `1AE7DF31-89B0-4C2D-9B13-4AA9AF803E67`; same inherited preset verified. Full response follows; this narrows/supersedes initial recommendations where stated.

# Oracle Plan



# Native Claude history identity: first slice, retry contract and minimum ledger evidence

## 1. First commit: outbound caller UUID with an explicit baseline claim

### Retry contract: omit the UUID on any admission that doesn't create the baseline

| Option | Behavior when admission returns `.alreadyRecorded` (earlier bytes unknown) | Verdict |
|---|---|---|
| Reuse the same UUID | If the earlier bytes landed, the CLI gets two user messages with one UUID. Native behavior is CLI-internal: it might deduplicate or drop the second one (which changes send semantics), or persist both (the reader then sees `conflictingDuplicate` and the whole file is refused for good). | Rejected |
| Refuse the send | Retry fails where it works today, which breaks existing send semantics. | Rejected |
| **Omit the UUID** | Bytes are the same as today's send. If the earlier write never landed, the claimed UUID never appears, so preflight refuses. If it did land, the extra user entry without a UUID matches no claim, so preflight refuses. Either way the result is honest. | **Chosen** |

**The decision sits inside admission, not in a coordinator pre-check.** The previous plan's helper read `dispatchBaseline(dispatchID:) == nil` in the coordinator. There is an `await` between that check and the admission that actually commits, so two different points would each decide. Instead, the existing `AgentRuntimeOperationOwner.writeAdmission` TaskLocal closure **returns** the UUID to put on the wire:

```swift
// before: writeAdmission: (@Sendable () async throws -> Void)?        (shape to confirm)
// after:  writeAdmission: (@Sendable () async throws -> UUID?)?       // nil = omit uuid
```

- `captureClaudeDispatchBaseline` returns the UUID only when **this call** records a new *captured* baseline with the gate on and agent `.claudeCode`. It returns nil for: gate off, untracked dispatch, `.alreadyRecorded`, or an unsupported baseline.
- `ClaudeNativeProcessSessionController.sendUserMessage` keeps admission's result as a `let` and passes it to `encodeUserMessage(text:sessionID:uuid:)`. With nil, the bytes are identical to today's.
- No new TaskLocal is needed, so drop the previous plan's `outboundUserMessageUUID`.
- Every other place that reads `writeAdmission` discards the result with `_ =`.
- **To check:** list every reader and binder of `writeAdmission`. If a non-Claude controller reads it, the change is still one line per site. If there are more than about 3 such sites, report back before widening.

### Proof stored in the baseline (additive, fixed when the baseline is first recorded)

Add one optional field to `DispatchBaseline`:

```swift
struct OutboundUserMessageClaim: Codable, Equatable { let uuid: UUID; let textSHA256: String }
var outboundUserMessage: OutboundUserMessageClaim?   // known key, encodeIfPresent
```

- The field is written in the same zero-row receipt and baseline commit that already happens before any bytes go out. That makes the claim durable before the UUID can exist on the wire.
- `uuid` = `dispatchID`. It is stored explicitly so association never infers it from `dispatchID`.
- `textSHA256` is computed over the exact provider-bound text.
- **Legacy baselines:** they have nil, so they never associate.
- **Rollback:** if an old build drops the unknown key, the baseline becomes legacy, and legacy refuses.
- **To check:**
  - Whether `DispatchBaseline` keeps unknown keys. Either answer is fail-closed.
  - Whether the controller changes `providerBoundText` before encoding. If it does, compute the digest from the text the controller actually encodes.

### Association proof in `AgentProviderHistoryAssociationPreflight.check` (replaces the ledger-`localItemID` user check)

1. The start baseline has a non-nil `outboundUserMessage`. Otherwise refuse with `.nativeUserAssociationUnavailable`.
2. Exactly one userText entry (from the observation or a Claude ledger `NativeItem`) has `UUID(nativeEntryID) == claim.uuid`. That entry has exactly one text block, and the SHA-256 of its text equals `claim.textSHA256`.
3. **Ordered multi-user completeness:** every item in `baseline.userItemIDs` appears in canonical exactly once, in baseline order, and none is missing. The match is all-or-nothing.
4. Every other userText row in the observation matches the claim of some other recorded baseline in the same conversation and generation, and passes steps 2–3 for that baseline. Otherwise refuse.
5. Remove the blanket `item == nil` refusal **only** for userText rows associated by steps 2–4.
6. Output association is unchanged. Live output still has random IDs, so any dispatch with persisted live output still refuses. That is correct for commit 1.

Nothing in this commit changes production behavior: with the gate off, no baselines are captured, so nothing is claimed, sent or imported.

**Tests:**
- Codec: nil gives identical bytes; non-nil adds a lowercase `uuid`.
- Admission:
  - `newCaptured` returns the UUID and persists the claim;
  - `.alreadyRecorded`, unsupported baseline, gate off and untracked dispatch all return nil;
  - admission that throws writes zero bytes;
  - a retry after a recorded baseline sends no `uuid`.
- Preflight:
  - single-item and multi-item dispatches pass;
  - each of these refuses: legacy baseline, missing entry, entry duplicated across observation and ledger, text-digest mismatch, multi-block user content, a missing, reordered or duplicated constituent, an unclaimed extra user entry, steering without a claim.
- Persistence: the claim round-trips; legacy JSON decodes with nil.

Withdraw the previous plan's ungated deterministic tool-invocation deriver. It breaks the "no ungated production changes" rule; move it into the reducer slice behind the gate.

---

## 2. Reconciliation evidence: one optional field on `NativeItem`, no new collections

**Yes, a single extension is enough.** Replace the previous plan's per-row `payloadDigest` with one field:

```swift
var envelopeDigest: String?   // NativeItem, known key, encodeIfPresent
```

- **What it covers:** SHA-256 over the envelope's full semantic payload, length-prefixed: entry type, the ordered list of every block (kind, raw ordinal, text, tool name, tool-use ID, canonical input JSON, result text, `isError`), and every block including ones that are never projected.
- **Stored on every `NativeItem` of the envelope.** The copy on each row is redundant, but it avoids a `materializedEnvelopes` collection.
- **No count field.** Because the digest covers the ordered block list, any added, removed or changed block changes it.
- **No zero-block persistence.** The supported profile is defined so every accepted envelope yields at least one row (empty assistant text and thinking keep their rows). An envelope that would yield zero rows is a profile refusal.

**Conflict check before dedup** runs in `ClaudeSessionHistoryReader`, `.importAfter`, before the known-row filter:

- Group observation rows by `nativeEntryID`.
- For any envelope with **any** ledger-known key, all of these must hold, or the reader refuses with `.ledgerConflict`:
  - the ledger key set for that entry equals the observed key set;
  - every one of those ledger rows carries the same non-nil `envelopeDigest`;
  - that digest equals the observed digest.
- Claude ledger rows with no digest refuse. In practice there are none, because Claude import has always refused. Codex is untouched.
- Envelope atomicity on write: the planner materializes all rows of an envelope or none.

**Overlap with live canonical rows** (reducer slice, needs no persistence): when an observation row's `localItemID` matches an existing canonical item, `item(for: row)` must be semantically equal to that item (text, tool name and input, result, `isError`) before the preflight treats it as already present. A mismatch refuses. This covers normalization, refusal-fallback rewrites and `final_content` edits without assuming raw wire output matches history.

**No persisted refusal is needed.** Retraction, supersede and refusal-fallback all leave canonical rows with no matching history counterpart: either the UUIDs are derived or the row is gone. Rule 5 (canonical ⊆ associated) already refuses these at every reconciliation, deterministically, from data that already exists. A persisted marker would only matter if the live reducer deleted or rewrote canonical rows on retraction. Instead, make that a contract for the reducer slice: **it must not apply `supersedes`, `aborted` or `retracted_message_uuids` to canonical rows.** `DispatchBaseline` stays immutable.

---

## 3. What the source can honestly claim, and what still needs live qualification

**Profile-local typed refusals to add now** (cheap, reader denylist only):
- `supersedes`, `aborted`, or any retraction-UUID key, at entry level or inside `message`;
- any refusal-fallback entry. This already refuses through `.entryType`/`subtype`; add a test that pins it.

Correction to the previous plan: drop the blanket graph-only acceptance of `system`/`progress`/`attachment`. A `structured_output` attachment can be the only persisted output, and a compact summary carries meaning. Leave those entries refused as they are today, with no metadata relaxation in these commits.

**Claim that is safe once the source work lands:**
> For built-in `.claudeCode` with the dispatch-baseline gate on (not activated):
> - a native user entry associates to local user items only through a caller UUID claimed in a baseline that was durable before any bytes were sent, with an exact text digest and complete ordered constituents;
> - history rows are imported only when every overlapping envelope is semantically identical to what the ledger and canonical transcript already hold;
> - any compaction, sidechain, metadata entry, retraction, supersede or abort marker, unsupported block, or ambiguous graph refuses with a typed reason, and the refusal leaves transcript, ledger and cursor unchanged.

**Not claimed (final live qualification, still pending):**
- that the installed CLI and wrapper persist the caller's streamed `uuid` as the native entry `uuid`;
- that live envelope UUIDs equal native UUIDs for each block, including tool-result user envelopes;
- that a missing marker means there was no retraction (the native entry union is CLI-internal);
- what share of ordinary `-p stream-json` histories fit the profile. Public fixtures show `progress`/`system`/`attachment` carry graph structure, so coverage **may be close to zero**; do not describe this as ordinary-history support;
- durability after acknowledgement (no fsync is assumed);
- session continuity across `--resume`.

Build nothing beyond the typed refusals: no supersede handling, no derived-UUID mapping from TS 0.3.309, no persisted issue log, no retention or tooling.

---

## Recommendations

1. **Commit 1:**
   - `writeAdmission` returns `UUID?`. It is non-nil only when this call records a new captured baseline.
   - Add `DispatchBaseline.outboundUserMessage {uuid, textSHA256}`.
   - Add the optional `uuid` codec parameter.
   - Rewrite the preflight user association: exact claim match, text digest, ordered all-or-nothing constituents.
   - Retries after `.alreadyRecorded` **omit** the UUID; legacy baselines never associate.
   - Drop the separate TaskLocal and the ungated deriver.
2. **Commit 2:** `NativeItem.envelopeDigest`, the envelope-grouped `.ledgerConflict` check before the known-row filter, all-or-nothing envelope materialization, and the reader refusals for `supersedes`/`aborted`/retraction markers.
3. **Commit 3:** the gated live carrier and reducer, with the semantic-overlap comparison and the rule that retraction events never mutate canonical rows. Move the deterministic deriver here, behind the gate.
4. Keep metadata entries refused. Report ordinary-history coverage as unqualified and possibly near zero, and leave all six live-qualification items above blocked.
5. **Record under `assumed:`** (reversible):
   - (a) omit-on-retry;
   - (b) one claim field on the baseline;
   - (c) digest-only, with no count;
   - (d) no persisted refusal.
6. **Validate during implementation:**
   - every reader and binder of `writeAdmission`;
   - whether `DispatchBaseline` keeps unknown keys;
   - whether the controller encodes `providerBoundText` exactly as passed;
   - the streamed-input `uuid` key, quoted from the verified `sdk.d.ts` `SDKUserMessage` into evidence.


## Synthetic-capture continuation recovered 2026-10-23

Recovered verbatim from chat `claude-identity-resoluti-DCE5EB` and its matching export. The interrupted send's result receipt was unavailable: unkeyed Oracle wait returned no undelivered operations, and the prior execution cell no longer existed. The returned preset ID/name therefore could not be reverified for this continuation. Retained as unverified consultation evidence; not synthesized or treated as implementation approval. Earlier verified planning and source reviews are unaffected.

# Oracle Plan

# Next step after the synthetic-only Claude CLI capture

## Pause credential-dependent capture

Yes, pause it until the owner authenticates through the CLI's normal flow.

- **No other auth routes.** The sandbox classifier denied the method-only auth-status check. Under the review policy, that denial makes this a "credentials or manual actions" item, so only the owner can unblock it. Don't try other credential stores, environment variables, config directories, keychain queries or API keys. Don't retry the status check in another form.
- **Don't repeat the experiment as-is.** Running it again now would only produce the same synthetic `authentication_failed` result.
- **Owner question to ask:**
  - **(A) Recommended:** the owner signs in to the CLI normally, outside the agent, then re-approves the same bounded capture: same flags, same caps, the temporary workspace, and reading only the new history.
  - **(B)** Defer live capture and keep the gate pending.
  - **(C)** Use another credential source. Rejected.
  - Until the owner answers, continue under (B). This blocks only the capture, not source work.
- **Unresolved isolation gap, independent of auth.** Plugin metadata (3 entries) and 4 built-in agent definitions loaded even with `--safe-mode --setting-sources user`. A rerun after sign-in is still not proven to be free of ambient plugins or instructions. Record that as a limitation of whatever the rerun yields. Don't add flags or config-dir tricks to remove it without owner approval.

## Parser broadening

None is justified. The evidence actually supports keeping the current refusals:

- **Attachments sit in the parent chain.** They are graph nodes between user and assistant, and their subtypes include `prompt_snapshot`, `session_context` and token-budget entries. These look like model-input context, not neutral metadata. Treating them as skippable would be a guess, and Commit 2 explicitly withdrew that kind of relaxation.
- **The only UUID-equality evidence is on a synthetic error assistant entry.** If that entry is an API-error message, the current profile refuses it anyway, so it says nothing about real completions.
- **Lines without a UUID** (queue-operation, latch, request shape, blob/request, last-prompt, cost-state) must keep refusing as unknown entry types. The one change justified now is a sanitized, hand-written fixture that pins this behaviour: user → attachment chain → assistant, plus one UUID-less line, refuses with a typed reason and leaves transcript, ledger and cursor unchanged. Build it from the observed structure: key names, type names and parent links only, with no captured text.

## Conclusions to record (evidence directory, marked "live CLI 2.1.302, synthetic auth-failure path, not real delivery")

1. A caller-supplied streamed user `uuid` was persisted verbatim as the native user entry `uuid`. This was seen on one version and one path only. It is consistent with the committed 4d1 wire key, not a qualification of it.
2. The assistant stdout `uuid` equalled the native `uuid`, for one single-text-block synthetic error entry only.
3. The session ID stayed the same across two prompts in one process.
4. Attachment entries are real parent-chain nodes. Under the current profile, every ordinary history from this CLI version will therefore refuse, so ordinary-history coverage is currently **zero**, not "possibly near zero."
5. Native history contains UUID-less operational lines. Raw request blobs can hold the complete prompt context, which is a data-sensitivity fact.
6. Isolation was not established (plugin metadata and agent definitions loaded). No credential values or config contents were read. The auth-status attempt was denied and not retried.

**Data handling:** put only a redacted structural summary into evidence: entry types, key names, uuid/parentUuid topology and equality booleans. Never copy blob or request contents. Delete the raw temporary capture once the summary has been checked against it.

## Remaining gates (unchanged unless noted)

- Owner sign-in, then a real-completion capture. **New: this blocks on the owner.**
- Plugin and instruction isolation. **New.**
- Live UUID equality on real assistant output: multi-block, thinking, tool_use and tool-result user envelopes.
- Attachment semantics, which decide whether any ordinary history can ever be supported. This is a future owner decision, after a real sample.
- Retraction, supersede and abort behaviour, `--resume` continuity, the wrapper and installed-version profile, and post-acknowledgement durability.
- Production gate activation and final live acceptance stay OFF.

## Recommendations

1. Set the capture step to `blocked` (open: owner CLI sign-in; plugin isolation unverified). Ask the owner A/B/C with A recommended, and continue on B meanwhile.
2. Don't broaden the parser. Add only the sanitized attachment-chain and UUID-less-line refusal fixture.
3. Record conclusions 1–6 with their exact provenance, never described as qualified delivery. Store only a redacted structural summary and delete the raw capture.
4. Continue source-only, gated work that doesn't depend on capture: Commit 2 (`NativeItem.envelopeDigest`, the `.ledgerConflict` check before dedup, all-or-nothing envelope materialization, retraction/supersede/abort marker refusals), then the gated Commit 3. Each goes through the A/B review.
5. Record under `assumed:`: (a) pause rather than seek other credentials; (b) the current profile refuses ordinary histories because of attachments, which is accepted until a real sample exists.


## Normal invocation continuation — verified 2026-10-23

Returned preset: `OracleB` / `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; selection `inherited`; operation `096445E6-A456-415C-9D1C-60EE950C2CF9`. Main verified identity and read the full response. This is planning guidance, not source review.

# Oracle Plan

# Using the owner's normal Claude CLI for the last capture

The owner chose "Use my normal CLI", but that answer doesn't say which command, doesn't confirm a login, and doesn't say where history may be written. A path lookup gives the agent a candidate command, not the owner's intent. Before the one remaining prompt, the agent needs one owner answer and two pieces of non-secret evidence it already holds. No credential discovery is needed.

## Does looking up the command identify the intended wrapper?

No. A read-only lookup is enough to propose a candidate, but the owner has to confirm it.

- **What the lookup shows:** running `type -a claude` (and the same for `claude-rotator`) in the agent's shell, plus the symlink target and whether each result is a script or a binary, shows where the agent's PATH leads.
- **What it can't show:**
  - Interactive aliases or shell functions (for example `alias claude=claude-rotator` in a shell startup file) are invisible to a non-interactive shell.
  - The historical note doesn't authorize switching commands.
  - The wrapper probably picks the account or config directory internally. Finding out how would mean reading its source, which is the kind of credential exploration the sandbox already denied once. Don't read the wrapper's body; record only its path and file type.
- **What the owner must supply:** a confirmation, not an environment dump. Show them the candidate path(s) the lookup found and have them pick one, or type the exact command name they normally use.
  - The agent runs that command with its inherited environment, adding only the existing capture flags.
  - The agent doesn't set or unset `CLAUDE_CONFIG_DIR`, `HOME` or any auth variable.
  - The owner states that they are signed in through that command. That is a statement from the owner, not something the agent checks.

## Where the history goes: this conflicts with the "temp-only" bound

Compare the env variable **names** the first experiment set or overrode, from our own run record, with the normal invocation. That comparison is non-secret.

- If that run redirected `HOME` or the config directory to a temp location, that probably explains `apiKeySource none`.
- It also means the normal invocation will write the new session file under the owner's **normal** config directory, which the wrapper may choose, not under temp.

So the owner must also choose how the history is handled:

- **H1 (recommended):** the agent may read exactly one new file, located by exact path from the session ID in the init message and the encoded temp working directory. If the wrapper uses a config directory the agent can't infer, the owner gives that directory path (a path, not its contents). The owner deletes that one file afterward; the agent doesn't modify the owner's private home.
- **H2:** the owner copies that one file into the temp workspace themselves.
- **H3:** defer the capture.

## Installed plugin execution vs built-in metadata

Don't ask for zero built-in definitions; that is impossible. Ask for "no installed customization had any way to run." The existing capture can already answer this without a new run:

1. **Classify the 3 plugin entries** from the init message already captured, by name and path:
   - bundled with the CLI install (inside the install root, or marked built-in) → built-in metadata, acceptable;
   - under the user config's plugin or marketplace directory → installed.
2. **The 4 agent definitions** are built-in and acceptable. With tools set to `''`, there is no Task/Agent tool to call them.
3. **Check every way a plugin could execute:**
   - tools, MCP, skills and slash commands: 0 (already recorded);
   - hooks: check that neither stdout nor the native history contains hook system events or hook-related attachment entries. The observed attachment types (environment, model, token budget, session_context, date, prompt_snapshot) include none.
4. **Rule for the capture:**
   - Proceed if every plugin is bundled, or if an installed plugin is listed but none of the checks in step 3 show it running. In that case record "installed plugin listed, not executed; full isolation not proven."
   - Stop if any hook event or hook attachment appears.

Repeat the same check on the new capture.

## What to record

- **Provenance:** the command path the owner confirmed, how the agent resolved it, the CLI version taken from init, and "via owner wrapper." Wrappers are outside the qualified contract, so this is evidence about the installed CLI as reached through that wrapper, not built-in qualification.
- **Plugins:** the classification table, hook absence, and the caveat that `--safe-mode` disables installed customizations according to the docs but this was observed only in this one run.
- **Scope of a single prompt:** at most one real completion, giving text-block UUID equality and possibly thinking. Multi-turn continuity rests only on the earlier synthetic run. Tools, multi-block output, retraction and resume stay unqualified.
- **Where to store it:** a redacted structural summary only (types, keys, UUID topology, equality booleans), with no prompt or request content.

## Recommendations

1. Run the read-only lookup and record candidate paths and file types only, without reading the wrapper.
2. Ask the owner one combined question:
   - **(A, recommended):** "Run `<confirmed path>` as-is with the inherited environment. I'm signed in. Read one session file by exact path (H1); I'll delete it afterward."
   - **(B):** a different command, typed by the owner.
   - **(C):** defer the capture.
   - Until the owner answers, the capture is blocked because it depends on credentials and a manual action. Source work continues.
3. Before the prompt, classify the plugin metadata from the existing init message and do the env-name diff against our own record. Neither needs a new run.
4. Then run the single prompt within the existing bounds: tools disabled, $0.50 cap, 120 s timeout. Apply the stop rule for any hook activity.
5. Status line: `open: owner command+login+history-location confirmation; assumed: bundled-plugin metadata acceptable when no plugin can execute`. Keep production gates and final live acceptance OFF.


## Post-real-capture source sequencing — verified 2026-10-23

Returned preset: `OracleB` / `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; inherited selection; operation `B1EEA478-2E04-4427-8564-D610E653DA18`. Main verified identity and read the full reply. Planning, not source review; recommendations require source verification and are not all adopted.

# Oracle Plan

# Next pre-live source slice for native Claude history identity

The next commit can be built from the real capture alone; it needs no new native sample. I call it **Step 4d2**:

- **Narrow reader profile.** Accept only the exact record classes that the real capture observed. That means an allowlisted set of attachment nodes, and an allowlisted set of operational records that have no UUID. Nothing else is relaxed.
- **Ledger extension.** Add one optional `NativeItem.envelopeDigest` and check it for conflicts before deduplication.
- **Acceptance test.** One end-to-end import over a sanitized fixture shaped like the capture.

Step 4d2 alone covers one case: a dispatch that wrote no live output to the transcript before the interruption. Live output saved today has random IDs, so the existing "every saved output row must be matched to history" rule refuses everything else.

To cover the restart plan's normal case, where live text was saved before the restart, one more gated piece is needed: **Step 4d3**, a live identity carrier for single-text-block assistant envelopes. The capture directly supports that one mapping. Every other carrier (thinking, tools, multi-block) stays unbuilt and refuses.

## 1. Why Step 4d2 is the smallest useful step, not scaffolding with zero coverage

The capture's normal shape is: user → attachment chain → assistant, plus a trailing `prompt_snapshot` leaf and operational records with no UUID. Today's reader refuses that shape. As long as it does, any digest, carrier or reducer work matches zero real histories. Making the reader accept the observed shape is therefore the precondition for every later step having coverage.

This is not a blanket skip of metadata:

- **Attachment nodes**: graph-only, never shown as rows.
  - Accepted only if the attachment-type string exactly matches one of the 8 types observed: environment, model, token budget, budget, session_context, date, the org-context type, and prompt_snapshot.
  - Copy the exact strings and the key path that holds the type from the redacted structural summary. Don't retype them from memory.
  - Accept on the type name only. Never read, hash, project or log the content. This applies in particular to the org-context attachment.
  - Any other attachment type refuses with a typed reason, `.attachmentType(type, line)`. That includes `structured_output` and anything that might carry the only copy of output.
  - Existing rejection flags still apply: sidechain, meta, and `logicalParentUuid`/compaction keys.
- **Graph rule.** Use the "effective children" rule from the earlier plan. An allowlisted attachment with no message below it in the graph is an ignorable leaf; that covers the trailing `prompt_snapshot`. One that has messages below it must have exactly one effective child, so it simply passes through.
  - It must never open a second message branch.
  - The existing requirement that a tool_result's parent is its call stays as it is. An attachment between a call and its result refuses.
  - The rule doesn't depend on position, so it works whether turn 2's user entry hangs off the trailing attachment or off the assistant entry.
- **Operational records with no UUID**: ignored lines, accepted only if all of these hold:
  - the type exactly matches the observed set (exact strings from the summary);
  - the line has no `uuid` and no `parentUuid` key;
  - `sessionId`, if present, matches the file's session.

  The same type appearing with a `uuid` refuses, as does any other type with no UUID. Do not interpret `last-prompt.leafUuid` or the queue-operation records. They aren't needed, because the 4d1 claimed-UUID check already does user association.
- **Sensitive content.** Request/blob lines can hold the complete prompt context. The reader may decode only enough to classify a line. It must never copy the line's content into rows, digests, refusal values, the ledger or logs. Refusal values carry a type name and line number only.
- Thinking, compaction, `isMeta`, API-error, sidechain, and the supersedes/aborted/retracted markers all stay refused.

Bump the profile name to V3 (V2 was the earlier, withdrawn draft). It is a label, not a version gate.

**Does importing without attachments lose anything?** No. Attachments are model input that the live transcript never shows, so an import that skips them reproduces exactly what live delivery would have shown. Record that reasoning in the evidence directory, not in the plan.

## 2. Ledger evidence: settling the sticky-refusal and counts disagreement

- **Add one field:** `NativeItem.envelopeDigest: String?`, a known key written only when present.
  - It is the SHA-256 of a length-prefixed encoding of: the entry type, then every content block in raw order (kind, ordinal, text, tool name, tool-use ID, canonical input, result text, `isError`).
  - It is stored on every row of the entry.
  - Allowlisted attachments and operational lines are never part of it.
- **No count field.** The digest already covers the ordered block list.
- **No sticky refusal and no persisted issue collection.** On refusal the cursor never moves. The transcript, ledger and cursor stay unchanged, and the next reconcile recomputes the same refusal from the same inputs.
- **Conflict check before deduplication**, in the `.importAfter` reader path, before rows already in the ledger are filtered out. For each `nativeEntryID` that has any key already in the ledger, all of these must hold:
  - the set of keys in the ledger equals the set observed;
  - every one of those ledger rows carries the same non-nil digest;
  - that digest equals the observed one.

  Otherwise the reader refuses with `.ledgerConflict`. A Claude ledger row with no digest refuses; none exist today, because Claude import has always refused.
- **All-or-nothing per entry:** the planner writes every row of an entry, or none of them.
- **To verify while implementing:** whether the existing reader refuses a file that is now shorter than the cursor, or whose bytes before the cursor were rewritten. If it doesn't, add exactly that refusal.

## 3. Acceptance contract for Step 4d2

All of these are fixtures labelled as fixtures. Build them by hand from the redacted structure: key names, type names and parent links, with synthetic text only.

1. **Real-shape fixture.** The reader yields exactly `[userText(claimed uuid), assistantText(uuid)]`. Attachments, operational lines and the trailing `prompt_snapshot` produce no rows.
   - Native user content takes the form recorded in the summary (string or array). The 4d1 text-digest claim check passes for it.
2. **Each of these refuses with a typed reason:**
   - an attachment type not on the list;
   - an allowlisted attachment that opens a second message branch;
   - an attachment between a tool call and its result;
   - an operational-type line that carries a `uuid`;
   - an unknown type of line with no UUID;
   - thinking;
   - compaction or `isMeta`;
   - supersedes, aborted or retracted markers.
3. **Leak test.** Put sentinel strings into a request/blob line and into the org attachment. Neither may appear in any row, digest, refusal description or persisted JSON.
4. **End-to-end in the view model,** with the gate enabled inside the test only:
   - Start from a 4d1 claimed baseline with no live output saved. Reconcile imports the assistant text behind the label. The commit carries the ledger digests and the receipt, then the cursor compare-and-swap runs.
   - A second reconcile does nothing.
   - A crash between the save and the compare-and-swap replays as a no-op.
   - A mutated assistant text on rescan refuses with `.ledgerConflict` and changes nothing.
5. **Boundary pins:**
   - A dispatch with saved live output that has random IDs refuses.
   - With the gate off, output is unchanged.
   - `envelopeDigest` survives a round trip, and older JSON decodes without it.

## 4. Step 4d3: the remaining pre-live piece that existing evidence supports

- **Carrier.** Only on a top-level `assistant` envelope that has non-empty `uuid` and `session_id`, no `parent_tool_use_id`, and exactly one content block, which must be `text`. The carrier is ordinal 0, kind assistantText.
- **Where it acts.** In the gated reducer:
  - give the row the same deterministic ID the reader computes;
  - append it as its own non-streaming row, without merging it into neighbouring text;
  - make replays idempotent;
  - leave usage, finalization, background routing and `final_content` handling unchanged.
- **Overlap check.** Where a saved row and a history row share an ID, their meaning must be equal (same text, etc.). If it differs, the import refuses.
- **No other carriers.** Thinking, tool_use, tool_result and multi-block envelopes get none. Their dispatches refuse.
- **Retraction events** never change saved transcript rows.
- **Parity test.** Run the same fixture JSON through the live path and the reader path, and compare the IDs.

## 5. What blocks source work and what blocks only activation

**Implementable now:**
- Step 4d2 (reader profile, `envelopeDigest`, conflict check);
- Step 4d3 (single-text-block carrier).

**Source work blocked:** nothing is built for these; they fail closed with the refusals that already exist.
- Thinking rows and projecting them as reasoning: no native sample with thinking.
- Tool carriers and deterministic invocation IDs: whether the live UUIDs on tool_use and tool_result envelopes equal the native ones has not been checked.
- Multi-block grouping, retraction and fallback semantics beyond the marker refusals, and `--resume` continuity.

**Blocks only activation and final live acceptance:**
- Isolation differences: plugin metadata entries 7 vs 3 and permission mode auto vs default. Differing counts don't prove any plugin ran.
- Which configuration directory and wrapper is qualified. The capture ran with `CLAUDE_CONFIG_DIR` removed from the environment.
- The installed-version profile beyond CLI 2.1.302, and durability after acknowledgement.
- The real share of turns that fit the profile.
- Gates stay OFF.

**If the owner later wants turns with tools covered,** exactly one fact is missing. It needs one new owner approval, because all 4 approved prompts are used:

> In one real turn with one read-only tool, does the live `tool_use` AssistantMessage `uuid`, and the tool-result user envelope `uuid`, equal the native entry UUIDs? And do attachments appear between the call and its result?

A single thinking-enabled turn would be the next most valuable fact. Neither one blocks Step 4d2 or Step 4d3.

## Recommendations

1. **Build Step 4d2 now** as defined above: exact-string allowlists for the observed attachment types and UUID-less operational types, the effective-children graph rule, a never-read-content rule, `NativeItem.envelopeDigest`, the conflict check before deduplication, all-or-nothing writes per entry, and the 5-part acceptance contract. Run the OracleA/OracleB review, then commit.
2. **Then build Step 4d3:** the gated carrier for single-text-block assistant envelopes, plus the parity test and the semantic overlap check. When it lands, pre-live source work is complete for the profile the evidence supports.
3. **Settle the disagreement between lanes:** digest only, no count, no sticky refusal, no new collections. Record this under `assumed:`.
4. **Don't build** thinking, tool or multi-block carriers, retraction handling, or tooling. They refuse as designed.
5. **Status lines:**
   - Step 4d2/4d3 `todo`, then proceed.
   - Live qualification `blocked`. Open items: the tool-turn fact, the thinking sample, isolation differences, wrapper and configuration directory, and the version profile.
   - Record in evidence (not as a Decision) that ordinary coverage is limited to uncompacted turns with text and tools but no thinking, and that only single-text live output is preserved when the transcript already holds saved output.
6. **Ask the owner once, and don't wait for the answer:** (A) defer the tool-turn experiment (recommended); (B) approve one read-only tool-turn capture within the same bounds. Proceed with A in the meantime.


## Capture-qualified projection decision — verified 2026-10-23

Returned preset: `OracleB` / `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; inherited selection; operation `9D223C14-0CF6-4BB2-886E-C04E37679971`. Main verified identity and read full reply. Planning, not implementation review.

# Oracle Plan

# Single-text projection profile for Claude history: is the evidence sufficient?

## Verdict

Yes, the evidence is sufficient for a production-OFF profile that is qualified only against this one capture. It holds under four conditions:

- the attachment and UUID-less type allowlists use exact strings;
- the graph is fully validated;
- anything not on the allowlists refuses;
- the claim stays exactly as narrow as you worded it.

The reasoning:
- **The projection already matches the SDK's own.** The official reader keeps attachments as graph nodes (`sessions.py` 826–833, 897–929), walks back from non-message terminals (931–1020), and filters to visible messages only after building the graph (1248–1261, 1341–1352). A profile that validates attachments as graph nodes and renders only user and assistant messages is the SDK's own visible projection. It does not claim the attachments are semantically irrelevant.
- **No context is lost.** The provider keeps its native history on `--resume`, and the baseline and cursor native-byte fences stay in place. The app transcript is a rendering, not the model's context.
- **Neither direction of mismatch can corrupt data.**
  - If the live app rendered something that history stores as an attachment, that saved row has no association, and canonical ⊆ associated refuses.
  - If an allowlisted attachment carried output, the result would be a silent drop. `structured_output`, the one documented case of an attachment being the only persisted output (TS 2155–2166), is not on the allowlist.

More captures with the same prompt would not add proof. No further runs are needed.

## Failure scenarios that still matter, and what stops each

| Scenario | Defense | Status |
|---|---|---|
| A refusal-fallback retry keeps the retracted assistant entry with no marker, and the fallback reply is persisted alongside it. Both get imported and the retracted text shows (wrong answer). | Both are assistant children of the same parent with different `message.id`, so the existing branch rule refuses with `.ambiguousBranch`. A UUID-less or unknown eviction record is refused by the exact-type rule. An explicit `supersedes`/`aborted`/`retracted_message_uuids` key must be refused because unknown fields are otherwise accepted. | Needs **one fixture each**. No new mechanism. |
| A `queue-operation` record means a queued steering prompt was dropped. The import then adds assistant rows after a local user item the provider never received. | 4d1 preflight must refuse when a claimed baseline in the window has no matching native user entry. | **Pin with one test.** If 4d1 only checks the start baseline, add exactly that check. It becomes reachable now because this step accepts queue records. |
| An allowlisted type keeps its name but changes meaning in a later CLI version. | The production gate is OFF. The qualified version is recorded in evidence as an activation gate. | **Activation only.** Do not gate the reader on version. |
| A rewritten native entry is found again on rescan and silently deduplicated against the ledger. | `envelopeDigest` conflict check before dedup. | **Build in the same step** (see below). |

None of these needs a stronger external check. Only the cheap source check below remains, and it doesn't block the step: confirm that the live reducer never creates an `AgentChatItem` from system/init stream events. If it does, those dispatches simply refuse, so the step stays fail-closed either way.

## Step shape: one coupled step, reader plus ledger digest

I don't recommend shipping the reader alone first. A reader that accepts real histories without the conflict check before dedup leaves a reviewed state where the end-to-end import (gate on in tests) dedups by key alone. That is a P1 the lanes would raise immediately. The digest touches the same reader path (`.importAfter`, before the known-row filter), plus one optional `NativeItem` field and one line in the planner. One Pair worker can do it, in about three source files plus tests.

## Acceptance and refusal contract (Step 4d2)

**Accept:**
1. `attachment` entries whose type, read at the key path recorded in the redacted summary, is exactly one of: `budget_usd`, `credential_org`, `date`, `environment`, `model`, `prompt_snapshot`, `session_context`, `total_tokens_reminder`.
   - They are graph nodes only and produce no rows.
   - Content is never decoded, hashed, logged or copied.
   - The existing `uuid`/`parentUuid`/`sessionId` rules and the sidechain/meta/`logicalParentUuid` refusals apply.
2. UUID-less operational lines whose type exactly matches the observed set, with the strings copied from the summary.
   - They must have no `uuid` or `parentUuid` key, and any `sessionId` they carry must equal the file's session.
   - They are ignored without interpretation, including `leafUuid`.
3. **Graph rule:** effective children are a node's children minus attachment-only subtrees.
   - Only message entries count as tips.
   - An attachment above a message passes through only if it has exactly one effective child.
   - The trailing `prompt_snapshot` leaf is ignored.
4. **Digest:** `NativeItem.envelopeDigest` (optional, known key, `encodeIfPresent`).
   - It is the SHA-256 of a length-prefixed encoding of the entry type plus every content block in raw order.
   - It is stored on every row of the entry, and every entry is written all-or-nothing.

**Refuse, each with a typed reason that carries only the type name and line number:**
- any other attachment type, including `structured_output`, or an attachment missing a type or with a non-string type;
- an operational type that carries a `uuid`, or any unknown UUID-less type;
- an allowlisted attachment that opens a second message branch, or sits between a tool call and its result;
- `thinking`, compaction, `isMeta`, API-error and sidechain entries;
- any `supersedes`, `aborted` or `retracted_message_uuids` key, whether at entry level or inside `message`;
- in `.importAfter`, an entry where any key is already in the ledger but the key sets differ, the digest is missing, or the digest differs → `.ledgerConflict`, raised before dedup;
- a file shorter than the cursor, or with rewritten bytes before the cursor. Check whether existing code already does this; add it only if missing.

**Tests** (fixtures, labeled as fixtures, built by hand from the redacted structure with synthetic text):
- A fixture shaped like the capture yields exactly `[userText(claimed), assistantText]`.
- One fixture for each refusal above.
- Sentinel strings placed in the `credential_org` attachment and in request/blob lines appear nowhere in rows, digests, refusal descriptions or persisted JSON.
- End to end in the view model (gate on in the test only), starting from a 4d1 claim with no saved live output:
  - the first reconcile imports the assistant text, then the cursor CAS runs;
  - a second reconcile does nothing;
  - a crash between the save and the CAS replays as a no-op;
  - a mutated text on rescan refuses with `.ledgerConflict` and changes nothing;
  - a claimed steering baseline whose user entry is missing refuses.
- Boundary pins: saved live output with random IDs refuses; with the gate off, output is byte-identical; `envelopeDigest` survives a round trip and legacy JSON still decodes.

## Claim wording (for evidence, not Decisions)

> "Capture-qualified on CLI 2.1.302 for a single text turn. The projection matches the SDK's visible-message projection. Allowlisted attachments are validated as graph nodes and not rendered. No claim is made about their semantic irrelevance. Production gates are OFF."

## Recommendations

1. **Proceed without an owner question.** This is a reversible internal implementation choice and does not change the lossless contract.
2. **Implement Step 4d2 as one coupled step** using the contract above, run the OracleA/OracleB review, and commit.
3. **Add the three cheap pins:** the retraction-key refusal, the sibling-fallback branch refusal, and the missing claimed-steering-entry refusal. If the steering check doesn't exist in 4d1, add only that check.
4. **Then do Step 4d3** (the gated single-text-block live carrier) as already planned.
5. **Keep these blocked for activation and final live acceptance only, with no more capture runs:** version profile, wrapper and config-dir qualification, the isolation deltas, tool, thinking and multi-block turns, and resume.
6. **Record under `assumed:`** that the profile is SDK visible-projection parity rather than attachment semantics, uses a coupled reader and digest step, and has no reader version gate.


## Prefix-fence coherence — verified 2026-10-23

Returned preset: `OracleB` / `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; inherited selection; operation `41A5A977-838F-4349-B777-AF21F2FACF05`. Main verified identity and read full response; planning, not implementation review.

# Oracle Plan

# Prefix fence for Step 4d2: one optional prefix digest on the baseline and the cursor

## Verdict

Yes, approve it. One optional `prefixSHA256` on the existing `DispatchBaseline` and `AgentRecoveryHistoryCursor` is the minimum that makes the "native-byte fence" claim true. That claim was stated in earlier rounds, but today the code stores only the file identity and an offset.

**Why the existing per-message proofs are not enough.** The claim UUID with its text digest, the ledger envelope digests and the graph checks only examine entries the app already knows about. The concrete gap is a silent loss:

1. A partial import commits cursor C1 partway through a dispatch, and the claim lands in the ledger.
2. The file is then rewritten without appending: it shrinks and regrows, or a region is rewritten in place. A not-yet-imported assistant entry now sits before C1, and C1 still falls on a line boundary.
3. That entry is unledgered and pre-cursor. Its parent is also pre-cursor, so the pre-cursor/post-cursor parent check doesn't fire. If it was never saved live, canonical ⊆ associated doesn't fire either.
4. The reader skips it and nothing reports the loss.

**Likelihood and cost.** Normal Claude CLI behaviour is append-only. But the native entry union is explicitly CLI-internal and retraction/eviction is documented, so this can't be ruled out. Data loss calls for full rigor, and the check is cheap: the reader already reads the bytes before the cursor to validate the graph. Hashing the raw bytes in that same pass adds no parsing and no exposure of content.

The other option is to retract the fence claim and record "append-only assumed". I reject it, because a loss of that kind can never be detected afterwards.

**No new store, journal or collection.** Only the digest is persisted. It covers opaque bytes and is never logged or decoded.

## Field contract (the same on both types)

- `prefixSHA256: String?`: lowercase hex SHA-256 of the exact raw bytes `[0, completeLineOffset)`, with no line normalization. Known key, written only when present.
- **Lenient decode, which is also the rule for `envelopeDigest`.** Anything other than a 64-character lowercase hex string decodes to nil, and the raw value stays in `extras` under the same key.
  - The codec must not consume the key when decoding fails, so the raw value round-trips.
  - A non-nil property overwrites the extras value on encode.
  - The session never fails to load because of this field. Main's rejection of the strict throw is correct: that throw is a P1 that makes a whole session unavailable.
  - If the 4d1 `outboundUserMessage` claim decodes strictly, apply the same rule there only if it is a one-line change.
- **Claude only.** A missing or unusable proof on any fence the Claude import relies on refuses.
  - Codex readers neither compute nor check the digest. Shared code (codec, CAS) only compares the optional for equality.
  - Claude cursors without a digest effectively don't exist, because Claude import has never succeeded. Claude baselines exist only where the gate was on. Failing closed therefore costs nothing in production.
- **Profile string V2: accepted.** The V2 draft I described earlier never landed, so there is no clash. A legacy V1 baseline still decodes and is kept, and it refuses through the missing prefix proof (and missing claim), not through a profile gate. That gives "not silently requalified" without adding any gate.

## Edge-case handling

| Case | Rule |
|---|---|
| Zero offset | Digest = SHA-256 of zero bytes (the constant `e3b0c442…`). Never use nil to mean "empty". Nil always means "no proof". |
| File verifiably absent at capture | Keep today's identity semantics for an absent file, and record offset 0 with the empty-input digest. An unreadable file, or one that changes during the read, is an **unsupported** baseline, so under 4d1 no UUID is sent. |
| Capture read | One file handle. Hash exactly `[0, offset)` in the same read that finds `completeLineOffset`. If the file shrinks mid-read, the baseline is unsupported. |
| Reconcile order | Check file identity, then length ≥ fence offset, then record boundary, then prefix digest. Only after those come parse/graph, envelope `ledgerConflict`, dedup and plan. Read one snapshot buffer, and take every hash and the parse from that same buffer. |
| Which fences to check | Every applicable fence: the baseline digest at its offset and, if present, the cursor digest at its offset. Both come from one incremental pass, finalizing a copy of the running hasher at each offset. Don't reason about which fence "starts" the window. |
| Identity changed, truncated, or prefix mismatch | One new typed refusal, e.g. `prefixFence(.missingProof \| .truncated \| .changed)`, carrying no bytes and no line content. Not sticky: transcript, ledger and cursor stay unchanged and the next reconcile recomputes the same result. Reuse an existing identity-mismatch case if one already has that meaning. |
| New cursor digest | Digest of `[0, candidateEnd)`, continued from the same pass and buffer, and never re-read when the CAS runs. |
| Normal and exact-repeat CAS | Equality covers `(file, offset, importID, prefixSHA256)`. If the importID repeats but the digest differs, take the existing mismatch failure path. |
| Crash after save, before CAS | Replay: the old fence digest is verified first, entries already in the ledger pass the envelope check and are deduped, the plan is a no-op, and the CAS writes the cursor with the freshly computed digest. If the receipt already embeds a cursor value, the field travels with it and the replay must match it exactly before the CAS. Don't add a receipt field otherwise. A prefix rewrite between the crash and the replay refuses with no CAS. |
| Rollback or older build | Unknown keys are kept via extras. Older builds don't check the digest, and the gates are OFF. |

**Execution context to check during implementation:** baseline capture runs inside send admission. Make sure hashing a large session file doesn't run on the main actor; if it does, move it off. Timing results are advisory only.

## Acceptance tests (fixtures, labelled as fixtures)

1. **Capture:** the baseline digest equals the hash of the exact prefix. Zero offset and verified absence give the empty-input digest. A read failure gives an unsupported baseline, and no `uuid` goes on the wire.
2. **Append-only growth:** the import passes.
3. **Changed prefix:** flipping one byte inside a pre-fence attachment or operational line refuses, with no rows and ledger and cursor unchanged.
4. **Other fence failures:** a file shorter than the fence offset refuses, and a different file identity refuses.
5. **Missing or malformed proof:** on either the baseline or the cursor, a Claude import refuses. Codex with nil digests behaves exactly as before.
6. **Malformed values round-trip:** a malformed `prefixSHA256` or `envelopeDigest` survives the round trip unchanged in extras, the session loads, and the Claude import refuses.
7. **Cursor and CAS:** the import's cursor carries the digest of `[0, end)`. An exact-repeat CAS with an equal digest is a no-op; with a different digest it fails.
8. **Crash between save and CAS:** replay is a no-op and then the CAS runs. A prefix rewrite before the replay refuses.
9. **No leaks:** a sentinel string placed in the prefix bytes appears in no refusal description, log or persisted JSON. Only the digest is persisted.

## Recommendations

1. **Approve the single optional `prefixSHA256`** on `DispatchBaseline` and `AgentRecoveryHistoryCursor`, carried from capture, candidate and observation through the existing receipt (only if the receipt already embeds the cursor) and the CAS. Add nothing else.
2. **Use the same lenient-decode rule** for `prefixSHA256` and `envelopeDigest`: keep the raw value in extras, treat it as nil, and refuse for Claude. Never fail the whole session load.
3. **Use the empty-input digest for zero offset.** Nil always means missing proof, and missing proof refuses.
4. **Check all applicable fences in the single read pass,** before the graph, conflict and dedup steps, using one typed `prefixFence` refusal. Add the digest to both the normal and the exact-repeat CAS equality.
5. **Accept the V2 profile string and the claim window scoped to the source attempt.** Legacy baselines are kept and refuse through the missing proof, with no profile gate.
6. **Record under `assumed:`:**
   - the prefix fence is defense against non-append rewrites that the CLI-internal format doesn't rule out;
   - the digest is computed over opaque bytes only;
   - no receipt field is added unless the receipt already embeds a cursor.
7. **Next steps:** finish Step 4d2 with these tests, run the OracleA/OracleB review, and commit. Live qualification, activation and final acceptance stay pending, with no new captures.
