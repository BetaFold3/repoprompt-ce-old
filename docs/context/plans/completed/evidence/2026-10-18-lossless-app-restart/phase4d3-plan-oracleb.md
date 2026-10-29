# Step4d3 planning — OracleB

Scope: read when the task touches Step4d3 Claude canonical payload validation or live single-text identity planning.
Authority: Reference
Last-verified: 2026-10-23

Fresh independent planning consultation; returned explicit preset identity verified before synthesis. This is guidance, not implementation review. Main's choices are in [the scoped execution note](phase4d3.md). Full response follows; trailing Markdown whitespace is normalized for repository checks.

# Oracle Plan



# Step 4d3: identity and proof for live single-text Claude assistant rows (pre-live, gate OFF)

## 1. Summary

Step 4d3 lets one kind of live output carry native identity: a built-in Claude `assistant` envelope that holds exactly one text block. It reaches the view model on the existing `content` result through the existing DTO → bridge → controller → router → `.stream(AIStreamResult)` path, as a new optional carrier field. The usage companion still comes first. With the gate OFF, results are byte-identical to today.

The view model adds one non-streaming row whose local ID is deterministic. It keeps the row's proof in memory until the run attempt ends cleanly. The proof is an ordinary `AgentSessionProviderHistoryRecovery.NativeItem`: the 4d2 row key, ordinal 0, and the 4d2 `envelopeDigest`. At a clean end, the proof goes into the existing ledger in a normal session save.

Rows that carry a ledger association are protected from mutation by the generic delta buffer, the background pointer and `final_content`. This covers rows this step identifies and rows imported earlier. The 4d2 reader moves from an IDs-only canonical check to an ordered payload comparison, and unavailable content refuses.

Disqualifying signals are handled in two ways:
- **Attempt-scoped signals:** no durable state is needed because the proof is never committed.
- **Signals that may target already-committed output:** these set one optional sticky revocation member on the existing ledger.

No receipt, cursor, controller accounting or router changes.

**Precondition:** implementation starts only after Step 4d2 is `done`. Every 4d2 seam below refers to its intended contract, and the seams are adapted if the landed names differ.

---

## 2. Current-state analysis

### Live path (unchanged by 4d2)
1. **Translator.** `ClaudeSDKNDJSONTranslator.parseAssistantMessage` emits the following, in order:
   - an optional `usage` result (with `contentMessageID = message.id` and an `.assistant` observation);
   - one `content` result per text block, with no identity.

   Other blocks are handled as follows:
   - Unknown blocks are dropped (`default: continue`).
   - `thinking` is dropped when the reasoning feature is off.
   - Unknown top-level types return `[]`.
   - Stream deltas also become `content`.
2. **Bridge.** `ClaudeCompatibleProviderRuntimeBridge.streamResult(from:)` and `providerStreamResult(from:)` copy every field explicitly, in both directions.
3. **Controller.** `ClaudeNativeProcessSessionController` runs this sequence for each payload:
   - usage and compaction bookkeeping on the raw payload;
   - `translator.parseNDJSONLine`;
   - `emitMainRequestUsageIfOwned` for `assistant`;
   - for each result: `shouldSuppressUserFacingStreamResult`, then `emit(.stream(result))`;
   - a `result` payload's `message_stop` drives turn completion separately (duplicate detection, the pending-turn FIFO, deferral to `idle`).
4. **View model.** `AgentModeViewModel.applyStreamResult` behaves as follows:
   - **`content`:** goes to `enqueueAssistantDelta`. `applyAssistantDelta` resumes the last streaming assistant row, even across user rows, through `resumableStreamingAssistantIndexAcrossTrailingUserInterjections`.
   - **Background content:** goes to `applyBackgroundAssistantDelta`. `backgroundCurrentAssistantIndex` can return an ended row, and the delta sets `isStreaming = true` again.
   - **`final_content`:** replaces the text of the tail assistant row (system rows are skipped) whether or not that row is streaming.
   - **`message_stop`:** flushes the buffer, ends the segment and stores `providerSessionID`.
5. **Ledger.** `AgentSessionProviderHistoryRecovery.NativeItem` (`provider, nativeSessionID, nativeEntryID, rowKind, ordinal, localItemID, envelopeDigest?, extras`) is the only native-to-local association. `rowKey(...)` is the key function. Unknown members round-trip.

### What blocks the goal today
- Live rows have no identity, so the 4d2 canonical check refuses any saved live output, and it compares IDs only.
- Three mutation paths can rewrite a row after its proof is recorded: `final_content`, the background pointer and the resumable delta.
- Translator drops (unknown blocks and unknown types) are invisible downstream, so the view model cannot tell that an attempt contained unqualified output.

### What can be reused
- The 4d2 projection of a native entry into rows, the digest function, the `rowKey` builder, and the provider/row-kind constants.
- The usage observation on the `result` `message_stop` (`resultSubtype`, `resultIsError`, `resultIndex`, `providerSessionID`).
- The existing terminal finalization path, `scheduleSave`, and the in-memory owner of the session.

---

## 3. Design

### Decision: targeted change, no refactor
The carrier is an optional field on the existing DTO and its core mirror. The ledger is reused unchanged except for one optional member. All row logic stays in the view model, with pure helpers in AgentCore so they can be tested. A separate live-identity collection or event channel would create a second transcript authority, which the brief rules out.

### 3.1 Carrier types (provider DTO and core mirror)

**Provider package, `ClaudeProviderStreamResult.swift`** (shape only):

