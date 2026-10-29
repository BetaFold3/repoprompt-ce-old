# Step 9-check review, round 0 — OracleB

Scope: read when the task touches the Step 9-check review of Check and resolve.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-0 review of prompt-exports/restart-fixes/check-r0.diff.

# Step 9-check review: "Check and resolve"

## Summary

The diff adds a "Check and resolve" button to the Needs Attention sheet. It captures the visible catalog items when clicked and checks them one at a time, with one check at a time across the app. Each item is reported as resolved, needs you, could not check, or failed. Stop takes effect before the next item. When the calling window's runner allows `.reconcileOnly`, the check first refreshes runtime ownership once. It then sends each unchanged informational run card through the window's existing Reconcile and re-reads the catalog. Otherwise it only classifies items from the catalog.

`refreshRuntimeOwnership()` now waits for its snapshot to be adopted before returning, instead of adopting it in a background task.

**Pre-activation path (checked, no finding):**
- With `checksActive == false`, `checkCatalogItems` never calls `refreshRuntimeOwnership` and never calls `reconcile`.
- `checkOutcome` returns before touching `reconcile` or `setCatalogActionState` (Check.swift:163–172).
- The only side effect is `postCatalogChange()`.
- No send, stop, discard, dismiss, session open or provider/process work is reachable on this path.
- **"Checks active":** it comes from `qualification.historyReconciliation && registrationActive()` on the calling window's runner, which is off in production. No qualification flag, registration or admission gate is changed.

I found no P0. One P1 needs checking against code that wasn't attached. The rest are P2.

## P1

### CHK-1 — Post-Reconcile catalog re-read may be stale, so a finished run is reported as "needs you" *(confirm before fixing)*
**Where:** `AgentRecoveryCoordinator+Check.swift:184–191`, `AgentModeViewModel+RecoveryCheck.swift:70`

`checkOutcome` re-reads `catalog.item(id:)` right after `reconcile(item)` returns. It decides "resolved" only from `after.automaticClear == .resolved`. The test suite itself suggests the catalog updates later, not at the moment of the write:
- `testCheckAfterActivationReportsEachReconcileResult` has to wait with `Support.eventually { changed.item?.attention == .needsAction }` after `reserveRecoveryAction`.
- The positive "resolved" case only passes because the fixture helper `cards[0].perform(...)` runs inside the injected closure.
- The real path (`reconcileRecoveryCheckItem` → `performRecoveryResumeAction`) is never exercised.

**Failure scenario (C2, after activation):**
1. A Codex run finished while the app was closed. Check reconciles it, and the runner records `importedCompleted`.
2. `performRecoveryResumeAction` returns before the catalog projection catches up.
3. `after` is the pre-Reconcile card, or a card that still shows the reservation (`hasUnfinishedAction`).
4. The report says "Needs you: Provider history didn't confirm it finished…" or "Check the conversation, then continue it…" instead of "Resolved". That is a wrong answer, and C2 fails.

**This is the same staleness the worker fixed for ownership refresh, but not for the history write.**

**Smallest fix (either):**
- Have the check path await the catalog rebuild for that session before re-reading. Use whatever completion signal the projection already has, or `await` the same rebuild the bulk-dismiss path uses.
- Or decide from the runner's own outcome: make `performRecoveryResumeAction` (or a thin wrapper) return the `AgentRecoveryActionResult`, and map `.completed(.importedCompleted, _)` to resolved. This also fixes CHK-6.

Also add one test that goes through the real view-model Reconcile path, or a fake one with the same asynchronous projection.

## P2

### CHK-2 — The ownership-refresh change can still return before any adoption, defeating its stated purpose
**Where:** `AgentRecoveryCoordinator+RuntimeOwnership.swift:100–107`

The supersession guard returns without adopting when a later pull bumped `runtimeSnapshotRequest`. The registry's change handler causes exactly such a pull (`startRuntimeOwnership`'s `Task { @MainActor in pullRuntimeRestrictions() }`). A refresh that finds a change is the case most likely to fire it.

**Failure scenario:**
1. `refreshRetryingStorage()` discovers an exit and the change handler enqueues a pull.
2. Refresh resumes first, sets request = n, and awaits the snapshot.
3. The pull runs and sets the counter to n+1.
4. Refresh's guard fails, so it returns without adopting anything; the pull adopts on a later main-actor hop.
5. Check's first catalog reads still see the old restriction. The report says "Needs you: Let it finish or Stop" for a process that already exited.

The outcome is conservative but wrong. Checking the other callers:
- **Row Refresh button:** no ordering harm.
- **Main actor:** no stall; it is a suspension, not a block.
- **Reentrancy:** same exposure as before.

**Fix:** track the last *adopted* request (e.g. `runtimeSnapshotAdopted`). Adopt if `adopted < request`; a later pull will overwrite it anyway. Or, when superseded, await that later pull's adoption.

### CHK-3 — "Resolved" is claimed for any item that disappeared, and "The process exited." is inferred
**Where:** `AgentRecoveryCoordinator+Check.swift:166–169, 184–186`

When checks are active, any captured item missing from `catalog.item(id:)` counts as resolved. For `.survivingProcess` it is reported as "The process exited."

Items can disappear for other reasons:
- the session or workspace was removed during the check;
- the window hosting a draft or edit proposal closed;
- the item ID changed;
- a refresh replaced individual survivors with the global-uncertainty `runtimeOwnershipUnknown` item.

In the last case the report says "Resolved: The process exited," while sending is actually paused app-wide.

