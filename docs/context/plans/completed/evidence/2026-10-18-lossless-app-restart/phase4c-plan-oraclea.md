# Step 4c planning — OracleA

Scope: read when the task touches the explicit uncertain-exit policy for a retained restart helper.
Authority: Reference
Last-verified: 2026-10-23

Verified returned preset OracleA (61D024A4-CCFB-4C9C-A614-CC65E0A1864C), explicit selection; chat helper-uncertainty-resol-EAB412; operation B4F271EE-E65B-43AE-AFCB-B5C1348A31B7; completed/ok. Both lanes received identical source and request with the full review policy. Original export: /Users/tnguyen/workspace/repoprompt-ce-personal-touch/prompt-exports/oracle-plan-2026-10-23-174642-helper-uncertainty-r-27a1.md. Complete response follows; trailing whitespace normalized and Markdown hard breaks expressed as explicit line breaks.

# Oracle Plan

## Summary

Resolve the policy blocker with **explicit, qualified consent to “Exit — may reopen”**, not a new helper protocol. Offer it only for application-level `.safeRestart` Stage B when the current attempt has acknowledged final persistence/clean-exit recording and verified every managed family/tool stopped **before invoking the arm operation associated with the retained helper**. Preserve all existing stop-proof, ownership, deadline, and ordinary Quit Anyway rules. This is a targeted change to two production files, existing test fixtures, and the specification; production activation and live qualification remain pending.

## Current-state analysis

### Existing shutdown and relaunch flow

`AgentLifecycleShutdownCoordinator` owns the request, attempts, deadlines, freezes, teardown task, and completion callback on `MainActor`.

1. **Stage A:** synchronously freeze admission; preserve layout; acknowledge `.shutdownInProgress`; settle released recovery input; prepare participants; prepare an unarmed relaunch helper.
2. **Stage B:** seal application admission; perform the single teardown; finalize participants.
3. `runFinalization` enqueues `recordCleanExit` and awaits its Boolean result.
   - `request.cleanWrite != nil` means a write exists, **not** that it succeeded.
   - Both paths into `runRelaunchStep` follow an affirmative clean-write acknowledgement, including Retry joining an earlier write.
4. `runRelaunchStep` verifies all managed processes stopped, prepares a fresh helper if necessary, and invokes `relaunch.arm`.
5. `AppRelaunchCoordinator` serializes prepare/arm/abandon operations and retains one `ProcessRelaunchParentSession`.
6. The parent session sets `armWasSent` before writing. Failed arming attempts abort and, if necessary, request exact-child termination within the existing absolute cleanup budget.
7. Without correlated `aborted` or observed exact-child exit, ownership remains retained. Neither EOF, elapsed time, nor delivered SIGKILL establishes safety.

On failure, `present` awaits abandonment. `.unresolved` currently produces an informational prompt whose answers are ignored. `observeRelaunchHelperStop` already restores normal choices after positive proof, without retrying or quitting automatically.

`WindowStatesManager+LifecycleShutdown.swift` translates failures into sheets/app-modal alerts and translates AppKit responses back into lifecycle choices.

### Reusable mechanisms and the missing policy

Reuse:

- The existing serialized helper driver and stop-proof latch.
- Request, attempt, and presentation identity fences.
- The existing stop observer and normal-choice restoration.
- `complete(_:)` for exactly-once termination authorization.
- Existing fake clocks, participants, relaunch hooks, and prompt recorder.

The missing distinction is between:

- **Ordinary Quit Anyway:** the helper cannot relaunch, established through safe abandonment or the never-armed guarantee.
- **Explicit uncertain exit:** the helper’s ability to relaunch remains unresolved, but preservation and stopped-runtime prerequisites are proven and the user knowingly accepts that uncertainty.

No persistence, provider registry, helper wire protocol, or production qualification changes are required.

## Design

### 1. Acceptance contract

The new exit action is available only when **all** of these hold:

1. The request is the current, unfinished application request.
2. Its reason is `.safeRestart`.
3. Its phase is `.finalizationFailed`.
4. The current prompt represents `.unresolved` abandonment—not `.safe` or `.unresolvedUnarmed`.
5. The request holds an arm-safety proof matching its request ID and current attempt ID.
6. The answer belongs to the currently presented prompt.

