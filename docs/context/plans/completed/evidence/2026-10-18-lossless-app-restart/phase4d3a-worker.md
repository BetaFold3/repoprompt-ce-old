# Step 4d3a: canonical payload check and protection of associated rows (worker implementation evidence)

Scope: read when the task touches the transient validation projection of a Claude history import, the canonical payload and relative-order check in `AgentProviderHistoryAssociationPreflight`, the `canonicalPayloadUnavailable`/`canonicalPayloadMismatch` refusals, or the protection of Claude-associated assistant rows at live delta and `final_content` sites.
Authority: Reference
Last-verified: 2026-10-23

Worker evidence for main's bounded Step 4d3a in [phase4d3.md](phase4d3.md). It covers three worker passes:
- **First pass:** the original implementation.
- **Completion pass:** main's decisions on the first-pass questions (see [Completion pass](#completion-pass-main-q1q4-decisions)). Main staged the eight source and test files of the first and completion passes as the initial snapshot.
- **Initial-review repairs:** made unstaged on top of that snapshot as delta 2241 (see [Initial-review repairs](#initial-review-repairs)).

**Completion.** A/B re-review 1 closed the P1 with no new P0/P1 and the step is done for its bounded source scope (see [phase4d3.md](phase4d3.md#step-4d3a-completion)):
- Re-review 1, verbatim: [OracleA](phase4d3a-review-oraclea-r1.md) and [OracleB](phase4d3a-review-oracleb-r1.md).
- Deferred with no action: B's re-review 1 P3s (the nil-normalizer fallback and the redundant anchor comment) and initial F2/F4/F5.
- Latest validation: reconciliation 43/43 on the repair delta. Reader 34/34 and lifecycle 195/195 ran on the initial snapshot, and the repair left those sources unchanged. Compile, format-check and lint passed.
- No commit has been made yet.

The Changed files table counts the first and completion passes against `bf1fce5a`. It adds no carrier, DTO, gate, persisted marker, terminal integration or tool-mutation redesign. All gates stay OFF. No provider, capture, app or lifecycle operation ran. The worker staged and committed nothing, and the original unrelated dirt was left untouched.

## Changed files

The counts are `git diff --numstat` (added/removed) against `bf1fce5a`.

| File | +/- | Change |
|---|---|---|
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | 8/0 | `Candidate.validationRows`: the whole validated capture's rows in projection order, before any suppression (empty for every baseline). |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | 206/5 | `AgentProviderHistoryObservation.validationRows` (defaults to `rows`; the Claude mapping converts `validationRows`); two refusal cases; the `canonicalPayloadRefusal` check as the last step of `check`. Completion pass: user order anchors, the claim's per-entry constituents, grounded placement ambiguity, and `canonicalItemIDs` made `package`. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | 8/0 | `associatesClaudeLocalItem(_:)`: any Claude ledger row whose `localItemID` is this item, whatever its digest. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | 23/3 | Protection at `applyAssistantDelta`, `applyBackgroundAssistantDelta` and `final_content`; private `isProviderHistoryAssociatedItem`. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | 11/1 | User text for the two new refusals. Completion pass: a Claude import plans against `canonicalItemIDs(canonical)`; Codex keeps `session.items`. |
| `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift` | 20/0 | Assertions on the validation projection. |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | 425/9 | Four new tests, deliberately updated existing assertions, and helpers. |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift` | 132/0 | Two new tests and a helper. |
| `Scripts/source_layout_guardrails.sh` | 4/0 | Exact allowlist entries for `phase4d3.md`, `phase4d3-plan-oraclea.md`, `phase4d3-plan-oracleb.md` and this file. |
| `docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d3.md` | link | Link to this file (main's note; untracked). |

## Behavior

### Validation projection

The reader already projected the whole ordered capture before ledger suppression and `ledgerConflict`. It now returns that projection as `validationRows`, next to the deduplicated new `rows`.

`ClaudeSessionHistoryReader.observation` maps both through the existing `item(for:)`, so each row carries its deterministic local ID. Only the payload check reads `validationRows`. The planner, ledger, receipt and cursor never see them, and nothing appends or persists them.

### Payload and order check

`AgentProviderHistoryAssociationPreflight.check` keeps every earlier refusal in its existing order. After the existing canonical-output subset check passes, it returns `canonicalPayloadRefusal(...)`, so the check runs before any overlap or deduplication is accepted.

**Rows compared:**
- Every Claude ledger row of this conversation that has a `localItemID`. User-text rows are excluded (see Q1). The digest may be nil.
- Every observation row whose deterministic item ID is already in the canonical transcript. This is the planner's dedup path, which recorded such rows without a payload check.

Each compared row's provider item comes from the validation row with the same row key. A ledger-mapped key that is absent, or whose row has no item, refuses as unavailable. A ledger-mapped local ID that differs from the projected deterministic ID refuses as a mismatch.

**Canonical copy.** The persisted turns (request plus `allActivities` through `toItem()`) and `suffixItems` are read in order:
- The suffix is the authoritative working copy of the newest full-detail turns, which the persisted turns repeat. A turn activity whose ID is also in the suffix is read from the suffix.
- Items found only in the turns come before suffix items.
- An ID that occurs twice outside that overlap is ambiguous.
- Turn items are incomplete when the turn's `retentionTier != .full` or it is structurally compacted, or when the activity's `toolExecution.summaryOnly` is set.

**Fields compared** (exact equality): `kind`, `text`, `toolName`, `toolInvocationID`, `toolArgsJSON`, `toolResultJSON` and `toolIsError`. JSON strings are compared exactly, with no normalization. Timestamp, `sequenceIndex` and `isStreaming` are ignored.

**Order:** the compared rows, sorted by projection index, must have strictly increasing canonical positions.

**Refusals:**
- `canonicalPayloadUnavailable`: the row is missing or ambiguous; it sits in a compacted or summary-only turn or tool execution; a tool argument or result the provider has is nil in the canonical copy; or the canonical result differs and `AgentTranscriptToolNormalizer.isSummaryOnly` is true (session compaction summarizes suffix tool results).
- `canonicalPayloadMismatch`: a field differs, or the relative order differs.

Both refusals reach the view model's existing `.associationUnavailable` path, before the planner. No row, ledger, receipt or cursor changes.

### Protecting associated rows

`isProviderHistoryAssociatedItem` checks `session.providerHistoryRecovery?.associatesClaudeLocalItem(id)`.

| Site | Target selection | When the target is associated |
|---|---|---|
| `applyAssistantDelta` | unchanged | the delta appends a new streaming row instead of extending the target |
| `applyBackgroundAssistantDelta` | unchanged | takes the existing new-row branch, which also points this source's background pointer at the new row |
| `final_content` | unchanged (background current row, resumable streaming row, or backward search) | equal text: no-op, no duplicate, no attention provenance; unequal text: a new visible `AgentChatItem.assistant` row, the original kept intact |

At `final_content`, unassociated targets keep the existing replace plus `recordAttentionFinalContentRewrite`. The background pointer is retired in every background case, as before.

**Bypass search:** I checked the other assistant-payload writers in `AgentModeViewModel`, `AgentTabSession` and the Claude runtime.
- `applyReasoningDelta` writes only thinking rows.
- The tool-result writer (`updated.text = outputJSON`) and session tool-result compaction rewrite tool rows only. They are out of scope; the payload check detects a changed tool row.
- `AgentModeViewModel+Types.swift:425` and the compaction comparison helper (`expectedCompactedItem`) are not transcript writers.

I found no other writer that mutates assistant text.

## Tests

- **Reader suite** (`ClaudeSessionHistoryReaderTests`):
  - `testSameFileImportReturnsOnlyRowsAfterTheCursor`: pre-frontier rows are retained in order.
  - `testLedgerKnownEntriesMustMatchTheirCompleteEnvelopeBeforeSuppression`: the known rows of a fully suppressed replay are retained, the observation carries the ledger's local IDs, and the row identity, payload and digest match the first projection.
  - `testBaselineOnMissingFileAndExistingFile` and `testCaptureQualifiedSingleTextTurnProjectsOnlyTheClaimedUserAndAssistantText`: a baseline has no validation rows.
- **Reconciliation suite** (`AgentRecoveryReconciliationTests`):
  - The new pure test `testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder` uses mapped assistant, tool-call and tool-result rows with nil digests. It covers:
    - the equal pass, and a pass when only presentation fields change;
    - refusal when known rows are absent from the validation projection;
    - same-ID changes to text, kind, tool args, tool name, invocation, result and error;
    - reversed order;
    - missing, ambiguous, dropped-args, dropped-result and summary-JSON payloads;
    - a full persisted turn (passes), plus condensed, structurally compacted and summary-only turns;
    - full-turn plus suffix overlap: passes, compares the authoritative suffix copy, and refuses a turn-only row that precedes the suffix out of order;
    - dedup of an already-present observation row: equal, changed, out of order, and outside the validation projection.
  - `testPreflightNeverAssumesNativeUserOrLiveOutputAssociations`: the ledger association now passes only with the provider's validation row. Without it the result is `canonicalPayloadUnavailable`.
  - The new real view-model test `testAChangedImportedRowRefusesTheNextImportWithoutChangingAnything` (window 4995) runs a real admit, import and reconcile with the reader. After an import, Claude appends `a2` and the imported row's text is rewritten. The reconcile returns `.associationUnavailable(.canonicalPayloadMismatch, …)` with item IDs, row text, ledger and cursor unchanged. Restoring the row lets the same reconcile import `a2` (row count 2) and advance the cursor, so the refusal really blocked an import.
- **Background transcript** (an extension of `AgentModeRunServiceLifecycleTests`):
  - `testClaudeLiveDeltasNeverExtendAProviderHistoryAssociatedRow`: active and background deltas.
  - `testClaudeFinalContentNeverRewritesAProviderHistoryAssociatedRow`: active equal/unequal and background equal/unequal final content. Associated IDs and text are preserved, the background pointer is retired, and every ledger row has a nil digest.

**Negative checks:** each guard was temporarily disabled, the suites were run, and the files were restored byte-identical (`diff -q`).
- Making `check` return nil instead of the payload refusal failed 3 reconciliation tests (28 assertions; ticket `a0ed503b-ba4b-49a7-baca-7d121d936fdb`).
- Making `isProviderHistoryAssociatedItem` return false failed both new lifecycle tests (6 assertions; ticket `5cfb1545-b177-43e2-a60a-f5dea7b18cc7`).

## Completion pass (main Q1/Q4 decisions)

### Q4: planner duplicate gap closed

After the preflight, the view model now passes `AgentProviderHistoryAssociationPreflight.canonicalItemIDs(canonical)` as the Claude planner's `existingItemIDs`. This is the existing ordered helper, now `package`: persisted turns (requests included) plus the suffix. Codex still passes `session.items`. No store or new helper was added.

A row held only by a full persisted turn is therefore payload-compared first, then recorded against the existing item instead of being appended again.

### Q1: user rows as order anchors

`canonicalPayloadRefusal` now takes `claimedUserConstituents`. This comes from `claimAssociation`'s existing window and claims, as a `ClaimAssociation.userItemIDsByNativeEntryID` map from each claimed native entry ID to its dispatch's ordered `userItemIDs`. There is no new persistent mapping.

Two kinds of user anchor are checked:
- Every ledger-mapped native user row's local item, at its validation row's index.
- Every claimed entry's constituents, at the index of that entry's single native user validation row. A rank keeps the constituents' own order.

Anchors compare position only, never text. Every anchor must have its validation row (exactly one for a claimed entry) and must exist unambiguously in the canonical transcript; otherwise the result is `canonicalPayloadUnavailable`. All compared rows and anchors, sorted by (projection index, rank), must have strictly increasing canonical positions; otherwise the result is `canonicalPayloadMismatch`.

No production path sets `localItemID` on a ledger user row (the planner records user rows with nil), so ledger user anchors are defensive, and claims carry the real evidence.

### Q3: suffix authority grounded, ambiguous placement refuses

The source anchor is `AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix` (`AgentTranscriptServices.swift`).
- It keeps the existing non-full turns, and rebuilds the full working turns from `workingItems`, the `AgentTabSession.items` suffix.
- `transcriptByReplacingWorkingTurns` merges the rebuilt turns in place.
- `AgentTabSession.items` is documented as retaining only the mutable full-detail working turns.

So the suffix is the authoritative copy of every item it holds. A turn-only item has a determined place only in a turn before the first turn holding any suffix item, and it precedes every suffix item. A turn-only item in or after a suffix-bearing turn is marked ambiguous, and refuses as unavailable when compared.

Q2 (every mapped row, pre-baseline included, checked conservatively), Q5 (linear lookup) and Q6 (flags-only finalization) were accepted as implemented. No retention, hydration or index work was done.

### Tests (completion pass)

The changed contract is deliberate: a mapped user row now needs its native validation row.

**Existing pure tests updated:**
- Their synthetic ledger user associations now supply `userRow(userItem)` in `validation`. User rows never go in `rows`, because the reader suppresses ledger-known entries.
- In `testPreflightRequiresPositiveAssociationOfEveryUserConstituent`:
  - the same input without the validation user row now refuses `canonicalPayloadUnavailable`;
  - swapped native order of two mapped user rows refuses `canonicalPayloadMismatch`.
- In `testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder`, the earlier-turn cases use a native order with the output before the user row. The user-first order now refuses `canonicalPayloadMismatch` (output on the wrong side of the user anchor; superseded by the option (a) repair). The overlap case uses `a0, user, t0, t1, a1`. A new mixed-turn case (a turn-only row inside a suffix-bearing turn) refuses `canonicalPayloadUnavailable`.
- No assertion was weakened.

**New tests:**
- `testClaimedUserConstituentsAnchorTheRelativeOrderOfNativeOutput`: a two-dispatch claimed window, where a ledger-known reply lies natively between the two claimed entries. (The completion-pass contract; the [initial-review repairs](#initial-review-repairs) renamed and replaced it.)
  - In order, the check passes.
  - Reply moved after the claimed steer: mismatch.
  - A locally edited user text still passes, since user text is never compared.
  - A missing claimed-entry validation row, or a duplicated one, refuses as unavailable.
- `testClaudeImportNeverReappendsARowHeldOnlyByAPersistedTurn`: a pure preflight-plus-planner composition with the same deterministic ID present only in a full persisted turn.
  - The preflight passes.
  - Planning with `canonicalItemIDs` appends nothing and records the ledger row against the existing item.
  - The old suffix-only set would append it again.
  - A differing turn copy refuses `canonicalPayloadMismatch`.
  - The view-model wiring itself (`selectedAgent == .claudeCode` chooses the set) is covered by compilation only.

**Negative check:** I passed empty claim constituents, disabled activity placement ambiguity and skipped ledger user anchors together, then restored the file byte-identical. 3 tests failed (5 assertions; ticket `591c6e65-6a3f-46eb-91fd-7501829783dc`): the claim-anchor test, the payload test and the user-constituent test.

**Completion-pass validation (final source):**

| Command | Result | Ticket |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 42 tests, 0 failures | `edfdb5bd-b4e4-4fb8-8d49-4cff270bdb18` |
| `make dev-swift-build PRODUCT=RepoPrompt` | completed | `4da0a053-9948-4654-aea2-a0f6167278ef` |
| `make dev-format-check` | 0/2175 files require formatting | `e16d7fa3-0234-4797-b8e0-45886938534a` |
| `make dev-lint` | passed | `2841ba32-3fea-4660-85d4-0c212102281f` |

The reader suite, the lifecycle suite, `AgentModeViewModel.swift` and the reader and model sources were not edited in this pass. Their first-pass final results below still stand.

## Initial-review repairs

Raw reviews, verbatim: [OracleA](phase4d3a-review-oraclea.md) and [OracleB](phase4d3a-review-oracleb.md). Main verified both presets.

**P1 (A R1 / B F1).** The Claude import appends recovered rows at the end of the suffix. After a steered attempt (`c1, a1, c2, a2` natively, `[first, steer]` canonically), the transcript becomes `first, steer, label, a1, a2`. The completion pass's cross check between output and user anchors then refused the importer's own unchanged replay, and every later import of that attempt.

**Fix (main selected B option (a), a reversible implementation assumption, not an owner Decision).**
- `canonicalPayloadRefusal` now tracks two independent positions: compared output rows must keep native order among themselves, and user anchors (ledger-mapped user rows and claimed constituents) among themselves.
- Output is never ordered against user anchors. That cross guarantee is cut, and the existing append-at-end recovered-history contract stays. No insertion or reordering was added, and no previously working steered import is refused.
- Every payload comparison stays, as do the identity, digest, source-window, user-constituent association, availability and ambiguity checks, and full canonical dedup.

**Cheap F3.** A round trip through the real builder (`AgentTranscriptIO.buildTranscript`) showed that the only difference in a turn copy is the tool name. `AgentTranscriptToolNormalizer.toolExecution` stores the normalized name (`Read` becomes `read`). The call copy carries no result, so no per-kind change was needed. The fix:
- `CanonicalPayload.isTurnCopy` is new.
- For a turn copy only, the exact builder transform `actual.toolName == AgentTranscriptToolNormalizer.normalizedToolName(expected.toolName)` is accepted.
- A suffix copy keeps verbatim equality, and a different tool's name still mismatches.

This is a one-line relaxation of the name comparison, grounded in the builder. It was flagged for re-review 1, and both lanes accepted it.

**Deferred, as main allowed:**
- F2: equal-text `final_content` on an associated row records no attention provenance.
- F4: the projection switches from ancestor order to file order when a later fork appears. This is a known limit beside the accepted compaction limit.
- F5: a whitespace-only delta for an associated row is dropped. This is defensive, since imported rows never stream.

### Repair delta (unstaged)

Counts are from `git diff --numstat` against the staged snapshot.

| File | +/- | Change |
|---|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | 25/13 | Separate output and anchor order positions; turn-copy tool-name transform; doc. |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | 122/16 | See the tests below. |
| `Scripts/source_layout_guardrails.sh` | +2 | Allowlist entries for the two review files. |
| `phase4d3a-review-oraclea.md`, `phase4d3a-review-oracleb.md` | new | Verbatim reviews with headers. |
| `phase4d3.md`, this file | note | Selected cut, tests and links. |

### Repair tests

- **`testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder`:** output before the mapped user anchor in an earlier turn now passes. This deliberately encodes the cut; every output-order, payload and availability assertion is kept.
- **`testClaimedUserConstituentsAnchorTheirOwnOrderAndOutputKeepsItsOwn`** (renamed from `…AnchorTheRelativeOrderOfNativeOutput`), with two ledger-known replies:
  - the importer's `[first, steer, a1, a2]` and the native interleaving both pass;
  - reordered provider output `[first, steer, a2, a1]` refuses `canonicalPayloadMismatch`;
  - reordered claimed constituents refuse `outboundClaimUnmatched`;
  - local user text is never compared;
  - a missing or duplicated claimed-entry row refuses as unavailable.
- **`testPreflightRequiresPositiveAssociationOfEveryUserConstituent`:** the swapped order of two mapped user rows still refuses, since anchors are ordered among themselves.
- **Real view-model regression, extending the existing two-dispatch positive control in `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything`.** After the first import of `Done.` and `Also done.` behind the claimed steer:
  - an unchanged second reconcile is a no-op, with items, ledger and cursor unchanged;
  - after a lost cursor CAS (cursor back at the first dispatch's boundary), the replay is a no-op, with items and ledger unchanged and the cursor at the boundary;
  - append-only later output (`a3`) imports once, as `[system, assistant]` with the cursor at the new receipt, and nothing earlier is re-appended.
  - The test's existing refusal case keeps its zero-mutation assertions. This also exercises the full-canonical planner ID wiring through the real view model.
- **New `testRealTranscriptBuilderToolCopiesCompareEqual`** (F3):
  - real-builder call and result turn copies compare equal;
  - the builder's name is `read`;
  - a rebuilt copy with another tool's name mismatches;
  - a suffix copy carrying the normalized name mismatches.

**Negative check:** I restored the single shared output/anchor position and turned off the turn-copy name transform, then restored the file byte-identical. 4 tests failed (10 assertions; ticket `eeaabc4e-e78a-451e-9d9b-a3966d593d8a`):
- the claim-anchor test;
- the payload test;
- the F3 test;
- the real view-model regression.

A temporary diagnostic used to find the F3 field was removed before the final runs.

**Repair validation (final source):**

| Command | Result | Ticket |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 43 tests, 0 failures | `804a6d70-0c1a-4364-91f7-d86bf15ed5f3` |
| `make dev-swift-build PRODUCT=RepoPrompt` | completed | `1f5a9ada-dcc6-4769-b0c3-dab615fad83f` |
| `make dev-format-check` | 0/2175 files require formatting | `aaf33246-ea40-4b4c-8a12-ff8318c4ef9d` |
| `make dev-lint` | passed | `ec257e33-1b73-4fb2-8a8f-936a7e760622` |

The reader and lifecycle suites were not re-run: neither the reader, the view models nor their tests changed in the repairs.

## Validation (first pass, final source, each run separately)

| Command | Result | Ticket |
|---|---|---|
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 34 tests, 0 failures | `397a58c2-2ce2-4a3c-8633-07fefb1bc929` |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 40 tests, 0 failures | `457662e2-bfb3-4d23-bd87-88686bf85316` |
| `make dev-test FILTER=ClaudeNativeBackgroundTranscriptTests` | refused by conductor: "matched no curated ledger entry or source suite" (the file is an extension, not a suite); no override set | — |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (owning suite, substitute) | 195 tests, 0 failures | `6e01f794-47ba-4fee-8a24-19c66555213d` |
| `make dev-swift-build PRODUCT=RepoPrompt` | completed | `ed5e9440-d60f-4d70-a1ea-13870f0b49d6` |
| `make dev-format-check` | 0/2175 files require formatting | `8b36eb45-b7f9-46db-9837-3bcb188a9fa1` |
| `make dev-lint` | passed | `fc0bea33-285b-486b-b8c0-67d5d4c11fe9` |

**Earlier failures, fixed:**
- The first reader run failed to compile because the verified-absence baseline `Candidate` lacked `validationRows`.
- A new reader assertion compared whole rows whose items carry per-projection timestamps; it now compares identity, payload and digest.
- The first format check reported `wrapArguments`/`indent` in the preflight's unavailable condition and `semicolons`/`braces` in a test closure. Both were restructured by hand; no format-mutation command ran.

The three suites, the build, format-check and lint were re-run on the final source.

**Docs and guardrails** (after the worker file, allowlist and link were in place): `git diff --check` was clean. `Scripts/check-agent-context` passed with the existing `route-count` warning on `AGENTS.md`. `Scripts/test-check-agent-context` passed 23/23. `make guardrails` and `.githooks/pre-commit` passed.

**Not run:** the full suite, packaging, providers, captures, the visible app and lifecycle operations, `RPCE_ALLOW_UNKNOWN_FILTER`, and Oracle review (main's).

## Questions for main (first pass; main's decisions implemented above)

1. **User-text rows are not compared.** Ledger user rows (claim-associated) have no projected item, and provider-bound text may legitimately differ from the local user text. Claim association already checks their digest and order. Should their order relative to output rows also be checked here?
2. **Every mapped row, not only post-baseline ones.** The check covers all of this conversation's mapped rows, so an older imported row that is later compacted, removed, or has its tool payload summarized refuses every later import of the conversation. This is conservative by design; confirm it is the intended reach.
3. **A turn copy that differs from its suffix copy is not compared.** The suffix is treated as authoritative for IDs present in both, and turn-only items as preceding the suffix. A real interleaving where a turn-only item belongs after a suffix item would refuse as a mismatch. That is conservative, and I found no such shape.
4. **Planner dedup reads only `session.items`.** A new row whose deterministic ID exists only in an older persisted turn (not in the suffix) is now payload-checked, but on equality the planner would still append it again (`existingItemIDs` is the suffix). I found no path that produces this shape, and the planner was left unchanged as out of scope.
5. **Linear scan per delta.** `associatesClaudeLocalItem` scans `nativeItems` on each delta and `final_content`. The ledger is nil or small in practice; no index was added.
6. **Associated rows can stay streaming.** If an associated row was streaming, the new row is appended while the associated row keeps `isStreaming` until its segment ends (no rewrite of the protected row). This matches "never mutate", but the presentation consequence is noted.
