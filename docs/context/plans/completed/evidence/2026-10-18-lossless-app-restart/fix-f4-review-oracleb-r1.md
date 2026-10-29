# Step 7-F4 — OracleB re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F4 (/compact after a cancelled Codex compaction) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F4, local fix-f4-r1-delta.diff and fix-f4-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review

# Step 7-F4 re-review, round 1: `/compact` after a cancelled Codex compaction

**Result:** I'm not contesting any disposition, and the delta adds no P0 or P1. I found five new low-severity items (one P2, four P3), listed below. They're for your list, not for another round.

**What the delta does:** It removes the ownership comparison, so `/compact` now refuses when the run-attempt generation changed or a run is active. It moves the "reconnect in progress" mark into `ensureCodexNativeSession`, so it covers the whole readiness pass, including the MCP startup-lease wait. The mark now keeps a reference to its controller. On the test side, the cancel test now cancels a real compaction through the view model's Stop path. The concurrent test now uses distinct controllers, the failed-reconnect test now retries, and there are two new gated tests for the overlap check and the session-rebind check.

## Disposition checks

| Finding | Verdict | Notes |
|---|---|---|
| B F4-R1 | Accepted | Analysis below. |
| B F4-R2 (mine) | Accepted | The code-reading trace covers each call the lease path and the managed-auth recovered start make, and none of them begins or ends a run attempt or binds a session. If this were wrong, idle `/compact` would fail with the "A Codex turn started…" message, and the user could still send a message. That is a loud failure with a clear recovery, so the missing lease-enabled test stays at P2. The live acceptance run should include one idle `/compact` with production tooling enabled (`shouldManageCodexTooling`). |
| B F4-R3 | Accepted | The test now cancels a real compaction through `cancelAgentRun(.userCancel)`. It still passes on the old logic, so the "lazy resume" explanation stays refuted. |
| B F4-R4 | Accepted | `other.resumedConversationIDs == []` does prove that no second controller was requested. |
| B F4-R5 | Accepted, one P3 below | Balance analysis below. |
| B F4-R6 | Accepted, one P3 below | Test detail under F4-RR4. |

### The simplified overlap check (B F4-R1)

It can't let compaction overlap a newly admitted turn:
- **A new attempt that starts and finishes** while `/compact` waits still advances the generation (`testRunStartedAndFinishedDuringReadinessRefusesCompaction`).
- **An admitted turn that never began an attempt**, like the untracked direct send, still sets the run active, so the `runState.isActive` half refuses it.
- **No suspension point after the checks.** From the generation check through the availability recheck, the controller guard and `codexStartIsInFlight` to `beginCodexCompaction`, everything is synchronous. A later submission therefore sees `.running` and the compact turn kind.
- **The only thing the dropped ownership comparison caught** was an old attempt that is ending. That doesn't overlap anything. If that attempt's late `endRunAttempt(ifCurrent:)` arrives after `beginCodexCompaction`, it no longer matches the current attempt.
- **One case is not overlap:** an intent the run service accepted but hasn't dispatched yet. Its dispatch will see compaction running and take the existing active-run path. That behaviour is unchanged by this step.

### Balance of the relocated in-flight mark (B F4-R5)

- **Every exit is covered.** A `defer` at function scope clears the mark when the pass returns, throws, is cancelled or returns early after a lease failure. That includes `lease.failAndRelease()` followed by a return.
- **Re-entry is balanced.** The recursive pass after the policy is installed, and the recursion after a missing route, each take and release their own counted mark. The managed-auth recovered start keeps its own nested mark.
- **Controller replacement is balanced.** `/compact`'s pass clears the mark on `first` when it returns. The replacing pass keeps `successor` marked until it settles. `testControllerReplacedDuringReadinessReportsReconnectInProgress` depends on exactly that.
- **No ObjectIdentifier reuse.** The mark keeps its controller alive, so another object can't take the same identifier while the mark is live.

## P2

