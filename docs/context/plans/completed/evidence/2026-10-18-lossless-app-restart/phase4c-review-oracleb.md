# Step4c initial review — OracleB

Scope: read when the task touches the explicit uncertain-exit repair or its review findings.
Authority: Reference
Last-verified: 2026-10-23

Snapshot `2026-10-23/1802`; preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; chat `step4c-uncertain-exit-in-67C356`; operation `8B4217FB-A019-4633-B570-5B4F06FE76C4`. Full response follows.

# Oracle Review



# Step 4c review: the explicit uncertain exit (`Exit — may reopen`)

**Verdict: acceptable to commit. I found no P0 or P1.** There are two P2s and one P3. One P2 is a contradictory message on the feature's main path and is cheap to fix before commit.

This change lets a `.safeRestart` request offer one explicit way out, `.exitMayReopen`, after Stage B failed and `abandon` returned `.unresolved` (an `arm` was sent and the helper's stop could not be proven). The exit is offered only when this request's current attempt recorded its pre-arm witness. That witness is recorded only after the clean write was acknowledged, all stops were verified, and a ready helper was held, within the attempt's work deadline.

The rest of the diff:
- **Fence:** the `abandon` result is now checked against the current request before any state change, stop observation, or prompt.
- **Keep Waiting:** answers on an admitted prompt show the same prompt again, without repeating `abandon`, the stop observation, or the deadline.
- **Stop proof wins:** a proven helper stop changes `presentationID` before it dismisses the prompt, so a stale answer loses.
- **`relaunchArmed`:** it is now set only after the "still current" check.
- **AppKit:** building the alert and mapping its response were split into static functions so they can be tested.

## Acceptance checks

| Requirement | Result | Where |
|---|---|---|
| Witness is only recorded after the clean write was acknowledged | ✅ | `runRelaunchStep` runs only after `written == true` (fresh write or joined Retry) |
| Witness respects "still current" and expiry | ✅ | `isExpired` is now checked again after `verifyAllStopped` and after `prepare`. The witness is set synchronously right before `arm`. |
| Witness is cleared when it should be | ✅ | Cleared at the start of each Stage A and Stage B attempt, on `cancel`/`supersede`/`complete`, after a `.safe`/`.unresolvedUnarmed` abandon, and on stop-proof recovery |
| A Retry never inherits the witness | ✅ | `startFinalizationAttempt` clears it; covered by the late verify/prepare test |
| Exit completes once, with no extra hooks, marks, deadline or teardown | ✅ | `exitWithUncertainRelaunch` → `complete`. The deadline task was already cancelled in `finalizationFinished`, and the stop observation is cancelled in `complete`. |
| A late `armed` after timeout doesn't change the request | ✅ | The fence now comes before `relaunchArmed = true`. `abandon` waits behind the in-flight `arm` in the driver's queue. |
| Stop proof beats a stale answer | ✅ | `presentationID` is changed before `dismissFailure`. Both orders were checked: proof first means the exit answer is ignored; exit first means the observation sees the request finished. |
| Keep Waiting doesn't restart cleanup, observation or budget | ✅ | `continue` inside the same presentation |
| Never eligible in Stage A, a window close, a plain quit, a missing clean acknowledgement, a failed stop proof, or an unarmed abandon | ✅ | `admitsUncertainRelaunchExit` checks stage, scope and reason; the witness is never set on those paths |
| Dismissals never become an exit | ✅ | The unresolved case is decided first; only `.alertSecondButtonReturn` on an admitted prompt maps to the exit |
| Helper protocol, driver and gates unchanged | ✅ | Neither `ProcessRelaunchHelper.swift` nor `AppRelaunchCoordinator.swift` is in the diff |

## Findings

### P2-1: In the lost-`armed` case, the exit prompt contradicts itself

- **Scenario:** Safe restart, Stage B, `arm` is sent, and the `armed` acknowledgement is lost.
  - R4 sets `expiry` equal to `workExpiry` (8 s minus the 1 s cleanup reserve). The driver's `arm` waits for the acknowledgement until that same `workExpiry`.
  - After that, `resolveLostArm` spends up to the rest of the cleanup reserve (up to 1 s) trying to stop the helper.
  - So R4's deadline task fires first, in practice every time this happens.
  - `finalizationFinished` sees `timedOut` and a set `cleanWrite`, and replaces the blockers with `restartTimeoutMessage`.
- **What the user sees:** the details line says "RepoPrompt could not confirm within 8 seconds that it recorded a clean exit, that every agent stopped, … Try again, or quit without restarting."
  - The text right under it says "your work was saved, a clean exit was recorded, and every managed agent and tool process was verified stopped."
  - The only buttons are Keep Waiting and Exit — may reopen, so "Try again, or quit without restarting" points at options that aren't there.
- **Impact:** The consent dialog's main path shows contradictory and inaccurate text. What the action does is still correct and honest ("may reopen, or may not"), so this is P2, not P1.
- **Evidence:**
  - `AgentLifecycleShutdownCoordinator.finalizationFinished`: `if timedOut, request.cleanWrite != nil { blockers = [ … restartTimeoutMessage … ] }`
  - `armDeadline`: `expiry = start + deadline - reserve`
  - `WindowStatesManager.makeLifecycleShutdownFailureAlert`: the `offersUncertainRelaunchExit` branch
  - The test `testSafeRestartTimeoutWhileArmIsInFlightKeepsTheWitnessAndFencesTheLateArm` asserts `messages.first == restartTimeoutMessage` alongside `[.exitMayReopen]`, so the fixture locks in the contradiction.
- **Smallest fix:** In `finalizationFinished`, when `relaunchArmSafetyProof` equals this request and attempt (the timeout landed after the witness), use a dedicated message instead of `restartTimeoutMessage`. For example: "RepoPrompt could not confirm within 8 seconds that its restart helper armed." Then update that one test assertion.

### P2-2: The tests never run the real driver through the uncertain-exit path

- **Scenario:**
  - `FakeRelaunch.abandon` returns whatever `.unresolved` it was scripted with, whether or not `arm` was sent.
  - So the "never eligible" tests for a failed stop proof, a failed or pending clean write, and Stage A exercise the coordinator's witness check only as defence in depth. With the real driver, those paths would return `.unresolvedUnarmed`.
  - The one test that composes the real `AppRelaunchCoordinator` (`testSafeRestartComposedHelperBudgetIsAbsolute…`) covers Stage A only.
  - So nothing checks the real timing of lost-ack → timeout → driver `.unresolved` (via `armWasSent`) → admitted prompt → exit or stop proof. That is also the timing that hides P2-1.
- **Impact:** The fake tests aren't wrong; they test the coordinator gate. But the main production sequence is only covered by reasoning.
- **Evidence:** `FakeRelaunch.hooks.abandon`; `AppRelaunchCoordinator.abandonCurrent` (`armWasSent ? .unresolved : .unresolvedUnarmed`).
- **Smallest fix:**
  1. Add one composed test that uses a `SilentRelaunchChannel` variant which replies `ready` but never `armed`.
  2. Assert that the prompt is admitted, the message is correct after the P2-1 fix, the exit completes once, and `driver.retainsHelper` stays true.
  3. Optionally, make `FakeRelaunch.abandon` downgrade to `.unresolvedUnarmed` when it never saw `arm`, so the fake matches the driver's contract.

### P3-1: The Keep Waiting loop spins the main thread if `WindowStatesManager` is gone

- **Scenario:**
  - The `presentFailure` fallback (taken when `self` is nil) returns `.cancel` for unresolved prompts without suspending.
  - On an admitted prompt, the coordinator's `while true` then calls `continue` straight away.
  - Both closures run on the main actor, so no real suspension happens and the main thread spins forever.
  - The coordinator stays alive because the `Task` holds a strong reference after `guard let self`.
- **Impact:** Not reachable in normal production, because the manager is the long-lived owner of `lifecycleShutdown`. That makes this hardening, so P3 under the policy.
- **Evidence:** `WindowStatesManager+LifecycleShutdown.swift`, the `presentFailure` fallback; the `present` loop `continue` on `offersUncertainRelaunchExit`.
- **Smallest fix:** Have the fallback return the ignored sentinel only after a suspension, e.g. `await Task.yield()` or a short sleep. Or have the coordinator `return` instead of `continue` when the presenter returns without having shown anything.

## Notes, no action needed

- In `admitsUncertainRelaunchExit`, `request.isPastPointOfNoReturn` repeats what `isCurrent(..., phase: .finalizationFailed)` already guarantees. It's harmless.
- `handle(_, .exitMayReopen)` → `break` would leave the request with no prompt if it were ever reached. It isn't, because `present` filters that choice first. A comment or `assertionFailure` would make the unreachability explicit.
- An unadmitted unresolved prompt (OK only) still returns after one answer and is not shown again. That matches the historical no-choice behaviour and is out of scope here.
- The validation you described is fixture-level and compile-only: no real helper run, no visible UI, no live qualification. That matches the stated gating, and recovery activation is still OFF (`appRelaunchCoordinator` is `nil` in production).

## Recommendations

1. Fix **P2-1** before commit. It's a one-branch message change plus one test assertion, and it's what the user sees on the feature's main failure path.
2. Add the composed real-driver Stage B test from **P2-2**, either in this step or as the first item of the Step 4 live-qualification prep. It is the only check that runs the real lost-ack timing end to end.
3. Defer **P3-1** with a status-line note, or fix it with a one-line `await Task.yield()` in the fallback.
4. Keep the gate as it is: activation OFF and final live qualification pending. Nothing here needs an owner decision, since no P0 or P1 is open.
