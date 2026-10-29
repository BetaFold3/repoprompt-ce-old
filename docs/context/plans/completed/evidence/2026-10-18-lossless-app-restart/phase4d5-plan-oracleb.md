# Step 4d5 — OracleB planning

Scope: read when the task touches Step 4d5 bounded Claude Read live-envelope planning.
Authority: Reference
Last-verified: 2026-10-24

Fresh independent planning from HEAD 7c4d3c33. Requested and returned preset identity verified as OracleB; main read the full reply. Same selected source, sanitized O20 evidence, question and verbatim review policy sent to both lanes together. This is planning, not source approval or live qualification.

## Verbatim response

# Oracle Plan



# Step 4d5 plan: inactive, bounded Claude Read-tool live path

## 1. Summary

**Decision: implement it.** Build the path the scout proposed, but inactive and default-off. Add three missing pieces:

- a single shared derivation of tool input JSON,
- a check that rejects a qualified result if the controller would suppress the result it is attached to,
- a guard that stops generic code paths from changing tool rows that the Claude ledger tracks.

O20 gives us what Step 4d3b got from O19, and a bit more:

- live stdout UUIDs match the native history UUIDs for every record type involved;
- the `message.content` arrays are equal in canonical JSON;
- the `tool_use`/`tool_result` link is shown;
- the result is attributed to the caller.

The setup with no replay is still unobserved. The design handles that by failing closed: it needs attribution on the call and on the result, and it never relies on replay. If an assumption is wrong, the producer is disqualified and the user sees the normal legacy display. Full Phase 4 and installed-profile qualification stay blocked.

**Cut condition:** if the raw O20 capture files can no longer be read, use only the keys named in the sanitized evidence doc. Record that under `assumed:`. Do not make up key sets.

## 2. What the code does today

- **Classifier (`ClaudeLiveTranscriptProducerState`).**
  - Turn states: `idle → dispatched → answered → idle`.
  - Every `tool_use` assistant is refused with `unsupportedAssistant`.
  - Every `user` that isn't a replay is refused with `unsupportedUserReplay`.
  - An assistant with no attribution is refused (`unattributedAssistant`) unless the turn was replayed.
  - The controller already classifies every payload before suppression, puts `.attach(index:)` evidence on any translated result, and emits refusals as standalone carriers.
- **Translator.** `resolveInvocationID` creates a random `UUID()` for each `tool_use_id`. `serializeJSONObjectString` writes args as `.prettyPrinted + .sortedKeys`.
- **Reader.** It formats tool input with compact `[.sortedKeys]` serialization, inline in `parseEntry`. `project` builds separate call and result rows:
  - row IDs come from `deterministicUUID("rpce-claude-history-row-v1", …entry.uuid, kind, ordinal)`;
  - the invocation ID comes from `deterministicUUID("rpce-claude-history-tool-v1", …toolUseID)`;
  - the result's `toolName` comes from the matching call.
- **Owner, legacy path (`applyStreamResult`).**
  - `tool_call` appends a row.
  - `tool_result` changes the matching call row into a result, matching by invocation ID or else by name only (`kind == .toolCall && toolName == … && isDeliveryRow`).
  - This collides with the canonical design. If the result is refused, the name-only fallback would turn a proof-backed canonical call row into a result row.
- **Owner, 4d3b/4d3c (`applyClaudeLiveTranscriptEvidence`).** It checks the projection and inserts the row, the ledger entry and the owned key together; `refuseClaudeLiveTranscript` invalidates proofs by key. All of this works for any row kind, so ledger, owned-key, hydration and reset code need no changes.

## 3. Design

### 3.1 Reader helpers (`ClaudeSessionHistoryReader.swift`)

- Move the existing inline tool-input serialization into `package static func canonicalToolInputJSON(_ input: NSDictionary) -> String?`, with the exact same options. `parseEntry` calls it. Output bytes must not change; the O20 reader tests pin this.
- Add two helpers built the same way as `singleTextAssistantRow`: create a synthetic `Entry`, then run `project`.

  ```swift
  package static func singleToolUseRow(nativeSessionID:, nativeEntryID:, toolUseID:, name:, inputJSON:) -> Row?
  package static func singleToolResultRow(nativeSessionID:, nativeEntryID:, toolUseID:, toolName:, text:) -> Row?  // isError: nil
  ```

  - The result helper passes a synthetic call entry in `entries` only so that `toolNames` resolves the name.
  - The live path never invents a row ID, invocation ID, digest or JSON form; all of them come from these helpers.
  - **Canonical JSON:** the classifier never uses the translator's `toolArgsJSON` as an identity. It takes `message.content[0].input` from the parsed stdout line, as an `NSDictionary`, and runs it through `canonicalToolInputJSON`. The input must have exactly the key `file_path` with a `String` value, so number and float canonicalization cannot come up. Escaped `/` behaves the same on both sides because both use `JSONSerialization`.

