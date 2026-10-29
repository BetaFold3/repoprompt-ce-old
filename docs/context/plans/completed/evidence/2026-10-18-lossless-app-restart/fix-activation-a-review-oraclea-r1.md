# Step 9-activation-a re-review, round 1 — OracleA

Scope: read when the task touches the Step 9-activation-a re-review.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA round-1 re-review of prompt-exports/restart-fixes/act-a-delta.diff.

The fixes preserve production activation as `.off`, strengthen provider qualification and run-provider checks, and prevent queued Check work from starting after Stop. **F1 is resolved in the supplied code:** the task checks `wait.isFinished` before entering reconciliation, and cancellation cleanup now distinguishes whether reconciliation started. No P0 or P1 findings in this re-review. Validation remains worker-reported, not independently or live verified.

## P2 — Consider

### F2 — Pre-start cancellation incorrectly promises a later result
**File:** `AgentRecoveryCoordinator+Check.swift:248–255, 299–301`

**Scenario:** Stop finishes the waiter before the queued item task starts—the exact case covered by the new regression test. The task correctly skips reconciliation, but the report still uses `abandonedText`: “Its check continues; the card shows the result.”

**Impact:** The user is told to expect a result from work that will never run.

**Smallest fix:** Choose the message using `waited.reconcileStarted`: retain the existing text for an ongoing reconciliation; otherwise report “Stopped before checking this item.” Update the pre-start cancellation test accordingly.

## Recommendations

- Close round-0 **F1**.
- Fix F2 cheaply or record it as deferred; it does not warrant another review round.
- Rerun the affected validation before committing, and keep production `.off` pending the separate live qualification.