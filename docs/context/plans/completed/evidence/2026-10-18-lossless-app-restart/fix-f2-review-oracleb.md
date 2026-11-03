# Step 7-F2 — OracleB initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F2 (blocked Send-now feedback for scheduled sends) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F2, local fix-f2-review.diff, worker report, code context); preset identity verified from the result.

# Oracle Review



# Review: Step 7-F2 — feedback when Send now is blocked

## Summary

The fix leaves the gate alone and adds a way to see it. `confirmAndSendNow` now returns an `AgentScheduledSendDisposition`: `rejected` with a reason for every early return, `blocked` with an itemized blocker, or `progressing`. The scheduler records an `AgentScheduledSendRecoveryBlocker` only at the two places where recovery decides: the new-session gate and the own-session busy branch. It posts a change notification, and the banner shows plain wording such as "choose It stopped (not Dismiss)". `hasUnresolvedRecoverySession` is rewritten on both sides (the recovery coordinator and the view model) as "the itemized blocker is not empty".

I checked the worker's claims against the diff. The gate condition and the branch it guards are unchanged. Consent is still per revision (`confirmedOverrides` is untouched). In the tests, Run alongside stays blocked, Dismiss leaves the gate in place and It stopped clears it (the composition test uses the real host), and one dispatch follows once the blocker clears. All four early returns of `confirmAndSendNow` are covered. Showing the reason on refresh is cheap: the banner props do a few dictionary lookups.

One behavior change slipped into the view model's rewrite of the predicate. The remaining findings are wording, the dashboard surface, and design details.

## P1

None.

## P2

### F2-R1: The view-model rewrite of the predicate can let new-session starts through
- **Evidence:** `AgentModeViewModel+ScheduledSend.swift`, new lines ~2696–2701 (old ~2652–2654).
  - Old code: `session.activeAgentSessionID != sessionID && scheduledSendHasUnresolvedRecovery(session)`. A tab whose `activeAgentSessionID` is `nil` passes the `!=` test, so it still counted.
  - New code: `guard let openSessionID = session.activeAgentSessionID, … else { continue }`. A tab with a `nil` ID is now skipped.
- **Failure scenario:** a tab has unresolved recovery but no bound `activeAgentSessionID` (for example during binding or rebinding). Before, it kept new-session starts in the workspace paused. Now `hasUnresolvedRecoverySession` returns `false` and the gate lets the start through.
- **Impact:** this is a recovery admission gate, which the safety fences say every fix must keep. The worker report says the rewrite "itemizes the same inputs". I could not confirm from the attached code whether `scheduledSendHasUnresolvedRecovery` can be true without a bound ID. If it can, this is P1.
- **Smallest fix:** keep the old predicate for unbound tabs:
  ```swift
  for session in sessions.values where session.activeAgentSessionID != sessionID
      && scheduledSendHasUnresolvedRecovery(session) {
      if let id = session.activeAgentSessionID { blocker.unresolvedOpenSessionIDs.insert(id) }
      else { blocker.unattributed = true }
  }
  ```
  Add one test with an unbound tab that has unresolved recovery.

### F2-R2: Send now from the Scheduled Messages dashboard is still silent when blocked
- **Evidence:**
  - `AgentModeViewModel+ScheduledSend.swift` ~975–981: `.blocked` maps to `nil`, on the assumption that the banner shows the reason persistently.
  - The worker's own open question says dashboard rows don't receive the blocker.
