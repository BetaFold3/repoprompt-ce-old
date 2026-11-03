# Step 4c — explicit uncertain exit after an unresolved arm-sent helper stop (worker implementation evidence)

Scope: read when the task touches the Restart safely prompt shown after an unresolved helper stop where `arm` was sent, the `.exitMayReopen` choice, the request/attempt pre-arm witness, or the AppKit mapping of lifecycle shutdown prompts.
Authority: Reference
Last-verified: 2026-10-23

Status: implemented in source only, on baseline `8f988afa`. Unstaged and uncommitted. Production stays gated OFF: `AppRelaunchCoordinator.production()`, the helper protocol, the driver, the registry and persistence are unchanged, and nothing was activated live. Main owns plan/status, review, synthesis and commit. Source is frozen for main's initial A/B review.

## Policy as implemented (main's settled choices 1–6)

**`.exitMayReopen` is offered only when all of these hold:**
- the request is the app's current, unfinished `.safeRestart` request;
- Stage B is failed (`.finalizationFailed`);
- the presentation is still current;
- `abandon` returned exactly `.unresolved`;
- the request holds a `RelaunchArmSafetyProof` equal to `(request.id, attemptID)` of that prompt's attempt.

The conditions are checked twice: when the prompt is built (after the post-abandon fence), and again when the answer arrives.

**Ordinary choices.** Retry, Cancel and Quit Anyway stay refused while the helper is unresolved. Quit Anyway keeps its no-relaunch meaning, and is reachable only after `.safe`/`.unresolvedUnarmed` or a Step 4b proof recovery.

## Implementation

### `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift`

**Types**
- `AgentLifecycleShutdownChoice.exitMayReopen` (≈184).
- `AgentLifecycleShutdownFailure.allowsUncertainRelaunchExit` (≈111), default false.
- Derived `offersUncertainRelaunchExit` (≈124): requires unresolved, allows, `.application` and `.finalization`.
- `offeredChoices` (unresolved → `[.exitMayReopen]` or `[]`).
- `appending(_:relaunchHelperUnresolved:allowsUncertainRelaunchExit:)` carries every field forward; the admission only holds while unresolved.

**Witness**
- `RelaunchArmSafetyProof { requestID, attemptID }` (≈286) is an immutable in-memory value with no persistence and no helper id. Its doc comment records the dependency on the driver's single, serialized, non-replaceable retained helper.
- `Request.relaunchArmSafetyProof` (≈349), plus test counters `relaunchUncertainExits` and `rejectedUncertainExitAnswers`.

**Capture in `runRelaunchStep`**
- It documents its precondition (≈764): called only from `runFinalization`'s two successful clean-write branches (a fresh write, or Retry joining an earlier one) after `written == true`. No redundant clean-ack Boolean is needed.
- New expiry rechecks follow the post-verify `stillCurrent` and the post-prepare `stillCurrent`. When the attempt has expired, the step returns a timeout outcome.
- The witness is installed synchronously at ≈790. Nothing is awaited between it and `relaunch.arm`; only `relaunchHelperReady = false` runs in between.
- Late arm bookkeeping is fenced: `guard stillCurrent()` now precedes `request.relaunchArmed = true` (≈801). A stale `armed` never mutates the request.

**Clearing the witness**
The witness is cleared when:
- `startPreparationAttempt` or `startFinalizationAttempt` begins (≈517, ≈649);
- `cancel` or `supersede` runs (≈622, ≈699);
- `complete` runs (≈859). This discards only the eligibility witness; the driver keeps ownership;
- a current abandonment returns `.safe` or `.unresolvedUnarmed` (≈924, ≈929);
- a stop-proof recovery occurs (≈1017).

It is kept through a timeout while `arm` is in flight and through an `.unresolved` result.

**`present`**
- After `abandon`, a fence runs before any state, observation or prompt mutation (≈915). It requires `self`, the presentation, the request, the attempt and the failed phase. An obsolete presentation never shows a prompt.
- The answer loop (≈959) reuses the same presentation. On an admitted unresolved prompt:
  - `.exitMayReopen` with a re-admission check calls `exitWithUncertainRelaunch`;
  - every other answer (Keep Waiting/dismissal sentinel, Retry, Cancel, Quit Anyway) increments `relaunchHelperUnresolvedPrompts` and shows the same prompt again. Nothing is repeated: no abandon, observer, marks, teardown, or deadline.