### 3.2 Classifier (`ClaudeLiveTranscriptQualification.swift`)

**New struct `ClaudeLiveTranscriptToolRow` (Equatable).**
- Fields: `nativeSessionID`, `nativeEntryID`, `rowKind` (`.toolCall` or `.toolResult`), `localItemID`, `invocationID`, `toolUseID`, `toolName`, `payload` (canonical input JSON for a call, result text for a result), `envelopeDigest`.
- Computed members, mirroring `ClaudeLiveTranscriptCompleteText`: `ledgerKey`, `ledgerItem`, `matchesProjection` (re-derives through the 3.1 helpers) and `canonicalItem` (via `ClaudeSessionHistoryReader.item(for:)`).
- `ClaudeLiveTranscriptCompleteText` stays as it is.

**New `Evidence.Kind` cases.** The existing cases do not change.
- `.toolCall(ClaudeLiveTranscriptToolRow)`
- `.toolResult(ClaudeLiveTranscriptToolRow)`
- `.toolTurnAgreement(callItemID: UUID, resultItemID: UUID, answerItemID: UUID, text: String)`

**New disqualification reasons:** `unsupportedToolUse`, `unsupportedToolResult`, `toolLinkMismatch`, `attachmentSuppressed`.

**New private `Turn` cases:**
- `toolCalled(call: ClaudeLiveTranscriptToolRow, outbound: UUID)`
- `toolResulted(call:, result:, outbound:)`
- `answered` gains `chain: (callID, resultID)?`. Use a small struct so `Turn` stays `Equatable`.

**Transitions.** `turnInFlight` and `eligibility == .eligible` are required throughout.

| From | Payload | Requirements | To / evidence |
|---|---|---|---|
| `dispatched` | assistant, exactly one block `{type,id,name,input}` with `type == "tool_use"` | `name == "Read"`, input is exactly `{file_path: String}`, attribution `== true` (required even when replayed; O20 had both), `wire_tool_inputs` allowed only on this kind of envelope (type taken from the capture, value never read), existing null keys still null, exactly one non-usage translated result of type `tool_call` named `Read` whose args parse to an object equal to `input` | `toolCalled`; `.attach` `.toolCall` |
| `toolCalled` | `user` that is not a replay | `isReplay` absent or false (decide from the capture), `parent_tool_use_id` null, fresh `uuid` (≠ outbound, ≠ call entry), message `{role: user, content: [ {type, tool_use_id, content: String} ]}` with no `is_error`, `tool_use_id == call.toolUseID`, `tool_use_result` is a dictionary and `tool_result_meta` is an array (both opaque, values never read), exactly one translated `tool_result` named `Read` | `toolResulted`; `.attach` `.toolResult` |
| `toolResulted` | assistant with exactly one text block | attribution absent or exactly the outbound (`false` → `attributionMismatch`); same shape and translation checks as today | `answered(chain)`; `.attach` `.completeText` (unchanged kind) |
| `answered(chain)` | success `result` | existing checks, plus attribution `== true` (required) | `idle`; standalone `.toolTurnAgreement` |

- **Refused in tool states:** a replay, a second `tool_use`, a `tool_use` after `toolResulted`, a text block in `toolCalled`, a non-Read tool, multiblock content, thinking, `is_error`, a non-null `parent_tool_use_id`, or a mismatched link.
- `rate_limit_event`, `system/init` and `command_lifecycle` stay benign in every turn state. O20 shows the rate-limit event between the call and the result, and init once per prompt.
- **Binding the unattributed final text without guessing.** Ownership is the dispatch's recorded outbound UUID, carried through the turn state:
  1. The call must name that UUID exactly.
  2. The result must carry the provider `tool_use_id` taken from that same attributed envelope.
  3. No other outbound can happen in between; `noteOutbound` from a non-idle turn already disqualifies with `overlappingOutbound`.
  4. The success result must then attribute the same UUID. If not, it disqualifies and the owner invalidates all three proofs.

  Nothing reads the transcript's "latest user" row.

