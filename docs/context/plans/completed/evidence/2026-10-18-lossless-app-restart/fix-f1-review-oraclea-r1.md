# Step 7-F1 — OracleA re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F1 (scheduled follow-up handoff hold and terminal attribution) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F1, local fix-f1-r1-delta.diff and fix-f1-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review

The delta addresses the three prior P2 findings: attribution no longer pins durable input to an earlier item, non-awaited settlements are cleared, and the exact ordinary-failure regression is tested. Coordinator-scoped tracking and cross-owner notifications cover successor ownership, while failed schedule persistence now retains a hold. No new P0/P1 identified in the supplied changes; Codex’s outcome handling remains unchanged.

## P2 — Consider

### F1-R4 — A transient record-read failure can leave a hold waiting without another wakeup

**Evidence:** `AgentModeViewModel+ScheduledSend.swift:1647–1658, 1689–1695`

The evidence recheck treats `.undecided` like `.pending`: it does nothing and returns, relying on another evidence-settlement or run-state notification. If the record read fails while processing the **last** such notification—for example, after the runner has ended and reported no-handoff—nothing shown schedules another attempt. The schedule can remain at `.awaitingProviderEvidence` despite the settlement already being available.

This is a liveness issue, not an unsafe dispatch: the payload stays held, but recovery requires another trigger such as reopening the session.

**Smallest fix:** For a still-current owner, distinguish a failed read from genuinely pending evidence and expose a retryable unresolved hold, or arrange a bounded retry. Add a test where the read fails once after the final settlement, with no subsequent provider or run-state events.

## Recommendations

- Close the previous F1-R1–R3 findings.
- Proceed without another review round solely for this new P2; fix cheaply or record it as deferred.
- Add fault-injection coverage for failed schedule persistence when practical.
- Treat the reported build, focused tests, repetitions, and lint as validation evidence—not live acceptance. No tools or tests were run for this review.