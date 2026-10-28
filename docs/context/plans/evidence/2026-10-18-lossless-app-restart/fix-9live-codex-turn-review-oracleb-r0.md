# 9-live fix 5 (Codex turn ID): OracleB review, round 0

Scope: read when the task touches how recovery identifies the interrupted Codex turn, the run attempt's provider turn ID, or the Codex history matcher's text.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 0) of the Step 5 diff, copied from its export; the fixes are in fix-9live-codex-turn-worker.md


# Review: Step 5 (R2), Codex native turn ID on the run attempt (round 0)

**Verdict:** I found no P0 or P1 in this diff. The write cannot block or fail Codex event handling. It goes to the right session and run attempt, it never records compaction or review turns, and it adds no resend path. Two items could become P1 depending on code outside the diff (F1, F4). F2 answers your question about the "contains tool calls" text. The rest are cheap P2/P3 items.

I worked from the diff, the report and the plan only. I did not read the rest of the source or run anything. Where a conclusion depends on code outside the diff, I say so.

## What holds up

| Concern | Evidence | Result |
|---|---|---|
| Event handling blocked or failed | `recordCodexProviderTurn` (Coordinator ~:1918) does only synchronous guard reads, then starts a `Task { @MainActor }` that is never awaited. A failure is only logged. | OK |
| Wrong session or run attempt | It uses the session's own `recoveryLane` and `activeRunOwnership`, and requires `ownership.attemptID == identity.runAttemptID`. The store then runs `requireOwnership` and `requireRunAttemptIndex`, and refuses another transcript generation with `runAttemptConflict`. | OK |
| Compaction or review recorded | Guarded by `turnKind == .user`. The test pins `.compact` (0.3 s negative window). | OK |
| Activation off | No lane means no task and no store access. | OK |
| Lookup reads the wrong attempt | RecoveryActions :188-192 looks up `runAttempts.first { $0.runAttemptID == sourceRunAttemptID }`. It applies only to Continue, Reconcile and Continue in new conversation. | OK |
| Resend | The unusable-observation path keeps `isUnconfirmedObservation: true`. Continue sends its continuation text and does not replay the original message. | OK |
| Revision handling | It reads the current revision inside the gate. An identical value returns `.unchanged` before `requireRevision`. Other extras are kept (store test). | OK |

## Findings

### F1 — P2 (P1 if reachable): a skipped non-user turn leaves an older, finished user turn recorded

**Evidence.** `recordCodexProviderTurn` returns early for any `turnKind != .user`. The report's "Uncovered paths" item confirms that `.unknown` and `.review` turns are never recorded. The record is last-wins over *user* turns, not over "the turn running at the kill", which is what the model doc comment says it names.

**Failure scenario.** In one run attempt:
1. User turn `T1` becomes authoritative and is recorded.
2. `T1` completes.
3. A `.compact` or `.unknown` turn `T2` becomes authoritative under the same `activeRunOwnership`.
4. The app is killed during `T2`.

After relaunch, Check and Reconcile observe `T1`, which is `completed`. That is exactly the path `testCheckReportsAConfirmedAndSavedCodexCompletionAsResolved` pins, so the interrupted run is reported **resolved** and `T2` is never surfaced. This is the "wrong turn" case, reached by skipping a turn rather than by reordering writes.

**Reachability.** Not verified. It depends on whether RepoPrompt ever starts a compaction turn, or sees an unattributed turn, inside the same run attempt after a user turn.

**Smallest fix.** In `recordCodexProviderTurn`, when a non-user turn becomes authoritative for the active run attempt, **clear** the recorded ID instead of returning. Use either a store `clearRunProviderTurn` or a write of `.null` / key removal. Reconcile then says "wasn't identified", which is honest. Add one row to the coordinator test: user turn, then compaction turn, then the record is cleared.

### F2 — P2: the "contains tool calls" text on a found turn with missing or empty items (your question)

**Answer: yes, it's worth fixing, and the cheap version is a wording change.**

**Evidence.** The report says `recoveryItems` returns `nil` both for unsupported item types and for a missing or empty `items` array. `unusableObservationText` only checks `observation.turnID == nil`, so both cases say the turn "contains tool calls".