```swift
public struct ClaudeProviderNativeTextEnvelope: Sendable, Equatable {
    public let nativeSessionID: String   // envelope session_id
    public let nativeEntryID: String     // envelope top-level uuid
    public let messageID: String         // message.id (diagnostics + intra-attempt check)
    public let envelopeJSON: Data        // JSONSerialization of the whole envelope dict
}
public enum ClaudeProviderNativeDisqualification: String, Sendable, Equatable {
    case unqualifiedAssistantEnvelope = "unqualified_assistant_envelope" // attempt-scoped
    case partialOutput = "partial_output"                                 // attempt-scoped
    case unknownEnvelope = "unknown_envelope"                             // may target committed output
    case retraction = "retraction"                                        // may target committed output
}
public enum ClaudeProviderNativeOutputSignal: Sendable, Equatable {
    case completeText(ClaudeProviderNativeTextEnvelope)
    case disqualified(ClaudeProviderNativeDisqualification)
}
// ClaudeProviderStreamResult: + `public let nativeOutputSignal: ClaudeProviderNativeOutputSignal?` (init default nil)
```

- **Why the raw envelope travels as `Data`:** core must run the exact 4d2 projection and digest on it. Carrying `Data` avoids mapping between JSON-value types, and the bridge copies it verbatim. The text itself is not duplicated, because the carrying `content` result's `text` already holds it.
- **Core mirror in `AIProviderFactory.swift`:** add `AgentProviderNativeOutputSignal`, `AgentProviderNativeTextEnvelope` and `AgentProviderNativeDisqualification` with the same cases, next to `AgentProviderUsageObservation`. Add `AIStreamResult.nativeOutputSignal: AgentProviderNativeOutputSignal?` (package visibility, init default nil). Existing `AIStreamResult(...)` call sites compile unchanged.

### 3.2 Translator classification (`ClaudeSDKNDJSONTranslator`)

- Add the init parameter `emitsNativeOutputSignals: Bool = false`. When it is false, every code path is exactly as it is today. This gives byte and result parity.
- **Qualification is structural only.** The authoritative check is done in core (§3.4). The translator never rewrites tool IDs, text, ordering, or the usage result. An envelope qualifies only when all of these hold:
  1. `json["type"] == "assistant"`. A `"message"` envelope does not qualify.
  2. `!isSidechainAssistantEvent(json)`.
  3. `uuid` and `session_id`/`sessionId` are non-empty strings on the envelope itself.
  4. `json["message"]` is a dictionary. The translator's fallback to the envelope itself does not count.
  5. `message.id` is a non-empty string, and `message.role == "assistant"`.
  6. `message.content` is an array with exactly one element, and that element is `type: "text"` with a non-empty string `text`.
  7. `JSONSerialization.data(withJSONObject: json)` succeeds.
- **A qualified envelope** produces the same result array as today: the usage result, then one `content` result. The only difference is that the `content` result carries `.completeText(...)`.
- **An unqualified assistant or message envelope** produces the legacy results unchanged, then one extra result: `ClaudeProviderStreamResult(type: lifecycleType, text: nil, nativeOutputSignal: .disqualified(.unqualifiedAssistantEnvelope))`.
- **A `stream_event` whose `event.type == "content_block_start"`**, in any lane, gets an extra `.disqualified(.partialOutput)` appended. It fires once per block, needs no new state, and has no effect when partial messages are off.
- **`default:` in `parseMessageDictionary`** (an unknown top-level type) emits `[.disqualified(.unknownEnvelope)]` instead of `[]`.
- **`.retraction`** is emitted only for the documented supersede, abort or retract event types and subtypes (see Q4). If none is documented for 2.1.302 stdout, the case stays unused.
- **The following stay benign and emit no signal:** `system` (any subtype), `result`, `user`, `tool_progress`, `auth_status`, `tool_use_summary`, `rate_limit_event`, `error`, and the other `stream_event` types. Each of these either is not model output or already produces a visible result that the view model's allowlist treats as disqualifying (§3.5).
- `resetMainModelTracking` is unchanged, because no translator state is added.

### 3.3 Controller and router
- `ClaudeNativeProcessSessionController` builds its translator with `emitsNativeOutputSignals: ClaudeLiveNativeIdentityGate.isEnabled && <is built-in Claude backend>`.
- The order of usage accounting, `emitMainRequestUsageIfOwned`, duplicate detection, the FIFO and `idle` deferral is untouched.
- **Required check:** `shouldSuppressUserFacingStreamResult` must not drop results that have `nativeOutputSignal != nil`. If it currently suppresses lifecycle results with nil text, add an exemption for results that carry a signal. A dropped signal would fail open.
- `streamResultLogPayload` may add `nativeEntryID`/`messageID`/`disqualification` strings. It must never log `envelopeJSON`.
- **Router:** no change. The new field rides inside the `.stream(AIStreamResult)` payload it already owns.
- **Gate:** `ClaudeLiveNativeIdentityGate.isEnabled` is a static, default `false`, overridable only through the same debug override mechanism the existing recovery gates use. It is independent of the production recovery activation, which stays OFF.

### 3.4 Core proof builder and ledger rules (AgentCore)

**New file `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionLiveNativeIdentity.swift`**, containing two value types.

**1. `ClaudeLiveNativeTextProof`**

```swift
struct ClaudeLiveNativeTextProof: Equatable {
    let item: AgentSessionProviderHistoryRecovery.NativeItem   // localItemID = deterministic ID, envelopeDigest set
    let messageID: String
    let text: String
    static func make(envelope: AgentProviderNativeTextEnvelope, contentText: String)
        -> Result<ClaudeLiveNativeTextProof, LiveIdentityRefusal>
}
```

`make` runs these steps:
1. Parse `envelopeJSON`.
2. Run the **4d2 entry projection** on it. It must produce exactly one row, with the 4d2 assistant-text `rowKindRaw` and ordinal 0. The row's text must equal `contentText` byte for byte, and the projected `nativeEntryID` must equal `envelope.nativeEntryID`.
3. Compute `envelopeDigest` with the **4d2 digest function**.
4. Build the key with `rowKey(providerRaw: <4d2 Claude constant>, ...)`.
5. Set `localItemID = AgentSessionProviderHistoryRecovery.deterministicLocalItemID(forRowKey:)`. Reuse the 4d2 derivation if one exists. If not, add it as a name-based UUID over the SHA-256 of the key, and the reader uses the same function for imports.

