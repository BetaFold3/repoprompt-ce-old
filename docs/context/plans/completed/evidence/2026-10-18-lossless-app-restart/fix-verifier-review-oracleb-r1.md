# Step 8-verifier-fixes re-review round 1: OracleB

Scope: read when the task touches Needs Attention session deletion (F8), View popover placement, or recovery accessibility identifiers (Step 8-verifier-fixes of the lossless app restart plan).
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleB round-1 re-review of the delta

Main agent's note: VF-R1-4 came from a wrong base in the main agent's evidence diff (a round-0 tree whose coordinator hunks were misplaced). Rebuilt against the real round-0 coordinator, round 1 changes the coordinator only in `noteSessionDeleted`; the flagged moves were not code changes.

# Re-review, round 1: Step 8 verifier fixes (`vf-r1-delta.diff`)

## Summary

This delta changes four things:

- **Popover placement.** The anchor-column `positioningRect` is gone. A new pure `placement(region:popover:visibleFrame:preferredEdge:)` picks the preferred outside edge, else the opposite edge, else falls back to the button (`.anchor`). On an outside edge, the popover is shown against the whole region's bounds.
- **Banner accessibility.** The banner now gets a container element before its identifier, which is the correct order.
- **F8 (deleted sessions).** The catalog now exempts surviving-process items from deletion pruning, and `noteSessionDeleted` now also drops the deleted session's released retirements, held-intent notes and unsaved input.
- **Tests.** New tests cover placement, an unreadable record, deletion during startup, quit no longer refusing over a deleted session's unsaved input, and how often change notifications fire.

The core logic is sound. I traced the edge maths against all four placement tests, including the exact-fit and one-point-short cases, and they hold. Moving `retireStartupState(ofDeletedSessions:)` into the startup completion is correct, and the deletion-during-loading test is a good regression guard. **There is no P0 or P1.** What remains: a narrower placement fallback, an untested exemption whose comment may not match behaviour, timing-based notification tests on a noisy host, and an evidence diff that is still partly rebuilt rather than real.

## Status of round-0 findings

| ID | Status |
|---|---|
| VF-1 | Recorded as an assumption. OK. |
| VF-2 | Exemption added, but no test, and its comment may contradict the restriction release (see VF-R1-2). |
| VF-3 | Mostly fixed. The `.anchor` fallback brings the original covering bug back on smaller screens (see VF-R1-1). |
| VF-4 | Resolved for the banner. The Check report's existing container isn't in this delta, so I couldn't check it; it's covered by the verifier re-check. |
| VF-5 | Partly resolved. The coordinator hunks' "before" side still isn't real file content (see VF-R1-4). |
| VF-6 | Tests added and revert-checked. One timing fragility (see VF-R1-3). |
| VF-7, VF-9 | Deferred. OK. |
| VF-8 | Resolved. |

## P2

### VF-R1-1: The `.anchor` fallback brings back bug (2) on common laptop screens
**Evidence:** `AgentRecoveryNativePopover.swift:63-70` checks only `preferredEdge` and its opposite. `:248-251` then falls back to showing against the button.

**Failure scenario:**
1. Take a maximized window on a 1280-pt-wide display with a 620-pt sheet centred in it. That leaves 330 pt on each side.
2. A popover of about 360 pt plus 24 pt of chrome doesn't fit on either side, so placement returns `.anchor`.
3. The View popover opens beside the button and covers the buttons of nearby rows.
4. Clicks there land in the popover's window, so the decision is `.ignore` and the click is swallowed. This is the verifier's original report.

The test `testRegionPlacementFallsBackToTheAnchorWhenNeitherSideHasRoom` treats this as intended. There's a workaround (Escape, then click), which is why this is P2.

**Smallest fix:** Before returning `.anchor`, also try the two edges at right angles to the preferred one: `[preferred, opposite, perp1, perp2]`.
- A sheet hangs from the title bar, so there is usually room below it.
- A banner may have room beside it.

Add one test where only the right-angle edge fits.

### VF-R1-2: The surviving-process exemption is untested, and its comment may not match what deletion does
**Evidence:**
- `AgentRecoveryCatalog.swift:496-498, 502-506`: surviving-process items are kept, but `blockers[sessionID] = nil` still runs for every deleted session.
- `AgentRecoveryCoordinator.swift:617-626`: `noteSessionDeleted` → `retireStartupState` drops the session's startup restriction.

**Failure scenario:** A process that outlived the previous launch is found at startup, so its restriction is startup state (`restrictions = AgentRecoveryRestrictions.from(results)`). When its session is deleted:
- the item stays, as the new code intends;
- the session's blocker and startup restriction are cleared.

The catalog comment says deletion "neither stops its process nor lifts its runtime restriction". If that restriction is keyed by session, it *is* lifted. The workspace's other sessions would then run alongside a still-live agent process, and the kept row would describe a restriction that no longer exists.

