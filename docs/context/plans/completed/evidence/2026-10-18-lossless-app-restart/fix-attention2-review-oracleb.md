# Step 8-attention-2 review, round 0 — OracleB

Scope: read when the task touches the Step 8-attention-2 review of automatic clearing and bulk Dismiss.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-0 review of prompt-exports/restart-fixes/att2-r0.diff.

# Review: Step 8-attention-2 (automatic clearing and bulk Dismiss), att2-r0

## Summary

The change adds two things to the Needs Attention sheet:

- **Automatic clearing.** An informational run card can now be cleared at projection time for one of three reasons: a recovery action resolved it, the conversation was reset after the run, or a later attempt exists in the same generation. Nothing is written. A cleared card stays in the catalog, is left out of `needsAttentionItems(includeDismissed: false)` and the header counts, and is shown with a label when "Show dismissed and cleared" is on.
- **Bulk Dismiss.** It runs one item at a time, one bulk at a time app-wide, and lives on the coordinator. Each captured item is checked again (key, freshness and attention class) before it is passed unchanged to the existing `dismissCatalogItem`. Skips, failures and Stop are reported in a status line that every window shares.

I found **no P0 and no P1**. The acceptance gates hold:

- `automaticClear` only applies when `attention == .informational`, and the switch over payloads is exhaustive (`AgentRecoveryCatalog.swift:172`).
- Bulk only calls `dismissCatalogItem`. Nothing touches blockers, `blockingCrashHold`, admission or send paths.
- The startup-composition test checks that a dismissed crash hold still blocks sending, still blocks the new-session gate, and still shows its paused indicator.

The findings below are P2/P3.

## Answers to the specific questions

- **Generation computation** (`AgentRecoveryCatalog.swift:460-461`)
  - This is the same expression `addResolution` passes to `addIntents`: the lane's binding if there is one, otherwise `max(startup binding, record)`.
  - For unlisted sessions, `bindings[id] = lane?.binding`, so it reduces to the `lane ?? record` rule used there. That is correct.
  - A retired or stale lane can only make the value *lower*, which under-clears. That is the safe direction.
- **`runAttempts` ordering**
  - Correct as long as the invariant the worker describes holds. Nothing enforces it, though; see F5.
- **A later attempt that is itself interrupted or failed**
  - If the later attempt B is interrupted, B gets its own card, so hiding A loses nothing.
  - If B never handed off, A is still labelled "session continued" even though nothing reached the provider; see F4. B's held input does still appear as a needs-action intent.
- **Can bulk Dismiss dismiss an item whose freshness changed?**
  - Not in any way that hides the newer state.
  - The synchronous check rejects a freshness mismatch (`BulkDismiss.swift:144`).
  - If freshness changes during the `await` at :115, the acknowledgement is written for the captured `(key, freshness)`. `isCardAcknowledged(key, freshness:)` then doesn't match the new state, so the card stays visible.
  - Intents and questions also go through `recordStillMatches` atomically with the write.
- **The "class changed" skip**
  - It is correct, but it only checks at one point in time; see F6.
- **App-wide flag and cancellation**
  - Safe. The coordinator runs on the main actor, and there is no `await` between the guard (:101) and the assignment (:102).
  - A double-click starts two VM tasks, and the second one returns `nil`.
  - Stop is honoured before the next item. It cannot interrupt an item that is waiting on a session's persistence gate; this is documented and acceptable.
  - Closing the sheet cancels nothing, as specified.
- **Notifications and refresh**
  - Fine. `postCatalogChange` is coalesced, but the handler reads live state when it renders, so the last update (`isRunning = false`) is never lost.
  - The extra `.agentRecoveryCoordinatorDidChange` subscription is harmless.
- **"Toggle on → cleared notes get dismissed"**
  - This is a real inconsistency; see F2.

## P2

**F1. Bulk eligibility is "has an acknowledgement", not "the row offers Dismiss" (needs checking)**
- **Evidence:** `AgentModeViewModel+RecoveryBulk.swift:30`, `AgentRecoveryCoordinator+BulkDismiss.swift:139`.
- **Scenario:** The row adapter (`recoveryListRow`) chooses each row's actions by state. If any item that has an acknowledgement is deliberately shown *without* `.dismiss`, the bulk still dismisses it. Possible examples are a schedule in some state, an intent that is `.dispatching`, or a remote session.
- **Impact:** A card is hidden that the single-row UI does not let you hide. Nothing is sent or lost.
- **Fix:** Check whether any such state exists. If it does, base eligibility on `row.row.actions.contains(.dismiss)` in the VM, plus the coordinator's own check. Either way, put the predicate in one place, because the VM version currently skips the `sessionID != nil` check.

**F2. With the toggle on, bulk captures hidden rows**
- **Evidence:** `AgentRecoveryNeedsAttentionSheet.swift:64,96,99`; VM `:28-31`.
- **Scenario:** The user turns on "Show dismissed and cleared". The Information header shows "(0)" because `headerCount` excludes `isHidden`, yet "Dismiss all" is enabled. Clicking it writes durable acknowledgements for every cleared note, turning projection-only clears into stored dismissals. In both sections, already-dismissed rows are captured and reported as "N skipped (N already dismissed)".
- **Impact:** The count says zero while the button acts on rows, extra writes happen, and the summary is noisy.
- **Fix:** Capture and count only rows where `!row.isHidden`, i.e. exactly what the headers count.