Any mismatch returns a refusal and never produces a partial proof. The refusal cases are `projectionRejected`, `rowCountOrKind`, `textMismatch`, `idMismatch` and `parseFailed`.

**2. `ClaudeLiveNativeIdentityAttempt`**

This is transient, in-memory state for one run attempt. It is a struct.

- **State:**
  - `runAttemptID`
  - `disqualification: String?` (the first reason only)
  - `pending: ClaudeLiveNativeTextProof?` (at most one per attempt)
  - `cleanResult: (resultIndex: Int?, providerSessionID: String?)?`
  - `sawNonCleanResult: Bool`
- **Rule: at most one identified envelope per attempt.** A second, different `nativeEntryID` disqualifies the attempt. This matches the evidence: one real turn with one text block.
- **Rule: result consistency.** A `message_stop` whose `usageObservation?.source == .result` is clean when `resultSubtype == "success"` and `resultIsError != true`. A repeat with the same non-nil `resultIndex` is a duplicate and is accepted. Any other second result disqualifies the attempt.
- **Rule: commit eligibility.** `commitEligible(terminalStatusIsCompleted:) -> NativeItem?` returns the pending item only when all of these hold:
  - the attempt is not disqualified;
  - `pending != nil`;
  - a clean result was seen;
  - `cleanResult.providerSessionID == pending.item.nativeSessionID`;
  - the terminal status is completed.

**Ledger member (`AgentSessionProviderHistoryRecovery.swift`)**

Add `liveOutputRevocation: LiveOutputRevocation?`:

```swift
struct LiveOutputRevocation: Codable, Equatable { reasonRaw: String; nativeSessionID: String?; observedAt: Date; extras }
var isLiveOutputRevoked: Bool  // decoded value != nil  OR  raw key "liveOutputRevocation" present in container extras
```

- Decoding is tolerant. A malformed value is kept verbatim in extras and **still counts as revoked**. This is the opposite of the digest rule, because it must fail closed.
- The member is absent when nil, and there is no version bump. 4d2 builds preserve it but ignore it (see Risks).
- There is one writer (the view model, §3.5) and one reader check (§3.6). It is sticky and is never cleared in 4d3.

**Why live proofs need no origin field**
- The reader re-verifies every known item against the full native capture on every read: presence, keyset, digest, and (new) ordered payload. Nothing treats ledger membership by itself as acceptance.
- A live proof whose entry is missing from native history therefore refuses on the existing removed/changed-entry path, and the local output is preserved. A live UUID never proves durability.
- An origin field would only become necessary to target committed live proofs for deletion. The design avoids deleting committed proofs (next section).

### 3.5 View model (`AgentModeViewModel`) and session state

**Session state on `AgentTabSession` (transient, not persisted):**
- `liveNativeIdentityAttempt: ClaudeLiveNativeIdentityAttempt?`.
- `nativeIdentifiedRowIDs: Set<UUID>`, a derived cache: the ledger's `items.compactMap(\.localItemID)` plus the pending proof's ID. It is invalidated whenever the in-memory ledger or the pending proof changes.

**Attempt tracking (active-run delivery only, gate ON):**
- On the first result for a `runAttemptID` that differs from the stored one, replace the state with a fresh attempt.
- Observe every result:

| Result | Effect on the attempt |
|---|---|
| `usage`, non-result `message_stop`, `session_state_changed`, `task_progress`, `system`, `lifecycle` without a signal | Neutral |
| `content` with `.completeText` | Identified path (below) |
| `content` without a carrier, `reasoning`, `tool_call`, `tool_result`, `error`, `.disqualified(*)`, any type not listed here | Disqualifies. The allowlist fails closed. |
| `final_content` | See guards |
| `message_stop` from a result | Recorded per §3.4 |

- `.disqualified(.unknownEnvelope | .retraction)` also sets `liveOutputRevocation`, whether it arrives in a run or in the background. Committed output cannot be ruled out as its target. Save immediately if a non-debounced save exists; otherwise use `scheduleSave`.
- In **background** delivery, only those two reasons have any effect. Background output never becomes identified, and its rows stay unidentified, which already refuses.

**Identified content path:** active run, gate ON, carrier present, attempt not disqualified.
1. `clearClaudeReasoningStatus`, then `flushPendingAssistantDelta`, then `endAssistantSegment(session, background: false)`. The identified row can then never merge with buffered generic text.
2. Call `ClaudeLiveNativeTextProof.make`. On failure, disqualify the attempt and fall through to the legacy `enqueueAssistantDelta`. The output stays visible with no identity claim.
3. Look up the key, first in pending and then in the ledger:
   - **Found, same digest, local row present with identical text:** no-op. No row, no pending change. Re-delivery is idempotent.
   - **Found with a different digest, a different row text, or a missing row:** do **not** touch the existing row. Disqualify the attempt. Append the text as a legacy unidentified row so it stays visible. If the match was in the ledger rather than pending, also set `liveOutputRevocation`.
   - **Not found:** append a non-streaming `AgentChatItem.assistant(text, ...)` with `id = proof.item.localItemID`. Set `pending` (a second distinct envelope disqualifies). Set `shouldUpdateBindings = true`.

**Guards:** unconditional on ledger association, so they also protect imported rows.
- **`applyAssistantDelta` / `resumableStreaming…`:** an identified candidate counts as "no resumable row", so a new row is appended.
- **`backgroundCurrentAssistantIndex`:** if the pointer's `rowID` is identified, retire the pointer and return nil.
- **`final_content`:** if the tail index found (run or background) is identified, the outcome depends on the text:
  - `content == row.text`: no mutation, no rewrite record, and the attempt is not disqualified.
  - Otherwise: no mutation. Append `content` as a new unidentified assistant row. Disqualify the attempt.
