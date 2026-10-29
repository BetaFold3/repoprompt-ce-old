# Step 4c planning — OracleB

Scope: read when the task touches the explicit uncertain-exit policy for a retained restart helper.
Authority: Reference
Last-verified: 2026-10-23

Verified returned preset OracleB (7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C), explicit selection; chat helper-uncertainty-resol-FA43CB; operation 4411A735-E31F-4EE6-9E0F-ADDACDCE1D9E; completed/ok. Both lanes received identical source and request with the full review policy. Original export: /Users/tnguyen/workspace/repoprompt-ce-personal-touch/prompt-exports/oracle-plan-2026-10-23-174642-helper-uncertainty-r-0a2d.md. Complete response follows; trailing whitespace normalized and Markdown hard breaks expressed as explicit line breaks.

# Oracle Plan



# Restart safely: let the user exit explicitly when the relaunch helper may still be armed

## 1. Summary

Today, an application `.safeRestart` request in Stage B can end in a state with no way out. This happens when the helper's `arm` was sent, its acknowledgement was lost, and the bounded stop produced neither a correlated `aborted` nor an observed exit of the exact child. The prompt then offers no choices, any answer is ignored, and the request never finishes, so the app can't quit. A later stop proof already brings back the normal choices (Step 4b).

**Recommended fix.** Add one terminal choice, `.exitMayReopen` ("Exit — May Reopen"), plus a default "Keep Waiting" button that shows the same prompt again.

- **When it is offered.** Only on an application, `.safeRestart`, Stage B prompt whose `abandon` returned `.unresolved`. It also needs proof tied to that request and attempt, recorded synchronously right before that attempt called `relaunch.arm`. The proof means the clean write was acknowledged (not just enqueued) and `verifyAllStopped` passed earlier in the same attempt.
- **What choosing it does.** It completes the existing termination once. It does not say the helper stopped. It does not call `abandon`, spawn a helper, arm, write a launch mark, or renew the deadline.
- **What stays the same.** Retry, Cancel and the ordinary Quit Anyway stay refused while the stop is unresolved. Quit Anyway keeps its meaning: "no relaunch".
- **What doesn't change.** No protocol, Platform or driver changes are needed: `ProcessRelaunchHelper.swift` and `AppRelaunchCoordinator.swift` stay untouched. The work is in 2 source files plus existing test fixtures.

This removes the source-level policy blocker. Production stays gated (`AppRelaunchCoordinator.production` returns `nil`), and live O3 qualification is still pending.

## 2. Current-state analysis

### How the arm is reached (`AgentLifecycleShutdownCoordinator`)

1. `enterPointOfNoReturn` seals admission, sets `phase = .tearingDown`, creates the single `teardownTask`, then calls `startFinalizationAttempt(freshDeadline: false)`.
2. `runFinalization` has two paths:
   - **Normal path:** every participant's `shutdownFinalize()` returns no blockers, then come the `isExpired`, `unknownParticipants` and `hasUnfinalizedWindowClose` checks. Next `authorizeCleanExit()` → `recordCleanExit` → `request.cleanWrite = write` → `awaitCleanWrite`. Only `written == true` continues to `runRelaunchStep`.
   - **Retry-join path:** `request.cleanWrite != nil` → join it → if `written`, go to `runRelaunchStep`.
   - Either way, `runRelaunchStep` is reached only after an acknowledged clean write. Note that `cleanWrite != nil` alone only means the write was enqueued, which is why it is not proof.
3. `runRelaunchStep` runs `isExpired` → `verifyAllStopped()` (must return `nil`) → `guard stillCurrent()` → optionally `prepare` plus `guard stillCurrent()` → `relaunchHelperReady = false` → `await relaunch.arm(budget)`. Nothing is awaited between the last `stillCurrent()` check and the `arm` call, so `arm` only runs while the attempt is current.

### How an unresolved stop surfaces

