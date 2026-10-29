# Phase 1b production cutover — OracleB R2

Scope: read when the task touches the final re-review findings for lossless-restart Phase 1b production input integration.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by main. Snapshot: `6d2ed2ec080604b02988df923c6a2e37fa0e70ba`. Final allowed re-review; verbatim response follows.

# Oracle Review



# R2 final re-review: Phase 1b input integration (93e8db40 → 6d2ed2ec)

This round checked the 8-file delta for regressions and confirmed my R1 dispositions. I did not run any code. Line numbers are approximate, taken from hunk offsets.

The delta does five things:
- It protects a restored draft whose rollback failed, across same-binding hand-over, ownerless release and reclaim, and a retired transit-only middle owner. It does this with an in-memory obligation, a rollback retried before every write, and explicit resolution that is written durably first.
- It keeps an older queue head ahead of newer input when both target a live instruction wait.
- It holds input that would otherwise be saved but invisible: the wait ended, the claim was refused, or the run-start prefix was blocked.
- It records instruction-wait handoffs as `deliveryUnknown` instead of `providerAccepted`.
- It fixes test ordering in the pre-denied lifecycle test.

The composer protection and the FIFO changes are sound. I traced adoption, the transit-only owner, retirement filtering, the consumption exclusion and both resolution paths, and found no way to lose a draft. The one regression I found that matters comes from the `deliveryUnknown` change.

## P1

### R2-1 — Every successful instruction-wait answer becomes uncertain input, and sessions get crash holds after every relaunch, including after a clean quit
- **Where:**
  - `AgentModeViewModel.swift` ~20467 (`deliverDurableQueuedInstructionHead`) and ~20514 (`claimLiveInstructionWait`): `noteAccepted()` became `noteDeliveryUnknown()`.
  - These interact with existing, unchanged rules in `AgentRecoveryCoordinator.swift`:
    - `uncertainInputHoldReason` (~830) flags any `deliveryUnknown` intent whose run has terminal or shutdown evidence.
    - `deriveCrashHolds` (~520) holds every earlier-instance `dispatching`/`deliveryUnknown` intent, whether or not the previous exit was clean. Its comment says "terminal run evidence settles completion, not … delivery".
    - `pruneHeldPresentation` drops held notes only for `providerAccepted` or `withdrawn`.
- **Scenario:**
  1. The agent is in `waitingForUser`. The user types a reply in the composer, or an MCP caller sends one. It is handed to the wait, and the agent answers normally.
  2. When the run ends, `presentUncertainInputOfEndedRuns` registers the reply as held: "Its run ended before delivery was confirmed." The recovery list then offers a send action for a message the agent visibly acted on, which would duplicate it.
  3. The owner quits and relaunches. Every session that used the wait in the previous launch now has a crash hold, and every send in it needs "the previous run may still be running" confirmation. Acknowledgements are exact, so each launch's new wait answers trigger the prompt again.
  4. There is no path from `deliveryUnknown` to `providerAccepted`, so these intents never settle.
- **Impact:** This is the normal reply path to a waiting agent, both composer and MCP. It produces a wrong delivery status, a row that invites a duplicate send, and a send-blocking confirmation after every restart. The tests were updated to assert `deliveryUnknown` at handoff, but none covers what happens after the run ends or after a relaunch, so the 799-test run could not catch this.
- **Smallest fix, either of:**
  - **(a) Revert both sites to `noteAccepted()`.** Document the claimed continuation as this route's local acceptance boundary. That is the F-3 design both lanes closed in R1.
  - **(b) Keep `deliveryUnknown` at handoff, and upgrade to `providerAccepted` on the first provider event for the same run attempt after the resume.** Any output after the tool result proves the provider consumed it. The intent stays unknown only if the run ends with no later activity. This needs the store to allow the `deliveryUnknown → providerAccepted` transition for this evidence kind; check that first.

  For this checkpoint I recommend (a); (b) can follow as hardening. Either way, add one test asserting that a wait answer followed by a normally ending run produces no held note and no next-launch crash hold.

## P2 (listed, not looped)

- **R2-2 — Whether a wait-claim race ends queued or held depends on timing** (`AgentModeViewModel.swift` ~17043).
  - **Scenario:** an older re-queued head A claims the wait while B is still preparing. If A's delivery finishes before B resumes, `instructionContinuation == nil` and B is held with "The agent stopped waiting…", even though the run is active and will wait again. If B resumes first, it is queued behind A. The test covers only the second order.
  - **Fix:** in that guard, if `session.runState.isActive`, call `queueBehindOlderInstructionHead` instead of holding. The same applies to a wait that timed out while the run continues.
- **R2-3 — A head that can never be delivered now stalls all later input to the wait.** This turns R1-8 from loud into silent.
  - With a permanently blocked head (prefix attach conflict), each new input queues behind it and the live wait never receives anything. Before this delta, B claimed the wait.
  - The trigger is contrived. **Fix:** when head delivery fails with the attach conflict, hold the head (R1-8's suggestion), which unblocks the queue.

## P3

- `resolveProtectedRestore` failure with `placing != nil` leaves an empty pending snapshot. If a later rollback succeeds, `retryOutstandingRestoreRollback` reports `heldComposerUnresolved` against an empty composer. Treat empty pending as nil there.
- The ownerless list renders only `inputs.first`. A protected first entry has no actions, so a residue entry behind it (for example "newer typing") can't be seen or discarded until the session is reopened. The row text does tell the user to open the session.
- `queueBehindOlderInstructionHead` with a non-durable identity plus attachments queues text only and drops the attachments. This is reachable only when admission isn't mandatory, which isn't the case in production.

## My R1 findings

| ID | Status |
|---|---|
| R1-1 | **Closed.** Continuation wait-loss and claim refusal now hold or queue; the start-prefix block holds for the two non-requeuing callers, and `holdsPrefixBlockedInput` is never combined with requeue. Hold instead of requeue is acceptable; the timing variance is R2-2 (P2). |
| R1-2 | Deferred (P2) to Phase 2 explicit resolution and dismissal. **Accepted.** |
| R1-3, R1-5 to R1-8 | Deferred. **Accepted.** R1-8 interacts with R2-3. |
| R1-4 | **Closed.** Job 4f173a11 on 93e8db40, plus the final combined job e25cda86 on 6d2ed2ec (799 tests, 0 failures) covering those suites. |
| F-8 notes | **Closed.** Retention deviation and the history-dependent cost trigger are recorded. |
| Composer rollback protection (new) | No regression found. |
| FIFO older-head priority (new) | No regression beyond R2-2 and R2-3. |
| Pre-denied lifecycle test fix | Sound; assertions and timeouts unchanged. |
| **Open P0/P1** | **R2-1** |

## Recommendations
1. Fix R2-1 with option (a), plus the one end-of-run/relaunch test, then rerun the affected recovery and producer suites. This is the second and last allowed re-review, so if you don't take (a) or (b), R2-1 goes to the owner as an open P1.
2. If the fix is (a), the reviewed behaviour returns to the F-3 contract both lanes closed in R1, so it needs only validation, not another review round.
3. List R2-2, R2-3 and the P3s as deferred, with R2-2 as the cheapest (a one-line guard change).
4. Once R2-1 is resolved and validation passes, checkpoint Phase 1b with signing and move on to R4 quit/window-close preservation. Live acceptance (O3) is still pending.
