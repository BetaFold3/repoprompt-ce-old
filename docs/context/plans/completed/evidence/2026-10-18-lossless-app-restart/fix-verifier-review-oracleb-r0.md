# Step 8-verifier-fixes review round 0: OracleB

Scope: read when the task touches Needs Attention session deletion (F8), View popover placement, or recovery accessibility identifiers (Step 8-verifier-fixes of the lossless app restart plan).
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleB round-0 review

# Review: Step 8-verifier-fixes (O39)

## Summary

The step fixes three things the verifier found:

- **F8 (deleted sessions stay listed):** the coordinator now listens for the tombstone notification `agentSessionDeletionDidCommit` and keeps a permanent `deletedSessionIDs` set. When a session is deleted, it drops that session's startup crash hold, confirmed hold and session restriction, and the catalog projection removes the session's items and blockers. If the deletion lands while startup is still loading, `performStartup` applies the same cleanup after it rebuilds `crashHolds` and `restrictions`.
- **Popover covering rows:** the View popover now opens outside a marked region: above the banner, and beside the Needs Attention sheet. Positioning is done by a pure, tested function (`positioningRect`). The anchor still toggles the popover, and the click-through monitor is unchanged.
- **Check report identifier:** the sheet root becomes an accessibility container, so the sheet's identifier no longer spreads onto its children.

The core logic is sound: the cleanup is idempotent, the deletion-during-startup race is handled, the clamping math is right, and the popover falls back to the anchor when the region is in a different window. I found **no P0 or P1**. The findings are a behaviour choice that should be recorded, two scope or fallback gaps, an unconfirmed accessibility fix, and a broken evidence diff.

---

## P2

### VF-1: Deleting a session lifts its crash hold without the "It stopped" confirmation
**Where:** `AgentRecoveryCoordinator.swift` ~623–635 (`noteSessionDeleted` → `retireStartupState`)

**Failure scenario:**
1. The app is SIGKILLed during a Claude turn in session A, in workspace W.
2. On relaunch, A's crash hold pauses W, which is the point of the hold: the orphaned provider process may still be editing the worktree.
3. The user deletes A from the sidebar while cleaning up.
4. The hold and restriction lift at once. An already-authorized scheduled send in session B (same workspace) can now run while the orphaned process is still alive.

Check and resolve warns about exactly this ("clearing a restriction may let already-authorized scheduled sends run"). Delete gives no such warning.

**Impact:** Small. The next launch already drops the hold, because the tombstone means nothing holds. So this moves an existing release earlier rather than adding a new one. But it is a safety behaviour change O39 did not explicitly ask for ("rows and badge go with the session").

**Smallest fix:** No code change. Record it on the status line under `assumed: deleting a session releases its crash hold and session restriction immediately, as the next launch already does`. Optionally, ask the owner whether Delete should mention it.

### VF-2: `removeDeletedSessions` may hide surviving-process items while their runtime restriction still pauses the workspace
**Where:** `AgentRecoveryCatalog.swift` ~498–505

**Failure scenario:** The comment says "Runtime items carry no session and stay." But `addRuntimeRestrictions()` runs just before this, and `items.removeAll { $0.sessionID.map(deleted.contains) ?? false }` removes every item kind with a matching session ID. If `.survivingProcess` items carry the owning session's ID, then once activation is on:
1. Deleting a session whose process family is still registered removes the only row with Stop / Let it finish.
2. The runtime restriction is not lifted (only `restrictions.lift(sessionID:)` and the crash-hold blocker are cleared).
3. The workspace stays paused with no visible reason, and a possibly running process has no UI.

Production activation is off today, so this can't happen yet.

**Smallest fix:** Exempt the kind explicitly, e.g. `items.removeAll { $0.kind != .survivingProcess && ($0.sessionID.map(deleted.contains) ?? false) }`. Alternatively, prove the comment with a one-line assertion in the F8 test that runtime items have `sessionID == nil`.

### VF-3: Sheet popover fallback can land back on the rows, with the arrow pointing at the sheet's centre
**Where:** `AgentRecoveryNativePopover.swift` ~45–57 (`positioningRect`, the horizontal-edge branch) and ~207–214 (`show`)

**Failure scenario:**
1. For edge `.maxX`, the rect is the anchor's row strip across the full sheet width.
2. If there is no room on either side (a small screen, a parent window barely wider than the sheet, or a widened sheet), AppKit picks `.maxY` or `.minY` of that strip.
3. The popover then sits directly above or below the row's strip, across the whole sheet width. That covers the neighbouring rows: the original bug.
4. Its arrow points at the strip's centre, not at the View button.

The banner has the same issue with `.minX`/`.maxX` fallback, but there it is much less likely to happen.

**Smallest fix:** Before showing, check that `regionView.window?.frame` leaves room on `edge` or its opposite within `screen.visibleFrame`. If neither side has room, use the existing anchor-relative `show`. At minimum, add "sheet at minimum width on a small display" to P7.

