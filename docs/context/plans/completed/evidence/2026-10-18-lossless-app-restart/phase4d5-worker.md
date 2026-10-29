# Step 4d5 worker evidence: inactive single main-thread Read chain

Scope: read when the task touches the Step 4d5 source change (default-OFF Claude live attachment of one successful main-thread Read call, result and final answer, plus Claude-associated tool-row mutation protection) or its validation evidence.
Authority: Reference
Last-verified: 2026-10-24

## Contract implemented (HEAD 7c4d3c33, uncommitted)

Sources: both `prompt-exports/oracle-plan-2026-10-24-091803-step4d5-bounded-tool-{c796,924e}.md` and the "Offline O20 shape inspection" in `phase4d5.md`. The gate is still default OFF. Nothing was activated, and there were no schema, ID or translator-algorithm changes.

- **Accepted shape (exact O20, no permissive fallback):**
  - One assistant `tool_use` block with exactly five keys, including `caller:{type:direct}`.
  - The name is `Read` and the input is exactly `{file_path: nonempty String}`.
  - `wire_tool_inputs` is the singleton `{tool_use_id: same input}`.
  - One user `tool_result` with a string `content`, `is_error` absent, and `tool_use_id` linked to the call. Its metadata links exactly to the call (file path and ID), and `file.content` is a substring of the block output, not equal to it.
  - Caller attribution is required on the call and on the success result. The unattributed final text is bound only through the latch chain state.
  - O19 single-text behavior is unchanged.
- **Latch** (`ClaudeLiveTranscriptQualification.swift`):
  - Turn states: `readCalled` → `readReturned` → `readAnswered`.
  - Evidence kinds: `readToolCall`, `readToolResult(call:)`, `readAnswer(call:result:)`, `readAgreement(call:result:answer:)`.
  - New disqualifications: `unsupportedToolResult`, `toolLinkMismatch`, `unattributedResult`, `attachmentSuppressed`. `attachmentSuppressed` is set when an attach target is suppressed (`ClaudeNativeProcessSessionController.swift` ~3684).
  - The translator's invocation ID is used only to check that the call and result pair up. Arguments are compared as canonical JSON.
- **Projection is reused, not re-derived:**
  - `ClaudeSessionHistoryReader.canonicalToolInputJSON`, `singleToolUseRow` and `singleToolResultRow` (~1069–1091) build the reader's own rows.
  - `parseEntry` now uses the same canonical JSON. Its output is unchanged and pinned by reader tests.
- **Owner** (`AgentModeViewModel.swift`):
  - `applyClaudeLiveTranscriptEvidence` (~20149) dispatches to `applyClaudeLiveTranscriptCompleteText` (~20214) and `applyClaudeLiveTranscriptToolRow` (~20270).
  - Prerequisites are checked against the full canonical view (transcript plus suffix) through `holdsClaudeLiveTranscriptRow` (~20375). That helper needs a digest, matching IDs, `nativeItem(forKey:) == ledgerItem`, and `AgentProviderHistoryImport.holdsCanonicalPayload` (~609, which reuses the extracted preflight `comparePayload`, ~578).
  - The chain is call `[]` → result `[call]` → answer `[call, result]`.
  - `readAgreement` re-verifies all three canonical payloads and proofs. Any mismatch refuses.
  - A new insert does translated accounting exactly once: tool input tokens for the call; output tokens plus the Codex reconcile parity call for the result. Then it inserts the row, ledger entry and owned key together and calls `scheduleSave`.
  - A duplicate whose ledger entry is equal and held is a no-op, with no accounting and no ownership. An imported row never becomes owned.
  - A refusal invalidates only owned keys (4d3c rule).

## Mutation audit (anchors on the working tree)

| Site | Conclusion |
|---|---|
| Generic `tool_result` branch, `AgentModeViewModel.swift` ~19617/19654 | Guarded. If the invocation or name match lands on a provider-history-associated row, the result is appended as a separate visible unidentified `toolResult` instead of replacing the row. This is the visible fallback. |
| `finalizePendingToolCalls` (~19904/19918) → `finalizePendingToolCallsInItems`; save repair ~14687; cold restore `AgentSessionDataService.swift` ~834; core `AgentTranscriptServices.swift` ~3486/3499 via `AgentTranscriptQualityRepair.swift` ~30 | Protected by `protectedItemIDs = claudeLocalItemIDs` (`AgentSessionProviderHistoryRecovery.swift` ~502). A dangling canonical call stays `.toolCall`. Unprotected callers behave as before. |
| `AgentTabSession` `replaceItem` / `mutateItem` / `updateLastItem` (~3128/3170/3232), `mutateItemsBatch` (~2682) | Central backstop: `preservingClaudeAssociatedToolPayload` / `restoringProjectedToolPayload` (~2855–2875) restores kind, text, toolName, invocation, args, result, isError and isStreaming. This holds even after proofs are cleared, because association comes from `claudeLocalItemIDs`. |
| `ClaudeAgentToolTrackingHandler.swift` ~519, ~877, and retract removal | Not reachable for canonical rows: these sites match translator or nil invocations and RepoPrompt MCP tool names, never reader invocation IDs. The backstop covers them anyway. |
| ACP (`ACPIntegratedAgentModeRunner.swift` ~2401/3091), Codex (`CodexAgentModeCoordinator.swift`, `CodexNativeSessionController.swift`) `kind = .toolResult` | Other providers; covered by the central backstop. |
| Cold-restore tool cancellation, `AgentSessionRestoreSupport.sanitizeColdRestoredActivity` (~683), its only production caller `AgentSessionDataService.swift` ~886 | **Missed in the first audit** (reproduced in the four-image round; repaired in the cold-restore audit repair below). It now skips the synthetic status, error and result rewrite for `claudeLocalItemIDs` rows. |
| `final_content` | Already guarded in 4d3a; unchanged. |
| `setItemsSilently`, retention compaction, `removeItem` | Deliberately not guarded, so hydration, rebind, clear-chat and retention keep their semantics. |