### 3.3 Controller (`ClaudeNativeProcessSessionController.swift`)

The only change is in `classifyLiveTranscriptPayload`. On `.attach(index, _)`, check `Self.shouldSuppressUserFacingStreamResult(streamResults[index])`. If it would be suppressed, disqualify with `attachmentSuppressed` and return the carrier. Without this, the evidence could be dropped silently. The check is harmless for `content`, so the single-text path is unaffected.

### 3.4 Owner (`AgentModeViewModel.swift`)

**Signature.** Change it to `applyClaudeLiveTranscriptEvidence(_:result:session:isBackground:)`. Accounting needs the translated values.

**Shared helper.** Pull out a private `insertClaudeLiveCanonicalRow(ledgerItem:item:producer:session:)` that does the append, the ledger write, the owned key, `isDirty` and `scheduleSave`. `.completeText` uses it with no change in behavior.

**`.toolCall`**
- Apply the same guards as `.completeText`: not background, producer not refused, `matchesProjection`, session match, no proofless rows for that session, canonical ID equal, and no existing key or collision (a duplicate counts only if its kind, invocation ID and args are equal).
- Also require that the legacy path would have shown the event: `toolName == "Read"`, not `shouldSuppressProviderToolEvent`, not `shouldHideToolFromTranscript`, and not `shouldAutoCompleteProviderToolCall`.
- `runService.handleProviderToolStreamEvent` has side effects, so it can't be used as a check. **Inspect it** and add a test asserting it returns false for Claude's built-in Read. If it can claim Read, refuse instead.
- Then run the legacy tool pre-steps: `flushPendingAssistantDelta`, `endAssistantSegment(background: false)`, `endActiveReasoningSegment`. Do **not** call `clearClaudeReasoningStatus`, matching legacy behavior.
- Then `addToolInputTokens(result.toolArgsJSON ?? result.toolArgs)`. This uses the *translated* value so token counts match exactly whether the gate is on or off.
- Then insert and return `true`.

**`.toolResult`**
- Same guards, plus: the call key must be in `claudeLiveTranscriptOwnedKeys[producer]` with a valid digest, and `session.items` must hold the call row (same invocation ID, `.toolCall`).
- **Append a separate result row; never change the call row.** This matches import.
- Then `addToolOutputTokens(result.toolResultJSON ?? result.toolOutput ?? "")`.
- `codexCoordinator.reconcile…` is skipped only if inspection confirms it does nothing for Claude sessions; otherwise call it with the translated values.

**`.toolTurnAgreement`**
- All three IDs must be Claude ledger rows with digests. The rows must exist with the right kinds, and the answer text must be equal.
- Otherwise call `refuseClaudeLiveTranscript`. Return `false`.

**Protecting mutation paths.** Both `tool_result` lookups (by invocation ID and by name only) skip rows where `session.providerHistoryRecovery?.associatesClaudeLocalItem(row.id) == true`; a match on such a row falls through to append. This also protects imported rows.

The implementer must then **search every remaining place that edits existing `.toolCall`/`.toolResult` rows** (`replaceItem`, `items[i] =`, and sweeps that finalize or cancel pending tools in AgentModeViewModel, the run service, `AgentToolTrackingSupport` and `AgentTabSession`) and add the same skip. Record each site in the evidence doc. This is what keeps refused or cancelled turns from rewriting proof-backed rows.

### 3.5 Things that stay the same

- Ledger schema, ID algorithms, the persisted model and `invalidateClaudeEnvelopeProofs` are unchanged.
- Owned keys stay transient.
- Clear-chat reset and hydration/rebind behavior are unchanged.
- A refusal invalidates every key the producer inserted, now including call and result keys.

## 4. Files that change

