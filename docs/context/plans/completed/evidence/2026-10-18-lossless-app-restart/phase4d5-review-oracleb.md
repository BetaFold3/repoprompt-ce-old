# Step 4d5 — OracleB initial review

Scope: read when the task touches Step 4d5 bounded source review and findings.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/1009, 14 files (+1926/−126). Fresh independent lanes received identical context and verbatim review policy. Exact requested/returned OracleB identity verified. Main read the full reply. No P0/P1. This is source review, not live acceptance.

## Verbatim response

# Oracle Review



# Step 4d5 review: Claude Read chain live evidence (snapshot 2026-10-24/1009)

This change adds the observed O20 main-thread Read exchange to the default-off Claude live-transcript latch. Each turn moves through `readCalled` → `readReturned` → `readAnswered` → agreement. Every link carries the history reader's own projection: deterministic row and invocation IDs, the envelope digest, and canonical input JSON. The translator's random invocation ID is used only to pair a live call with its result.

On the owner side, each link is inserted only while every earlier link is still held across both the persisted turns and the suffix. A new row is accounted exactly once, using the translated values. A duplicate of a held row, whether live or imported, does nothing and gains no ownership. A refusal invalidates only keys the producer itself inserted.

Claude-associated tool rows are protected in three places:
- the generic `tool_result` conversion, which appends a separate visible row instead;
- an `AgentTabSession` backstop on incremental and batch mutations;
- pending-tool finalization on the live, save-repair and cold-restore paths.

**Gate-off and O19.** I found no regression. Every new guard depends on a Claude ledger association that gate-off sessions don't have. The O19 complete-text path was extracted into `applyClaudeLiveTranscriptCompleteText` without changing its meaning when `prerequisites` is empty. The O19 classifier gives the same outcomes; only the diagnostic reason changes for unsupported tool-use envelopes.

**Severity.** I found no P0 or P1. Everything below matters only once the gate is activated, so under the policy these are P2 or lower.

## P2

### F1 (P2): a canonical Read call that never gets its canonical result stays "pending" forever

**Scenario.** The gate is on and the Read call qualifies, so its canonical `.toolCall` row is inserted with the reader's invocation ID. The result then fails to qualify. This is realistic, for example:
- a Read of an image, PDF or notebook, or a truncated file, where `tool_use_result` has other keys;
- a result with `is_error: true`;
- the user cancelling while the Read is in flight.

What happens next:
- The generic `tool_result` path finds no row with the translator's invocation ID. Its name-only fallback lands on the canonical call, which is associated, so the output is appended as a separate row. That row carries the translator's invocation ID and no `toolArgsJSON`.
- Cancellation and terminal finalization skip the call, because it is protected. So do the save repair and the cold restore.

**Impact.** The legacy path shows one completed Read row. Here the user sees a call row that never resolves, plus an orphan result with no arguments, and this persists across restarts. Nothing is lost and the answer is still visible, so this is a display problem only. It is acknowledged in Limitations ("A dangling canonical call … stays `.toolCall`"), but it is the most likely visible regression once the gate is on.

**Evidence:**
- `AgentModeViewModel.swift:19654-19663`: the associated branch appends the fallback row without arguments.
- `AgentTranscriptServices.swift:3499-3504`: protected rows are skipped during finalization.
- `AgentModeViewModel.swift:19925`.

**Smallest fix:**
- In the associated branch, copy the matched row's arguments onto the fallback: `toolResultItem.toolArgsJSON = argsJSON ?? session.items[index].toolArgsJSON`.
- Before activation, decide how a protected call that never resolved is presented. Options are to render it as finished-unknown, or to have finalization append a separate unidentified terminal result instead of skipping it. If you decide against changing this, record it as an accepted limitation in the activation decision.

### F2 (P2): nothing shows that a live Read row's identity and digest match what a later import of the native session file reads

**Scenario.** The live call and result rows take their entry `uuid`, `input` and result `content`/`is_error` from stdout. The later import reads the same entry from the native JSONL. The phase4d5 shape inspection read only the two O20 stdout files. The new reader test feeds the reader's own rows into the live projection functions, so it shows the two projection functions agree given the same inputs. It does not show that stdout and the native file carry the same inputs.

Concrete ways the two could differ:
- the native entry has `is_error: false` (the digest component becomes `"false"` instead of `"none"`);
- the native result uses array content;
- the native tool-result entry has a different uuid.

Any of these makes the next import hit `ledgerConflict`, which refuses the whole candidate.

**Impact.** Once activated, every qualified Read chain could permanently block restart import for that conversation. This fails closed, so no transcript data is lost, but restart recovery stops working for the conversation.

**Evidence:**
- `ClaudeSessionHistoryReader.swift`, `envelopeDigest`: the `tool_result` component includes the error flag, `?? "none"`.
- `ClaudeSessionHistoryReader.swift`, `parseEntry`: array content is joined with `"\n"`.
- `ClaudeLiveTranscriptQualification.swift`, `classifyReadResult`: requires a string `content` and no `is_error`.
- `phase4d5.md`, "Offline O20 shape inspection": stdout files only.
- `ClaudeSessionHistoryReaderTests.swift:~1473`: inputs come from the reader's own rows.

**Smallest fix.** Record this as an activation prerequisite in `phase4d5.md`. Before activation, run an offline key/type/equality-only comparison of the existing O20 stdout and native files for each call and result. It should cover:
- entry uuid equality;
- `input` equality;
- whether the result `content` is a string or an array;
- whether `is_error` is present.