The proof certifies that, before this attempt invoked arming:

- Final persistence succeeded.
- The clean-exit write returned `true`.
- `verifyAllStopped` returned success.
- The helper was prepared for that arm operation.
- The attempt was still current and within its work deadline.

Accepting the new action:

- Completes the existing termination request exactly once.
- Cancels the stop observation through `complete(_:)`.
- Does **not** call `proceedAnyway(_:)`.
- Does not mark the helper stopped or release unresolved helper ownership.
- Does not prepare, spawn, arm, abort, or signal another helper.
- Does not renew a deadline, repeat persistence/teardown, or write another launch mark.

Until positive stop proof arrives, Retry, Cancel, and ordinary Quit Anyway remain rejected. If eligibility cannot be established, preserve the existing informational-only behavior.

### 2. Capture narrowly scoped proof in the shutdown coordinator

In `AgentLifecycleShutdownCoordinator.swift`, add:

- `AgentLifecycleShutdownChoice.exitMayReopen`.
- A default-false `AgentLifecycleShutdownFailure.allowsUncertainRelaunchExit` property.
- A private immutable `RelaunchArmSafetyProof` value containing:
  - `requestID: UUID`
  - `attemptID: UUID`
- An optional proof owned by `Request`.

The value is an in-memory control-flow witness, not a persisted authorization or helper-stop claim.

#### Capture point

Keep `runRelaunchStep` private and callable only from the two existing successful clean-write acknowledgement branches. Document that precondition explicitly.

Inside that method:

1. Confirm the attempt is current and unexpired.
2. Await `verifyAllStopped`.
3. Recheck current attempt and expiry after successful verification.
4. Prepare the helper if required.
5. Recheck current attempt and expiry after preparation.
6. Immediately before invoking `relaunch.arm`, synchronously install the proof with the current request and attempt IDs.
7. Invoke arming without another suspension between recording the proof and entering that hook.

A guard failing due to expiry returns a timeout outcome; a stale attempt returns `nil`. Neither installs proof nor starts a new arm operation.

This placement is deliberately **before awaiting arming**: a timeout can race a lost acknowledgement, yet the prerequisite proof must remain available when abandonment reports a possibly armed helper.

#### Proof lifecycle

- Clear proof synchronously at the beginning of every preparation or finalization attempt.
- Do not clear it merely because the current attempt times out or enters a failure phase.
- Clear it after a current abandonment result of `.safe` or `.unresolvedUnarmed`.
- Retain it for `.unresolved`.
- Clear it when the request ends; this discards only the coordinator’s eligibility witness, not driver ownership.
- Fence post-arm bookkeeping: set `request.relaunchArmed = true` only after confirming the attempt is still current. A stale result must not mutate a replacement attempt.

Do not add a separate “clean acknowledged” Boolean. The existing successful call paths provide that prerequisite; the proof is installed only after the remaining checks succeed.

#### Association with the retained helper

No helper identifier needs to cross the existing hook interface. The supplied architecture establishes the association:

- Only one helper is retained.
- Prepare/arm/abandon are serialized.
- An unresolved helper cannot be replaced.
- A new attempt clears the previous proof.

Therefore, `.unresolved` following this attempt’s arm belongs to the retained helper whose arming this proof preceded. Add a comment recording this dependency so future changes allowing helper replacement cannot silently invalidate it.

### 3. Failure presentation, choice admission, and races

Modify `AgentLifecycleShutdownFailure.offeredChoices`:

| Failure state | Lifecycle choices |
|---|---|
| Unresolved helper, eligible proof | `.exitMayReopen` |
| Unresolved helper, no eligible proof | None |
| Ordinary Stage A failure | Retry, Cancel |
| Ordinary Stage B failure | Retry, Proceed Anyway |

`appending` must preserve the new field.

In `present`:

1. Await abandonment as today.
2. **Before mutating request state, registering observation, or showing an alert**, recheck request identity, attempt identity, expected failed phase, and presentation ID.
3. For `.unresolved`, calculate eligibility from the request’s proof and the acceptance contract.
4. Store the fully enriched failure in `lastFailure`.
5. Register the existing stop observer and present the failure.