**F4-RR1 — The in-flight mark is taken on the controller in the slot when the pass begins, not on the one actually started**
- **Evidence:** In `CodexAgentModeCoordinator.swift`, `markCodexStartInFlight(session.codexController)` runs at about :5168. The start-site mark on `startController` (about :5290) was removed. The pass-entry mark is only right if nothing replaces the controller between :5168 and the start, other than the recursion and the managed-auth path, which take their own marks. The replacement test only covers a replacement *before* the mark. I can't confirm from the diff that `startController` always equals the marked controller.
- **Scenario:** Some later code in the pass swaps the controller without recursing, then starts it. A concurrent `/compact` then sees an unmarked controller that is still starting.
- **Impact:** Message wording only. The user gets "Couldn't reconnect… try /compact again" instead of "still reconnecting". The thread is not lost and nothing is compacted.
- **Smallest fix:** Put back the 2-line start-site `mark`/`defer` on `startController`. Marks are counted, so marking the same controller twice is harmless. Alternatively, add `assert(startController === startInFlightMark?.controller)`.

## P3

**F4-RR2 — The mark now keeps a controller alive across the whole lease wait**
- **Scenario:** Stop or a replacement invalidates the controller while another pass is waiting on the MCP startup lease. The invalidated controller then stays alive until that pass ends, not just during its own start.
- **Impact:** If any teardown (process exit, finishing the event stream) relies on `deinit` and not on an explicit `shutdown()`, that teardown is delayed by the lease wait.
- **Smallest fix:** Confirm that `invalidateCodexControllerForReconnect` shuts the controller down explicitly. If it doesn't, store a weak reference plus the `ObjectIdentifier` in the mark, and treat a dead reference as "cleared".

**F4-RR3 — The worker report contradicts itself (docs only)**
- The "Fix" section still says the code captures `activeRunOwnership` and checks "generation, ownership or active run state". It also says the mark sits "around the attempt's own `startCodexNativeSession`".
- The test table still lists `testCancelDetachThen…` and 6 tests.
- Someone reading only the top half of the report would come away with the old design.
- **Smallest fix:** Add one line to those sections saying they are superseded by "Review fixes (round 1)", or update them in place. Do this together with the R9 link edit.

**F4-RR4 — The R6 retry test can't tell "reused controller" from "new controller"**
- The factory returns its last controller again when it runs out. So `fresh.resumedConversationIDs == ["thread", "thread"]` holds whether the retry reused the controller in the slot or asked the factory for a new one.
- **Smallest fix:** Give the factory a second controller and assert that it was never resumed, as the R4 test does.

**F4-RR5 — Two resumes run at once on the same controller (observation; predates this step)**
- In the concurrent test, the gate reaching 2 waiters with `other` unused means `fresh.startOrResume` ran twice concurrently: once for `/compact` and once for the send.
- That matches production readiness today, which has no single-flight join. The test doesn't assert on it, and this step doesn't change it.
- Track it with the existing open question about single-flight joins. The in-flight mark is now a natural place to detect it later.

## Recommendations

1. **Commit is unblocked.** No P0 or P1 is open. Do the R9 evidence link and the F4-RR3 note in the same docs edit.
2. **F4-RR1:** cheapest to just put back the start-site mark (2 lines, harmless because marks are counted) instead of relying on the "no replacement after :5168" argument. If you do, rerun `CodexCompactReadinessTests` and the 9 focused suites. That's a later edit to reviewed behaviour, but it narrows the existing invariant without changing it, so it doesn't need another review round.
3. **F4-RR2:** spend about a minute confirming that invalidation calls `shutdown()` explicitly. If it does, close the item.
4. **Live acceptance:** add one idle `/compact` with production tooling (`shouldManageCodexTooling`) to close my B F4-R2 residual. Also do one cancel → `/compact` re-run, so the new `CodexSlashCommand` refusal reasons name the mutation that actually happened in the K3 race.
5. **F4-RR4 and F4-RR5:** list as deferred. Neither needs a round.