# Step 7-F1 — OracleB initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F1 (scheduled follow-up handoff hold and terminal attribution) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F1, fix-f1-review.diff kept locally under prompt-exports/restart-fixes/, worker report, code context); preset identity verified from the result.

# Oracle Review



# Review: Step 7-F1, scheduled follow-up handoff hold and terminal attribution

## Summary

The diff fixes the F1 race on three layers.

1. **Explicit outcomes from `startRun`.** Every exit before a runner owns the input now returns `.failed` or `.stale` for every provider. This covers the knowledge-profile and workspace failures, the DEBUG Oh My Pi exits and the unreachable `guard let handoff`. A `nil` now means "a runner owns the input". Codex returns the same values as before.
2. **A hold instead of a withdrawal.** When a non-Codex scheduled dispatch gets a runner-owned `nil`, it now holds as `.awaitingProviderEvidence`. A new in-memory registry on the lane tracks each deferred run-start handoff: `pending`, `notHandedOff(message)`, or removed once committed. Settling without a commit posts the lane's existing settle notification. The re-check withdraws and fails the schedule only on a recorded `notHandedOff` while the intent is still `queued`.
3. **Terminal attribution bound to the attempt's own input.** Each run attempt now names its input's user item. If that item is gone, nothing is attributed. Steering moves the attribution to the newer input.

It also adds content-free `os.Logger` reasons for the identical "…delivery could not be recorded…" texts.

The core logic matches the spec's Fix list and its "Do not change" list. I found no P0/P1 that I could confirm from the attached code. The findings below are mostly holes in the guards, one Codex-safety assertion I couldn't verify, and test-realism gaps. One finding (F1-R2) would be a P1 if a lane survives tab replacement.

## P2

### F1-R1: Hard-coded `runnerOwnsInputOnNil: true` on the second submit path may reach Codex
- **Evidence:**
  - `AgentModeViewModel+ScheduledSend.swift:2138` derives the flag from the agent: `session.selectedAgent != .codexExec`.
  - `:2198` hard-codes `true` after the `if session.selectedAgent == .codexExec {` block at `:2142`.
  - The attached slice doesn't show whether that Codex block always returns, or whether it builds a fallback context and falls through to the shared `startRun` call.
- **Failure scenario:** suppose the Codex block falls through. A Codex `nil` with a never-dispatched intent then holds, instead of taking the old explicit failed-before-handoff path. The re-check finds no registry entry (`.notDeferred`), so the R9 repair transfers it as `savedInQueue`.
- **Impact:** Codex behaviour changes silently, which the spec forbids ("Codex semantics are unchanged"). Even if the Codex block does return today, the asymmetry is fragile.
- **Smallest fix:** compute the flag the same way in both places (`session.selectedAgent != .codexExec`, captured before the `await`). Also make the field non-defaulted so every construction states it.

### F1-R2: A successor owner's repair ignores the registry; the stand-in test doesn't cover it
- **Evidence:**
  - `resolveScheduledSendTransfer` (`ScheduledSend.swift` ~1597) goes straight to `performScheduledSendTransferRepair` under an `.awaitingRecovery` hold. It never calls `settleScheduledDeferredHandoffIfNeeded`.
  - `testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput` stops after the old owner declines. No successor owner is ever hydrated.
- **Failure scenario:**
  1. The tab is replaced or reopened while the old runner's handoff is still `.pending`.
  2. The hydrated owner runs R9, sees a `queued` intent, and completes `savedInQueue`, clearing the schedule.
  3. The old runner then commits through `heldLane`.
  4. If the lane object survives replacement, `issuingLaneIsCurrent` passes and the input is delivered while it is also presented as saved queued input.

  If replacement always retires the lane, the commit is refused (`.refused(.laneRetired)`) and the outcome is benign.
- **Impact:** this would be a P1 (possible duplicate delivery) if the lane survives. I couldn't confirm either way from the attached code.
- **Smallest fix:** in `resolveScheduledSendTransfer`, look up the linked intent's registry entry first. Defer while it is `.pending`; apply the no-handoff settlement when it is `.notHandedOff`. Add a test that hydrates a successor while `.pending`.

