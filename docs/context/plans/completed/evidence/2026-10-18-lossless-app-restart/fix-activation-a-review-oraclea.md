# Step 9-activation-a review, round 0 — OracleA

Scope: read when the task touches the Step 9-activation-a review.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA round-0 review of prompt-exports/restart-fixes/act-a-r0.diff.

The changes centralize activation, add exact-pair registration and provider refusals, and let Check abandon its wait without cancelling reconciliation. Production remains `.off`; the supplied launch changes preserve fail-closed behavior for covered pairs. The main concern is a Stop race before the newly created item task starts. Validation below is source review only; the reported test runs were not independently verified.

## P1 — Should fix

### F1 — Stop can finish before reconciliation starts, allowing `.working` to return afterward
**File:** `AgentRecoveryCoordinator+Check.swift:269–280`, especially the unstructured `Task`; cleanup at `:238–240`.

- **Scenario:** `waitForCheckOutcome` installs its waiter and enqueues work. Stop can win before that work starts, resume the caller, clear `.working`, and finish the report. The queued task does not check whether its waiter was abandoned before calling `checkOutcome` and the reconciliation closure.
- **Impact:** Reconciliation can start after the report finished, acquire the session hold, and set the card back to `.working`. If it hangs, the intended escape from the stuck progress state fails. Main-actor isolation prevents simultaneous mutation, but does not guarantee task execution order.
- **Smallest fix:** Track whether item work has started or been abandoned. Before invoking `checkOutcome`, synchronously skip work whose waiter already finished through Stop. Preserve the non-cancellation behavior once reconciliation has started. Add a test that stops before the worker begins, not only after its history performer suspends.

## P2 — Consider

### F2 — Provider-refusal tests do not establish binding to the actual target session
**Files:** `AgentRecoveryActionRunner.swift:191–198`; `AgentRecoveryActionTests.swift`, `testUnqualifiedProvidersRefuseEveryChoiceBeforeAnyReservation`.

The new gate trusts `request.target.providerKindRaw`. The tests construct that field directly, proving refusal of unqualified strings but not that a request naming Claude cannot survive a session switch to GLM/Kimi/custom or another unqualified provider.

**Impact:** The requested stale/spoofed-target guarantee remains unverified. This is a coverage gap, **not a demonstrated bypass**: the supplied material omits the target-construction and downstream target-validation implementations.

**Suggestion:** Exercise the real request-building path, retain a qualified request across a provider change, and assert refusal without reservation or dispatch. Include actual Claude-compatible variant mappings. Reuse existing target validation if it already provides this guarantee.

### F3 — Stopping the final item produces a non-cancelled summary
**File:** `AgentRecoveryCoordinator+Check.swift:173–175, 237`.

When Stop abandons the only or final item, `notChecked` becomes zero. `summaryText` therefore says **“Checked N of N”**, despite the cancellation and unfinished check.

**Suggestion:** Use `cancelRequested` to select the cancelled heading; keep `notChecked` for the remaining-item count. Add a single-item Stop assertion.

## Recommendations

- Fix F1 and add the pre-start Stop regression test before accepting the abandonment behavior.
- Close the actual-target provider-binding coverage gap before the activation flip.
- Keep production `.off` until live acceptance. Fix the reported documentation guardrail failures before commit.

No P0 findings. No confirmed covered-launch fallback or Claude-compatible qualification bypass was found in the supplied code.