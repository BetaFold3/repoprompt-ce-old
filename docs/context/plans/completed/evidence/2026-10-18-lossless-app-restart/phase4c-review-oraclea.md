# Step4c initial review — OracleA

Scope: read when the task touches the explicit uncertain-exit repair or its review findings.
Authority: Reference
Last-verified: 2026-10-23

Snapshot `2026-10-23/1802`; preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`; chat `step4c-uncertain-exit-in-E9D56A`; operation `288A38C5-C625-4D51-80A3-837EF9DAEC9B`. Full response follows.

# Oracle Review

The change adds an explicit, one-shot **Exit — may reopen** choice backed by a current-attempt pre-arm witness, preserves helper ownership, and fences stale completions and prompt answers. The implementation is focused and the supplied tests cover most coordinator transitions. However, the actual timeout prompt contradicts the new uncertainty disclosure.

**Verdict: Changes requested — one P1.** Review based on the supplied snapshot; reported validation was not independently rerun.

## P1 — Should fix

### F1: Uncertain-exit prompt promises that automatic reopening will not happen

- **Scenario:** The deadline expires while `arm` is in flight, and abandonment returns `.unresolved`.
- **Evidence:** `AgentLifecycleShutdownCoordinator.swift`, `finalizationFinished` assigns `restartTimeoutMessage`, which says **“it won't restart automatically. Try again, or quit without restarting.”** The new branch in `WindowStatesManager+LifecycleShutdown.swift:129–136` includes those messages unchanged before explaining that exiting **may reopen automatically**. `testSafeRestartTimeoutWhileArmIsInFlightKeepsTheWitnessAndFencesTheLateArm` explicitly verifies that this contradictory timeout message reaches the eligible failure.
- **Impact:** The consent prompt simultaneously promises no automatic restart and warns of a possible restart. It also recommends ordinary choices that are currently prohibited. This undermines the central disclosure required by Step 4c.
- **Smallest fix:** When constructing an admitted uncertain-exit failure, replace the generic restart-timeout explanation with wording limited to the unconfirmed arm/stop outcome. Preserve unrelated diagnostic details. Add an alert-content assertion using the coordinator-generated timeout failure; the existing builder test uses a generic message and misses this contradiction.

## Recommendations

Fix F1 and rerun the focused lifecycle tests. Otherwise, no additional production correctness defect is established by this bounded diff. Keep recovery activation **OFF** and live qualification pending; the supplied fixture and alert-builder results do not establish visible AppKit or real-helper behavior.