**Why it matters.** The sentence asserts a fact that may be false. Tool calls imply side effects, so a user told "it ran tools" may go and check their working tree for nothing. It is also not just a corner case:
- a kill before the rollout flushed any item can produce a found turn with no items;
- I believe some Codex app-server v2 responses return `Turn.items` as an empty list except on `thread/resume`/`thread/fork`. Please check this against the schema under `prompt-exports/openai-pricing-evidence/codex-app-server-schema/v2` for the `.turnsList` source.

If that holds, the "tool calls" text could be the *common* result.

**Smallest fix.** Change one constant to a neutral sentence, for example: "Codex's record of the interrupted turn can't be imported (it has tool calls or no readable items); nothing was imported." Update the two test strings to match.

The better fix, only if it stays under about 20 lines, is to make `recoveryItems` return a three-way result (`.items` / `.unsupported` / `.unavailable`). Then `CodexRecoveryObservation` can carry an `itemsUnavailable` flag and each case gets its own text. Defer that until partial import is designed.

### F3 — P2: the order of two quick writes is assumed, not enforced

**Evidence.** Each write is its own `Task { @MainActor }` entering `lane.transaction`. The order is only preserved if the main-actor jobs run FIFO *and* the lane gate admits waiters FIFO, with no actor hop in `transaction` before the gate is taken. The report's "Unresolved" section acknowledges this.

**Failure scenario.** `user-turn-1` and a steer-mismatch `user-turn-2` arrive close together, and the writes commit in the order 2 then 1. The record then names `T1` while `T2` was running at the kill, which is the same outcome as F1.

**Smallest fix.** Chain the writes per session:

```swift
let previous = session.codexProviderTurnWriteTask
session.codexProviderTurnWriteTask = Task { @MainActor in
    _ = await previous?.value
    ...
}
```

That is about 4 lines and one stored property. It guarantees commit order without an ordering token in the store.

### F4 — P2 (verify): the write is lost if the run attempt isn't committed yet, and is never retried

**Evidence.**
- The store refuses with `runAttemptNotFound` and the coordinator only logs it.
- The same-ID repeat path (`current.turnID == turnID`) writes nothing, so a failed first write is never retried.
- The report says "the dispatch commit creates it before the provider write". That holds only if every Codex `turn/start` path *awaits* `ensureRunAttempt` first. Paths to check: fallback-queue drain, resumed-thread dispatch, and the steer-to-`turn/start` fallback.

**Failure scenario.** `turnStarted` arrives before a fire-and-forget `ensureRunAttempt` commits. The ID is never recorded, and Reconcile says "wasn't identified". The result is honest but defeats R2 on that path.

**Smallest fix.** Confirm that every dispatch path awaits `ensureRunAttempt` before the provider write. If any path doesn't, route that `ensureRunAttempt` through the same per-session chain as F3, so it is ordered before the turn-ID write.

### F5 — P3: test gaps

These are cheap to add:
- **Record wins over span.** No test has both a span `providerTurnID` and a *different* recorded ID. Add one row to the Check test, with span `"turn-old"` and record `"turn-c"`, so the record really is pinned to win over the span.
- **Write guards.** The coordinator test doesn't cover the ownership-mismatch guard (identity on another run attempt means nothing is written) or the no-lane guard.

## Note (not a defect)

A late provider-turn write rewrites the record and bumps its revision. A Check or "It stopped" write that lands between the card render and its own write will take the existing conflict-and-retry branch. That costs nothing extra, but don't treat it as a new error in logs.

## Recommendations

1. **F1:** confirm whether a `.compact` or `.unknown` turn can become authoritative under a run attempt after a user turn. Either way, clear the recorded ID on non-user authoritative turns instead of skipping them. This is the only finding that can make Check falsely report an interrupted run as resolved.
2. **F2:** make the neutral wording change now, and check the Codex v2 `Turn.items` population rule for the `.turnsList` source. Add the three-way items result later, together with partial import.
3. **F3:** chain the provider-turn writes per session (4 lines) so last-wins means newest-wins.
4. **F4:** check that `ensureRunAttempt` is awaited before `turn/start` on every Codex dispatch path. If not, put it on the same chain.
5. **F5:** add the record-over-span test row and the ownership-mismatch and no-lane negatives.
6. Run `AgentRecoveryActionTests` and `AgentRecoveryActivationTests` once the parallel worker is finished, because the RecoveryActions lookup change touches their area. Include the rewritten Check test in the live re-check's Codex fixtures.