### VF-4: The report's identifier may still not resolve to a single element
**Where:** `AgentRecoveryNeedsAttentionSheet.swift` ~124–128

**Failure scenario:** `.accessibilityElement(children: .contain)` on the sheet root stops the sheet identifier from overriding its children. That is necessary, but may not be enough. The diff does not touch the report view. If the report is a plain `VStack` with `.accessibilityIdentifier("agent.recoveryNeedsAttention.checkReport")` and no `.accessibilityElement(children: .contain)`, SwiftUI applies the identifier to each leaf `Text`. The verifier then still finds no single `checkReport` element (C2), because the same root cause reappears one level down.

**Smallest fix:** Add `.accessibilityElement(children: .contain)` right before the report view's `accessibilityIdentifier`. Do the same for any other container identifier the scenarios query, such as `agent.recoveryList.banner`.

### VF-5: The saved evidence diff is not a valid patch for the coordinator
**Where:** `prompt-exports/restart-fixes/vf-r0.diff`, coordinator hunks `@@ -573`, `@@ -593` and `@@ -935`

**Failure scenario:** The coordinator hunks in the export are misplaced:
- The observer registration sits under `// MARK: Live records`, and `deinit` is left unclosed.
- `noteSessionDeleted` is spliced inside `adoptRecordCommit`'s `guard`.
- `retireStartupState(...)` is inside the `AgentRecoveryStartupReport(...)` argument list.
- The index hash (`023c04c1`) differs from the worktree's (`3b2b8bfe`).

Using it with `git apply --cached` to "stage only this step's hunks" will be rejected or produce code that doesn't compile. Reviewers handed only this file would review code that does not exist. The live file is correct.

**Smallest fix:** Stage with `git add -p`, splitting around the parallel worker's hunks (`test_crashHoldProofBeforeCommit`, `hasRecoveryActionHold`, `publishCrashHoldConfirmation`, `runtimeRegistrationRaw`). Then regenerate the evidence from `git diff --cached` and save that.

---

## P3

### VF-6: Test gaps
**Where:** `AgentRecoveryCoordinatorTests.swift` (new F8 tests)

- Neither new test has been run with the fix reverted. Do it once and record it.
- The startup-race path (the `retireStartupState(ofDeletedSessions: deletedSessionIDs)` call in `performStartup`) is untested. It is easy to cover: call `noteSessionDeleted` after `startIfNeeded()` and before `awaitStartup()` returns, then assert there is no hold and no item.
- The tests poll `coordinator.catalog` but never check that windows and the badge are told to refresh. `noteSessionDeleted` relies on `postCoordinatorDidChange()` to invalidate and announce the catalog, as `confirmCrashHold` does, and never calls `invalidateCatalog()` itself. Assert that the catalog-change notification is posted once.

### VF-7: The deletion observer is not scoped to its data service
**Where:** coordinator ~581–592

The observer uses `object: nil`, and the post uses `object: nil` too. Every coordinator alive in the process therefore reacts to any data service's deletions. This is harmless in the app, which has one coordinator, but tests run several. Post with `object: self` and observe `object: dataService`, if the data service is a reference type the notification can carry.

### VF-8: Other per-session state is hidden from the catalog but not pruned
**Where:** coordinator ~623–635

`heldIntentNotes`, `releasedUnsavedInputs`, `catalogActionStates` and `laneWorkspaceIDs` keep the deleted session's entries. The catalog filter hides them. But any admission or scheduler path that reads them directly, rather than through the catalog or `crashHolds`/`restrictions`, could still count the session. The test covers only the crash-hold and restriction inputs of `hasUnresolvedSession`. Confirm that `hasUnresolvedSession` and `unresolvedSessionSummary` read nothing else, or drop those entries in `noteSessionDeleted`.

### VF-9: Frozen bulk Dismiss and Check lists can include a just-deleted session
A bulk Dismiss or Check started before the deletion still holds that session's item. Acting on it fails against the tombstoned session and shows up as a failure in the summary. This is only cosmetic. Optionally, skip items whose session is in `deletedSessionIDs` when each one is processed.

---

## Recommendations

1. **Fix before commit:** VF-5 (stage hunk by hunk and regenerate the evidence from the staged diff) and VF-4 (add the container modifier to the report view; it's one line and it is the actual verifier check).
2. **Cheap code fixes:** VF-2 (exempt `.survivingProcess` explicitly, or prove the comment with an assertion) and the VF-6 tests (revert-check, the startup-race case, the catalog-change notification assertion).
3. **Status line:** record VF-1 under `assumed:` and VF-3 under `deferred:`, unless the owner wants Delete to mention releasing the hold.
4. **Verifier re-checks:** besides H1 and P1/P7/P11, run P7 with the sheet at minimum width on a small display (VF-3) and C2's `checkReport` query (VF-4).
5. VF-7 to VF-9 can be deferred.