- Terminal drains (`endStreamingAssistantRows`) only flip `isStreaming`. Identified rows are never streaming, so nothing changes there.

**Commit:** this hooks into the existing terminal finalization of the attempt, after the drains.
- If `commitEligible(...)` returns an item **and** the local row still exists with text equal to `proof.text`:
  - append the item to the in-memory ledger, creating the ledger if it is nil;
  - `isDirty = true`, then `scheduleSave`.
- Otherwise, drop the attempt state.
- The commit writes no receipt and does not touch the cursor.
- A crash before this save leaves rows that are saved without a proof, so the reader refuses (fail closed).

### 3.6 Reconciliation reader (4d2 Claude reader, extended)

The reader's checks run in this order, before any dedup or overlap:
1. `isLiveOutputRevoked` causes a refusal (`liveOutputRevoked`) and leaves local rows untouched.
2. Existing presence, keyset and digest checks over the full native capture, unchanged.
3. **New, ordered payload comparison** across persisted full turns and the suffix. For every ledger item with `localItemID`:
   - the local row must exist;
   - its kind must equal the projected native row kind;
   - `row.text` must equal the projected text byte for byte.

   The associated local rows, in transcript order, must also appear in the same relative order as their native entries in the projected chain.
4. **Unavailable payload refuses:** if either side cannot be materialized, refuse (`payloadUnavailable`), whether the cause is native content behind compaction or an elided or compacted local row. Unavailable content is never skipped or treated as equal.
5. Known keys that appear after the latest receipt target count as overlap and are skipped, never re-projected, but only after checks 2–4 pass. If 4d2 refuses here, this is the one branch that changes (Q3).
6. The existing rule stays: an unassociated local assistant row ("saved random live output") refuses.

---

## 4. File-by-file impact

| File | Change | Why / dependency |
|---|---|---|
| `Packages/.../ClaudeProviderStreamResult.swift` | Add `ClaudeProviderNativeTextEnvelope`, `...Disqualification`, `...OutputSignal`; add `nativeOutputSignal` field and init param with default nil | §3.1. First step. |
| `Packages/.../ClaudeSDKNDJSONTranslator.swift` | Init param `emitsNativeOutputSignals`; qualification in `parseAssistantMessage`; signals for `content_block_start`, `default:` and documented retraction types | §3.2. Depends on the DTO. |
| `Sources/RepoPromptAgentCore/AI/Providers/AIProviderFactory.swift` | Core mirror types; `AIStreamResult.nativeOutputSignal` | §3.1 |
| `.../ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` | Map the new field in `streamResult(from:)` and `providerStreamResult(from:)`, plus the per-type mappers (same pattern as `usageObservation`) | Explicit two-way copy. Depends on both types. |
| `.../ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | Pass the gate and built-in flag to the translator; signal-carrying results are not suppressed; optional log IDs | §3.3. No change to usage, finalization or FIFO. |
| `.../AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | `liveOutputRevocation` plus tolerant decode and `isLiveOutputRevoked`; `deterministicLocalItemID(forRowKey:)` if 4d2 has none | §3.4. After 4d2 lands. |
| **New** `.../AgentMode/Models/AgentSessionLiveNativeIdentity.swift` | `ClaudeLiveNativeTextProof`, `ClaudeLiveNativeIdentityAttempt`, `ClaudeLiveNativeIdentityGate` | §3.4 |
| 4d2 Claude reconciliation reader (the type that holds the IDs-only canonical check) | Revocation refusal, ordered payload comparison, `payloadUnavailable`, verified suffix overlap | §3.6 |
| `AgentTabSession` (wherever it is defined) | Transient `liveNativeIdentityAttempt`; `nativeIdentifiedRowIDs` cache | §3.5 |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Identified `content` branch; attempt observation in `applyStreamResult`; guards in `applyAssistantDelta`, `backgroundCurrentAssistantIndex` and `final_content`; commit in terminal finalization; revocation write | §3.5 |
| `AgentSessionDataService` | **Only if** the ledger is not held in memory on the session (Q2): `commitLiveNativeIdentity(...)`, which does one session save containing the current rows plus the appended item, on the same save serialization as `commitProviderHistoryImport`, with no receipt and no cursor | Single owner |
| `AgentChatItem` | Only if `assistant(...)` cannot take an explicit `id`: add that overload | Deterministic ID |

### Test matrix (existing suites only; no new harness or captures)

**Translator tests** (`RepoPromptClaudeCompatibleProviderTests`)
- **T1, gate OFF parity:** for a qualified envelope, multi-block, thinking+text, sidechain, `content_block_start`, and an unknown type, the results equal today's arrays exactly.
- **T2, gate ON, qualified:** `[usage (unchanged), content(text, .completeText(uuid, session, message.id, envelopeJSON))]`.
- **T3, gate ON, unqualified:** two blocks, a non-text block, missing `uuid`/`message.id`/`session_id`, `"message"` type, string content, sidechain. Each produces the legacy results plus a trailing `.unqualifiedAssistantEnvelope`, with no carrier.
- **T4:** `content_block_start` gives `.partialOutput`; an unknown top-level type gives `[.unknownEnvelope]`.

**Bridge** (ClaudeCompatible tests)
- **B1:** each signal case round-trips in both directions.

**Router and controller tests**
- **C1:** a result carrying a signal reaches the `.stream` event unchanged and is not suppressed.
- **C2:** existing usage and turn-completion tests pass with the gate ON.

**Core unit tests**
- **P1:** `make` succeeds; the key and digest equal 4d2's for the same entry; the deterministic ID is stable.
- **P2:** each refusal case.
- **P3:** attempt rules: a second envelope disqualifies; duplicate results are accepted; a non-success result is rejected; a session mismatch is rejected.
- **Digest parity:** if the O19 capture is already committed as a fixture, the live digest of the stdout envelope equals the 4d2 digest of the JSONL entry. Otherwise run this offline against the existing capture and record it in evidence as not-live (Q1).

