# Step 7-F2 — OracleB re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F2 (blocked Send-now feedback for scheduled sends) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F2, local fix-f2-r1-delta.diff and fix-f2-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review



# Re-review round 1: Step 7-F2 (blocked Send-now feedback)

## Summary

The delta makes four changes:

- **Predicate loop.** It restores the pre-F2 membership in `AgentModeViewModel.scheduledSendRecoveryBlocker`. Bound tabs are listed by session ID, and unbound tabs mark the blocker `unattributed`.
- **Gate.** The new-session gate in `evaluatePass` now walks the hosts once and blocks when the merged blocker is non-nil. The second walk, the `?? unattributed` fallback and the internal default witness are removed.
- **UI.** Dashboard rows now get the recorded blocker and reload when it changes. Two banner messages are reworded, and the banner height now counts the action-error line.
- **Tests and docs.** It adds a regression test for unbound tabs and an end-to-end crash-hold test on a real host, and updates the docs and evidence.

I found no new P0 or P1. Admission is the same as before the delta, and the gate still matches the handoff-time check for both real conformers.

## Verification of my findings

| ID | Disposition | Verdict |
|---|---|---|
| **F2-R1** (conditional P1) | Answered and fixed | **Closed.** The guard in `scheduledSendHasUnresolvedRecovery` (`guard let sessionID = session.activeAgentSessionID else { return false }`) means the first-pass rewrite did not change admission, so my condition was never met. The restored loop (`where session.activeAgentSessionID != sessionID && scheduledSendHasUnresolvedRecovery(session)`) is exactly the HEAD predicate. Bound tabs go to `unresolvedOpenSessionIDs` and unbound ones set `unattributed`. The new test pins the reachable behavior: an unbound tab doesn't block, and once bound it is listed and excluded as the schedule's own session. Leaving the `unattributed` branch untested, with no test-only seam, is acceptable. I don't contest. |
| **F2-R2** | Fixed | **Closed.** Both dashboard paths (hydrated and live) pass `recoveryBlocker(scheduleID:)`, the view reloads on `.agentScheduledSendDispositionDidChange`, and the test checks that the row and the banner show the same text. The listed early returns of `sendScheduledSendNow` all already return a message. One test weakness is listed below. |
| **F2-R3** | Fixed | **Closed.** The wording no longer promises a fix that may not apply. |
| **F2-R4** | Fixed | **Closed.** See the equivalence check below. |
| **F2-R5** | Fixed | **Closed.** |
| **F2-R6** | Fixed | **Closed** at code level. Rendered layout is unverified; see P3-2. |
| **F2-R7** | Added | **Closed.** This is a real composition: a real startup crash hold, the real scheduler and view model, Run alongside stays blocked, Dismiss is a no-op, It stopped leads to exactly one dispatch, and a re-evaluation causes no second dispatch. |

### Is admission identical, and consistent with the handoff check?

- **Old gate:** `registrations.contains { $0.host?.hasUnresolvedRecoverySession(ws, excluding: s) == true }`
- **New gate:** `registrations.compactMap { $0.host?.scheduledSendRecoveryBlocker(ws, excluding: s) }.first != nil`, then merged.

These are equivalent when, for every host, `hasUnresolvedRecoverySession == (scheduledSendRecoveryBlocker != nil)`:

- **`AgentModeViewModel`:** `hasUnresolvedRecoverySession` is literally `scheduledSendRecoveryBlocker(...) != nil`. The blocker returns `nil` unless `isBlocking`, and its inputs match HEAD:
  - `unresolvedSessionSummary` is `!isEmpty`, which equals `hasUnresolvedSession`;
  - `hasRecoveryAction`;
  - the workspace-scoped runtime check;
  - the open-tab loop.
- **`FakeScheduledSendHost`:** defined the same way.
- **Released hosts:** a deallocated host is `nil` in both versions and does not block.
- **Short-circuit:** `if record.isNewSessionStart, let blocker = …` still calls the hosts only for new-session starts, as before.

The handoff validator (`blocksOnUnresolvedRecovery`) still asks each host `hasUnresolvedRecoverySession`. That is the same predicate for both conformers, so the gate and the handoff check agree today. The only way they could drift is the leftover protocol default (P3-1).