- An ineligible unresolved prompt stays informative: the answer is ignored and the prompt is not shown again.
- On every other prompt, `.exitMayReopen` is rejected (counted, same prompt shown again). It is never handed to `handle`, so it is never a Cancel or a Quit Anyway.

**`exitWithUncertainRelaunch` (≈867)**
- Increments the counter, then calls `complete` exactly once (guarded by `isFinished`). `complete` cancels the observation.
- No `proceedAnyway`, helper hook, launch/clean mark, finalization, teardown, or deadline.

**`observeRelaunchHelperStop`**
On proof, it invalidates `presentationID` and clears the witness before `dismissFailure` (≈1016), so a second-button answer resumed by the dismissal is stale.

**`handle`**
`case (_, .exitMayReopen): break` (≈1053) keeps the switch exhaustive. The case is unreachable because `present` filters the choice.

**Docs**
The header comment and the `.unresolved` doc comments were updated.

### `Sources/RepoPrompt/App/WindowStatesManager+LifecycleShutdown.swift`

**`makeLifecycleShutdownFailureAlert(_:)` (≈123), static, no display**
- The eligible branch comes first:
  - title "RepoPrompt can exit, but may reopen";
  - the text says that before the arm request the work was saved, a clean exit was recorded, and every managed agent and tool process was verified stopped;
  - whether the helper armed or stopped is unconfirmed;
  - the app may reopen automatically, or may not, and neither is guaranteed;
  - Keep Waiting waits for confirmation, after which Retry and Quit Anyway return;
  - no time bound is stated.
- Buttons, in order:
  1. "Keep Waiting", with `keyEquivalent "\r"`;
  2. "Exit — may reopen", with `keyEquivalent ""`.
- The ineligible unresolved prompt keeps the informational OK. The other branches are unchanged.

**`lifecycleShutdownChoice(for:response:)` (≈183), static**
- The unresolved branch is decided first: only the admitted second button maps to `.exitMayReopen`. Every other response maps to the ignored `.cancel` sentinel, including the first button, sheet `.cancel`, app-modal `.abort` and `.stop`.
- The ordinary mapping is unchanged.

**`presentLifecycleShutdownFailure`**
Uses both helpers. Sheet and app-modal presentation and cleanup are unchanged.

**Fallback for a released `self`** (≈78)
For an unresolved prompt it returns `.cancel` (never exit or Quit Anyway). The ordinary fallback is unchanged.

### Unchanged by design

- `ProcessRelaunchHelper.swift`, `AppRelaunchCoordinator.swift` and their tests.
- Hook signatures; no helper id or new hook API.
- Launch-mark schemas, production gates and the frozen ledger.
- The plan body and other docs.

An exhaustive search found no other `AgentLifecycleShutdownChoice` switch or failure constructor outside these files. `AppDelegate`'s reply does not branch on `relaunchArmed`.

## Test map (`Tests/RepoPromptTests/App/AgentLifecycleShutdownCoordinatorTests.swift`)

**Fixture changes**
- `FakeRelaunch` gains one-shot `verifyGate`/`prepareGate`/`armGate` hangs.
- `Recorder.answerOnDismiss` lets a test inject an answer that races a dismissal.
- `import AppKit` added.
- No real helper or process, and no immediate-response spin. The recorder always suspends until it gets an answer.
- Every new test ends with the request finished or with an ignored, non-reshowing prompt.

**Updated existing tests**
- The former `…OffersNoChoicesAndNeverFinishes` test is replaced by `testSafeRestartUnresolvedArmedHelperOffersOnlyTheUncertainExitAndWaitingShowsTheSamePromptAgain` (≈1398). It covers:
  - only `[.exitMayReopen]` is offered;
  - Keep Waiting plus Retry, Quit Anyway and Keep Waiting again: 4 re-shows of the identical prompt;
  - no repeated hooks, observer, dismissal or deadline;
  - finalization and teardown run once;
  - after proof, the ordinary choices return and the witness is cleared;
  - the ordinary Quit Anyway then quits with one arm and no uncertain exit.
- Step 4b `testSafeRestartProvenRetainedHelperStop…` now expects `[.exitMayReopen]` on the first prompt; everything else is unchanged.
- `testSafeRestartStopProofArrivingBefore…` asserts the first prompt offered the exit and the witness was cleared after recovery.

