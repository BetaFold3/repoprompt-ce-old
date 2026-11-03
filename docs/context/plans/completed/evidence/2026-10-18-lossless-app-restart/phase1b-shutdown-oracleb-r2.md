# Phase 1b shutdown re-review 2 — OracleB

Scope: read when the task touches final review of R4 shutdown preservation and window lifecycle fixes.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-shutdown-r2-orac-1A9096`. Frozen tree: `9f938f44cc977a9a0697033c71ff2ee7bfcd56c5`. Each lane received only its own R1 findings and dispositions.

# Oracle Review

# R4 Phase 1b-shutdown: re-review round 2 (independent lane)

**Scope:** static review of tree `9f938f44` against my round-1 tree `1c704e77`. I didn't run anything and took no live action.

## Summary

This round fixes my open findings N1, N2 and N4 and adds failed-removal retention. I found no P0 or P1.

- **N1:** the window's appear/disappear callbacks now sit on a stable `ZStack` host. The admission-dependent content is a branch beneath it.
- **N2:** each view model now runs one Stage A preparation at a time, across requests. A new preparation first waits for the previous one to finish and for its late removals to land, then captures questions.
- **Failed removals:** a question-snapshot removal that fails keeps its IDs and lane. It is retried before the next Stage A writes, and blocks that Stage A if the retry also fails.
- **N4:** the freeze now reaches the composer and run-interaction stores the views actually observe. Typing is refused in the text view before it changes. Image paste is consumed without being attached.

I traced both supersession orderings (window close → app quit, and Cancel → new quit) against the current source, and the N2 fix holds for both. The rest are P2/P3 leftovers, listed below and not looped on.

## Status of my prior findings

| ID | Prior | Status | Reasoning against current source |
|---|---|---|---|
| **N1** | P1 (likely) | **Closed in code.** Real-window acceptance stays owner-deferred (O3); this is not a contest. | `WindowAdmissionLifecycleHost` (`WindowContentView.swift:117-130`) puts `.onAppear` and `.onDisappear` on the `ZStack`, and the title, accessor and sheet modifiers on the host. `ZStack` is a single container, so a branch change below it cannot fire the host's lifecycle callbacks. The production-host fixture (`testAdmissionBranchChangeNeverReportsTheWindowContentDisappearing`) shows: the pending branch disappears, the admitted branch appears, the host's `disappear` count is 0 and its re-`appear` count is 0. The bare-conditional control did not reproduce the failure, so my round-1 premise is unproven. Either way, the fix removes the structural risk and changes nothing else. `handleAppear` and `handleDisappear` are line-for-line moves of the old closures. I see no remaining code failure here. |
| **N2** | P2 | **Fixed** | See the trace below. |
| **N4** | P3 | **Mostly fixed.** Residual P3s listed below (N4-r). | `beginShutdownFreeze` and `endShutdownFreeze` call `publishShutdownFreezeToObservedUI()`. The composer props and the run-interaction snapshot both carry `isShutdownFrozen`. The cards now read `runInteractionSnapshot.isShutdownFrozen`. `textView(_:shouldChangeTextIn:replacementString:)` checks `acceptsEdits` live (`ResizableTextField.swift:~606`), through a closure that reads the view model directly, so a stale `parent` can't make it wrong. |
| N3, N5 | P3 | Deferral accepted | — |
| Others | — | Closed in round 1 | Nothing in this delta changes them. |

### N2 trace

**Window close → app quit**
1. `requestApplicationQuit` re-freezes the window for request A, then calls `supersede`. That call's `endShutdownFreeze(W)` is ignored by the request-ID fence.
2. The app's `prepareSessionsForShutdown` records `freezeRequestID = A` and `predecessor = P1`, then waits on P1.
3. P1's write lands. Because the freeze no longer belongs to P1, it takes the not-still-frozen branch (`AgentModeViewModel+Shutdown.swift:~375-384`). There it enqueues the removal of `X` before P1's task returns.
4. P2 runs `await shutdownQuestionSnapshotWriteTask?.value` (`:~267`), so the removal lands first.
5. P2 then retries any failed removals and upserts `X`. `alreadyStored` doesn't contain `X`, so P2 records `X` as introduced and owns it.

**Cancel → new quit:** same result. `clearShutdownQuestionSnapshotsAfterCancel` runs synchronously before P2 exists, and P1's later stale removal is again waited on before P2 captures.

**Concurrent question timeout:** a question that times out during P2's write converges either way. If the removal lands first, P2's after-write `stillLive` check finds `X` gone and removes it again. If the upsert lands first, the queued removal deletes it.

The mutation check (predecessor set to `nil` causes 10 failures) shows the regression tests actually distinguish the fixed and unfixed behaviour.

## New findings in this delta (P2/P3, listed, not looped)

### N6 — P2: a removal that never succeeds blocks every later quit or close, and Stage A only offers Retry or Cancel

- **Scenario:** a removal fails for a reason that doesn't go away. Every later Stage A in that window then returns the blocker "a question that is no longer pending could not be removed…", and the user's only way out is to force-quit.
- **Evidence:** `retryFailedQuestionSnapshotRemovals` (`:~176-191`); the gate at `performShutdownPreparation` (`:~270-271`); `handle(.preparation, …)` in the coordinator.
- **Why only P2:** I can't see the failure classes `updateQuestionSnapshots` returns. If the record became unreadable, the Stage A upserts would already fail and block anyway, so in practice this needs a new kind of persistent failure.
- **Impact if it happens:** the entry being retried only over-preserves. At worst, a resolved question shows up as a recovery item after relaunch, and Dismiss clears it. No input is lost.
- **Smallest fix (optional):**
  - only block on I/O-class failures, and drop entries whose failure is a fence, generation or tombstone failure; or
  - after one failed retry, record the entry as "stale snapshot, may reappear" instead of blocking.

### N4-r — P3: input paths that can still change the composer during the freeze

1. **Status pills aren't disabled.** In `AgentInputBar.body`, `.disabled(composerUI.props.isShutdownFrozen)` comes before `.overlay { statusPills }`, so the overlay isn't covered. The workflow shown in the pills is part of the composer snapshot.
   - The old placement covered the overlay but wasn't reactive, so this isn't a regression in practice.
   - **Fix:** move `.disabled` after `.overlay`.
2. **Image drop isn't checked.** `handleImageDrop` (`AgentInputBar.swift:~2547`) has no freeze check. A drop whose async load finishes after the freeze still reaches `actions.attachImages`.
   - **Fix:** add the same guard inside the completion, before `attachPreparedImages`.
3. **The view model doesn't refuse composer mutations.** `attachImages`, `commitTaggedFile` and the snippet-palette insertions are refused only if they go through `shouldChangeText`. This depends on the text view's delegate actually being the `Coordinator`, and has only been compile-checked.
   - **Impact:** at worst, a Stage A "kept changing" blocker, or a late attachment lost on Quit Anyway.
   - **Fix:** fold this into the O3 live check.

### N7 — P3: the freeze publishes to the UI of a window that is already being torn down

- `requestApplicationQuit` calls `beginShutdownFreeze` on every participant, including windows already past their own window-close point of no return.
- Before this delta that only set state. Now it also runs `syncComposerUIState()` and `syncRunInteractionUIState()` on a view model that is mid-teardown.
- **Unverified risk:** `makeComposerSubmitTarget` can reach `session(for:createIfNeeded: true)`. That could create a session, or publish to SwiftUI for a closing window — the observation-crash class the spec guards against.
- **Realistic trigger:** closing a window, then pressing Cmd-Q while that close is still in Stage B.
- **Fix:** in `publishShutdownFreezeToObservedUI`, return early when `hasPreparedForWindowClose`. The stores already show the window as frozen from the window close's own freeze.

### N8 — P3: a hung preparation now carries over from Cancel into the next quit

- Before this delta, a new request ran its own preparation alongside the old one. Now it waits for the old one.
- If the old preparation never finishes (for example, a lane write or an in-flight save that never returns), every later Stage A on that view model times out until it does.
- Most hang sources are shared, so the new quit would probably hang anyway. This is a note, not a defect.
- **Fix if wanted:** document it, or race the wait against the request's own expiry.

### N9 — P3: test hygiene in `AgentRecoveryResetBoundaryTests`

1. **Misplaced doc comment.** The new tests were inserted between the doc comment "R4-06: the native user-input card seeds each request…" and `testNativeUserInputCardReseedsRetainedPartialAnswersPerRequest`.
   - That comment now heads the R4-01-R1 tests, and the R4-06 test has none.
   - **Fix:** move the comment back above the R4-06 test.
2. **Blocking test helper.** `RecoveryStoreRunShutdownWriteHold` blocks with a `DispatchSemaphore` inside `writeAtomically`, which probably runs on a cooperative-pool thread.
   - It's fine as written, because release always happens, `defer` also releases, and the hold is single-use. It could starve the pool on a host with very few cores.
   - **Fix (optional):** use an async gate.

## Recommendations

1. **Close N1 and N2.** Neither has a remaining code-level P0/P1. N1 is a structural fix whose original failure was never reproduced. Record it that way, with real WindowGroup / New Window / tab "+" behaviour pending under O3, not as verified live.
2. **Defer N6 and N4-r–N9 as P2/P3.** If you want any of them now, the three one-line fixes are the cheapest:
   - N7: skip publishing when `hasPreparedForWindowClose`;
   - N4-r 1: move `.disabled` after `.overlay`;
   - N4-r 2: add the freeze check in the drop completion.

   The N9 doc-comment move needs no review. If you make the source changes, rerun `AgentRecoveryResetBoundaryTests`, `WindowCloseCoordinatorLifecycleTests` and lint; no further review round is needed under the policy.
3. **Add to the O3 live checklist:**
   - window-close → app-quit supersession;
   - Cancel → immediate re-quit;
   - typing, paste and drop during the freeze, including whether the text view's delegate is the `Coordinator`;
   - status pills during the freeze;
   - New Window / tab "+" staying registered.
4. **No owner escalation is needed from this lane.** No P0/P1 is open, so the step can be committed under the policy once pre-commit checks pass.