**F3. Bulk scope is the whole app; the design's per-workspace grouping was dropped**
- **Evidence:** Sheet `:64`; the synthesis says bulk Dismiss is "per section and per workspace group".
- **Scenario:** One confirmation of "Dismiss eligible…" dismisses crash holds, held input and schedules in every workspace, including other workspaces' cards marked "Another workspace". The confirmation title only gives a count.
- **Impact:** The badge stops counting paused sessions in workspaces the user isn't looking at. Gates are unaffected.
- **Fix:** Ask the owner whether to accept this or require grouping. At minimum, say "(N in other workspaces)" in the confirmation title.

**F4. Clearing can hide the only pointer to delegated children**
- **Evidence:** `AgentRecoveryCatalog.swift:172-178`, `:357`.
- **Scenario:** Run A started delegated sessions, recorded in `delegatedChildLinks` (Step 5b). The user sends one more message in the parent, creating attempt B in the same generation. A is cleared as `sessionContinued`, and the delegated-child discovery list disappears from normal view.
- **A related case:** If B is verifiably never handed off, A is still labelled "session continued".
- **Fix (one guard each):**
  - Return `nil` when `!delegatedChildLinks.isEmpty`.
  - Ignore later attempts for which `record.isVerifiedNeverHandedOff(runAttemptID:)` is true.

## P3

**F5. Ordering by array position is an unenforced invariant**
- **Evidence:** `AgentRecoveryCatalog.swift:357`.
- **Scenario:** A future change upserts an attempt late, for example when recording terminal evidence for an attempt that was never ensured, or compacts the record. The *newer* card would then be hidden in place of the older one.
- **Fix:** Compare `startedAt` (falling back to index on ties), or add a store test that pins down append order.

**F6. The class check happens once, before the write**
- **Evidence:** `BulkDismiss.swift:145` vs `:115`.
- **Detail:** Attention class is not part of freshness. A card that becomes needs-action during the `await` is still dismissed, and `isOpenNeedsAction` then drops it from the badge.
- **Mitigation:** The row is marked `.working`, and single-row Dismiss has the same window.
- **Fix:** Note it in a comment, or recheck class inside `dismissCatalogItem`.

**F7. The last summary never goes away**
- **Evidence:** `bulkStatusLine`, sheet `:148`.
- **Detail:** A summary from hours ago appears every time the sheet opens, and it doesn't say which section it covered.
- **Fix:** Clear the summary when the sheet is dismissed, or after the next catalog rebuild, and include the section in the text.

**F8. Duplication and loose ends**
- The current-generation expression appears at `Catalog:460` and again in the `addIntents` call. Extract a `Builder.currentGeneration(sessionID:record:)` helper.
- The row's `automaticClear` and `isHidden` duplicate the item's own values (`AgentComposerUIModels.swift` around 483-497). Make `item` non-optional and derive both from it.
- `postCatalogChange` was widened from `private` to module-internal. Acceptable, but worth a doc note.
- The dialog title is recomputed live and can briefly read "Dismiss 0 cards…" as it closes.
- The dialog's "Dismiss" button has no `role: .destructive`.

**F9. Test gaps**
- No test covers the generation path when a session has no lane (the `max(binding, record)` branch).
- No test covers bulk with the toggle on (F2).
- No UI or a11y check of the dialog has been done (the worker already disclosed this).

## Fixture oddity: one extra needs-action item for sessions created after startup

This could point to a production problem. Creating sessions after startup is the *normal* production path, because that's how every new session is made. That path goes through `addHeldInputOfUnlistedSessions` and `addLaneComposerState`. If a spurious needs-action item appears there, it would raise the badge for real users. It would now also be swept into "Dismiss eligible…".

The most likely explanation is still the fixture. For example, a lane claimed with a test `Owner()` and no durable composer authority could produce a save-failure or preparation item. That cannot be confirmed from this diff. It is cheap to settle: dump `catalog.items.map { ($0.id, $0.kind, $0.attention) }` in the fixture.

- If it's a `draft-*`, `savefail-*` or `draft-prep-*` row caused by how the test claims lanes, it's an artifact.
- If it's a `turn-`, `run-` or `intent-` row, or a duplicate, investigate before 9-live.

## Recommendations

1. Fix F2 now: filter on `!isHidden` when capturing rows and when counting eligible ones. It's a two-line change.
2. Check F1, then move bulk eligibility into a single coordinator predicate, ideally tied to the row offering `.dismiss`.
3. Add the two guards in F4: don't clear cards with delegated-child links, and ignore never-handed-off later attempts.
4. Ask the owner about F3 (whole-app scope vs per-workspace groups). Record the choice under `assumed:` if there's no answer.
5. Identify the extra fixture item before commit (one assertion dump).
6. List F5–F9 as deferred. None of them justifies another review round.