**Load-bearing probes** (each disabled one guard temporarily; both were reverted, and the diff was checked clean):
- **Generic guard disabled** (ticket 1db7fd1a): `testClaudeLiveReadChainRefusalsKeepEarlierRowsAndShowLaterOutputUnidentified` failed. The backstop restored the call, so the real output was lost.
- **Central backstop disabled** (ticket b6ddebd7): the mutation test failed at replace, mutate, displace and batch. Cancellation finalization still held through `protectedItemIDs`.

## Tests added (existing tests unchanged)

- `ClaudeLiveTranscriptQualificationTests` (~794–1083):
  - The O20 chain attaches the reader's rows, with replay and with no replay.
  - A refusal matrix of about 50 cases covering shape, link, attribution and translation.
  - Controller evidence only, with gate-off output identical to legacy.
  - A malformed EOF tail after the call is refused before retirement.
- `AgentModeRunServiceLifecycleTests` extension in `ClaudeNativeBackgroundTranscriptTests.swift` (~1791–2106):
  - Three canonical rows, accounted once; duplicates are no-ops.
  - Refusals cover a dropped call, a tampered result plus a later generic result, an answer before the result, and an agreement mismatch.
  - The chain over imported rows never takes ownership.
  - Finalization plus every generic mutation, with valid and cleared proofs.
  - The pending finalizers on the save and cold-restore paths.
  - The real controller → runner → owner path, gate on and off.
- `ClaudeSessionHistoryReaderTests.testO20LiveProjectionsAreTheReadersRowsAndAnImportOverLiveRowsAppendsNothing` (~1473).
- `AgentRecoveryReconciliationTests`: superseded in the repair round; see "Repair round" below. The initial round-trip test kept the in-memory rows and copied only the ledger, so it did not show a reload.

## Validation, initial round (coordinated, separate runs)

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 515287eb, dfd1976a | 12/12 twice (after the sorted-keys EOF fix; the earlier 934361c9 had 1 failure from unsorted serialization quoted in the debug skip notice) |
| `dev-test FILTER=AgentModeRunServiceLifecycleTests` | e34e40ae | 208/208 |
| `dev-test FILTER=ClaudeSessionHistoryReaderTests` | 277589f2 | 41/41 |
| `dev-test FILTER=AgentRecoveryReconciliationTests` | 948f12f8 | 47/47 |
| `dev-swift-build PRODUCT=RepoPrompt` | 86845d29 | pass |
| `dev-format-check` | 00edd31c | pass |
| `dev-lint` | bd730f63 | pass |

No `dev-build`, packaging or run was done, and the frozen ledger was not touched.

## Repair round (after the initial review; source staged 2026-10-24/1009, fixes left unstaged)

The review exports are `prompt-exports/oracle-review-2026-10-24-101614-step4d5-initial-{a-86-d368,b-b2-3994}.md`. The fix delta is unstaged; the staged snapshot is untouched.

- **A R1** (`applyClaudeLiveTranscriptCompleteText`): a duplicate Read answer (one with prerequisites) is now treated as already recorded through `holdsClaudeLiveTranscriptRow`, over the full canonical view.
  - Before, the check searched only `session.items`.
  - The O19 path with no prerequisites keeps its exact 4d3b suffix check, unchanged.
  - Test: `testClaudeLiveReadChainHeldOnlyInPersistedTurnsIsADuplicateNoOp`. Every chain row is held only in the persisted transcript turns. The duplicate call, result and answer plus the agreement are no-ops: no rows, accounting, ownership, ledger change or refusal. An O19 single-text duplicate is still refused, as before.
- **B F1** (generic `tool_result` associated branch): the separate fallback row now carries `argsJSON ?? matched row's toolArgsJSON`.
  - Assertions were added to `testClaudeLiveReadChainRefusalsKeepEarlierRowsAndShowLaterOutputUnidentified`: the fallback row carries the call's arguments, and a result that brings its own arguments keeps them.
  - The presentation of a call that never resolves is still pending activation; there is no UI work.