No code change is needed now.

### F3 (P2): the round-trip test doesn't exercise the persisted payloads or the save-repair and cold-restore protections it is cited for

**Scenario.** `testLiveReadChainRoundTripsAndItsLaterImportIsANoOp` saves while `runState == .running`. That likely means the terminal save repair does not run; this is unverified. It then copies back only `persisted.providerHistoryRecovery` and keeps the in-memory `harness.session.items`. For persisted items it checks only the IDs (`persisted.items.suffix(3).map(\.id)`).

So a regression would pass this test if the save path or cold restore rewrote the canonical call's payload, for example through a finalizer caller that was missed and defaults to `protectedItemIDs: []`. In real use that same regression would produce `canonicalPayloadMismatch` or `canonicalPayloadUnavailable` on the next import.

The finalizer protections are unit-tested directly in `testPendingToolFinalizersKeepClaudeAssociatedToolRowsAsProjected`. They are not tested end to end.

**Impact.** The worker evidence ("persist and reload, then reconcile …") claims more than the test proves. This is a coverage gap; I found no defect in the code itself.

**Evidence.** `AgentRecoveryReconciliationTests.swift:~2360-2372`: the reload replaces only the ledger, and persisted items are compared by ID only.

**Smallest fix.** In that test, also assert `persisted.items.suffix(3) == harness.session.items.suffix(3)` on the payload fields. Better still, set a terminal `runState` before `flushSave` and reconcile against `persisted.items`. Either way, reword the evidence line to match what the test does.

## P3

- **F4: the finalizer's `protectedItemIDs` parameter defaults to empty, so a missed caller fails silently.** See `AgentTranscriptServices.swift:3486` and `AgentTranscriptQualityRepair.swift:30`. Any caller left out of the audit, or added later, that writes through `setItemsSilently` will finalize canonical calls with no warning. Fix: drop the `= []` default so every call site has to state its protection. The audit already covered the current callers.
- **F5: one doc comment doesn't match the code.** The comment on `applyClaudeLiveTranscriptToolRow` says "Every check that could refuse runs before any effect". The `handleProviderToolStreamEvent` refusal at `AgentModeViewModel.swift:20317-20323` runs after the flush, segment-end and reasoning-end preamble. The behaviour still matches legacy (it returns `true`, so the preamble doesn't run twice), but the comment should say so.
- **F6: the backstop does work on every tool-row mutation.**
  - `preservingClaudeAssociatedToolPayload` scans the ledger through `associatesClaudeLocalItem` on every tool-row `mutateItem`/`replaceItem`.
  - `preserveClaudeAssociatedToolPayloads` rebuilds `claudeLocalItemIDs` and compares the full items array a second time on each batch.
  - Locations: `AgentTabSession.swift:2855`, `2862` and `2682-2683`.

  This is negligible today, but bash and live tool output streaming goes through `mutateItem` on tool rows. Fix: cache the ID set, or return early when the ledger has no Claude tool rows.
- **F7: replacing a protected row inside a batch behaves differently from `replaceItem`.** `replaceItem` never lets a different item replace a protected row. A `mutateItemsBatch` body that swaps in a different ID at the same index does displace it, because restoration matches by ID. No current caller does this. Fix: document the difference, or restore by index when the ID changed.
- **F8: one gate covers both O19 and the Read chain.** `liveTranscriptQualificationEnabled` turns on both, so O19 can't be activated without the Read chain. Note this in the activation decision.

## Things I checked that hold

- **Accounting.** The new path accounts once, using the translator's pretty-printed arguments and output, which matches legacy. Refusals fall through to legacy accounting, and duplicates or imported rows are never accounted.
- **Ownership.** An imported duplicate gets no ownership, and refusals invalidate only keys the producer inserted itself.
- **Unattributed final text.** It is accepted only in `.readReturned`, with a turn in flight, a null `parent_tool_use_id`, and the overlapping-outbound guard in place. The success must carry both attribution fields.
- **Suppression.** `attachmentSuppressed` runs before any evidence is attached to a result that would be suppressed.
- **`final_content` after a canonical answer.** The 4d3a guard covers it: equal text means no change.
- **Background deliveries.** These are refused, and the legacy background path never name-matches run rows.

## Recommendations

1. Fix the cheap parts of F1 now (copy the arguments onto the fallback row) and F5 (the comment). Record the presentation of a call that never resolved (F1) and the stdout-to-native equality check (F2) as explicit activation prerequisites in `phase4d5.md`, not as code work for this step.
2. Strengthen or reword the round-trip evidence (F3). It is the only end-to-end claim about save and reload, and as written it says more than the test proves.
3. Defer F4, F6, F7 and F8 as P3. F4 (making the parameter required) is a one-line hardening worth taking if it compiles cleanly.
4. One thing worth checking before activation, though I have no evidence of a defect: canonical items built by `ClaudeSessionHistoryReader.item(for:)` don't pass `sequenceIndex`, whereas legacy rows use `session.nextSequenceIndex`. Confirm that `appendItem` or the builder doesn't order or split turns by `sequenceIndex`. O19 already shares this path for assistant rows.
5. On these findings the step can be committed with no open P0 or P1. The status line would read `deferred: F1–F8` (with F1 and F5 partly fixed if you take recommendation 1) and `assumed:` noting that the no-replay case is fixture-only.