### F1-R3: Indeterminate preconditions fall through to the R9 repair (the code doesn't match its own doc)
- **Evidence:**
  - The first guard of `settleScheduledDeferredHandoffIfNeeded` (`ScheduledSend.swift` ~1677-1686) returns `.notDeferred` for every one of these: owner not current, no lane, retired lane, lane/session mismatch, `readRecord` failure, and zero or multiple linked intents.
  - The caller then runs `performScheduledSendTransferRepair`.
  - The worker report says "Owner not current → `.pending`", but only the second guard does that.
- **Failure scenario:** a transient `readRecord` failure, or an owner change, while the registry says `.pending`. The R9 repair decides on a still-`queued` intent, which is exactly what F1 forbids ("never infer from a record read"). In practice R9 probably re-reads and holds, or refuses a non-current owner, but that is incidental.
- **Smallest fix:** return `.pending` (decide nothing) when the owner isn't current or the lane is unavailable. Reserve `.notDeferred` for "record read succeeded and the linked intent has no registry entry, or has been dispatched".

### F1-R4: The untracked fallback pins attribution at prepare time and can regress to an earlier turn
- **Evidence:** `AgentProviderHandoff.swift` ~119, in `attributedUserItemID(of:in:)`:

  ```swift
  constituents.last(where: { $0.userItemID != nil })?.userItemID
      ?? session.items.last(where: { $0.kind == .user })?.id
  ```

  The fallback is captured inside `prepareRunStart`/`begin`, before the runner starts.
- **Failure scenario:** any route with untracked input, or durable constituents without a `userItemID`, where the user item is appended after the handoff is prepared. The attribution then names the previous user item. Before this change, `items.last(.user)` was read at terminal time and found the new item.
- **Impact:** the outcome (interruption stamp, terminal join, process-run retention) lands on the earlier turn. That is the F1 symptom class, now reachable from a different direction.
- **Smallest fix:** drop the fallback. Name an input only when a constituent carries `userItemID`; otherwise pass `nil` and keep the legacy behaviour. That is also what the spec asked for: bind to "the attempt's `userItemID`".

### F1-R5: The barrier test doesn't model the F1 shape (an earlier completed turn) or check `terminalState`
- **Evidence:** `testTerminalBarrierAttributesTheAttemptsOwnInputNeverANewerQueuedUserItem` (lifecycle tests ~5865).
  - In the `ownItemRemains == false` case the transcript is just `[newer]`, so no earlier turn exists that could be wrongly failed.
  - It asserts only `interruption`, using `.cancelled`/`.appQuit`.
- **Gap:** F1's observed damage was the previous completed turn rewritten to `terminalState: failed` with an error item. The test covers neither the `.failed` terminal nor the previous turn's `terminalState`.
- **Smallest fix:** add a case with transcript `[earlier(completed), own]` where `own` is removed and the terminal is `.failed` with error text. Assert that `earlier.terminalState == .completed` and that nothing is attributed.

### F1-R6: No test runs the real runner with the scheduled hold; shutdown during preparation is untested
- **Evidence:**
  - The scheduled tests use `StarterProbe.deferredRunStarter`, which plays the runner by hand. Several also call `recheckScheduledSendTransferAwaitingEvidence` directly, so the observer wiring isn't exercised there.
  - The real-runner tests (`testClaudeDeferredStart…`, `testACPDeferredStart…`) check only the lane registry, not the view model's hold.
  - The spec's Tests list includes "shutdown during preparation"; the worker didn't run it.
- **Risk:**
  - The real `notifyScheduledSendRunStateChanged` timing relative to the runner's `finalize` is not proven end to end.
  - At quit, a cancelled preparing runner settles `notHandedOff`, and the live owner then withdraws the intent and fails the schedule inside the quit window. These are two separate durable writes. Each intermediate state looks recoverable (withdrawn intent with no attempt → `.rolledBack`), but that is unproven.
