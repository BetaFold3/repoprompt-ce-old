# Step 7-F1 — OracleA initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F1 (scheduled follow-up handoff hold and terminal attribution) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F1, fix-f1-review.diff kept locally under prompt-exports/restart-fixes/, worker report, code context); preset identity verified from the result.

# Oracle Review

The changes address the main F1 race by making non-Codex startup failures explicit, retaining scheduled input while its runner prepares, and adding a no-handoff settlement notification. They also introduce attempt-scoped terminal attribution and distinct delivery-record diagnostics. The delayed-runner tests materially improve realism. The supplied code supports the main fix, but attribution and tracking cleanup have remaining gaps; the worker’s broader caller audit cannot be fully verified from these slices.

## P2 — Consider

### F1-R1 — Missing input identity still permits attribution to an earlier turn
**Evidence:** `AgentProviderHandoff.swift:119–122`; `AgentRunTerminalCommitBarrier.swift:476–487`.

When no constituent supplies a `userItemID`, `attributedUserItemID(of:in:)` selects the session’s last user item—even for durable input. If that input has no transcript item and an earlier completed turn exists, the new attempt becomes explicitly attributed to the earlier turn. A subsequent failure can therefore reproduce the incorrect attribution F1 intends to prevent.

The optional identities and incomplete-baseline handling permit this case, although the supplied context does not establish a normal producer that exercises it.

**Smallest fix:** Restrict legacy fallback to explicitly legacy/untracked routes. Represent “this attempt has no attributable input item” separately from “use legacy attribution,” and test a durable input without a user-item identity.

### F1-R2 — Deferred settlements are retained without a general cleanup path
**Evidence:** `AgentRecoveryCoordinator.swift:3053–3096`; `AgentProviderHandoff.swift:377–389, 470–479`.

Every durable run-start handoff enters the registry, but a non-scheduled run that fails before committing leaves `.notHandedOff(message:)` behind. The supplied changes clear committed entries and certain scheduled settlements; ordinary failed/cancelled inputs have no corresponding consumption path. Repeated failures of distinct inputs accumulate entries and failure messages for the lane’s lifetime.

**Smallest fix:** Add explicit settlement consumption or abandonment for non-scheduled inputs and terminal intent removal. Preserve scheduled settlements until their owner consumes them; do not simply clear them immediately after posting the notification.

### F1-R3 — Regression assertions do not directly verify the observed historical-turn corruption
**Evidence:** `AgentModeRunServiceLifecycleTests.swift`, new F1 terminal-attribution tests; `AgentScheduledSendNonCodexMandatoryTests.swift`, new deferred-start tests.

The barrier tests use cancellation/interruption attribution, while the scheduled tests check earlier user-item text. Neither directly asserts that an earlier **completed** turn retains its terminal state and error information when a later scheduled attempt fails with its bubble absent—the recorded F1 failure.

**Smallest fix:** Add an ordinary `.failed` terminal commit with nonempty `errorText`, a completed historical turn, and a removed scheduled input. Assert the historical turn’s terminal state and error remain unchanged.

## Recommendations

- Address the attribution fallback and add the exact historical-turn regression test.
- Verify `markScheduledSendFailed`’s persistence-error behavior before approval: `ScheduledSend.swift:1702–1711` releases the hold unconditionally after that non-throwing call. Its omitted implementation must guarantee successful persistence or preserve an unresolved hold.
- Inspect omitted caller and runner early-return paths before accepting the universal `nil` contract and caller-compatibility claims.
- Add the requested shutdown-during-preparation test. The reported 669 passing tests are useful worker evidence, not independently reproduced validation.