**`ClaudeNativeBackgroundTranscriptTests` / view model**

| ID | Scenario | Expected |
|---|---|---|
| V1 | Identified row, then clean finalization | Ledger item committed; one save |
| V2 | Re-delivery | No-op |
| V3 | Same key, different text | Original row untouched; new visible row; no commit (revocation set if the match was committed) |
| V4 | Generic delta after an identified row | New row |
| V5 | `final_content` equal / conflicting | No change / visible append and no commit |
| V6 | Background delta or `final_content` targeting an identified or imported row | Not mutated |
| V7 | Tool, reasoning, carrier-less content or a signal in the attempt | No commit; output visible |
| V8 | Cancelled or error finalization | No commit |
| V9 | Background `.unknownEnvelope` | Revocation persisted |
| V10 | Gate OFF | Existing tests unchanged |

**Reconciliation suite** (all failures must preserve local rows)

| ID | Scenario | Expected |
|---|---|---|
| R1 | Committed live proof with a matching native entry | Dedup; no duplicate row |
| R2 | Native entry missing | Refuse |
| R3 | Digest mismatch | Refuse |
| R4 | Local text edited (live **and** imported rows) | Refuse |
| R5 | Local row missing | Refuse |
| R6 | Order mismatch | Refuse |
| R7 | Payload unavailable | Refuse |
| R8 | Revocation, both decoded and malformed raw | Refuse |
| R9 | Codec: revocation round-trip; absent means nil; unknown members preserved | — |

---

## 5. Risks and migration

- **Schema:** one additive optional member. There is no version bump and no backfill. Old sessions decode to `nil`.
- **Rollback:** a 4d2 build preserves `liveOutputRevocation` but ignores it, so it would fail open on that one case. Production recovery is OFF, so this is accepted and recorded under `assumed:`.
- **Gate-ON-only UX:** a conflicting `final_content`, or a same-key-different-text re-delivery, appends a visible row instead of replacing one. This is intentional: refuse rather than overwrite.
- **The revocation is sticky.** After a background unknown event, the session can never reconcile in 4d3. That matches the existing outcome for any unidentified live row.

---

## 6. Implementation order

1. **Validate first (code reading only, no model prompts):** Q1–Q5 below, plus Q6 (the call sites listed under Q6).
2. **Steps 2a–2c are atomic: land them together.** They add the DTO field, core mirror, bridge mapping and B1, and they are inert.
3. Translator gate and classification, plus T1–T4.
4. Controller wiring (gate default OFF), the suppression exemption, and C1–C2.
5. Ledger `liveOutputRevocation`, the deterministic ID, and R9.
6. Reader upgrade, R1–R8. This is independent of steps 2–4 and already hardens imported rows.
7. View model guards (ledger association only), V4–V6 with imported rows. This can land before step 8.
8. Proof builder and attempt state (P1–P3, digest parity), then the view model's identified path, commit and revocation write (V1–V3, V7–V10). **Steps 8a and 8b are atomic.**

Proposed status line: `Step 4d3 — todo | rounds 0/2 | open: | downgraded: | assumed: rollback-ignores-revocation (activation OFF) | deferred: origin field, live proof pruning, multi-block/thinking/tools/partial`

---

## Answer: is a run-scoped marker necessary?

- **Invalidation is enough inside an attempt,** provided proofs only become durable at the attempt's clean authoritative end. "Invalidate" then means "never commit". A crash, a cancellation or an in-attempt signal all leave saved rows without a proof, and the existing rule refuses those. A durable open/closed run marker would only repeat what a missing proof already says.
- **One live-only gap remains.** It needs all three of these:
  - a signal that may target **already committed** output (unknown envelope, documented retraction, or the same key with a different payload) arrives after the commit, in the background or in a later attempt;
  - native history keeps the targeted entry unchanged and unmarked;
  - the signal's target can't be resolved, because ledger keys don't store `message.id`, retraction semantics are unqualified, and deleting imported proofs would disturb 4d2 receipts and keysets.
- **For that gap, one optional sticky member is needed:** `liveOutputRevocation`. It is set in memory by the view model, serialized in the existing session save as an optional member of `AgentSessionProviderHistoryRecovery`, and makes the reader refuse even when it is malformed.
- **What stays unprotected:** the window between observing such a signal and that save completing. Closing it would require write-ahead logging of stdout, which is out of scope.

## Consequential unresolved questions

- **Q1. Digest parity and the qualified config.** Does the 4d2 semantic payload digest the same for the stdout envelope and its JSONL entry? `stop_reason` and `usage` may differ between them. Also, does the qualified default config emit `stream_event` content blocks? And is `result.result` byte-equal to the assistant text?
  - **Validate:** the existing O19 capture, offline.
  - **If the digest differs or deltas are present:** 4d3 is correct but never fires. Bring the semantic-subset question to the owner rather than adding partial support.
  - **If `result.result` differs:** every qualified turn gets disqualified and gains a duplicate row.
- **Q2. Where the ledger lives in memory.** Is the ledger held on `AgentTabSession` and serialized by the regular save? If not, use the `AgentSessionDataService` fallback, and build the guard cache from that owner.
- **Q3. Known keys after the receipt target.** Does the 4d2 reader already treat known keys after the latest receipt target as overlap? If not, step 6 changes that branch.
- **Q4. Documented retraction events.** Which 2.1.302 stdout events are documented as supersede, abort or retract?
  - **Recommendation:** map only those to `.retraction`, and leave unknown top-level types as `.unknownEnvelope`.
  - **Assumed if unanswered:** no documented types, so the case stays unused.