- **Failure scenario:** an overdue new-session start in a workspace with crash holds. The user clicks Send now in the dashboard. Consent is recorded, nothing dispatches, and the dashboard shows nothing. This is the F2 symptom again, on a second surface. (This assumes the dashboard goes through the same `sendScheduledSendNow`; that wasn't in the attached code.)
- **Impact:** the workflow breaks in the same way as F2, though the user can work around it by opening the session to see the banner.
- **Smallest fix:** the one-argument change the worker describes. Pass `recoveryBlocker(scheduleID:)` into the dashboard row props and render `recoveryBlockedMessage` there. If that's out of scope, list it as deferred in the status line.

### F2-R3: Banner wording sends users to actions that don't help
- **Evidence:** `AgentComposerUIModels.swift` `recoveryBlockedMessage(for:)`, about lines 280–286.
  - The restricted-session message says "Open it or restart RepoPrompt to check again." Of the three restriction kinds, only a held transfer lifts when the session is opened. Unknown status and duplicate destination lift only at the next launch, as the worker notes.
  - The `destinationUnresolved` message says "Review it in Needs Attention…". When the schedule's own session is restricted with unknown status or a duplicate destination, Needs Attention has nothing that resolves it.
- **Impact:** the user opens the session, nothing changes, and the banner keeps saying the same thing. Restarting fixes it, so this is easy to work around.
- **Smallest fix:** drop "Open it or" from the restricted message, so it reads "…Restart RepoPrompt to check again." Alternatively, carry the restriction kind on the blocker and word each kind separately. Ask the owner about the wording, as the worker already proposes.

## P3

### F2-R4: The gate and the shown reason come from two separate host calls
- **Evidence:** `AgentScheduledSendCoordinator.swift` ~1899–1906.
  - The gate still calls `hasUnresolvedRecoverySession` on every host.
  - The recorded reason then calls `scheduledSendRecoveryBlocker` on every host again.
  - The `?? AgentScheduledSendRecoveryBlocker(unattributed: true)` fallback exists only because the two might disagree.
- **Effects:**
  - Each gated candidate on each pass walks the hosts twice. The old early exit is gone: the view model now always builds full sets of crash holds, restrictions and sessions.
  - "Non-nil exactly when true" is only a doc comment on the protocol. Nothing enforces it.
- **Smallest fix:** compute `workspaceRecoveryBlocker(...)` once and gate on it being non-nil. Admission is identical for both conformers, and the shown reason then comes from the same call that admission used.
- **Dead code:** the internal default witness in the protocol extension can't be seen from the app module, and both conformers implement the method themselves. Remove it.

### F2-R5: `.rejected` can be returned after consent was installed
- **Evidence:** `AgentScheduledSendCoordinator.swift` ~1148–1149. `return disposition(scheduleID:)` runs after `evaluate()`, and `disposition` checks `sendNowRefusal` first.
- **Failure scenario:** the `evaluate()` triggered by `confirmAndSendNow` installs a pending confirmation obligation, for example after a clock change or wake. The call then returns `.rejected(.confirmationPending)`, but `confirmedOverrides` already holds the consent.
- **Impact:** the message the user sees ("confirm it once more") is correct. Because consent is per revision, the stale override can't dispatch the message on its own. Only the documented contract is wrong: the enum docs say `rejected` means no consent was installed.
- **Smallest fix:** change the doc comment to "no consent applies" (or "Send now must be repeated").

### F2-R6: Banner height is fixed and doesn't count the error line
- **Evidence:** `AgentScheduledSendBanner.swift`, `bannerHeight` (~304). It adds 26 pt for the blocked message but nothing for `actionError`.
- **Failure scenario:** a 2-line `recoveryMessage`, a 2-line blocked message and a refusal error all at once can clip inside the fixed frame. The worker did not check the rendered layout.
- **Smallest fix:** add about 14 pt when `actionError != nil`, or replace the fixed height with `minHeight`.

### F2-R7: Test gaps against the spec's test list
- No end-to-end test with the real host goes from a real crash hold, through the banner text "It stopped (not Dismiss)", to It stopped, to exactly one dispatch.
  - The composition test checks only the predicate.
  - The dispatch test uses another session's transfer hold, so it exercises `unresolvedOpenSessionIDs` and its generic wording rather than the crash-hold message.
- No test covers the unbound-tab case from F2-R1.
- I couldn't check `sendScheduledSendNow`'s own early returns before `confirmAndSendNow` (resync, the `.dispatching` refusal, a missing coordinator) from the attached slices. Make sure none of them returns `nil` without doing anything.

## Recommendations

1. **Fix F2-R1 before committing.** It costs one line and keeps the recovery admission fence exactly as it was.
2. **Do F2-R4 in the same edit.** Gating on the computed blocker makes the gate and the shown reason one call and removes the second host walk on every pass. Delete the dead default witness at the same time.
3. **Fix F2-R2 (dashboard) and F2-R3 (wording) now if cheap; otherwise list them under `deferred:`.** F2-R3 is reasonable to put to the owner with the worker's question, recommending "Restart RepoPrompt to check again" as the safe wording.
4. **Fix F2-R5's doc comment and F2-R6's height now; they're trivial.** Add the F2-R1 regression test. If a real-host crash-hold → It stopped → one-dispatch test (F2-R7) is cheap to build from the composition harness, add it too.
5. **Before marking the step done,** look at the rendered banner at the narrowest composer width in a quick live run with a crash hold.