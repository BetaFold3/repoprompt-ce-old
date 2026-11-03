# Step 9-check re-review, round 1 — OracleB

Scope: read when the task touches the Step 9-check re-review of Check and resolve.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-1 re-review of prompt-exports/restart-fixes/check-delta.diff.

# Re-review, round 1: Step 9-check (Check and resolve)

## Summary

Round 1 makes these changes:
- **Run-card results:** the report now comes from the runner's typed result (`AgentRecoveryActionResult` and the observed `AgentRecoveryReconcileResult`). An optional `RecoveryResumeActionReport` box on `performRecoveryResumeAction` carries them back. There is no longer a catalog re-read after Reconcile.
- **Snapshot ordering:** runtime-ownership snapshots now go through a `runtimeSnapshotAdopted` counter. Refresh waits for its own adoption, or a newer one.
- **Items that changed while waiting:**
  - A card that was cleared or dismissed during the check is reported from that state and is not reconciled.
  - A vanished survivor is reported as exited only when the registry proves it.
- **UI:** the help text, the "Refreshing process ownership…" phase and the item totals were updated.

I traced each fix against the delta.
- **CHK-1 is fixed:** the reconciled card is no longer reported from the catalog.
- **CHK-2 is fixed for Refresh.** The same change to adoption ordering also changed how startup adopts its snapshot, and that is the one regression candidate below.
- **No P0 or P1** findings.

## P2 — Consider

### R1-1: Startup's own snapshot can now be discarded in favour of a mid-start pull (regression from the CHK-2 fix)
**Where:** `AgentRecoveryCoordinator+RuntimeOwnership.swift:~126-137` (`startRuntimeOwnership`) and `:~154-156` (`adoptRuntimeRestrictions` guard).

**Before:** startup adopted `registry.start()`'s snapshot unconditionally. Readiness therefore always saw start's final state.

**Now:**
1. The change handler is installed first.
2. Startup issues request N, then runs `await registry.start()`.
3. If `start()` mutates state and suspends partway through (discovery, inventory), the handler starts a `pullRuntimeRestrictions` Task. That Task issues N+1, reads `restrictionSnapshot()` on the registry actor while `start()` is still running, and adopts the partial snapshot.
4. When `start()` returns, `adoptRuntimeRestrictions(snapshot, request: N)` fails `request > runtimeSnapshotAdopted` and the final snapshot is dropped.

A later pull, triggered by start's last mutation, should eventually correct this, but it lands one main-actor hop *after* startup goes on to readiness.

**Failure scenario:** a previous-instance writer is discovered late in `start()`. The pull that landed mid-start doesn't include it. Readiness is reached and the scheduled-send evaluation admits a send on that conversation before the corrective pull lands.

The impact depends on whether the registry's partial snapshot is permissive (empty) or conservative (global uncertainty), and I can't see that from here. If it is permissive, raise this to P1.

**Smallest fix:** in `startRuntimeOwnership`, issue the request number *after* `start()` returns:
```swift
let snapshot = await registry.start()
runtimeSnapshotRequest &+= 1
adoptRuntimeRestrictions(snapshot, request: runtimeSnapshotRequest)
```
Any pull that read during `start()` saw older or equal state and then loses correctly. The general fix would be a monotonic generation stamped by the registry on each snapshot, so adoption order follows when the data was read rather than when the request was issued. That is optional.

### R1-2: The "resolved" mapping depends on unverified runner semantics and is not exercised through the real runner
**Where:** `AgentRecoveryCoordinator+Check.swift:~76-78` and the VM glue in `AgentModeViewModel+RecoveryCheck.swift:~92-100`.

**The assumption:** the mapping treats `.completed(.importedCompleted, reason: nil)` as resolved and any non-nil `reason` as a save failure.