- **Q5. Lifecycle results with nil text.** Today, does the controller suppress them, or does the view model render them? Either one would break signal delivery.
- **Q6. Field-by-field rebuilds.** Do any other `AIStreamResult(...)` constructions copy an existing result field by field (remote wire, gateway, logging)? Such a site would drop the carrier, which fails safe as legacy, but it should be listed.

## Recommendations

1. Settle Q1 from the existing capture before anything else. It decides whether this step does anything for the qualified config.
2. Land the reader upgrade (step 6) and the guards (step 7) first. They harden imported rows whatever the outcome of Q1.
3. Keep the gate OFF by default, and keep it separate from recovery activation. Record any gate-ON results as fixture or offline evidence, never as live.
4. Defer:
   - an origin field;
   - pruning of live proofs;
   - multi-block, thinking and tool shapes;
   - partial support;
   - clearing the revocation.

   Each needs new qualification evidence that this step doesn't have.


## Controller-only scope reduction

Returned inherited preset identity verified, operation `F68AD9FB-B505-4573-816C-0CC3AF0D7781`. The prior operation A032E3B8-0818-4D0E-9586-CCD1B2063838 failed with oracle_stream_failed/message_missing; this is its one permitted retry, not a substitute lane. Planning only; full response follows.

# Oracle Plan



# Step 4d3b: should evidence attach in core, inside the controller?

## Verdict: yes, with four conditions

**Recommendation:** attach the evidence inside `ClaudeNativeProcessSessionController`. Drop the provider-package DTO, translator and bridge changes from Step 4d3b.

**Why the cut works:**
- The root wrapper `SDK/ClaudeSDKNDJSONTranslator.swift:60–67` turns the package output into core `AIStreamResult`s before the controller sees the array.
- From 2434 to 2515 the controller already has three things in one scope: the raw payload bytes, the original `payloadType`, and the translated core array.
- Nothing between the controller's `emit(.stream(result))` and the view model needs a package type. The router passes the whole `.stream(AIStreamResult)` event through.
- Mirrored package types would therefore only carry data the controller already holds. They would also add two more field copies to the bridge, which copies explicitly in both directions, and each copy can drop or misalign the field.
- Enrichment at the controller also gets around two blind spots in the translated array, which the old plan had to patch inside the translator:
  - Unknown types translate to `[]`.
  - The controller suppresses task and abort results.

**The cut holds only if all four of these are true:**
1. **Classify the raw payload, not the translated array.** Disqualifications must not depend on what the translator or the suppression step keep.
2. **Feed the classifier and the translator the same bytes.** `envelopeJSON` is the exact `Data` passed to `parseNDJSONLine`, so the evidence and the content text come from one input.
3. **Nothing on the built-in path converts core back to package.** No caller after the controller may run `providerStreamResult(from:)` and then convert back. That round trip would drop the field. This fails closed (no identity), but it would make the feature do nothing without any error. Check this by listing the callers of `providerStreamResult(from:)` (Q4).
4. **The full 4d2 projection and digest run in the classifier**, so the controller is the only place that grants qualification (§2).

---

## 1. Where enrichment goes, in what order, and how it avoids duplicates

### Core-only evidence type
This lives in a new AgentCore file next to the existing 4d2 Claude helpers. It is immutable and `Sendable`. It is `Equatable` only if `AIStreamResult` is.

```swift
struct ClaudeNativeOutputEvidence: Sendable, Equatable {
    let producerLaunchToken: <type of activeStdoutLaunchToken>
    enum Kind: Sendable, Equatable {
        case completeText(item: AgentSessionProviderHistoryRecovery.NativeItem, // 4d2 rowKey/ordinal 0/digest/deterministic localItemID
                          messageID: String, envelopeJSON: Data)
        case disqualified(reasonRaw: String)
    }
    let kind: Kind
}
// AIStreamResult: + `var nativeOutputEvidence: ClaudeNativeOutputEvidence? = nil`
```

- **If `AIStreamResult` is `let`-only:** add one `withNativeOutputEvidence(_:)` helper in its own file. Do not rebuild results field by field in the controller.
- **If `AIStreamResult` has synthesized `Codable`:** exclude the new property from coding. Wire and log output then stay byte-identical whatever the gate state.
- **Never log `envelopeJSON`.**

### Order inside the per-payload function

1. **2434–2440 (unchanged):** serialize the payload, then `parseNDJSONLine`.
2. **New pure call, after parsing and before the 2472 block:**
   `classify(payload:, bytes:, results:, latch:&, mainTurnOwned:) -> (attachIndex: Int?, standalone: ClaudeNativeOutputEvidence?)`
   - It runs only when the launch's latch exists (§2).
   - Otherwise it is skipped entirely, so gate-OFF and ineligible launches behave byte-for-byte and result-for-result as today.
3. **2472–2480 (unchanged):** the `payloadType` checks and the assistant usage that the loop owns. Nothing about usage moves.
4. **Standalone disqualification emit, new:** if `standalone != nil`, call `emit(.stream(<metadata-only result>))` once.
   - The result has `text == nil`, no usage observation, and is not `message_stop` or `final_content`.
   - It goes immediately before the loop and **outside it**, which means:
     - it never meets suppression or the special state and progress branches;
     - it still fires when the translator returned `[]`;
     - it always comes before the original result's FIFO and completion handling.
   - It uses the most inert existing core type the view model already ignores (check this; see Q5).
   - The view model reads `nativeOutputEvidence` before it dispatches on `type`.
5. **Loop 2482–2515 (unchanged):** if `attachIndex` is set, the evidence was attached to `results[attachIndex]` before the loop. That is the single `content` result, and it goes through the ordinary emit.
6. **Completion after the loop (unchanged):** completion still uses the original `payloadType`.

### Rules for `completeText`
The evidence attaches only when **all** of these hold. Anything else becomes a standalone disqualification and sets the latch.

