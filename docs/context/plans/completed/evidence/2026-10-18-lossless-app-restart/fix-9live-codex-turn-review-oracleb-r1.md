# 9-live fix 5 (Codex turn ID): OracleB review, round 1

Scope: read when the task touches how recovery identifies the interrupted Codex turn, the run attempt's provider turn ID, or the Codex history matcher's text.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 1) of the Step 5 diff, copied from its export; the fixes are in fix-9live-codex-turn-worker.md


# Re-review: Step 5 (R2), Codex native turn ID — round 1

**Verdict: F1 and F3 are fixed, and these changes introduce no new P0 or P1.** I worked from the r1 diff and the report only. I did not read the source outside the diff or run the tests.

## F3 (write order): fixed

- `recordCodexProviderTurn` runs synchronously on the main actor. It reads the current tail (`previous`) and installs the new task as the tail in the same step, so nothing can slip between those two operations.
- Each new task does `await previous?.value` before it enters the lane. Writes therefore commit in the order the turns became authoritative, whether or not the lane admits waiters first-come-first-served.
- `testProviderTurnWritesCommitInAuthoritativeInstallOrder` checks this deterministically: it holds T1 at the seam, asserts that T2 has not entered the lane, and checks that the stored value was `user-turn-1` when T2 entered. The report says the test fails with the `await` removed, so it actually guards the chain.

## F1 (stale user turn): fixed

- Any authoritative turn on the active run attempt now writes through the chain. A `.user` turn writes its ID, and any other kind writes `nil`. A finished user turn is therefore never named once a compaction, review or unknown turn has taken over.
- The test row "user turn, then compaction turn → record cleared" covers this. The store test covers the clear and confirms a second clear is `.unchanged` and that `providerKind` is kept.

## New risks checked

| Concern | Result |
|---|---|
| Chain blocks event handling | No. Production code never awaits `codexProviderTurnWriteTask`, and the install is synchronous. |
| Deadlock with the recovery lane | None in the diff. The only thing waiting on the chain is the chain itself. If some lane transaction stalls, later writes queue behind it, which is the same as before the chain. |
| Leaks across runs or sessions | No. Each write captures its own `lane` and `ownership` when it is installed. A queued write from run A still targets A's attempt through A's lane binding, and the store checks the transcript generation. Completed tasks release what their closures captured, so the chain does not grow without bound. |
| A clear erases the ID of the turn running at the kill | Only if a non-user turn becomes authoritative while the user turn is still running. Codex runs one turn per thread at a time, so the authoritative turn at the kill *is* the non-user turn, and "wasn't identified" is the honest result. I can't fully rule out a stray `.unknown` `turnStarted` while a user turn is live, because the event routing is outside the diff. |
| Suppressed log for a compaction-only run | Correct. It only matches the `nil` case on `runAttemptNotFound`. |

## One residual item (P3, cheap)

**The lookup can't tell "cleared" from "never recorded".** In `RecoveryActions` (~:188), a `nil` record keeps the span-derived `codexTurnID`. If a span ever carries a `providerTurnID`, a run cleared by a later compaction turn falls back to the older span turn. That reintroduces the F1 problem through the fallback path.

The report says spans stay unwritten (plan §8), so this path is dead today. The smallest guard is one of:
- drop the span fallback for Codex; or
- store the clear as `.null` (key present) and fall back to the span only when the key is absent.

## Recommendations

1. Accept F1, F2 and F3 as fixed. No further change is needed for P0/P1.
2. Optionally close the P3: make the span fallback unreachable after a clear, either by dropping it or by writing `.null` and falling back only when the key is absent.
3. Still outstanding from round 0:
   - Run `AgentRecoveryActivationTests` once the parallel worker finishes.
   - Add the ownership-mismatch and no-lane guard negatives in a later pass.
   - Include the Check test's two rows in the live re-check fixtures.