**Fix:** report disappearance as `couldNotCheck("It is no longer listed.")`, or as a separate "no longer listed" count. Only say "The process exited." when the adopted snapshot positively lacks that `runtimeID` and `hasGlobalUncertainty == false`.

### CHK-4 — The restriction warning appears only after the action it warns about
**Where:** `AgentRecoveryCoordinator+Check.swift:76–80`; sheet button tooltip (`AgentRecoveryNeedsAttentionSheet.swift`, Check button)

The synthesis puts the warning in *confirmation* text. Here the header appears only after the click, and the refresh runs immediately. The button tooltip also says "Nothing is sent…", but a cleared restriction may let already-authorized scheduled sends run.

This matches the literal acceptance ("the report says"), so it is P2. The cheap fix: when `recoveryChecksActive`, add the restriction sentence to the tooltip (or to a caption next to the button).

### CHK-5 — Stop cannot end a stuck Reconcile or refresh, and that blocks every later check app-wide
**Where:** `AgentRecoveryCoordinator+Check.swift:127–138`, `AgentModeViewModel+RecoveryCheck.swift:37`

Cancellation is checked only between items. The task is never cancelled, and `clearRecoveryCheckReport` keeps a running status. If one Reconcile hangs (for example, the temporary Codex `app-server` after a cold relaunch never answers), the check stays `isRunning` until the app quits. The button stays disabled in every window.

Also, a Stop pressed during the initial refresh says "Checking 1 of N… Stopping after this item." while no item is in progress.

**Fix:** check `Task.isCancelled` and have Stop cancel the stored task. Alternatively, rely on the existing Reconcile timeout if there is one, and note that here. Show a "Refreshing process ownership…" phase.

### CHK-6 — Reconcile refusals and "nothing to import" results are reported as "Failed"
**Where:** `AgentRecoveryCoordinator+Check.swift:190`; `AgentRecoveryActionRunner.swift` (`perform` refusal and disabled paths)

`.performed(failure:)` folds every non-nil text into `.failed`. That includes:
- `sessionActionInFlightText` (another recovery choice for this session or workspace is running — a concurrency skip, not a failure);
- `disabled` texts;
- `nothingImported` / `associationUnavailable` reasons.

The worker flagged this. It distorts the summary counts. Returning the typed runner result, which is the same change as the CHK-1 fix, would let these map to `couldNotCheck`.

### CHK-7 — Wrong reason text on the active path
**Where:** `AgentRecoveryCoordinator+Check.swift:173–174`

When checks *are* active, a run card that is not informational and has neither `hasUnfinishedAction` nor `hasUnsentContinuation` falls through to `"Provider history checks are not active."`. That is false on this path.

It may be unreachable under the current classification, but it is cheap to fix: use a neutral reason such as "This card needs action; Check doesn't reconcile it."

### CHK-8 — One report shared by all windows, cleared by any window
**Where:** sheet `.onDisappear` → `clearRecoveryCheckReport()`

When the sheet is open in windows A and B and the check has finished, closing B clears the report A is still showing. This is the same pattern as the bulk-dismiss summary, so it is consistent but worth knowing. Possible fixes:
- record which window started the check and clear only from that window;
- or keep the report until the next check starts.

### CHK-9 — Displayed rows without a catalog item are silently left out
**Where:** `AgentModeViewModel+RecoveryCheck.swift:35`; sheet button `.disabled(... !rows.contains { !$0.isHidden })`

`compactMap(\.item)` drops visible rows that have no catalog item, yet the summary still says "Checked N of N". If every visible row has a `nil` item, the button is enabled and the progress text reads "Checking 1 of 0…".

**Fix:** base both the enable condition and the total on `compactMap(\.item)`.

### CHK-10 — Test coverage gaps
- `reconcileRecoveryCheckItem` (real view-model path: working state, lane lookup, `performRecoveryResumeAction`) is untested.
- The active-path refresh isn't exercised; the fixtures likely have no registry, so `refreshRuntimeOwnership` does nothing there.
- No test shows that a check reads the restrictions that its own refresh adopted.
- No test covers the `.survivingProcess` "exited" branch or a bulk Dismiss running at the same time.

**Other checks (no finding):**
- **Bulk Dismiss and per-row actions:** the `.working` action state, plus the acknowledgement and payload revalidation before Reconcile (Check.swift:163, 176; VM:65–68), correctly keep Check, bulk Dismiss and per-row actions from running on the same item. The check runs on the main actor with no suspension between revalidation and `setCatalogActionState(.working)`, so there is no gap.
- **Double click or two windows:** a second start returns `nil` harmlessly.

## Recommendations
1. **Before 9-activation:** confirm CHK-1 by reading how `performRecoveryResumeAction` and the catalog projection settle. If it is confirmed, return the typed runner outcome from the Reconcile path and map it directly; that also resolves CHK-6. Add one test through the real view-model path.
2. Fix the ownership-refresh adoption guard (CHK-2) with an adopted-request counter. It is a few lines, and it is what the behavior change was meant to guarantee.
3. Stop claiming "resolved" or "the process exited" when an item merely disappeared (CHK-3).
4. Cheap UI fixes: put the restriction warning before the click (CHK-4), add a refreshing phase and a Stop that cancels (CHK-5), and base the button state and total on actual catalog items (CHK-9).
5. Defer CHK-7 and CHK-8 unless the files are being touched anyway. Record that the pre-activation path was checked as write-free and process-free; C1 still needs the live verifier.