- The raw payload qualifies (§3).
- The 4d2 projection gives exactly one assistant-text row at ordinal 0, and its digest computes.
- The translated array has **exactly one** result of type `content`, and its `text` equals the raw text block byte for byte.
- The array contains nothing besides that content result and the existing usage result.

### Why this cannot duplicate anything
- **Content:** no content result is ever added. The evidence rides on the existing one, so the row and its proof arrive in the view model as one unit.
- **Accounting:** the usage path is untouched. The standalone result has no usage observation.
- **Finalization:** the standalone result is never `message_stop`, and completion still keys off the original `payloadType`.
- **Re-delivery:** if a router or replay delivers the same result twice, the view model treats the same row key with the same digest, with the row present and the same text, as a no-op.

---

## 2. Latch and evidence ownership, scoped to the producer

### The controller owns the only qualifying latch
It lives in the controller's existing stdout-processing isolation, the same place `activeStdoutLaunchToken` lives:

```swift
private var nativeQualificationLatch: (token: Token, disqualifiedReason: String?, turnText: String?)?
```

- **Created only at 1359–1362,** when a real producer launch is installed, and only if `injectedQualificationEnabled && outboundUserMessageIdentityEligible`:
  - `injectedQualificationEnabled` is an injected controller init/config value, default `false`, that no production caller sets;
  - `outboundUserMessageIdentityEligible` is the check at 924–932.
- **Cleared at 1084 and 3316,** together with the token.
- **Never reset by** `resetEventsStreamForNewRun` (789), a turn start, `system/init`, or the router. Each of those changes the consumer, not the producer.
- **Sticky once disqualified:** within a token, every later assistant envelope gets `.disqualified("latched")`, never `completeText`. A later turn or a background emission cannot bring qualification back.
- **Main-turn ownership:** `completeText` also needs the payload to arrive while a main turn is owned, using the same predicate as `emitMainRequestUsageIfOwned`. An assistant envelope with no owner is a disqualification and sets the latch.
- **Token stamping:** evidence is stamped with the token of the producer whose stdout the line came from.
  - If the line's reader token differs from `activeStdoutLaunchToken`, no `completeText` is produced.
  - Check whether stale lines are already dropped before 2434.
- **Per-turn state:** `turnText` holds the qualified text of the current turn.
  - A second assistant envelope before `result` disqualifies.
  - The `result` payload checks `turnText` (§3), then resets it.

### What the view model keeps
It is transient, never persisted, and **not** a second qualifier:

```swift
liveProofKeysByLaunchToken: [Token: (rowKeys: Set<String>, locallyDisqualified: Bool)]
```

**When `completeText` arrives on the active-run path,** check four things in this order:

| Condition | Action |
|---|---|
| Token is locally disqualified | Render the legacy row |
| Row key already in the ledger with the same digest, and the row is present with the same text | No-op |
| Row key already in the ledger with a different digest or text | Do not overwrite. Append the text as a visible unidentified row. Disqualify the token. |
| Otherwise | Append a row with the deterministic ID, and add the ledger `NativeItem` to the same main-actor mutation. Record the row key under the token. `markDirty`, then `scheduleSave`. |

**Other cases:**

| Case | Action |
|---|---|
| `completeText` delivered on the background path, or the row cannot be built | Render the legacy row, unidentified. Set `locallyDisqualified`. Clear digests for that token's keys. |
| `.disqualified` arrives on any path | For every row key under that token: clear the typed `envelopeDigest` and the raw `extras["envelopeDigest"]`. Keep the association. Leave the row text untouched. `markDirty`, then `scheduleSave`. |

- **Why token scope is enough:** with resume and restart activation OFF, a launch cannot target proofs from another launch. Imported rows rely on the 4d3a guards and on the reader.
- **Why losing the map on restart is acceptable:** the map goes away when the app restarts, but so does the producer. That is safe while resume is OFF.

---

## 3. Explicit benign classification for the observed shape

This is an allowlist over the **raw** payload, matching the O19 counts. Anything not listed here disqualifies and sets the latch, including:
- any `stream_event`;
- any other `system` subtype (for example compaction);
- tool progress or summary payloads, `auth_status`, and `error`;
- unknown top-level types, including ones the translator turns into `[]`;
- extra keys or unknown states in the lifecycle payloads.

| Raw payload | Benign / qualifying when | Otherwise |
|---|---|---|
| `command_lifecycle` | `state ∈ {queued, started, completed}` and keyset ⊆ `{command_uuid, session_id, state, type, uuid}` | Disqualify (covers abort, cancel and fail states) |
| `system` | `subtype == "init"` only | Disqualify |
| `user` | It is the replay of the outbound caller message: the same UUID that 4d1/4d2 claim association matches, and no `tool_result` blocks | Disqualify (Q3) |
| `rate_limit_event` | Always benign. It is not model output. | — |
| `assistant` | Not sidechain; `uuid`, `session_id` and `message.id` are non-empty; `message.role == "assistant"`; exactly one `text` block with non-empty text; the 4d2 projection and digest succeed; a main turn is owned; no earlier assistant in this turn | Disqualify (covers multiblock, thinking, tools and partial output) |
| `result` | `subtype == "success"`, `is_error != true`, and when both `result.result` and `turnText` exist they are equal | Disqualify (covers conflicting `final_content` and abort-shaped results; Q2) |

**Control-protocol payloads** that the controller consumes before 2434 never reach the classifier. Confirm that interrupt requests and responses are among them. If they are not, they disqualify, which is the safe default.

**Why the result check lives in the controller** (one string comparison): it disqualifies a conflicting `final_content` even if the 4d3a guard only declines to mutate the row. The 4d3a guard must still append a differing `final_content` as visible text. It must not silently drop it.

---

## 4. Can the existing scheduled save stay? Yes