1. A lost or late `armed` acknowledgement, or a deadline timeout while `arm` is in flight, leads to `finalizationFinished` → `present(stage: .finalization)`.
2. `present` starts a new `presentationID` and ends the stop observation. Its Task resets `relaunchHelperReady` and `relaunchArmed`, then calls `relaunch.abandon()`. `abandon` is serialized, so it joins any in-flight `arm`.
3. The driver (`AppRelaunchCoordinator.abandonCurrent`) returns `.unresolved` only when `current.armWasSent`. Otherwise it returns `.unresolvedUnarmed`, which keeps the normal choices.
4. On `.unresolved`: `failure.appending(reason, relaunchHelperUnresolved: true)` → `offeredChoices == []`, then `observeRelaunchHelperStop` is registered, then `presentFailure`. The answer goes through the `presentationID` and `isCurrent(...failedPhase)` checks; with `relaunchHelperUnresolved` it only increments `relaunchHelperUnresolvedPrompts` and returns. **The request stays unfinished for good unless proof arrives.**

### Why the armed helper must be the one this attempt armed

These invariants hold today and the design relies on them:

- `prepareFresh` refuses to spawn while a helper is retained with an unresolved stop.
- `arm` on a session in `.stopUnresolved` returns `.unresolved` right away and sends nothing.
- `present` clears `relaunchHelperReady`, so a Retry always prepares a fresh helper.
- Retry is only reachable from a prompt with choices, i.e. after `abandon` returned `.safe` or `.unresolvedUnarmed`, or after Step 4b released the retained session.

So when `abandon` reports `.unresolved`, the retained `armWasSent` session is exactly the helper the **current attempt's** `arm` call used.

### What the AppKit adapter does (`WindowStatesManager+LifecycleShutdown.swift`)

- `presentLifecycleShutdownFailure` shows a single "OK" button for an unresolved prompt.
- Response mapping:
  - first button → `.retry`
  - `.preparation` + anything else → `.cancel`
  - `.finalization` + second button → `.proceedAnyway`
  - anything else → `.cancel`
- How a prompt gets dismissed: `dismissFailure` calls `endSheet(returnCode: .cancel)` for a sheet, or `NSApp.abortModal()` (response `.abort`) for an app-modal alert.

### What can be reused

- The `presentationID`/attempt checks, the `observeRelaunchHelperStop` restore path, `complete(_:)` (guarded by `isFinished`, ends the observation), and `endRelaunchStopObservation`.
- The existing `FakeRelaunch` and the recorder fixtures in `AgentLifecycleShutdownCoordinatorTests`.

## 3. Design

### 3.1 Policy choice: explicit consent vs. a stronger protocol

| Option | Removes the uncertainty? | Cost / new surface | Verdict |
|---|---|---|---|
| **A. Explicit uncertain exit (recommended)** | No. It tells the user about it truthfully and lets them leave. | 2 source files, no new persisted state, no protocol change. | Fixes the blocker honestly. |
| B. Later "commit" frame (helper opens only after a second frame sent just before exit) | No. The commit frame's acknowledgement can be lost too, so the same uncertainty just moves one frame later (a Two Generals problem). | Protocol v2, codec exact-key changes, helper state machine, re-review of everything around the arm. | Rejected: it makes the window smaller but doesn't remove it. |
| C. Revocable persisted permit (helper re-reads a parent-owned permit after the verified parent exit; Quit Anyway deletes it) | Mostly. The parent's last write comes before its exit, which the helper checks. What's left: a failed delete. | New persisted file and location, symlink/ownership checks inside the helper, stale-permit cleanup on next launch, a v2 `prepare` field, a new helper failure mode on FS reads, and a large re-test of reviewed Platform code. | Not needed now; listed as an option to defer. |
| D. Status quo (no choices) | — | — | A P1 under the policy: quit is blocked with no workaround except force-quit. |

**Is there a real reason to require B or C?** Only if reopening after an explicit exit could cause harm. It can't:

- The admission prerequisites (§3.2) guarantee that all admitted state was finalized, the clean mark is durable, and every family and tool was proven stopped before the arm.
- A reopen opens the exact bundle after the exact parent's verified exit, with `createsNewApplicationInstance = false`. That is the outcome the user asked for when choosing Restart safely.
- If the helper never armed or dies, there is no reopen and the user relaunches by hand. Nothing is lost.

The only effect is visible: the app may reopen when the user expected it not to. Disclosing that in the button label and text is a full remedy at this stakes level. "Visible app lifecycle actions are not reversible", so the wording must be truthful, and this design meets that. Also, a helper that follows the protocol leaves the armed state within 15 s (`parentExit`) or after the 10 s `open`, and its exit then produces proof. So "Keep Waiting" usually brings the ordinary choices back on its own. The wording must not promise that, because a stuck or suspended helper has no bound.