The post-abandon fence also prevents an obsolete presentation task from showing an alert after another presentation supersedes it.

When the response returns:

- Retain the existing presentation/request/attempt checks.
- For unresolved failures, accept only `.exitMayReopen`, and only after rechecking both the displayed eligibility and the current proof.
- Ignore every other answer without ending observation or changing shutdown state.
- Outside this branch, reject `.exitMayReopen`; never reinterpret it as Cancel or Proceed Anyway.
- Leave normal `handle` behavior unchanged for existing choices.

#### Late proof versus an old answer

In `observeRelaunchHelperStop`, after its existing guards succeed:

1. Invalidate the old presentation ID synchronously.
2. Clear the arm-safety proof.
3. Dismiss the old prompt.
4. Re-present the original failure with normal choices through the existing path.

Invalidation must precede dismissal because dismissal can resume a pending presentation response.

The race is linearized on `MainActor`:

- **Proof recovery wins:** an old exit answer is stale and ignored.
- **Explicit exit acceptance wins:** completion runs once and cancels observation; a later proof cannot present another prompt or complete again.

This does not promise ordering against the instant an external process event physically occurred. It guarantees ordering when the coordinator accepts the proof or user answer.

### 4. AppKit wording and response mapping

In `WindowStatesManager+LifecycleShutdown.swift`, add an eligible-unresolved branch before the existing unresolved branch.

**Title**

> RepoPrompt can exit, but may reopen

**Informative text**, following the existing failure details:

> Your work was saved, a clean exit was recorded, and all managed agent and tool processes were verified stopped before the restart helper was armed.<br>
><br>
> RepoPrompt could not confirm that the restart helper stopped. Exiting may cause RepoPrompt to reopen automatically; reopening is not guaranteed.<br>
><br>
> Choose Wait to keep waiting for confirmation. If the helper is confirmed stopped, Retry and Quit Anyway will be offered again.

For maximal precision, use **“before the restart helper’s arm request”** instead of “before the restart helper was armed” in the implemented text: actual arming is the uncertain event.

**Buttons, in order**

1. **Wait** — default Return-key action.
2. **Exit — may reopen** — never the default.

“Wait” is a neutral acknowledgment, not a lifecycle choice. It dismisses the alert while keeping the request frozen, unfinished, and observing stop proof. Escape and non-button dismissal have the same effect.

Response mapping must inspect the failure kind **before** the existing stage-based switch:

| Eligible unresolved response | Result |
|---|---|
| Second button | `.exitMayReopen` |
| Wait, Escape, dismissal, unexpected response | Existing `.cancel` sentinel, ignored by the unresolved branch |

For ineligible unresolved prompts, retain the informational OK button and map every response to the same ignored sentinel. Normal second-button mapping remains `.proceedAnyway` only for ordinary Stage B prompts.

Extract two internal static helpers in this file so tests can inspect behavior without displaying UI:

- `makeLifecycleShutdownFailureAlert(_:) -> NSAlert`
- `lifecycleShutdownChoice(for:response:) -> AgentLifecycleShutdownChoice`

The existing async presenter remains responsible for parent selection, alert ownership, sheet/modal execution, and cleanup. Both presentation modes use the same builder and mapper.

### 5. Why not add a later commit frame?

A later launch-authorization frame would move the uncertainty boundary:

- Send commit, lose its acknowledgment: the helper may still reopen.
- Exit before establishing commit: reopening becomes unreliable.
- Add a durable permit or another authority: introduce persistence, cleanup, and failure-recovery obligations beyond this bounded policy issue.

A stronger protocol would be justified if the requirement were **“allow exit while guaranteeing no reopening despite unresolved helper state.”** That is not the selected policy. Honest, explicit consent resolves the present dead end without weakening stop-proof rules or pretending uncertainty disappeared.

### 6. Required tests

Extend `AgentLifecycleShutdownCoordinatorTests.swift` using the existing fixture style.

**Positive acceptance**

- Drive successful finalization, acknowledged clean write, successful stopped proof, then unresolved arm abandonment.
- Assert only `.exitMayReopen` is offered.
- Select it; assert one successful reply, completed request, canceled observer, and no subsequent helper hook, launch mark, deadline renewal, finalization, or teardown.
- Assert no normal stop-recovery counter is incremented.