## Findings

None are P0 or P1. Under the policy, these are listed and not looped on.

### P3-1: The leftover `hasUnresolvedRecoverySession { false }` default lets the gate and the handoff check drift apart
- **Where:** `AgentScheduledSendCoordinator.swift`, protocol extension (about line 511).
- **Scenario:** a future conformer implements `scheduledSendRecoveryBlocker` but relies on the default `hasUnresolvedRecoverySession`. The evaluation gate then blocks, but the handoff-time check passes everything.
  - The two current conformers are consistent, so this is hypothetical.
  - It is also why the docs line "Hosts derive `hasUnresolvedRecoverySession` from that blocker" holds by convention rather than by construction.
- **Smallest fix:** change the default body to `scheduledSendRecoveryBlocker(inWorkspace:excluding:) != nil` and delete the two identical conformer implementations. This replaces an existing member's body, so it doesn't trip the `extensionAccessControl` lint again.
- **Alternative:** have the handoff validator call `workspaceRecoveryBlocker(...) != nil`.

### P3-2: The banner reserves only one line (14 pt) for the action error, but some refusal texts are long
- **Where:** `AgentScheduledSendBanner.swift`, `bannerHeight`.
- **Scenario:** some refusal texts are long, for example `.transferHeld`: "The last send of this message is still being checked. It won't be sent again until that finishes." At a narrow composer width, if the action-error `Text` allows more than one line, the second line is still clipped by the fixed frame.
- **Impact:** cosmetic, and the rendered UI is unverified.
- **Fix:** give the action error `.lineLimit(1)` plus `.hoverTooltip(actionError)`, matching the blocked message. Alternatively, reserve 26 pt for it.

### P3-3: The dashboard's "nil after dispatch" assertion may pass vacuously
- **Where:** `AgentScheduledSendDispatchTests.swift`, the end of `testSendNowOnRecoveryBlockedNewSessionShowsWhyAndDispatchesOnceWhenResolved`.
- **Scenario:** `dashboard.rows.first { … }?.props?.recoveryBlockedMessage` is `nil` whenever the row has been removed after dispatch. The assertion then checks nothing.
- **Fix:** either assert that the row still exists before checking the message, or assert that the row is gone and say so.

### P3-4: The end-to-end test's "exactly once" depends on what the stub's `.stale` outcome does
- **Where:** `AgentRecoveryStartupCompositionTests.swift`, `testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce`.
- **Scenario:** the injected starter returns `.stale(reason:)`. Whether a later re-evaluation can dispatch again therefore depends on how `.stale` retires the revision, not on the accepted path. The coordinator and dispatch tests do cover once-only with an accepted (`.sent`) outcome, so the risk is low.
- **Fix (optional):** return `.sent`, or note in a comment why `.stale` was chosen.

### P3-5: An empty-but-non-nil blocker would close the gate
- **Where:** `AgentScheduledSendCoordinator.swift`, `workspaceRecoveryBlocker`.
- **Scenario:** the gate trusts any non-nil value. A host that returns a non-blocking blocker, such as `AgentScheduledSendRecoveryBlocker()`, closes the gate. This fails safe and is only reachable by breaking the protocol contract, for example through the fake host's `recoveryBlockers` map.
- **Fix (optional):** filter with `.filter(\.isBlocking)` in `workspaceRecoveryBlocker`.

## Recommendations

1. **No P0 or P1 is open, and I don't contest any disposition.** On my lane, the step can be committed once the pre-commit checks pass.
2. **Before committing, fix the failing `Scripts/check-agent-context` run.** It reports reachability errors for the three F2 evidence documents. Link them from the spec's Step 7-F2 status line. This is a docs/status edit, so it needs no review, but it is a pre-commit check.
3. **Fix P3-1 if it's cheap.** It's a one-line default plus deleting two duplicate implementations, and it turns "the gate and the handoff check are one predicate" from a convention into a guarantee. Rerun the focused suites afterward; no re-review is needed.
4. **Either apply P3-2 to P3-5 now or list them as deferred.** Each is a single edit.
5. **Still outstanding:** the rendered UI (banner wrap at the narrowest width, tooltip) and one live check of the recovery-blocked banner, both already listed as not run. They are advisory and not a blocker.