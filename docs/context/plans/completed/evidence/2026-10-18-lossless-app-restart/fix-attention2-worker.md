# Step 8-attention-2 worker report

Scope: read when the task touches Needs Attention bulk Dismiss or automatic clearing of informational recovery items (Step 8-attention-2).
Authority: Reference
Last-verified: 2026-10-26
Covers: worker session 38C04ABE-ED64-453E-8C6E-422BBD04EA78 reports (projection-only automatic clearing, bulk Dismiss).

Step 8-attention-2 is in place: run notes now clear themselves from the sheet without any writes, and the sheet has a bulk Dismiss for each section. Build, lint, guardrails and the three touched recovery suites pass; I did not launch the app, so the sheet UI itself is untested.

## Files changed
- `Sources/RepoPromptAgentCore/.../Recovery/AgentRecoveryCatalog.swift`: adds the clear reason `AgentRecoveryCatalogAutomaticClear` (`resolved` / `conversationCleared` / `sessionContinued`), the pure rule that picks it, and `item.automaticClear` / `item.isHidden`. `needsAttentionItems(includeDismissed:)` now also hides cleared items (`includeDismissed: true` shows them).
- `.../Recovery/AgentRecoveryCoordinator+BulkDismiss.swift` (new): the status and skip types, `dismissCatalogItems(_:section:)`, `requestBulkDismissCancel()` and the per-item skip check.
- `.../Recovery/AgentRecoveryCoordinator.swift`: one stored property `bulkDismiss` (line 525). `postCatalogChange()` changed from private to internal so the extension can wake observers.
- `Sources/RepoPrompt/.../AgentModeViewModel+RecoveryBulk.swift` (new): thin wrapper with the confirmation text, the eligible count, start and cancel.
- `AgentComposerUIModels.swift`: the sheet row now carries `automaticClear`, the displayed `item`, and an `isHidden` property.
- `AgentModeViewModel+RecoveryList.swift`: fills those two fields.
- `AgentRecoveryNeedsAttentionSheet.swift`: toggle renamed "Show dismissed and cleared", cleared labels, counts that exclude cleared items, the two bulk buttons, the needs-action confirmation, a summary line with Stop, and it now also listens for coordinator changes.
- `AgentRecoveryNeedsAttentionCommands.swift`: comment wording only.

## Clearing rules (`AgentRecoveryCatalog.swift`)
- **Rule:** the pure function at :347. First match wins:
  1. A recovery action resolved the card → `resolved`.
  2. The run's reset generation is lower than the session's current one → `conversationCleared`.
  3. A later attempt with the same generation follows it in `runAttempts` → `sessionContinued`.
- **Current generation:** computed in `Builder.append` (:460–467). It uses the lane's binding if there is one, otherwise the larger of the startup binding's and the record's generation, the same rule `addIntents` uses.
- **Never needs-action:** `item.automaticClear` (:172) returns nil unless the item is informational and is a run card (exhaustive switch). Unfinished actions, holds and unsent continuations therefore never clear.
- **Run cards without an attempt:** a legacy turn, or an attempt missing from the record, can only be cleared by rule 1.
- **No age-based expiry.**
- **`runAttempts` ordering I rely on:** the array is in first-record order. `AgentRecoveryStore.ensureRunAttempt` (around Store.swift:1194) is the only place that adds an attempt; it appends new ones at the end and updates existing ones in place. Nothing reorders or removes them, and the codec keeps array order. This is documented on the function.

## Bulk Dismiss (`AgentRecoveryCoordinator+BulkDismiss.swift`)
- **One at a time app-wide:** `guard !isBulkDismissRunning` at :101; a second request returns nil.
- **Sequential, cancellable:** before each item it checks for a cancel request (:105) and records the rest as "not attempted". It then calls the existing `dismissCatalogItem(item)` with the captured item (:115), setting the row's action state to working and then to the failure or nothing. A failure stays on its row.
- **Skip check (:138):**
  - no acknowledgement → "can't be dismissed"
  - already dismissed (captured or current) → "already dismissed"
  - row working → "busy"
  - missing, or acknowledgement key/freshness differs, or its class changed (:145) → "changed"
  - The class check means an informational note that now needs action is never dismissed without the needs-action confirmation.
- **Status and summary:** both live on the coordinator, so every window shows the same line and any window can Stop. Closing the sheet cancels nothing (the task belongs to no view). Example line: "Dismissed 1 of 6 · 5 skipped (1 can't be dismissed, 1 already dismissed, 1 busy, 2 changed)", and after Stop "… · stopped, 2 not attempted" (`summaryText` :58).
- **Sheet:**
  - "Dismiss eligible…" captures the displayed Needs action rows at click time (sheet :64) and confirms with the exact text you specified (VM :12).
  - "Dismiss all" for Information runs with no confirmation.
