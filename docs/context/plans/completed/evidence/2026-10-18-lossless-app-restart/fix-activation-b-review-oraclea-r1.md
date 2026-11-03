# Step 9-activation-b re-review round 1: OracleA

Scope: read when the task touches crash-hold confirmation from process-registry proof, the run-start registration mark, or Step 9-activation-b of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleA round-1 re-review of the delta

The round-1 delta closes the dismissal/write race, retains `.working` until crash-hold confirmation actually finishes, distinguishes Stop during confirmation, and expands registry overlap checks to include record-level ownership keys. It also adds targeted refusal-path tests and scheduler integration coverage.

## Review result

- **P1-01 resolved.** `AgentRecoveryStore.swift:1600–1607` checks the captured card key and freshness against persisted dismissal state before any acknowledgement mutation, within the synchronous store-actor operation. Both live-lane and closed-session paths supply that condition. The new test exercises dismissal after the final coordinator check for both destinations and verifies that sending remains paused.
- **Previous P2-02 addressed.** The added startup-composition test covers an already-authorized scheduled send remaining blocked before acknowledgement and dispatching once afterward.
- **No new findings in the scoped round-1 delta.** Moving snapshot checks into each commit attempt and making confirmation own its `.working` cleanup are consistent with the intended behavior.

Validation results are worker-reported; I did not independently execute tests. The broader baseline diff and excluded shared-file changes were not reviewed.

## Recommendations

Approve this round with no open P0/P1 findings. Keep production activation `.off`; retain shared launch authority as a pre-activation gate and the shared-store composition assertion as a documented deferred item.