- **Smallest fix:** add one scheduled-send test driving the real Claude runner with the gated `expectedPIDPolicyArmer`, covering both the accept and the acquire-fail outcome. Add one test that cancels with `.appQuit` during preparation and asserts the persisted state after each write.

### F1-R7: The caller audit for the `nil` → `.failed` contract change is thin
- **Evidence:** the worker report says "Every caller that receives `.failed`/`.stale` treats it as not handed off" but names only `startFollowUpRun`, the ACP follow-up path and the composer path.
- **Unlisted callers:**
  - other `startRun` callers: MCP/delegated starts, remote dispatch, held-input retry, queued drain;
  - `stagedInputStartDisposition`;
  - callers that may present `.failed(message)` themselves after `failBeforeProviderStartup` has already appended an error item.
- **Risk:** for these, non-Codex workspace and knowledge failures used to look like "started". Codex already had this combination, so most handlers are probably fine.
- **Smallest fix:** grep every `startRun(` call site, list each one's handling of `.failed`/`.stale` in the evidence file, and confirm no duplicate error item and no re-queue loop.

## P3

- **F1-R8: Registry entries are not cleaned up on several paths** (`AgentRecoveryCoordinator.swift` ~3053-3096). Every non-scheduled deferred handoff that settles without a commit leaves a `.notHandedOff` entry for the lane's lifetime, because only scheduled code clears entries. Two scheduled paths also leave entries: the `scheduledHandoffWasRevoked` branch never clears, and the withdraw-failure branch in `settleScheduledDeferredHandoffIfNeeded` returns `.resolved` without clearing. Intent IDs are unique per attempt, so this is harmless today. Fix: clear at the end of `settleRunInputScope` for non-scheduled origins, or clear in those two branches.
- **F1-R9: The user-facing failure text can be internal or contradictory.** `lastFailureMessage` takes whatever string was passed to `noteNoHandoff`:
  - the raw `"run attempt not recorded: \(failure)"`;
  - reason codes such as `recovery_dispatch_target_changed`;
  - `CommitFailure.userText` ("…It stays saved."), shown after the intent was withdrawn and the bubble removed.

  Fix: map the message through a small allowlist, or always use `scheduledNotHandedOffMessage` and log the source reason.
- **F1-R10: A doc comment is now attached to the wrong class** (`AgentProviderHandoffTests.swift` ~1734). `F1ArmerArrival` was inserted below the existing `/// Suspends one lane transaction until released…` comment. That comment now sits on `F1ArmerArrival`, and `DispatchCommitGate` has lost its doc. Move the new class above the comment.
- **F1-R11: `ScheduledSubmitResult.runnerOwnsInputOnNil` defaults to `false`.** This hides the early-return construction at ~2133. Make it a required `let` (see F1-R1).
- **F1-R12: A tab reopened in the same process can resolve differently from a live owner.** The live owner fails the schedule on `notHandedOff`, while a hydrated owner's R9 path transfers `savedInQueue`. No input is lost either way, but users see two outcomes for the same event. The same fix as F1-R2 removes the difference.

## Recommendations

1. Fix F1-R1 before commit (cheap, and it protects the "Codex unchanged" fence), then rerun `AgentScheduledSendDispatchTests`.
2. Find out whether tab replacement retires the lane, which decides F1-R2's severity. Either way, make `resolveScheduledSendTransfer` check the registry, and tighten the guard mapping in F1-R3. These are small changes inside one function.
3. Remove the prepare-time fallback in `attributedUserItemID` (F1-R4), and extend the barrier test with the real F1 shape (F1-R5).
4. Add the real-runner scheduled-hold test and a test that quits during preparation (F1-R6). Record the `startRun` call-site audit in the evidence file (F1-R7).
5. Batch the P3s cheaply. If the evidence files stay tracked, resolve the guardrail allowlist question with the owner.