### 3.2 Admission proof (where and how it is recorded)

New state on `AgentLifecycleShutdownCoordinator.Request`:

```swift
/// Durable fact: a clean write under a valid authorization reported `true`. Never reset.
fileprivate(set) var cleanExitAcknowledged = false
/// The attempt whose `relaunch.arm` was entered with the clean write acknowledged and
/// `verifyAllStopped` proven earlier in that same attempt. Reset when a finalization attempt starts.
fileprivate(set) var uncertainExitProofAttempt: UUID?
/// Test observability: uncertain exits taken (0 or 1).
fileprivate(set) var relaunchUncertainExits = 0
```

Where each field is set:

- **`cleanExitAcknowledged`:** set to `true` in `awaitCleanWrite` when `written == true`, whether or not the awaiting attempt is still current, because a written clean mark is durable either way. Only this flag counts as proof; `cleanWrite != nil` never does.
- **`uncertainExitProofAttempt = nil`:** at the top of `startFinalizationAttempt`, next to `request.attemptID = attempt`. A Retry or new attempt can never inherit the old proof.
- **Recording the proof:** in `runRelaunchStep`, immediately before `await relaunch.arm(relaunchBudget(request))`, synchronously with no await in between:
  ```
  guard stillCurrent() else { return nil }                 // explicit, even though implied today
  if request.cleanExitAcknowledged && request.scope == .application {
      request.uncertainExitProofAttempt = attempt
  }
  // then: relaunchHelperReady = false; await relaunch.arm(...)
  ```
  This line sits after the `verifyAllStopped() == nil` branch of the same call, so "every family and tool stopped" is guaranteed by its position. Keep it after the optional `prepare` and its `stillCurrent()` check; it must be the last statement before `arm`.

  If `cleanExitAcknowledged` is unexpectedly false, no proof is recorded and the arm proceeds as today. That fails closed: the user gets today's no-choice prompt.

Admission predicate, a new private method, evaluated both when the prompt is built and again when the answer arrives:

```
admitsUncertainExit(request, attempt, stage) =
    stage == .finalization && request.scope == .application && request.reason == .safeRestart
    && request.isPastPointOfNoReturn && request.cleanExitAcknowledged
    && request.uncertainExitProofAttempt == attempt
```

### 3.3 Type changes

- **`AgentLifecycleShutdownChoice`:** add `case exitMayReopen`, documented as "Stage B, Restart safely, helper unresolved after a proven arm: completes without claiming the helper stopped."
- **`AgentLifecycleShutdownFailure`:** add `var offersUncertainExit = false`.
  - `offeredChoices`: `guard !relaunchHelperUnresolved else { return offersUncertainExit ? [.exitMayReopen] : [] }`. "Keep Waiting" is not an R4 choice; it is an ignored answer.
  - `appending(_:relaunchHelperUnresolved:)`: gains `offersUncertainExit: Bool = false` and sets the result's flag to `offersUncertainExit && (relaunchHelperUnresolved || unresolved)`. It must carry the existing value forward; the struct is rebuilt field by field, so a missed field silently becomes `false`.

### 3.4 `present(...)` flow changes

Inside the existing Task, in the `.unresolved(reason)` branch:

```
let offers = admitsUncertainExit(request, attempt, stage)
failure = failure.appending(reason, relaunchHelperUnresolved: true, offersUncertainExit: offers)
request.lastFailure = failure
observeRelaunchHelperStop(...)    // unchanged; registered before the prompt
```

The single `presentFailure` call becomes a loop that keeps the **same** `presentation`:

```
while true {
    let choice = await environment.presentFailure(failure)
    guard request.presentationID == presentation, isCurrent(request, attempt, failedPhase) else { return }
    if failure.relaunchHelperUnresolved {
        if choice == .exitMayReopen, failure.offersUncertainExit, admitsUncertainExit(request, attempt, stage) {
            exitWithUncertainRelaunch(request); return
        }
        request.relaunchHelperUnresolvedPrompts += 1
        if failure.offersUncertainExit { continue }   // Keep Waiting / any other answer: show again
        return                                        // no proof: today's behavior (ignored, not shown again)
    }
    handle(choice, ...); return
}
```