- **B F5**: the `applyClaudeLiveTranscriptToolRow` comment now names the one later refusal, a provider handler consuming the event after the legacy preamble, which returns handled exactly as legacy does.
- **B F3**: the round-trip test is replaced by a shared setup (`deliverLiveReadChainAndSaveTerminally`, which does a real terminal save with `runState = .completed`) and two tests:
  - `testLiveReadChainTerminalSaveAndInMemoryImportIsANoOp`:
    - The terminal save holds the IDs, proofs and kinds; the call is never finalized.
    - The answer's persisted payload equals the canonical one.
    - The tool rows are persisted summarized, and the test asserts that they are **not** the reader's payloads.
    - With the persisted ledger over the **in-memory** rows (explicitly not a hydration), the import gives `.imported(.unconfirmed, rowCount: 0)` and keeps the proofs.
  - `testLiveReadChainAfterPersistedHydrationFailsItsLaterImportClosed` (the real `loadSessionFromDisk` hydration seam, `.applied`):
    - The rows and ledger come from disk, and the call is still `.toolCall` after the cold-restore repair.
    - The answer holds, and the tool rows are summaries.
    - The later import gives `.associationUnavailable(.canonicalPayloadUnavailable, _)`, with items and ledger unchanged.
    - This pins the current fail-closed boundary. It is **not** a successful reload.
- **B F3 finding** (applies to activation; not fixed, because it is a persistence-policy or comparison decision):
  - The ordinary tool-result persistence sanitizer stores a Claude-associated tool row as follows:
    - the name is lowercased (`read`);
    - `toolArgsJSON` is dropped;
    - the result becomes `{"status":"unknown","summary_only":true,…}`;
    - the turn activities are marked `summaryOnly`.
  - The evidence is the temporary diagnostic, ticket a4dbf473-5a48-4775-89a1-f31614ab0abb, which has since been removed.
  - So after any save and reload, the live Read rows no longer hold their canonical payloads, and the next import of that conversation fails closed. The same sanitizer keys on `kind`, not on origin, so imported O20 tool rows are presumably affected the same way. This is an inference; it was not tested here.
- **A R2 / B F7 deferred (P2)**: `mutateItemsBatch` callers include intentional removal (`RemoteAgentModeCoordinator.swift` ~834 removes host-removed IDs and then upserts) and positional insertion (`CodexAgentModeCoordinator.swift` ~6745 shifts indices).
  - Rejecting a protected ID that is missing would change the removal semantics, and restoring by index would break insertion. A plain batch cannot tell displacement from intended removal without the caller saying so.
  - No current caller swaps a protected row for a different ID at the same index.
- **Deferred**: B F4 (the default parameter), F6 (caching), F8 (the split gate). B F2 (stdout-to-native equality) is handled by main offline.

**Probes** (temporary; each was restored from a backup, and nothing is left in the tree):
- With the R1 branch and the F1 copy disabled (ticket 79caf15e-b0ba-45e9-be3d-72f142a0e7b9), there were 8 lifecycle failures:
  - the new R1 test;
  - the suffix duplicate-answer assertions of `…InsertsThreeCanonicalRows…` (the guarded O19 branch no longer covers Read answers);
  - both F1 assertions.
- With the cold-restore `protectedItemIDs` disabled (ticket 32ada45a-4b96-43cc-be67-65c5e6b77595), both reconciliation tests failed. `harness.persisted()` reads back through the same load normalization, so both depend on that protection.