**Proof boundaries**

- Pending or failed clean write never authorizes uncertain exit.
- Failed stopped-process verification never authorizes it.
- Timeout while verification or helper preparation is suspended does not allow a late continuation to install proof or invoke arming.
- Timeout while arming is already in flight preserves eligible proof when abandonment subsequently reports `.unresolved`.
- Proof from an earlier attempt cannot authorize a later attempt’s failure.
- Application `.appQuit`, window close, Stage A, and `.unresolvedUnarmed` never offer the new action.

Use a narrow proof-matching test seam only if required to exercise an otherwise unreachable mismatched identity; do not make request proof generally mutable.

**Choices and races**

- Retry, Cancel, and Proceed Anyway are ignored while the helper remains unresolved.
- Wait keeps observation alive; later proof restores normal choices.
- Proof-before-answer invalidates the old exit response.
- Exit-before-proof completes once and prevents replacement prompts.
- Duplicate proof and duplicate/stale responses do nothing.
- A stale abandonment completion cannot show an obsolete prompt.
- After proof recovery, ordinary Quit Anyway still quits without any new arm operation.

**AppKit contract**

Using the extracted helpers, inspect button titles, ordering, default key equivalent, and all response mappings without calling `runModal` or displaying a sheet. Include ordinary Stage B second-button regression coverage.

Retain and rerun the existing parent-session and driver tests for unresolved ownership, no replacement helper, replayed proof, and non-renewing cleanup budgets. Their contracts must not change.

## File-by-file impact

Paths are relative to the repository root.

| File | Changes and dependencies |
|---|---|
| `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift` | Add the choice, failure eligibility, request-local proof, proof capture/reset rules, guarded uncertain completion, and presentation race fences. Core change; no hook signature changes. Update comments that currently categorically prohibit all choices after unresolved arming. |
| `Sources/RepoPrompt/App/WindowStatesManager+LifecycleShutdown.swift` | Add qualified uncertain-exit wording/buttons; extract alert builder/response mapper; special-case unresolved responses. Depends on the coordinator’s new choice and eligibility property. |
| `Tests/RepoPromptTests/App/AgentLifecycleShutdownCoordinatorTests.swift` | Update existing unresolved-arm expectations and extend current fakes with controllable verification/preparation/arm/abandon suspension where needed. Add acceptance, rejection, race, and alert-mapping tests. |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Add the bounded uncertainty-consent policy under R4, distinguishing it from ordinary Quit Anyway and preserving pending qualification. Record this as a new prerequisite-resolution step, not a reopened old checkpoint. |

**Unchanged:** `AppRelaunchCoordinator.swift`, `ProcessRelaunchHelper.swift`, their protocol/state contracts, launch-mark schemas, production gates, and their existing regression fixtures.

## Implementation order

1. **Record the bounded policy and acceptance contract.**<br>
   Suggested status:
   `Step 4c — todo | rounds 0/2 | open: implementation and validation | downgraded: none | assumed: existing serialized single-helper ownership | deferred: production activation and final live qualification`

2. **Land coordinator behavior and AppKit mapping atomically**, with updated focused tests. The new enum case, eligibility, and button mapping must not temporarily disagree.

3. **Add deterministic race and negative-path coverage.** Use fixture-controlled suspension and existing clocks, not elapsed wall-clock timing. Verify cancellation leaves unresolved helper ownership untouched.

4. **Run affected unit suites and compile all choice switches.** The supplied test files are excerpts: search the full repository during implementation for exhaustive `AgentLifecycleShutdownChoice` switches and failure constructors. Any additional match must preserve the same admission contract; no broader redesign is implied.

5. **Perform the required OracleA/OracleB review process on this bounded delta**, attaching the supplied policy verbatim and clearly labeling fixture evidence as non-live. No review, execution, or validation has been performed in this text-only analysis.

## Recommendations

- Adopt **“Exit — may reopen”** with the request/attempt-scoped pre-arm proof described above.
- Preserve the helper protocol, unresolved ownership, ordinary Quit Anyway semantics, and production gates.
- Treat this as resolving the **source-level policy blocker** once implemented and validated—not as production activation or final live acceptance.