Design notes:

- **Same presentation on re-show.** The Step 4b observer, which checks against `presentation`, stays valid. No `abandon` or `awaitRetainedHelperStop` call is repeated, no abort frame or kill is re-sent, and no budget is consumed.
- **Why show it again.** If "Keep Waiting" simply closed the sheet, the user would lose the only way out, which is the blocker this step removes. The app has nothing else to offer at this point: sessions are torn down and admission is sealed.
- **Race with late proof.** Both sides run on the main actor and both are checked, so whichever runs first wins:
  - Observer first: it calls `dismissFailure`, then `present` starts a new presentation synchronously. The old answer, even `.exitMayReopen`, fails the `presentationID` check and is dropped, so a late proof beats an old answer.
  - Exit first: `complete` sets `isFinished` and cancels the observation, so the observer's `isCurrent` check fails.

New private method `exitWithUncertainRelaunch(_ request:)`:

- `request.relaunchUncertainExits += 1`, then `complete(request)`. That sets phase `.completed` and `isFinished`, ends the stop observation, and calls `completion(true)` exactly once.
- It does **not** touch `relaunchArmed` (stays `false`) or call `relaunch.abandon`/`prepare`/`arm`. It does not call `recordLaunchState` or `recordCleanExit`, does not change `hasUnfinalizedWindowClose`, and does not re-arm the deadline (no deadline task is running in the failed phase). The driver keeps owning the helper until the process exits.
- After the exit, the child is reparented when the parent exits:
  - armed helper: `parentExitObserved` → verified exit → may open once;
  - ready helper: `.failed`, nothing opens;
  - stuck helper: unknown, which is what the wording discloses.

`handle(...)` must stay exhaustive with the new case:

- `(.preparation, .exitMayReopen)` joins the existing "anything but Retry cancels" branch.
- `(.finalization, .exitMayReopen)` joins the `(.finalization, .cancel)` re-present branch. The choice is never offered on a normal prompt, so it must never act as Quit Anyway.

### 3.5 AppKit adapter (`WindowStatesManager+LifecycleShutdown.swift`)

**Pure mapping, extracted so it can be tested:**

```swift
nonisolated static func lifecycleShutdownChoice(
    for failure: AgentLifecycleShutdownFailure,
    response: NSApplication.ModalResponse
) -> AgentLifecycleShutdownChoice
```

Rules, checked in this order:

1. If `failure.relaunchHelperUnresolved`: return `.exitMayReopen` only when `failure.offersUncertainExit && response == .alertSecondButtonReturn`. Otherwise return `.cancel`, which covers Keep Waiting, OK, a sheet ended by `endSheet(.cancel)` and app-modal `.abort`; R4 ignores it.
2. Otherwise, the existing mapping, unchanged.

Rule 1 must come before the `(_, .alertFirstButtonReturn) → .retry` arm. The current code only stays safe because R4 ignores the answer.

**Wording.** Replace `case _ where failure.relaunchHelperUnresolved` with two branches.

*With `offersUncertainExit`:*

- `messageText`: "RepoPrompt can't confirm its restart helper stopped"
- `informativeText`: `details` + "\n\nEverything was saved and every session was stopped. You can keep waiting: if RepoPrompt confirms the helper stopped, Retry and Quit Anyway are offered again. If you exit now, RepoPrompt may reopen by itself after it quits, or it may not — reopening is not guaranteed."
- Buttons, in this order:
  1. "Keep Waiting" (first; default; Return)
  2. "Exit — May Reopen" (second)

  Leave the second button's `keyEquivalent` unset. NSAlert only gives Escape to a button titled "Cancel" or "Don't Save", so neither key can trigger the exit by accident. Verify this once in implementation by reading `alert.buttons[1].keyEquivalent == ""` in a unit test, or by assertion while debugging.

*Without it:* keep today's text and the single "OK" button.

**Sheet vs. app-modal.** No other change is needed. `dismissFailure` already ends the sheet with `.cancel` or aborts the modal (`.abort`), and both map to `.cancel`. The adapter's cleanup of `presentedLifecycleShutdownAlerts` (an identity check) already tolerates an immediate re-show from the R4 loop.