None of the new tests covers this, so the revert check couldn't catch it.

**Smallest fix:** Add one test: a session with a surviving process is deleted, and the test asserts both that the item stays and the intended restriction/blocker state. Then either:
- exempt surviving-process restrictions in `retireStartupState(ofDeletedSessions:)` as well, or
- reword the catalog comment to match the VF-1 assumption, if lifting the restriction is intended.

### VF-R1-3: The notification-count tests rely on a fixed 100 ms sleep on a shared, noisy host
**Evidence:**
- `AgentRecoveryCoordinatorTests.swift:3621-3624` (`drainMainActorPosts` = `Task.sleep(100ms)`)
- the exact-count asserts at `:3700-3701`
- the count asserts in the first deletion test

**Failure scenario:** Under load, the coalesced main-actor post hasn't run after 100 ms, so `catalogChanges.value == 0` and the test fails. Or a post left over from setup lands after the counter is installed and pushes the count to 2. Either way the assertion is flaky, not a regression.

**Smallest fix:**
- Wait for the event instead of sleeping: `await Support.eventually { catalogChanges.value >= 1 }`.
- Only then settle briefly before asserting the upper bound (`== 1` or `<= 2`).
- For the setup drain, wait until the coordinator has no coalesced post pending, if that is observable, rather than sleeping.

### VF-R1-4: The coordinator hunks' "before" side still isn't real round-0 file content (VF-5 only partly fixed)
**Evidence:** In `vf-r1-delta.diff`, the "before" side of the `AgentRecoveryCoordinator.swift` hunks could not compile:
- at about `-617`, `private func adoptRecordCommit… return` runs straight into the doc comment of `noteSessionDeleted`;
- at about `-976`, `retireStartupState(...)` sits inside the argument list of `AgentRecoveryStartupReport(`.

Round 0's tests ran, so the real round-0 file compiled. The "before" side therefore came from the old rebuilt evidence, not the real file.

**Impact:** Three hunks (the `// MARK: Live records` move, the `adoptRecordCommit` move, and the `retireStartupState` move) are probably artifacts. A reviewer can't tell which of them are real changes; in particular, whether the startup-ordering change is new in this round.

**Smallest fix:** Regenerate the delta with `git diff <round-0 commit/stash>..<now> -- <files>` from real snapshots, and record that command next to the diff in the evidence directory.

## P3

- **VF-R1-5: On an outside edge, the arrow no longer points at the row** (`AgentRecoveryNativePopover.swift:247`). Showing against `regionView.bounds` centres the popover and its arrow on the region's edge. With several rows, nothing visually ties the popover to the row whose View was clicked. `placement` has already confirmed room on `edge`, so you could position against the anchor's extent along that edge, clamped to the region (the old `positioningRect`). Keep whole-region bounds only as a safety margin if the measured size turns out to be wrong.
- **VF-R1-6: `host.view.fittingSize` is measured before content loads** (`AgentRecoveryNativePopover.swift:242`). Content that grows after its `.task` runs (for example the Check report) can outgrow the room `placement` measured. AppKit then shifts or flips the popover, which can overlap the region. Fix: measure with a stable minimum frame, or add a small margin to `popoverChrome`.
- **VF-R1-7: Deleting a session with notes or unsaved input may announce the change twice** (`AgentRecoveryCoordinator.swift:630-631`). `composerStateDidChange` is followed by `postCoordinatorDidChange`. If the former also posts a coordinator change, this path sends two. Only the no-notes path has a count test. Either fold both into one post or extend `testDeletedSessionNoLongerHoldsQuitOverItsUnsavedInput` to assert the count.
- **VF-R1-8: The quit test bypasses the real deletion path.** `testDeletedSessionNoLongerHoldsQuitOverItsUnsavedInput` calls `noteSessionDeleted` directly rather than `service.deleteAgentSession`. The other tests cover the notification path, so it's fine, but going through the service here as well would cover the full flow at no extra cost.

## Recommendations

1. **VF-R1-1:** Add the two right-angle edges as extra candidates in `placement`, plus one test. Small, and it closes the most likely remaining way for the verifier's covering bug to come back.
2. **VF-R1-2:** Add a test for deleting a session with a surviving process, and make the catalog comment and the startup-restriction release agree, one way or the other.
3. **VF-R1-3:** Replace the fixed sleep in the notification tests with waiting for the event, since the Stakes say the host is noisy.
4. **VF-R1-4:** Regenerate the coordinator part of the evidence diff from real snapshots before saving it as this round's evidence.
5. The P3s are cheap but optional; list them as deferred if not taken. None of this needs another review round. Under the policy this step can be committed once the verifier's live re-check of placement near screen edges and of the accessibility queries passes.
