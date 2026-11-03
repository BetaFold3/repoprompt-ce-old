# Step 4b — retained relaunch-helper stop liveness (worker implementation evidence)

Scope: read when the task touches liveness of the Restart safely no-choice prompt after an unresolved arm-sent helper stop, or the parent session's stop-proof observation.
Authority: Reference
Last-verified: 2026-10-23

Status: implemented in source only, on baseline `ff475f0b`. Unstaged and uncommitted. Production stays gated OFF: `AppRelaunchCoordinator.production()` is still `nil` and `AgentRecoveryActionQualification.production.safeRestart` is still `false`. Main owns review, status and commit.

## Problem closed

After `abandon` returns `.unresolved` (the helper's `arm` was sent and its stop is unproven), R4 shows a prompt with no choices and ignores any answer (`AgentLifecycleShutdownCoordinator.present`). Before this change, the only way to release the retained session was a later `abandon`, and nothing ever called one. So proof arriving later (the exact child's exit, or a late correlated `aborted`) was never acted on and the request stayed wedged forever. Only liveness after real proof is closed here. Without proof, the arm-sent unknown-stop policy is still fail-closed and blocked: no choice, no Retry, no Quit Anyway, no fresh helper.

## Contract as implemented

- **Proof (Platform, `ProcessRelaunchHelper.swift`).** A lock-protected `ProcessRelaunchStopProofLatch` (≈677) is fed by the session's existing pumps:
  - the exact child's observed exit (`waitForExit`, ≈811);
  - a correlated `aborted` received after an `abort` was sent (`noteAbortSent` before the write, ≈1004; `recordAborted`, ≈802).
  - End of input, a delivered signal, a timeout, a foreign correlation and an unsolicited `aborted` never count as proof.
- **Observation.** `stopProof()` (≈1055) is replay-safe: proof that arrived earlier, even during registration, returns at once. It is cancellable (returns `nil`), sends nothing, and changes no state. Once proof is latched, `stopUnarmed` (≈989) reports `.safe(proof)` with no frame, no kill and no timer. No other protocol or state transition changed.
- **Driver (`AppRelaunchCoordinator`).** The new hook `awaitRetainedHelperStop` (≈67, ≈166) works in three steps:
  - it captures the retained session before any await;
  - it waits outside the serialized tail, so it never blocks or joins other hooks;
  - it then releases ONLY that same session, serialized. It returns `false` when nothing is retained, on cancellation, or when another hook already released the session. It never spawns, prepares, arms or renews a budget.
- **R4 (`AgentLifecycleShutdownCoordinator`).** The hook is added to `AgentLifecycleRelaunchHooks` (≈223), defaulting to `{ false }`.
  - Every `present` gets a fresh `presentationID` (≈803). An answer from a dismissed or replaced prompt is ignored (≈845).
  - On `.unresolved`, `observeRelaunchHelperStop` (≈861) is registered before the prompt is shown. On proof it checks request, attempt, phase and presentation (≈875); the helper-identity check is the hook's. It then dismisses the informational prompt and presents the same stage's original failure again. The repeated `abandon` is `.safe`, so the normal Stage B choices (Retry / Quit Anyway) return.
  - The observation is cancelled by the next `present`, `complete`, `cancel` and `supersede` (`endRelaunchStopObservation`, ≈883).
  - The notification does nothing beyond that: no Retry, quit, helper, save, clean mark, launch mark or renewed deadline.
  - Explicit Retry keeps its reviewed contract: `startFinalizationAttempt(freshDeadline: true)`, one absolute deadline per user attempt, then the normal pipeline (it joins the acknowledged clean write, verifies, then prepares and arms a fresh helper). Restart semantics are unchanged; Quit Anyway quits without relaunching.