1. **`ClaudeSessionHistoryReader.swift`:** the `canonicalToolInputJSON` extraction and the two row helpers.
2. **`ClaudeLiveTranscriptQualification.swift`:** the `ToolRow` struct, the new kinds, reasons and `Turn` states, the new tool_use, tool_result and final-text branches, and the stricter result attribution. Depends on step 1.
3. **`ClaudeNativeProcessSessionController.swift`:** the suppression check on attachment targets.
4. **`AgentModeViewModel.swift`:** the owner cases, the shared insertion helper, accounting parity and the lookup guards. Plus any sweep sites found by the search.
5. **Tests**
   - **`ClaudeSessionHistoryReaderTests`:** for each exchange, the helper rows must equal the O20 reader's rows (IDs, invocation ID, digest, JSON form).
   - **`ClaudeLiveTranscriptQualificationTests`:**
     - stdout-shaped O20 fixtures, without replay and with replay as corroboration;
     - every transition and refusal in the table above;
     - controller parity with the gate off and for ineligible launches, on a tool turn;
     - the suppressed-attachment refusal;
     - the result evidence's `localItemID` and digest equal the reader's projection of the matching native fixture.
   - **Existing 4d3b/4d3c owner test file:**
     - a qualified chain yields three distinct canonical rows, three ledger entries and owned keys, no merged legacy row, and the same token totals as gate-off;
     - when the result is refused, the call row is unchanged, a separate legacy result row is appended, and the call proof is invalidated;
     - result evidence with no held call is refused;
     - an agreement mismatch invalidates all three proofs;
     - live insertion followed by an import of the matching native fixture through `AgentProviderHistoryImportPlanner` appends nothing.
   - Run all existing 4d3b, 4d3c and 4d4 tests unchanged.
6. **Docs:** a new `evidence/.../phase4d5-…md` (scope, the key-inspection record, the list of mutation sites, validation) and the status line in the spec.

**What to inspect in the approved capture** (key names and JSON types only; no values, ids or content):
- **Tool_use assistant:** top-level keys, the `message` key set, the block key set, the input key set, the type of `wire_tool_inputs`, and which of `user_message_uuid` / `user_message_uuids` are present.
- **Tool-result `user`:** top-level keys (`isReplay`? `timestamp`?), the `message` and block key sets, the content type, and whether stdout carries `parentUuid` or `sourceToolAssistantUUID`.
- **Final text assistant:** confirm its keys ⊆ `assistantKeys`.
- **Result:** confirm its keys ⊆ `resultKeys`.

## 5. Risks

- **No-replay profile unobserved.** The app's real setup (no replay) is unobserved; an unseen variation in attribution or record shape could exist. The worst allowlisted failure is a live row whose native entry is missing. Import would then refuse; the row is not silently lost. This is why installed-profile qualification stays a prerequisite before going live.
- **Two rows instead of one card.** With the gate on, a tool exchange shows as separate call and result rows, the same as imported history, instead of the legacy merged card. Behavior with the gate off is unchanged.
- **Wider effect of the lookup guard.** The guard also changes legacy behavior for imported Claude rows: a name-only match now appends instead of rewriting the row. That is the intended protection.

## 6. Implementation order

1. Inspect the capture key sets and record them in the evidence doc. If unavailable, use the cut condition from section 1.
2. Reader extraction and helpers, plus parity tests. Must leave the O20 and 4d4 tests unchanged.
3. Classifier states and tests.
4. Controller suppression check and tests.
5. Owner cases, lookup guards, the mutation-site search and the guards it requires, plus owner tests. Steps 3–5 land together if the new `Kind` cases break exhaustive `switch` statements.
6. Full focused test suite, build and style checks; OracleA/OracleB review; docs and status.

## Recommendations

1. **Go:** implement Step 4d5 as an inactive, default-off source-and-fixture step. Label it "O20-modelled; no-replay app profile assumed, not qualified."
2. **Bounds:** main thread only, exactly one Read call with `{file_path}` input, string result content with no `is_error`, a text-only final answer, and attribution required on both the call and the result. Everything else disqualifies to the legacy display.
3. **Identity:** take every ID, digest and JSON form from the reader helpers, using the raw stdout input. Never take them from translated values. Use translated values only for accounting.
4. **Protection:** never change rows tracked by the Claude ledger through generic tool paths. Treat the mutation-site search as an acceptance item for review, not optional polish.
5. **Remaining before going live** (not done after this step):
   - owner-approved installed-profile capture of the app's real launch flags (no replay, its permission mode, MCP and tool set);
   - production activation wiring and the owner decision on it;
   - the deferred crash window between proof invalidation and the scheduled save;
   - full Claude canonical merge and closure of the Step 4 blocked items;
   - final live acceptance (O3).
6. **Optional breadth, deferred:** other built-in or MCP tools (note that real app turns will mostly disqualify until MCP tools are covered), thinking, multiblock, parallel tools, sidechains, errors and denials, interrupts and abnormal exit, compaction, fork-resume, permission prompts, the F3 cosmetic fixes, and retention.