### 3.6 Acceptance contract (smallest complete set)

1. **When it's offered.** `.exitMayReopen` appears only for scope `.application`, reason `.safeRestart`, stage `.finalization`, after `abandon` returned `.unresolved`, with `uncertainExitProofAttempt == attempt` of that prompt and `cleanExitAcknowledged`.
2. **When it's never offered:**
   - Stage A;
   - window close;
   - `.unresolvedUnarmed` (normal choices stay);
   - a clean write that is pending or failed;
   - `verifyAllStopped` failed or timed out before arm;
   - a new attempt whose arm was never entered (stale proof from an earlier attempt).
3. **What choosing it does.** It completes exactly once with `reply(true)`. No further relaunch hook calls (no `abandon`, `prepare`, `arm`, `verify`). The stop observation is cancelled. No launch mark after `.cleanExit`. `expiry` unchanged. `relaunchArmed == false`. Teardown and finalize counts unchanged.
4. **Other answers while unresolved.** `.retry`, `.cancel`, `.proceedAnyway` and Keep Waiting are ignored. When the exit is offered, the same prompt is shown again with the same presentation, and no hook is re-run.
5. **Late proof.** It restores the normal choices (existing behavior). An `.exitMayReopen` answer to the dismissed prompt is ignored. A duplicate proof does nothing.
6. **Late `arm` or timeout.** If the deadline fires while `arm` is in flight, the prompt for the same attempt offers the exit. A late `.armed` that becomes stale is resolved by `abandon` as today.
7. **Ordinary Quit Anyway** keeps its meaning and is reachable only after `abandon` returned `.safe` or `.unresolvedUnarmed`.

## 4. File-by-file impact