- **Alert seam (`WindowStatesManager+LifecycleShutdown.swift`).**
  - `dismissFailure` also ends an app-modal prompt (no parent window) with `NSApp.abortModal()` (≈85) when that alert is the modal window. Previously it only ended sheets.
  - The no-choice alert text now says the usual choices come back once the helper's stop is confirmed.

## Tests (injected fixtures only)

- `ProcessRelaunchHelperTests` (+3):
  - Exact exit after an unresolved stop: observed, replayed, and the next stop is `.safe` with no new kill or timer.
  - A late correlated `aborted` is proof; a foreign `aborted` and end of input are not; cancellation returns `nil` and the session stays `stopUnresolved`.
  - An unsolicited `aborted` is not proof, and the observation is cancellable.
  - Fixture: `FakeHelperChannel` gained `deliver`, `finishInput` and `received`.
- `AppRelaunchCoordinatorTests` (+2):
  - An observed exit releases only the retained arm-sent helper, with no frame and no spawn. A duplicate observation is `false`; only a later explicit prepare spawns a fresh helper.
  - A cancelled observation and an idle driver both return `false`; the helper stays retained and is still refused.
- `AgentLifecycleShutdownCoordinatorTests` (+2, 1 updated):
  - **Late proof:** the old prompt is dismissed and its answer fenced, and the normal choices return with the original messages. No retry, prepare, arm, finalize, mark or renewed expiry follows; a duplicate proof is a no-op. An explicit Retry then gives a fresh expiry and a verify → prepare → arm sequence.
  - **Proof before registration:** the choices are restored; Quit Anyway never relaunches.
  - **Updated:** the existing no-choice test now also asserts that the observation (`awaitStop`) is registered and still pending after the ignored answer. This is a deliberate contract update, not a weakened assertion.
  - Fixtures: the `Recorder` dismissal now returns the pending prompt the way `endSheet` does, and `FakeRelaunch` gained a scripted stop proof.

## Validation (coordinated, all waited)

| Ticket | Operation | Result |
|---|---|---|
| `0ad0be5e` | dev-test ProcessRelaunchHelperTests | 29/29 pass; flagged a new trailing-closure warning in my test helper, since fixed |
| `f479b2c7` | dev-test AppRelaunchCoordinatorTests | 11/11 pass (remaining warnings were already there at baseline) |
| `c208b0ad` | dev-test AgentLifecycleShutdownCoordinatorTests | 35/35 pass |
| 9 tickets (`64e41737`…`eecf4759`) | dev-test-artifact, the 3 suites × 3 | all pass (flake check; not source validation) |
| `340b457d` | dev-lint | **failed**: SwiftFormat `modifierOrder` (`nonisolated package`), fixed to `package nonisolated` |
| `bcac2a33` | dev-lint | pass |
| `3ec398e3` / `64f1f222` | dev-swift-build PRODUCT=RepoPrompt / repoprompt-mcp | pass (compile only) |
| `beefe9e7` / `fa053a91` / `bcddf575` | dev-test, the 3 suites on final source | 29 / 11 / 35 pass |

The full failure history is the one lint failure above plus one new compiler warning that was fixed. There were no test failures.

Not run: the root suite or broader tests, packaging, the app lifecycle, provider/helper/MCP executable runtime, process inspection, signalling, live acceptance, dev-format, and Oracle review.

## Remaining limits

- The AppKit dismissal paths (`endSheet`, `abortModal`) and the real `Process` exit latch are not exercised by tests; R4 tests use injected prompts.
- If proof never arrives, the request still stays unfinished with an informational prompt. That is the existing fail-closed inactive checkpoint behavior, not accepted full R4 compliance; any alternative needs an owner decision.
- R4's cancellation of an observation on complete/cancel/supersede is defensive: no reachable path ends the request while the observation is pending, so no test exercises it. Cancellation itself is tested at the driver and session layers.
- A late correlated `aborted` counts only after an `abort` was sent. That is by design; the helper never sends one otherwise.
- Phase 4, O3 live acceptance and production activation stay blocked and gated OFF.