**Repair validation** (coordinated, run separately). The qualification and reader suites were not rerun because the classifier and reader source are unchanged; their earlier results stand: 515287eb-a92e-415a-85cf-77714a187e22 and dfd1976a-b618-4232-a89c-1fe2497c4145 at 12/12, and 277589f2 at 41/41.

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=AgentModeRunServiceLifecycleTests` | 398cfc39-10f2-409e-a9fd-21b9c20d2ddf | 209/209 |
| `dev-test FILTER=AgentRecoveryReconciliationTests` | a34506ab-aa0f-4c32-b620-80aa467d2da5 | 48/48 |
| `dev-swift-build PRODUCT=RepoPrompt` | 77fbf7f5-3145-4b61-ab57-d476558d680c | pass |
| `dev-format-check` | 12a104ab-7feb-4edc-b7dc-3143d89f47aa | pass |
| `dev-lint` | cbbe27bd-100c-40c0-aa95-94b672bf2c17 | pass |

The final format, lint and build were rerun after a comment-only reflow.

## Stored-projection round (Oracle B remedy): STOPPED at the fixed-point gate

The brief is the main's chosen remedy (`phase4d5.md`, "Chosen persistence remedy"), from the plan exports `prompt-exports/oracle-plan-2026-10-24-103845-step4d5-persisted-pr-{1272,3f42}.md`. Everything is unstaged; the staged 1009 snapshot is untouched. The brief says to stop if the real-pipeline projection is not a fixed point of the actual fresh load, and not to loosen the comparison. That condition was reached, so the remedy is implemented but **not** demonstrated. It needs a main decision before any further work.

**Implemented (unstaged):**
- `AgentTranscriptPolicyPipeline.storageRoundTripActivities(_:)` puts the given items through the real canonical build, `persistedTranscript`, `runtimeNormalizedTranscript` and `runtimeTranscriptOnly`, and returns the activities by ID.
- `AgentProviderHistoryObservation.storageComparableReadItemIDs` is computed from the complete `validationRows` by `ClaudeSessionHistoryReader.storageComparableReadItemIDs`:
  - each row must be a singleton (ordinal 0, the only row of its entry, with a local item ID);
  - a call must be `Read` with exactly `{file_path: non-empty string}`, its canonical input JSON must equal the row's, and `singleToolUseRow` must agree with it;
  - a result must be `Read` with no error flag and text, and `singleToolResultRow` must agree with it;
  - rows are grouped by `toolUseID`: exactly one call and at most one result.
- In the preflight, the existing complete or raw comparison runs first and is unchanged. Only when it reports `.unavailable` for an eligible ledger row whose native digest equals the row's does `compareStoredProjection` run. It requires:
  - a unique backing activity in a full, uncompacted turn;
  - equality of the backing's kind, text and complete `toolExecution` with the stored projection;
  - equality of the projected item fields;
  - agreement of a suffix copy with its backing.

  Otherwise it returns unavailable (no backing, an ambiguous one or a condensed one) or mismatch.
- `holdsCanonicalPayload` and `comparePayload` are unchanged.

**Finding** (temporary diagnostics, all since removed from the tree):
- The projection *is* a real fixed point of save and storage load. Ticket 2a3e75de-ce1b-4299-95b5-f549a4ea6698: re-persisting and reloading it twice gives the same activity. Ticket 0263627f-86f3-4dff-8769-12147a2e9431: the session as saved, and the session read by a separately constructed `AgentSessionDataService` after each cycle, both equal the projection; the result is `{"status":"unknown","summary_only":true,"summary_text":"read • unknown"}`.
- The tab session's in-memory transcript, which is what the import's canonical view reads, differs in a way that depends on context.
  - **Visibility.** `runtimeTranscriptOnly` re-sanitizes tool results that are not visible. In the real turn, the answer that follows the result hides it, so the result becomes `{"status":"unknown","summary_only":true}` without `summary_text` (`summaryText` is still `read • unknown`). This applies both to the live tab before any hydration and after `loadSessionFromDisk`. The isolated call-plus-result projection keeps the result visible, so it never takes this step.
    - Ticket ee743b6f-fc50-44f4-8769-85bb16e5459d: the real `sanitizeTranscriptWithMetrics(…, preservedVisibleToolResultRowIDs: [], purpose: .runtimePresentation)` applied to the stored projection reproduces the hydrated backing exactly.
  - **Cold restore of a saved running turn.** The first hydration's call is re-derived from the working items: `summaryOnly: false`, and `summaryText` equal to the item text (`Using tool: read`).
- Ticket 1c19a782-e70a-46ec-8d97-39c01ffd46c2 checked each actual backing for exact equality against six real-pipeline images of the proven row: loaded, loaded plus runtime, hidden, rebuilt, rebuilt plus runtime, and rebuilt plus hidden.
  - Terminal and re-saved sessions: the call equals the loaded form, and the result equals the hidden form.
  - Running cold restore: the call equals the rebuilt form.
  - Every actual backing equals *some* real image. **No single image matches across contexts.** The deciding inputs are row visibility and whether the load rebuilt the turn from items, and neither is a function of the row.

**Options for main** (none is implemented):
1. Derive the row's visibility from the actual canonical transcript, and apply the real runtime sanitizer with that preserved set. This is exact for terminal and re-saved sessions. The cold-restore rebuild of a running turn would still fail closed, unless load-purpose context were added, which is new authority.
2. Accept exactly one of a closed set of real images: loaded, hidden, or rebuilt from working items (with or without hidden). Equality stays exact, but the accepted set grows from one form to several. Whether that counts as loosening is the reviewers' call.
3. Compare in storage space (storage of the actual equals storage of the projection). **Not recommended.** It erases fields that exist only at runtime, so some in-memory alterations would be accepted.
4. Restore the previous pinned fail-closed boundary, and defer the remedy.

**Tree state:**
- The remedy source and its tests are present but unstaged.
- The previous fail-closed test (`testLiveReadChainAfterPersistedHydrationFailsItsLaterImportClosed`) was replaced as the brief required, so the fail-closed boundary currently has **no** pinned passing regression.
- The two round-trip tests fail and stay that way until main decides:
  - `testLiveReadChainSurvivesRepeatedSaveAndHydrationAndItsImportIsANoOp` (terminal and running, two cycles each): 4 × `canonicalPayloadMismatch`.
  - `testImportedReadRowsSurviveRepeatedSaveAndHydrationAndReimportAsANoOp`: 4 × mismatch, plus the first import's `rowCount`. Actual values are 4 for the whole chain and 2 for call-only, against the test's 3 and 1. This is not yet explained; it probably includes the claimed caller row, but that is unverified.
- The pure matrix `testStoredReadProjectionIsAcceptedOnlyForAProvenExactStoredForm` passes. It covers acceptance (suffix plus backing, prefix-only, call-only, raw exact) and refusal (cleared proof, digest change, no ledger entry, altered suffix or backing summary, missing, duplicate or condensed backing, Bash, extra argument, empty path, error, digest mismatch, multiblock, two results), and checks that the strict `holds` stays false.
- The "B F3 finding" above is superseded in one detail: after hydration, the import's refusal is now `canonicalPayloadMismatch`, not `canonicalPayloadUnavailable`, because the backing exists and differs from the projection.

**Validation this round** (coordinated, run separately):

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=AgentRecoveryReconciliationTests` | 9d249d33-5de8-490d-b032-174c35b109f8 | 50 run, 10 failures (the two round-trip tests above) |
| `dev-test FILTER=ClaudeSessionHistoryReaderTests` | d9df59d9-5353-44ae-93e5-6d4d86ecc8dd | 41/41 |
| `dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 6d3f9680-17f7-4027-99cd-df24e5a68a5b | 12/12 |

These were not rerun this round, pending main's decision: lifecycle, persistence-policy and Oracle-inspection suites, product build, format-check and lint. The frozen ledger is untouched.

## Four-image round (main decision after the fixed-point stop)

Main chose option 2, OracleA's bounded set of four **current-pipeline** representations, from `prompt-exports/oracle-plan-2026-10-24-110700-step4d5-persisted-pr-a461.md`; the rationale is recorded in `phase4d5.md`. Storage-space normalization was not selected. Everything is still unstaged, and the staged 1009 snapshot is untouched (14 files, +1926/−126).

**Contract implemented (unstaged), replacing the single-image helper and matcher atomically:**
- `AgentTranscriptPolicyPipeline.storageComparisonActivities(_:)` (`AgentTranscriptPolicyPipeline.swift:62`) puts the proven native exchange through the real canonical build and `persistedTranscript`, then generates exactly four images:
  - loaded: `runtimeTranscriptOnly(runtimeNormalizedTranscript(stored))`;
  - loaded-hidden: the real runtime sanitizer with no preserved visible rows;
  - rebuilt: a canonical build from the loaded working items, then `runtimeTranscriptOnly`;
  - rebuilt-hidden.

  Equal images are deduplicated per row ID. It returns nil if an input ID is duplicated or missing from any image. Nothing else is added to the set.
- In the preflight (`AgentProviderHistoryImport.swift`), only ledger entries for this provider and session apply. Key and local-item counts are computed over them (around line 526). A stored-form fallback becomes possible only when all of these hold:
  - the row is storage-comparable;
  - its key and its local item each appear exactly once (line 549);
  - the native digest is equal;
  - the expected row has an invocation ID.

  A repeated or competing mapping therefore never lends its proof, whatever the order.
- Images are cached per invocation within one preflight only (`storedReadImages`, line 673). There is no cross-request state.
- `compareStoredProjection` (line 692) still needs a unique, full, uncompacted backing. Matching then works per row:
  - the backing must equal ONE complete image in kind, text, `toolExecution` and the projected tool fields;
  - a suffix copy must independently equal ONE complete image in the projected fields;
  - there is never a field-by-field union, so a mixed representation is a mismatch.

  The strict comparison runs first and is unchanged; the fallback runs only when it reports `.unavailable`. `holdsCanonicalPayload`, `comparePayload`, the ordering checks and eligibility are unchanged.

**Harness changes:**
- `makeProducerHarness(…, relaunching:)` builds an actual new `AgentSessionDataService`, store and VM. They are on the same storage, home and recovery roots, with a new `appInstanceID`.
  - It binds the persisted session, clears `hasLoadedPersistedState`, and requires `loadSessionFromDisk` to return `.applied`.
  - The tested hydration is therefore the fresh service's own load, not a side-read next to the same VM loader.
  - An earlier cross-service `test_applyPersistedHydration` attempt was abandoned: the stamp's `serviceID` breaks save authority and the lane.
- The temporary diagnostics used during this round are removed (`grep PROBE4D5` over Sources and Tests is empty).

**Findings and resulting expectations:**
- **Outcomes.** With the four images, the live terminal and running chains pass the association preflight on both relaunch cycles.
  - Cycle 1 returns `.imported(.unconfirmed, rowCount: 0)`: only the claimed caller is added, ledger-only.
  - Cycle 2 returns `.nothingImported("The provider has no new history for this conversation.")`, which is reached only after the preflight passes.
- **Imported first rowCount 4/2** is explained by the planner's existing recovered label. The test asserts the exact composition:
  - the deterministic label ID (`rpce-history-import-label-v1`), `.system` kind and `recoveredLabel` text;
  - appended IDs `[label] + native output` in order, with kinds;
  - ledger entries `[caller, c1(, r1, a1)]`, with the caller having no local item.
- **Re-saved content** (superseded: main rejected the summary-only check; see the cold-restore audit repair). The "nothing appended" check is now exact on IDs, kinds and every non-tool row. Tool rows must stay summarized: no args and no output content.
  - This changed because a reconcile's save legitimately moves a summarized result from its visible to its hidden generated form.
  - Each re-save is still checked by `assertStoredSummarized`.
- **Imported call-only after relaunch: refused, set NOT expanded** (superseded: main identified this as a missed canonical mutation site, not a contract cut; see the cold-restore audit repair). A cold restore cancels a call that is still pending: `status = .cancelled` and `toolIsError = true`, via `AgentSessionRestoreSupport.sanitizeColdRestoredActivity` and `activeToolExecutionIDsNeedingColdRestoreCancellation` (`AgentSessionRestoreSupport.swift:677`, `:700`).
  - That is an outcome stamp, not one of the four representations.
  - Per "don't expand set", the test pins it on both cycles: the hydrated call is cancelled or error, and the result is `.associationUnavailable(.canonicalPayloadMismatch, _)` with nothing changed.
  - The whole imported chain re-imports as `.nothingImported` on both cycles.
  - The pure matrix still accepts a call-only stored projection that has not been cold-restored.
- **Integration tamper.** After the live cycles (terminal and running), the hydrated result's `summaryText` is altered. The result is a mismatch, with items and ledger unchanged and no ownership.
- **Pure matrix additions** (`testStoredReadProjectionIsAcceptedOnlyForAProvenExactStoredForm`).
  - The hidden fixture is generated by the explicit runtime sanitizer, and asserts that it differs in result JSON and text.
  - Accepted: the hidden and rebuilt forms, each from the real pipeline, and a suffix and backing that each match a different whole image.
  - Mismatch: a mixed result (hidden text with visible execution), a mixed call (rebuilt flag with loaded summary), a competing mapping, and a reversed suffix.
  - Unavailable: duplicate proofs, in either order.
  - The existing tampered, cleared-proof, digest, missing, duplicate or condensed backing, and non-Read cases are kept.
- Privacy and ownership: the summarized stored form is unchanged, the strict `holds` stays false for stored tool rows, and the ledger is never owned on dedupe.

**Validation, four-image round** (coordinated, run separately, all exit 0):

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=AgentRecoveryReconciliationTests` | ab70ab1a-7280-48dc-9562-396a5398c3d6 | 50/50, after the style fixes; also 1eac8160-db83-4be8-86a0-2937a633ea6e and 004d0687-6e81-4e8d-a9ae-a716bff0431d |
| `dev-test FILTER=AgentModeRunServiceLifecycleTests` | 5f596814-25de-4abe-9422-b734784dc3f5 | 209/209 |
| `dev-test FILTER=ClaudeSessionHistoryReaderTests` | b9188c0f-70ae-4c05-9973-119f07fd8c4e | 41/41 |
| `dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 27d0fad0-eb2e-42a4-990b-f626f6aa4236 | 12/12 |
| `dev-test FILTER=AgentToolResultPersistencePolicyTests` | dd801032-5eec-4334-b48a-f58f72b44944 | 25/25 |
| `dev-test FILTER=OracleToolResultInspectionTests` | 16b2ca87-39da-4cd4-a02c-66c094d6b6ee | 22/22 |
| `dev-swift-build PRODUCT=RepoPrompt` | a89ca625-d7bb-4cf8-9d21-d21e42be576f | pass (the later style edits touch tests only) |
| `dev-format-check` | 1ca53e7c-391a-446f-bfc8-9b4d33ed1dc6 | pass, after dc4e11b3 failed on two test-only style issues that were fixed by hand |
| `dev-lint` | 5766beeb-1742-4e57-bc2d-f0c3d363c541 | pass, after cca1497f failed on the same issues |
| `git diff --check` | — | clean |

The staged index is unchanged at 14 files, +1926/−126. The frozen ledger is untouched. No full suite, package, app or provider operation was run.

## Cold-restore audit repair (main review of the four-image round)

Main ruled that the call-only refusal is **not** an accepted contract cut. It is a reproduced audit bug: an existing canonical mutation site that the first mutation audit missed. The fix is to protect that site, not to add a fifth image. All changes remain unstaged, and the 1009 index is intact.

**Repair** (no new authority, schema, gate or image):
- `AgentSessionRestoreSupport.sanitizeColdRestoredTranscript` (line 526) takes `protectedItemIDs: Set<UUID> = []` and threads it through turn → span → activity.
- `sanitizeColdRestoredActivity` (line 683) still sets `isStreaming = false` for every activity. It skips only the synthetic tool rewrite for a protected row (line 693): `status = .cancelled`, `toolIsError`, and the cancelled result JSON and text.
- Turn handling is untouched:
  - `activeToolExecutionIDsNeedingColdRestoreCancellation` and `shouldCancelTurn` are computed exactly as before, protected rows included;
  - the turn's terminal state, interruption stamp, `completedAt` and summary are unchanged;
  - every span's lifecycle, `completedAt` and summary are unchanged.

  So a turn holding a protected pending call is still closed and stamped interrupted honestly, and unprotected pending tools are cancelled as before.
- The only production caller, `AgentSessionDataService.swift:890`, passes `session.providerHistoryRecovery?.claudeLocalItemIDs`. This is the same set as the save repair at line 834, so a valid or a cleared proof protects alike.

**Tests (actual):**
- **`AgentRunTerminalCauseTests.testColdRestoreKeepsAnAssociatedToolPayloadAndStillClosesTheTurnHonestly`** builds a running saved turn with a Read call (streaming) and a Bash call, both pending.
  - Without protection: the Read call is cancelled, the turn is `.cancelled` with an `appCrash` interruption, and no span stays open.
  - With the ledger's own `claudeLocalItemIDs`, for both a valid and a cleared (nil) digest:
    - the Read call's `toolExecution` and text equal the saved ones, and streaming ends;
    - the Bash call is cancelled and errored;
    - with only the Read activity swapped back, the turn equals the unprotected restore exactly (outcome, interruption, completion, summary, every span).
- **Imported call-only cycles** are accepted again after a fresh load, twice: `.nothingImported("The provider has no new history for this conversation.")` on both cycles. The pinned refusal was removed.
- **Partial-history continuation:** after those cycles, the native result and answer arrive.
  - The reconcile returns `.imported(.unconfirmed, rowCount: 3)`.
  - The appended rows are a new deterministic recovered label, then `r1` and `a1` in order, with kinds `[.system, .toolResult, .assistant]`.
  - The ledger is `[caller, c1, r1, a1]`. The call row and its proof are unchanged, the call is never converted, and nothing is owned.
- **Nothing-changed check (replaces the summary-only weakening):** `assertGeneratedRepresentations` runs after each fresh hydration and again after each reconcile. For every tool row of the proven native exchange it requires:
  - exactly one backing, equal to ONE complete current-pipeline representation (kind, text, whole `toolExecution` and projected tool fields);
  - exactly one suffix copy, equal to ONE complete representation's projected fields.

  The exchange is the live reader projection, or the imported raw rows captured before the first save. Item IDs, kinds and order are exact, every non-exchange row is exactly unchanged, and the proofs are preserved. A visible↔hidden move is allowed only by this membership.
- No new form or outcome appeared beyond these. In particular, the hydrated call-only backing equals a generated image with no cancellation.

**Validation, cold-restore audit repair** (coordinated, run separately, all exit 0):

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=AgentRunTerminalCauseTests` | 591bc90e-3e4b-4ed6-b99e-191acdc555f4 | 17/17, after the style fix; also f9cc737c-1ff1-4865-a43f-68e1ebf86fc2 |
| `dev-test FILTER=AgentRecoveryReconciliationTests` | cf3b8d5c-cfad-4652-ab33-b6dd6a122600 | 50/50 |
| `dev-test FILTER=AgentRecoveryStartupReconciliationTests` | 1944a0e7-b580-430e-9a54-03ab8185590d | 21/21 |
| `dev-test FILTER=AgentTranscriptRefreshDiagnosticsTests` | f9887b08-2b99-4e4d-ac81-c279dc9fd925 | 38/38 |
| `dev-test FILTER=AgentModeRunServiceLifecycleTests` | 053d72e0-c316-4de5-b42d-3567cf7d16cb | 209/209 |
| `dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 2df02a66-6df2-45af-b4b5-b5d7785b36a6 | 12/12 |
| `dev-test FILTER=ClaudeSessionHistoryReaderTests` | 467cc338-bbbc-4317-8b8c-b1cad17f5c06 | 41/41 |
| `dev-test FILTER=AgentToolResultPersistencePolicyTests` | 024b7b0b-6e30-4462-82c7-6591f4d69225 | 25/25 |
| `dev-test FILTER=OracleToolResultInspectionTests` | 4c7626e2-9547-4094-9a4c-88f965fc8101 | 22/22 |
| `dev-swift-build PRODUCT=RepoPrompt` | b80904b9-0db9-442b-a194-e188a8004c94 | pass (the later style edit is test-only) |
| `dev-format-check` | e0c7ce51-2cc5-44e1-9972-fa8df40ad581 | pass, after 52e43a16 failed on a test `hoistTry` (fixed by hand) |
| `dev-lint` | 3d88fbda-f40f-4673-88b1-4f1b3c600592 | pass, after 0d86a588 failed on the same issue |
| `git diff --check` | — | clean |

The staged index is unchanged at 14 files, +1926/−126. The frozen ledger is untouched, and `grep PROBE4D5` over Sources and Tests is empty. No full suite, package, app or provider operation was run.

## Final cheap-fix round (fresh R1 reviews: no P0/P1)

From `prompt-exports/oracle-review-2026-10-24-115348-step4d5-persistence-1f25.md`, as main scoped it. The changes are left unstaged on top of main's 11:47 frozen delta.

**Fixed:**
- **P2-05.** The live and imported fixtures' Read output gains a second line, `OUTPUT-ONLY-SENTINEL-7Q4`, which appears nowhere else (not in the answer, the prompt or the path). `assertStoredSummarized` asserts that it is never on disk.
- **P2-03.** After the partial continuation there is exactly one more save, relaunch and reconcile cycle. The exchange is the imported raw call and result. The cycle returns `.nothingImported`, the stored rows stay summarized, and `assertGeneratedRepresentations` passes after both hydration and reconcile.
- **P3-01.** `sanitizeColdRestoredTranscript` no longer defaults `protectedItemIDs`. The production caller passes the ledger's `claudeLocalItemIDs`. The test callers pass `[]` explicitly: three in `AgentRunTerminalCauseTests`, one in `AgentTranscriptRefreshDiagnosticsTests`.
- **P3-05.** The cold-restore fixture's ledger row kind is now `ClaudeSessionHistoryReader.RowKind.toolCall.rawValue`.
- **P3-02.** The `…HeldOnlyInPersistedTurns…` test is documented as an IN-MEMORY shape, not an actual disk load; after a real load the exact prerequisite check fails closed. The test name is unchanged.
- **P3-03.** A doc comment on `hidden(_:)` states the idempotence assumption, and the pure matrix asserts that sanitizing the hidden form again changes nothing.
- **P3-06.** The stored result is checked against literals, independent of the production helper:
  - `resultJSON == {"status":"unknown","summary_only":true,"summary_text":"read • unknown"}`;
  - `summaryText == "read • unknown"`.

**Deferred per main:** P2-01 (golden session / upgrade compatibility; the current conservative refusal of a future policy is accepted), P2-02 (activation gate, recorded by main), P2-04 (multi-exchange context) and P3-04 (performance).

**Read-only check (Oracle B recommendation 6):**
- `AgentTranscriptQualityRepair.terminalMetadataRepairNeeded` (`AgentTranscriptQualityRepair.swift:43-62`) compares only each turn's `conclusionActivityID` with the recomputed trailing-assistant conclusion, and whether that conclusion has a displayable body. Tool status is never read. A protected pending call therefore does not keep it true.
- It is consulted only when `repairTerminalState != nil` (`AgentSessionDataService.swift:818`, `:861`). That never happens for a persisted active run.
- The other rebuild trigger relevant here, `repairedWorkingCount` from `finalizePendingTerminalTools` (`:829-837`), is 0 for a protected call, because the call is skipped through the same `claudeLocalItemIDs`.
- No new repair is needed, and nothing here invalidates the tested contract.

**Validation, final round** (coordinated, all exit 0):

| Check | Ticket | Result |
|---|---|---|
| `dev-test FILTER=AgentRecoveryReconciliationTests` | a0e1d8f5-7269-4f08-8e5f-3ca3391e2c8c | 50/50; also 62e64a49-7864-4bf7-82ea-3192f7fb1f06, before the comment-only style fix |
| `dev-test FILTER=AgentRunTerminalCauseTests` | d2b4be98-e531-4ba2-96ba-d713178c1a7d | 17/17 |
| `dev-test FILTER=AgentTranscriptRefreshDiagnosticsTests` | 9c1ad61c-d4e2-40bb-b0f8-7f91333589de | 38/38 |
| `dev-test FILTER=AgentModeRunServiceLifecycleTests` | 4fa6cf69-816d-4629-ab68-7b2e49a5315c | 209/209 (only comment and message text changed in its extension file) |
| `dev-swift-build PRODUCT=RepoPrompt` | 02d5e8b4-449c-4146-acc3-28ca61725ef3 | pass |
| `dev-format-check` | 2d314cec-1bf9-410c-a2f7-d36489df35d7 | pass, after 14a4ae53 failed on a `docComments` rule for the new comment (made `///`) |
| `dev-lint` | ef760274-e802-49fa-8b28-3e5d6bcd1302 | pass, after 9c81d69c failed on the same rule |

The reader, qualification, persistence-policy and Oracle-inspection suites carry forward from the cold-restore audit repair: their sources and tests are unchanged since then.

## Limitations

- Fixture-only. This is not installed, live or no-replay evidence. The source-model no-replay case is a fixture, not live evidence.
- The `attachmentSuppressed` refusal is defensive. No qualified shape reaches it through the real translator, so it is covered by inspection only.
- A dangling canonical call with no result stays `.toolCall` by projection.
- The reconcile tests use a minimal O20 history without attachments.
- A real persisted reload summarizes tool payloads. The import accepts them only as one of the four current-pipeline representations, after a unique ledger proof (see the four-image round).
  - Cold restore no longer rewrites associated tool rows (see the cold-restore audit repair).
  - A future pipeline change may conservatively refuse older summaries.
- Same-launch hydration in the middle of a chain stays fail-closed. Accounting is checked only through "no ownership" on dedupe, with no separate accounting counter.
- Activation, multi-tool, error results, sidechain and parallel Read are out of scope.