| File | Changes | Depends on |
|---|---|---|
| `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift` | `AgentLifecycleShutdownChoice.exitMayReopen`.<br>`AgentLifecycleShutdownFailure.offersUncertainExit`, `offeredChoices` and `appending(...)` parameter.<br>`Request`: `cleanExitAcknowledged`, `uncertainExitProofAttempt`, `relaunchUncertainExits`.<br>Reset in `startFinalizationAttempt`; set in `awaitCleanWrite`; proof recorded in `runRelaunchStep` before `arm`.<br>`admitsUncertainExit`, the `present` loop, `exitWithUncertainRelaunch`, and the exhaustive `handle` cases.<br>Header comment: one paragraph on uncertain exit. | — |
| `Sources/RepoPrompt/App/WindowStatesManager+LifecycleShutdown.swift` | Static `lifecycleShutdownChoice(for:response:)`; the two-branch unresolved wording and buttons; `presentLifecycleShutdownFailure` returns through the static mapping. | The coordinator types |
| `Tests/RepoPromptTests/App/AgentLifecycleShutdownCoordinatorTests.swift` | Update 2–3 existing tests (below); add the new tests (below). Extend the recorder if needed. | Both source files |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` (R4, Restart safely bullets) | One bullet on uncertain exit (who may offer it, what it guarantees and doesn't). Plan status line for this step. | — (no review needed) |
| `ProcessRelaunchHelper.swift`, `AppRelaunchCoordinator.swift`, their tests | **No change.** Protocol, stop proof, `armWasSent` and retention rules are kept. | — |

### Tests

**Existing tests to update:**

- `testSafeRestartUnresolvedHelperStopOffersNoChoicesAndNeverFinishes` → rename to `…OffersOnlyUncertainExitAndRejectsOrdinaryChoices`.
  - `offeredChoices == [.exitMayReopen]`.
  - `.proceedAnyway`, `.retry` and `.cancel` answers each increment `relaunchHelperUnresolvedPrompts`, show the prompt again (same failure, `presented.count` grows), and leave `calls` unchanged.
  - After proof, the restored prompt has `[.retry, .proceedAnyway]`. Adjust the `presented.count` waits.
- `testSafeRestartProvenRetainedHelperStopRestores…`: `informational?.offeredChoices == [.exitMayReopen]`; everything else unchanged.
- `testSafeRestartStopProofArrivingBeforeTheObservation…`: additionally assert `presented.first?.offersUncertainExit == true`.

**New tests, using the `FakeRelaunch` fixture:**

1. `testSafeRestartUncertainExitCompletesOnceWithoutHooksMarksOrDeadline` (contract item 3; `cancelledStopWaits == 1`, `relaunchUncertainExits == 1`).
2. `testSafeRestartUncertainExitAnswerToDismissedPromptLosesToLateProof` (item 5).
3. `testSafeRestartUncertainExitNotOfferedWithoutProof`, table-driven. Each case gets `abandonResults = [.unresolved]`:
   - clean write fails;
   - `verifyAllStopped` fails;
   - timeout with a pending clean write;
   - Stage A prepare failure.

   Each asserts `offeredChoices == []`, that an `.exitMayReopen` answer is ignored, and that the prompt is not shown again.
4. `testSafeRestartUncertainExitProofDoesNotSurviveANewAttempt`: arm-unresolved → proof → Retry → `verifyAllStopped` fails → fake `.unresolved` → `[]`.
5. `testSafeRestartArmInFlightAtDeadlineOffersUncertainExitForThatAttempt` (item 6).
6. `testLifecycleShutdownChoiceMappingForSheetAndAppModalResponses`: a pure test of the static mapping covering first/second button, `.cancel`, `.abort` and `.stop` for unresolved with and without the exit offer, plus the unchanged Stage A/B rows.
7. Struct-level `offeredChoices` matrix, which also covers the window scope that can't be reached end to end.

## 5. Risks and migration

- **No persistence or protocol migration.** Rollback means reverting two files.
- **Behavior change:** the unresolved prompt is no longer final. Unknowns to check during implementation:
  - **(U1)** `FakeRelaunch` must support a suspendable `arm` for new test 5. Check its fields; if missing, add an `armGate` continuation mirroring `proveRetainedHelperStop`.
  - **(U2)** The test recorder must be able to answer a dismissed prompt with an injected choice. If it can't, add an `answerOnDismiss` choice.
  - **(U3)** Grep for other `switch` statements on `AgentLifecycleShutdownChoice` (fixtures and AppDelegate) and make them exhaustive.
  - **(U4)** Confirm that the `requestApplicationQuit(reason: .safeRestart)` reply closure in `AppDelegate`/`WindowStatesManager` does not branch on `relaunchArmed`. It should only do `reply(toApplicationShouldTerminate:)`.

## 6. Implementation order

1. Coordinator types: the choice case, the failure field, `offeredChoices`/`appending`, and the exhaustive `handle` cases. Compiles; existing tests pass except where they assert `[]`.
2. `Request` proof fields: the reset, the `awaitCleanWrite` flag, the proof line before `arm`, and `admitsUncertainExit`.
3. The `present` loop and `exitWithUncertainRelaunch`. Steps 1–3 land together.
4. AppKit mapping function and wording.
5. Test updates, new tests, and fixture extensions (U1/U2).
6. Spec bullet and plan status line.
7. Oracle review A/B under the full-rigor tier (externally visible lifecycle). Save evidence; label all results as fixture-based, not live.

## Recommendations

1. **Adopt option A** (explicit "Exit — May Reopen" consent). It resolves the owner-delegated policy blocker without a new persisted permit, protocol frame, or owner question. A commit frame (B) only moves the lost acknowledgement. A revocable permit (C) would make Quit Anyway truthful in this state, but nothing about the harm requires it now. Record C as `deferred:`, to revisit only if live acceptance shows the unresolved state happens in practice.
2. **Record the proof** as `uncertainExitProofAttempt`, set synchronously right before `relaunch.arm` in `runRelaunchStep` and reset per finalization attempt. Require `cleanExitAcknowledged` and never rely on `cleanWrite != nil`. Re-check it when the answer arrives.
3. **Re-show the prompt in the same presentation** for every ignored answer when the exit is offered, so the user never loses the way out and the Step 4b observer stays valid. Never repeat `abandon`.
4. **Map AppKit responses through one pure static function**, with the unresolved check first, so neither sheet dismissal nor app-modal abort can become an exit or a Retry.
5. **Status line:**
   ```
   Step 4c — todo | rounds 0/2 | open: | downgraded: | assumed: uncertain-exit consent policy (owner delegated judgement) | deferred: revocable permit (option C)
   ```
   This resolves the **source** policy blocker only. Production activation and live O3 qualification of the real helper stay pending and are not requested here.