**Proof creation.** The row and its `NativeItem` change in the same main-actor mutation, and `makePersistedAgentSession` (15165/15196) snapshots both. Every saved snapshot therefore has either both or neither, and no barrier is needed.

**Invalidation.**
- The digest is cleared in memory, then `markDirty` and `scheduleSave` run.
- An older save may still be in flight. 14951 only checks the owner, so that save can write the stale digest.
- Afterwards, 14994–15008 requests a fresh save, so the cleared state is what lands last.
- So an older view-model save cannot cancel out a successful invalidation.

**Crash window (state this plainly).** The window runs from the moment the disqualifying payload is processed until the next save containing the cleared digest completes. That includes the debounce and any stale save in flight. A crash inside it leaves a digest on disk that the reader may accept.
- No stdout journal exists, and no immediate-durability claim is made.
- With the production gates OFF and final live acceptance pending, this is P2 at most. Record it under `deferred:` as `invalidation crash window (no WAL)`.
- If the data service already has a non-debounced save request, using it for invalidation is a free improvement. Add no new barrier.
- Proof creation has no matching window: a crash before the first save simply loses both the row and the proof together.

**Precondition this step depends on (Q1).** Clearing the digest only refuses if the reader treats a Claude association with **no typed digest and no raw digest** as a refusal. If 4d2 accepts digest-less items as back-compatible (for example, items from before 4d2), invalidation has no effect. The design then needs a different rule before implementation. Reader test R1 below settles this.

---

## Minimum tests

All tests use existing suites with synthetic fixtures built from the documented keysets. None uses raw capture data, and none counts as live evidence.

**Pure classifier** (core unit tests, alongside the 4d2 reader tests)

| ID | Covers |
|---|---|
| K1 | The O19-shaped sequence (`command_lifecycle` ×3, `system/init`, user replay, assistant, `rate_limit_event`, `result`) gives exactly one attached `completeText` whose key and digest equal 4d2's for the same entry. Every other payload is benign. No extra results. |
| K2 | Each disqualifier in the §3 table gives a standalone disqualification, including an unknown type whose translated array is `[]` and an abort-shaped payload whose translated result is suppressed. |
| K3 | Latch: once disqualified, a later qualified envelope stays disqualified. `resetEventsStreamForNewRun` keeps the latch. A new launch token resets it. An envelope with no turn owner disqualifies. A second assistant envelope before `result` disqualifies. |
| K4 | Gate OFF or ineligible launch: no evidence, and the emitted sequence is identical. |

**Existing controller tests**

| ID | Covers |
|---|---|
| C1 | The standalone result is emitted before that payload's loop results and before completion. Usage emission count and the FIFO/completion sequence are unchanged when the gate is ON. |

**`ClaudeNativeBackgroundTranscriptTests`**

| ID | Covers |
|---|---|
| V1 | `completeText` gives an identified row with the deterministic ID, plus a ledger item, and the next persisted snapshot contains both. |
| V2 | Duplicate delivery is a no-op. Same key with a different digest leaves the original row untouched, appends a visible row, and disqualifies the token. |
| V3 | A disqualification after the row clears both the typed and raw digests, keeps the association and the text, and marks the session dirty. |
| V4 | Background `completeText` renders a legacy row and disqualifies its token. |
| V5 | Equal `final_content` changes nothing; conflicting `final_content` stays visible (depends on 4d3a). |

**Reconciliation**

| ID | Covers |
|---|---|
| R1 | An association with no digest, in both typed and raw forms, refuses and preserves the local rows. |
| R2 | A live proof whose digest matches native history is accepted with no duplicate row. |

**Cut:** package DTO, translator, bridge and mirror types; any new persistent member; WAL or barrier; app harness; new captures; log tooling. A save-interleaving test is optional. Add it only if the existing save tests already expose the in-flight hook; otherwise cite 14951/14994–15008 as code-read evidence.

---

## Open questions that matter

- **Q1 (blocks the design).** Does the 4d2 reader refuse a Claude item that has a `localItemID` but no digest? If not, choose before implementing:
  - **Option (a):** refuse digest-less items only when they are live-created. This needs some way to tell live-created items apart.
  - **Option (b):** refuse all digest-less Claude items. This is only safe if no pre-4d2 ledger items exist.
  - **Recommendation:** check first. Prefer (b) if no pre-4d2 items exist.
- **Q2 (owner choice).** When the user cancels and Claude then emits a non-success `result`, the classification above treats it as an abort and disqualifies. Only interruptions **without** a result keep their proof. Choices:
  - **(a):** keep it conservative, as specified above. This is my recommendation.
  - **(b):** treat a non-success result after a complete envelope as benign. This would need qualification evidence we don't have.

  If you don't answer, I will proceed with (a) and record it under `assumed:`.
- **Q3.** Can the controller actually see the outbound caller UUID needed to recognise the user replay? If not, `user` payloads can't be classified as benign, and every turn disqualifies. The feature fails closed but never fires.
- **Q4.** Does anything call `providerStreamResult(from:)` downstream on the built-in path?
- **Q5.** Which existing core result type does the view model and router treat as inert when `text == nil`?
- **Multiple turns per launch (assumed, not a blocking question).** Each turn is classified independently, with the latch spanning the launch. O19 covers one turn only, so I will record this under `assumed:`.

## Recommendations

1. Take the scope cut. Put the classifier in core, call it from the controller, and attach the evidence to the existing `AIStreamResult`. Make no package, translator or bridge changes.
2. Settle Q1 by reading the code before writing anything. The whole invalidation approach depends on it.
3. Make the controller latch, keyed to the producer token, the only place that grants qualification. The view model keeps only the token-to-row-key index and local disqualifications, and nothing it keeps can turn qualification back on.
4. Keep the scheduled save boundary. Record the invalidation crash window under `deferred:`, and don't make any durability claim.
5. Keep the injected qualification flag OFF by default with no production caller. Record every gate-ON result as fixture evidence, never as live.