**New tests**

| Test | Covers |
|---|---|
| `testSafeRestartUncertainExitCompletesOnceWithoutHooksMarksOrDeadline` (≈1590) | Positive path: the witness equals `(request.id, attemptID)`. One reply `true`; phase `.completed`; the observation is cancelled (`cancelledStopWaits == 1`). Hook calls are unchanged; launch marks unchanged; expiry unchanged after 3 s; finalization/teardown once; `relaunchArmed == false`; no stop recovery. A later proof or answer adds no prompt or reply. |
| `testSafeRestartExitAnswerResumedByTheProofDismissalLosesToTheProof` (≈1651) | Proof before answer: the exit answer resumed by the dismissal is ignored. On the restored ordinary prompt, `.exitMayReopen` is rejected and the prompt is shown again: never Cancel or Quit Anyway, and no repeated hook. The ordinary Quit Anyway then works. The opposite order (exit before proof) is covered by the positive test. |
| `testSafeRestartTimeoutWhileArmIsInFlightKeepsTheWitnessAndFencesTheLateArm` (≈1696) | The witness is recorded before `arm` is entered. A timeout while arm is in flight shows the restart-timeout prompt with the exit offered. The late `armed` is fenced (`relaunchArmed` false, no completion, no new prompt). The exit then completes. |
| `testSafeRestartLateVerifyOrPrepareAfterATimeoutNeverRecordsTheWitnessOrArms` (≈1741) | A late verification after a timeout neither arms nor creates a witness; its exit answer is ignored and the prompt not shown again. After proof, Retry runs; its preparation outlives the fresh deadline and the new unresolved prompt offers no exit (the stale witness is not inherited). The late preparation never arms. Exact call sequence asserted. |
| `testSafeRestartFailedCleanWriteNeverAdmitsTheUncertainExit` (≈1830) | Failed clean ack → no exit, no verify. |
| `testSafeRestartPendingCleanWriteNeverAdmitsTheUncertainExit` (≈1846) | Pending clean ack and timeout → no exit. The late acknowledgement never continues to verify. |
| `testSafeRestartFailedStopVerificationNeverAdmitsTheUncertainExit` (≈1868) | Failed all-stopped proof → no exit. |
| `testSafeRestartStageAUnresolvedHelperNeverAdmitsTheUncertainExit` (≈1883) | Stage A → no exit. Cancel after recovery. |
| `testSafeRestartUnresolvedUnarmedStageBKeepsTheOrdinaryChoicesAndRejectsTheExit` (≈1901) | `.unresolvedUnarmed` clears the witness. Ordinary choices; the exit is rejected and the prompt shown again, never a quit. |
| `testUncertainExitIsOfferedOnlyOnAnAdmittedUnresolvedApplicationStageBPrompt` (≈1948) | Struct matrix: app B, unadmitted, Stage A, window scope, ordinary prompts. `appending` carries the admission forward and never admits without an unresolved helper. The matrix has no shutdown-reason input, so it covers window scope but NOT `.appQuit`. A direct plain-quit negative was added in the repair below. |
| `testLifecycleShutdownAlertButtonsKeysAndResponseMapping` (≈1974) | Builds alerts headlessly with no `runModal` or sheet. Checks titles and order, the `\r`/`""` key equivalents, the wording claims (verified before the arm request, may reopen or may not, no bound), and the OK/Retry/Quit/Close/Cancel button sets. Checks the full response mapping (first/second/third, `.cancel`, `.abort`, `.stop`) for: an eligible prompt, an informational prompt, a window scope with a forced admission flag, ordinary Stage B, and Stage A. |

Helper-driver contracts (unresolved ownership, no replacement helper, replayed proof, non-renewing budgets) were re-run unchanged in the two helper suites below.