**Coverage:** the only real-path test (`testCheckReportsTheRealReconcileTypedResult`) covers the association-unavailable branch. The confirmed/resolved branch, which is the scenario CHK-1 was about, is covered only through a stub closure that builds the result by hand.

**Failure scenario:** suppose the runner sometimes sets an informational `reason` on a successful `importedCompleted`, for example a note about the number of imported rows. A finished run would then be reported as "Failed: The turn had finished, but its history couldn't be saved: …". No test would catch it.

**Fix:** add one real-path test where the history confirms completion and the rows are saved, and assert `.resolved`. Alternatively, cite the runner line that sets `reason` only on a save failure.

### R1-3: An action that was already performed is reported as "couldn't start"
**Where:** `AgentModeViewModel+RecoveryCheck.swift:~97-99`.

`performRecoveryResumeAction` returns `nil` when "found already performed", without reaching the runner. The report box then stays empty and Check reports "Could not check: Reconcile couldn't start for this card." That is misleading for a card whose choice was already made. A cheap fix is a distinct reason, e.g. "A choice on this card was already made. Review it on the card."

### R1-4: The row's action state can disagree with the Check report
**Where:** `AgentModeViewModel+RecoveryCheck.swift:~95`.

The row state is set from the free-text `failure`, while the report comes from the typed result. For association-unavailable or nothing-imported results, the card can show a failed state while the report says "Needs you". This was already how a manual Reconcile behaved, so it is not a regression. If it's cheap, derive the row state from the same typed outcome. Otherwise list it as deferred.

### R1-5: `adoptRuntimeRestrictions` was widened from `private` to module-internal for the tests
Any code in `RepoPromptAgentCore` can now inject a snapshot and bypass the registry. The tests only need it to check ordering. Consider a `test_`-prefixed wrapper, or keep it `private` and test the ordering through overlapping pulls.

## Verification of round-0 items
- **CHK-1 is fixed.** The reconciled card is reported from `report.result` / `report.observed`, which are set synchronously after `recoveryActionRunner.perform`, so the async `adoptRecordCommit` hop no longer matters.
  - Cards *later* in the same session can still be read from a catalog that hasn't caught up with an earlier card's commit. Any resulting stale request is refused by the runner and reported as "could not check", so the report is not wrong.
- **CHK-2 is fixed for Refresh.** Refresh's request is issued after `refreshRetryingStorage`, and the snapshot read is enqueued in order on the registry actor. A newer request that wins therefore carries newer or equal data. The exception is startup (R1-1).
- **Cleared, dismissed and vanished items:** the cleared and dismissed checks come before the attention and acknowledgement guards. Proof of exit requires a registry, no global uncertainty, and the runtime ID being absent from the snapshot. No regression found.
- **Refreshing phase and Stop during refresh:** if Stop is pressed during the refresh, the check breaks at index 0 with `notChecked = total`. That is correct.

## On the timeout deferral
I agree with deferring it. The path is unreachable until 9-activation, and Reconcile's providers belong to that step. Record it as an **activation blocker**, not a deferred P2, for three reasons:
- A hung Codex `startIfNeeded` holds the app-wide check lock: `isRecoveryCheckRunning` stays true in every window.
- The row stays in `.working`.
- The check Task can't be cancelled at all, because no handle is kept and closing the sheet cancels nothing.

The 9-activation acceptance should require either a bounded Reconcile, or a Stop that abandons the current item and releases the row's `.working` state.

## Recommendations
1. Fix R1-1 now. It is a three-line move that restores the old guarantee that readiness sees start's final snapshot.
2. Add the real-path test for confirmed and saved → `.resolved` (R1-2), or cite the runner's `reason` contract in the step's evidence.
3. R1-3 to R1-5 are cheap and optional. Fix them, or list them as deferred.
4. Add "a bounded Reconcile, or a Stop that abandons the current item" to the 9-activation acceptance criteria as a blocker.
5. With R1-1 addressed, nothing from this lane blocks committing Step 9-check.