- **Notifications:** progress goes out through the catalog-change notification rather than the coordinator-change one.
- **Gates untouched:** no crash-hold, restriction, revision-check or send-path code changed.

## Tests (all in `Tests/RepoPromptTests/AgentMode/Recovery/`)
- **`AgentRecoveryCoordinatorTests`:** 63 tests, 0 failures. New:
  - `testAutomaticClearRuleOrder`
  - `testRunCardIsClearedWhenALaterRunAttemptExists` (also checks nothing is written and the card stays in the catalog)
  - `testRunCardIsClearedWhenAnActionResolvedIt`
  - `testRunCardIsClearedWhenTheConversationWasClearedAfterIt`
  - `testNeedsActionRunCardIsNeverCleared` (an unfinished action and an unsent continuation, each with the later-attempt rule matching)
  - `testBulkDismissSkipsIneligibleAndChangedItems`
  - `testBulkDismissReportsPartialFailureOnTheRow`
  - `testBulkDismissCancelStopsBeforeTheNextItemAndKeepsCommittedOnes` (holds the first item's write on a latch, so it is deterministic)
  - The run-card fixture was split so several cards can share one coordinator, with sessions still created before startup.
- **`AgentRecoveryStartupCompositionTests`:** 16 tests, 0 failures. New `testNeedsActionBulkDismissKeepsTheCrashHoldBlockingAndItsPausedIndicator`. After the bulk Dismiss the crash hold still blocks, the scheduled-send gate still names the session, the paused indicator still offers "It stopped", the saved input's delivery state is unchanged, and no crash-hold acknowledgement is written.
- **`AgentRecoveryListHeaderTextTests`:** 9 tests, 0 failures. New tests cover cleared-note counts and labels, and the confirmation title and text.
- **`AgentRecoveryTestSupport.swift`:** added `failingWritePathFragment` to the write-failure switch, so writes for one session can fail while others succeed.

## Validation
- `make dev-build` passes (rebuilt after the last source edit).
- `make dev-lint` passes after I removed four redundant `Sendable` conformances.
- `make guardrails` passes, with one warning that was already there: AGENTS.md route count.
- The three suites above were run one at a time.

## Not verified / open
- **No live UI check.** The confirmation dialog, layout and VoiceOver were not checked in the running app.
- **No workspace grouping**, because 8-attention-1 didn't add it; bulk Dismiss works per section. The summary line sits at the top of the sheet, not under a section header.
- **Which rows bulk Dismiss captures:** only the displayed rows. With the toggle on, cleared but not-dismissed notes are included and get dismissed.
- **Fixture artifact:** while refactoring the tests I saw that sessions created after coordinator startup carry one extra needs-action item in the catalog. It looks like a fixture-ordering artifact that existed before my change; I didn't investigate.
- **Docs:** per the rules I didn't touch `docs/`. The lossless-restart spec's step status for 8-attention-2 needs updating on your side.

## Accessibility IDs for the verifier
- `agent.recoveryNeedsAttention.dismissAll.informational`
- `agent.recoveryNeedsAttention.dismissAll.needsAction`
- `agent.recoveryNeedsAttention.dismissAll.needsAction.confirm` (I added this one for the dialog's Dismiss button)
- `agent.recoveryNeedsAttention.bulkSummary`
- `agent.recoveryNeedsAttention.bulkCancel` (the Stop button, shown while a bulk runs)
- `agent.recoveryNeedsAttention.showDismissed` (unchanged; its label is now "Show dismissed and cleared")
- Unchanged: `.section.needsAction`, `.section.informational`, `.sheet`, `.sidebarButton`

Nothing is staged or committed.


## Round 1 — fixes for the round-0 review (worker report, verbatim)

All seven fixes are in. Build, lint and the three test suites pass. `make guardrails` fails, but only because the two new review files in `docs/` aren't linked from anywhere — I'm not allowed to touch `docs/`. Nothing committed; `make dev-format` not run.

**Fix outcomes**

1. **Freeze at click time (ATT2-01).**
   - The coordinator now has `bulkDismissCapture(_:)`. It splits the shown items into the eligible ones, which are the confirmed count, and skips with reasons.
   - The sheet stores this frozen set when "Dismiss eligible…" is clicked. Confirming dismisses exactly those items; a row that was busy or ineligible at click time stays a skip and is never added later.
   - New test `testBulkDismissActsOnlyOnTheItemsEligibleWhenConfirmed`:
     - The other card's own Dismiss is blocked, then fails while the bulk's first write is still blocked.
     - The bulk dismisses only 1 of 2, and the summary is "Needs action: Dismissed 1 of 2 · 1 skipped (1 busy)".
     - It also checks the bulk is still blocked at that moment, so the test can't pass without the scenario actually happening.
2. **Hidden rows (F2).** Dismissed and cleared items are never captured or counted, so the total always matches the section header. The VM-level test now ends with a toggle-on check: total equals the header count, 0 eligible, and the dismissed rows are not among the skips. I added it to the existing `testNeedsActionBulkDismissKeepsTheCrashHoldBlockingAndItsPausedIndicator` rather than a separate test, because its end state already has dismissed rows.
3. **One eligibility rule (F1).**
   - New `AgentRecoveryCatalogItem.offersDismiss`: has an acknowledgement, has a `sessionID`, not dismissed.
   - The row adapter's `.dismiss` now uses it (RecoveryList.swift:162). So does `bulkDismissIneligibility(of:)`, which drives the VM count, the capture and each item's re-check.
4. **Clearing guards (F4).**
   - A run with delegated-child links is never cleared.
   - A later attempt that verifiably never delivered its input no longer counts as "session continued".
   - Both are wired in the catalog builder. There is one rule-level test for each; an end-to-end fixture for these two cases was too heavy.
5. **Other workspaces (F3).** No grouping. The title becomes e.g. "Dismiss 5 cards that need action (2 in other workspaces)?" or "(1 in another workspace)", counted from `isOtherWorkspace` on the frozen eligible rows. The header-text test covers both wordings.
6. **Summary (F7).**
   - Each summary now starts with its section, e.g. "Information: Dismissed 1 of 5 · …", and the existing summary assertions are updated.
   - Closing the sheet clears a finished summary.
   - A summary for a bulk that is still running is kept, and stays until the sheet is closed again.
7. **Fixture oddity:** no production change.

**F1 finding.** Nothing in the Needs Attention sheet is acknowledged and undismissed but shown without `.dismiss`.
- Acknowledgements are given only to crash holds, turns, run cards, closed-session drafts, intents, questions, held drafts and schedules (Catalog.swift:541, 582, 602, 620, 680, 775, 802, 901, 998). Every one of those rows includes `dismiss`.
- The only acknowledged row without `.dismiss` is the composer banner's "Sending is paused" row (RecoveryList.swift:206–208). It is built only from an already-dismissed hold (:40–44), and the sheet never builds it (:71–83).
- Every acknowledged item also has a `sessionID`, so adding that check changes nothing today.

**Fixture finding.** The extra needs-action item is not a `turn-`/`run-`/`intent-` row or a duplicate:
```
workspace-<id> | statusUnknown | needsAction | workspaceFailure(NSCocoaErrorDomain 260 … ".../workspace")
```
- **Cause:** the fixture's custom storage folder (CoordinatorTests.swift:62) doesn't exist until the first session is saved. So a coordinator started first finds no folder.
- **Where it comes from:** `recoverySessionFiles` throws for a missing custom folder on purpose (AgentSessionDataService.swift:3646–3658). The startup sweep records that as a workspace failure (Reconciliation.swift:470–478), and the catalog lists it (Catalog.swift:504–512).
- **Production:** a default-location workspace with no folder returns no sessions instead. A missing custom folder, such as an unmounted volume, is meant to show this card. So it's a fixture artifact.

**Files changed this round:**
- `AgentRecoveryCoordinator+BulkDismiss.swift`
- `AgentRecoveryCatalog.swift`
- `AgentModeViewModel+RecoveryBulk.swift`
- `AgentModeViewModel+RecoveryList.swift` (one line)
- `AgentRecoveryNeedsAttentionSheet.swift`
- Tests: `AgentRecoveryCoordinatorTests`, `AgentRecoveryStartupCompositionTests`, `AgentRecoveryListHeaderTextTests`

**Validation**
- `make dev-build` and `make dev-lint` pass.
- `make guardrails` fails as described above, plus the existing too-many-routes warning in `AGENTS.md`.
- Coordinator tests: 66, 0 failures (3 new). Startup composition: 16, 0 failures. Header text: 9, 0 failures.

Two things outside the brief:
- **Extra test runs.** I added a temporary dump test (which fails on purpose), ran it, then removed it. While looking for its log I also ran `make dev-test-artifact` once by mistake; it isn't on the allowed list, but it only re-runs tests.
- **Staging.** `git status` shows the two new source files as already staged (`A`). I didn't stage anything this round.