## All tickets (coordinated conductor)

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentLifecycleShutdownCoordinatorTests` | `36080131-75e1-4f71-b545-2a4261bd13e5` | passed, 46 tests, 0 failures |
| `make dev-test FILTER=AppRelaunchCoordinatorTests` | `79205544-919f-4a4e-a333-c5a0588efaca` | passed, 11 tests |
| `make dev-test FILTER=ProcessRelaunchHelperTests` | `2d43704d-7dcc-49ed-96d2-7c049d75aae8` | passed, 29 tests |
| `make dev-swift-build PRODUCT=RepoPrompt` (compile only) | `76692a7f-926c-4e49-a5ca-0e797a2bbb92` | succeeded |
| `make dev-format-check` | `84e6d392-d03a-4047-9ae4-d94d911888f4` | FAILED: 1 file, test-file `trailingCommas` |
| `make dev-lint` | `54af6a3d-41c5-44e8-be4b-0a0242d49268` | FAILED: same finding |
| `make dev-format-check` (after the fix) | `6a467358-7b7a-4a64-85b2-3d2df6d6c24b` | passed, 0/2175 |
| `make dev-lint` (after the fix) | `12fe8e9f-b44f-417f-8644-21202a9dac77` | passed, 0/2175 |
| `make dev-test FILTER=AgentLifecycleShutdownCoordinatorTests` (rerun, test file changed) | `77a302c4-175e-4eb3-8109-66b7a100de6d` | passed, 46 tests, 0 failures |

The first suite log showed no warnings in the touched files and no leaked or misused continuation messages.

## Failures and their resolution

- **Format/lint:** one `trailingCommas` finding in the new response array of the alert test. The trailing comma was removed, and format, lint and the focused suite were re-run and passed. No source or behavior change.
- There were no test or compile failures.

## Limits

- All evidence is fixture-based (fake hooks, fake recorder, injected manual clock, real recovery store in a temp dir), not live. There was:
  - no real helper process, signals, dev-build, packaging, dev-run or visible app lifecycle;
  - no provider or MCP execution;
  - no private runtime, home or credential inspection;
  - no ledger or release change.
- Production activation and live O3 qualification are still pending.
- The witness's association with the retained helper rests on the driver's existing invariant: one serialized retained helper, which cannot be replaced while its stop is unresolved. This is documented in source, not enforced by a helper id.
- Keep Waiting depends on AppKit returning an answer only after a user action or a dismissal. If the presenter answered immediately and forever (only possible in the fallback where `WindowStatesManager.shared` has been released, which cannot happen in production), the admitted prompt's re-show loop would spin. Test fixtures always suspend.
- The wording is fixed in source. It was not reviewed with the owner and is not localized.
- AppKit's default Escape mapping was not exercised interactively. The builder sets the exit's key equivalent explicitly to empty, and the test asserts it.
- Not run (by instruction): the full `make dev-test`, `make dev-build`/package/run, real helper qualification, and repeated runs after passing.

## Repair round 1 (A F1 P1, B P2-1, B P2-2; B P3-1 deferred)

Unstaged and uncommitted on top of main's staged snapshot (`MM` for the coordinator and tests; `WindowStatesManager+LifecycleShutdown.swift` unchanged by the repair). Main owns staging, status, allowlist and the A/B re-review.

### What was wrong (A F1 / B P2-1)

In the main lost-`armed` path, R4's deadline and the driver's `armed` wait share the work expiry, so `finalizationFinished` replaced the blockers with `restartTimeoutMessage`. The admitted exit prompt therefore said both:
- "could not confirm … that it recorded a clean exit … so it won't restart automatically. Try again, or quit without restarting";
- that the clean exit was recorded, that the app may reopen, and only Keep Waiting / Exit.

The earlier test asserted this contradictory text.

### Fix (`AgentLifecycleShutdownCoordinator.swift`)

- New `restartArmUnconfirmedMessage` (≈301): "RepoPrompt's restart helper did not confirm within 8 seconds whether it was armed."
- In `present`'s `.unresolved` branch, the current admission is computed once (≈962). Only when it is admitted does `failure.admittingUncertainRelaunchExit()` (≈132, `@MainActor`, fileprivate) run. It:
  - maps exactly `restartTimeoutMessage` to the new message;
  - keeps every other message (the driver's stop reason and arm blockers);
  - sets `awaitsCleanExitAcknowledgement = false`, which the witness proves;
  - carries every other field forward.
- `finalizationFinished`, ineligible prompts, and `.safe`/`.unresolvedUnarmed` prompts are unchanged.
- The restored ordinary prompt after a Step 4b proof still uses the original `messages`. "Won't restart automatically. Try again, or quit" is true there, with Retry and Quit Anyway offered.
- No change to helper, driver, protocol, gates, or the AppKit file.

### Tests (`AgentLifecycleShutdownCoordinatorTests.swift`)

- **`assertHonestUncertainExitAlert` (≈1826).** Passes the coordinator-generated failure to the real `WindowStatesManager.makeLifecycleShutdownFailureAlert`. Asserts the Keep Waiting / Exit buttons, the absence of "won't restart automatically", "Try again", "quit without restarting", "that it recorded a clean exit" and "could not record", and that the text says "may reopen automatically, or it may not". It is used by:
  - the positive one-shot test (non-timeout failure);
  - the arm-in-flight timeout test, which now asserts messages `== [restartArmUnconfirmedMessage, unresolvedStopText]` and `awaitsCleanExitAcknowledgement == false`;
  - the composed test.
- **Ordinary timeout stays truthful.** `testSafeRestartLateVerifyOrPrepare…` now asserts:
  - the unadmitted unresolved prompt keeps `restartTimeoutMessage`;
  - after proof, the restored ordinary prompt's messages are exactly `[restartTimeoutMessage]`;
  - the real builder shows Retry / Quit Anyway with that text.
- **B P2-2, done economically.** `testSafeRestartComposedLostArmAcknowledgementOffersAnHonestExitAndTheDriverKeepsTheHelper` (≈2215) uses the real `AppRelaunchCoordinator`.
  - It reuses this file's `SilentRelaunchChannel`, which gains an optional `respond` script (≈2078; default never replies, so the existing Stage A budget test is unchanged), decoded with `ProcessRelaunchCodec`. The script answers `prepare` with `ready` and never sends `armed`.
  - It reuses the existing shared manual clock with a new `nextPendingDeadline` query (≈67). The clock only advances to deadlines that are actually awaited, never past 8 s.
  - No process, real helper, or new harness.
  - Asserts:
    - the witness is recorded before `arm`;
    - a Stage B timeout prompt by 8 s;
    - only `[.exitMayReopen]` is offered;
    - the first message is `restartArmUnconfirmedMessage` and `restartTimeoutMessage` is absent;
    - an honest alert;
    - `driver.retainsHelper` (the driver's real `.unresolved` via arm sent);
    - the exit completes exactly once (`[true]`, `relaunchUncertainExits == 1`, `relaunchArmed == false`);
    - after the exit: the helper is still retained, `spawnCount == 1`, and there are no further frames or kill requests.
- **Overclaim corrected.** The struct matrix has no reason input; see the corrected row above. The new `testPlainQuitWithComposedRelaunchHooksNeverOffersTheUncertainExit` (≈2287) composes the fake hooks (scripted `.unresolved`) for an `.appQuit` Stage B finalization failure. It asserts:
  - `[.retry, .proceedAnyway]`, no admission, no witness;
  - zero hook calls (no abandon);
  - a rejected `.exitMayReopen` shows the same prompt again;
  - the ordinary Quit Anyway completes with no uncertain exit.

### Deferred

**B P3-1** (re-show spin if `WindowStatesManager.shared` were released and its presenter fallback answered without suspending) is not addressed, per main. There is no endless-yield workaround, and the existing limit above stands.

### Repair tickets

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentLifecycleShutdownCoordinatorTests` | `3dd8f1b5-762a-4354-80de-95ae8334dd88` | passed, 48 tests, 0 failures |
| `make dev-swift-build PRODUCT=RepoPrompt` (compile only) | `a294ccba-7c4c-4bfa-b3d5-c47a477bc281` | succeeded |
| `make dev-format-check` | `e2dc595b-a5f4-4704-9471-39a83add49b5` | passed, 0/2175 |
| `make dev-lint` | `00bc2dde-68ac-4784-80ef-681569e9774f` | passed, 0/2175 |

- The test and build logs show no warnings in touched files and no leaked or misused continuations.
- There were no failures in this round.
- `AppRelaunchCoordinatorTests` and `ProcessRelaunchHelperTests` were not re-run, because helper and driver behavior is unchanged.

### Repair limits

- The composed test is still fixture-level: an in-memory channel, an injected clock, and no real helper process or visible AppKit.
- The admitted prompt's first message names only the unconfirmed arm. The driver's own unresolved-stop text follows it unchanged.
- Production gates stay OFF and live qualification is pending.
