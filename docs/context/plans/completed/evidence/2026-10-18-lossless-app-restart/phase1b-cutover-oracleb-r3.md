# Phase 1b production cutover — OracleB R3

Scope: read when the task touches the owner-authorized third re-review findings for lossless-restart Phase 1b input integration.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by main. Snapshot `a2617a770d9bd8bafb8c68aa69d43e912e4a0c7b`. Decision O7 authorized this extra round; verbatim response follows.

# Oracle Review



# R3 re-review: Phase 1b composer-preservation delta (6d2ed2ec → a2617a77)

This round covers the three-file delta and my R2-1 contest. I traced the code by hand and did not run anything. I relied on the validation you reported: 802 tests with 0 failures, the focused Coordinator 30 + Composer 21 run, and lint exit 0.

The delta makes two changes:
- **R02-R2 placement fence.** When the user chooses Restore on a protected restored copy, the placement is written only while it is still the live composer revision. If newer typing lands during the write, the committed placement becomes a new protected revision and is put straight back into the held slot. If that put-back fails, the lane's visible copy takes on the new obligation.
- **R02-R1 in-flight transfer.** When a lane retires while a resolution is still running, retirement now carries forward the obligation that resolution created, exactly once and ahead of the newer typing it raced.

I traced these paths and all hold:
- Fence check, then snapshot capture inside `writePending`. Nothing can suspend between them, so the snapshot is always the placement.
- Commit followed by put-back success. The entry is removed by `restoreRollbackDidSucceed`, the state becomes `.held`, and the result is `composerChangedDuringRestore`.
- Commit followed by put-back failure, with the lane live and with the lane retired. Retirement drops the stale obligation O1 and appends O2 once.
- Failed write with typing. The obligation is restored and the typing is kept.
- Retirement with `preserving: false`. `retire` waits for `operationTail`, so the obligation is known before `outstandingRestoreRollback` is read.

I found no path that loses a draft or carries one twice, and no P0 or P1.

## My previous findings

| ID | Status |
|---|---|
| **R2-1** | **Contest withdrawn. I accept P2, deferred.** Reasoning below. |
| R2-2, R2-3 | Deferred (P2). Accepted. Nothing in this delta touches them. |
| R2 P3s | Deferred. The empty-pending P3 is still present but is now confined: the clearing write happens only while the placement is still live. |
| R1-1, R1-4 | Closed. No change. |
| R1-2, R1-3, R1-5 to R1-8 | Deferred. Accepted. |

### R2-1 disposition
I am withdrawing the contest on the merits:

1. **Part of my R2 scenario was wrong.** `recoveryListIntentActions` gives `deliveryUnknown` only `[.remove]` and `dispatching` gets `[]`. The row says "may have been delivered" and warns about duplicates. There is no send affordance, so the duplicate-send impact I claimed doesn't exist.
2. **My recommended fix (a) conflicts with spec R2.** R2 says "accepted only on affirmative provider acceptance". Resuming the in-app MCP continuation happens before the tool result reaches the provider's transport. Calling `noteAccepted()` there would mark a reply as accepted even if the app crashed before the RPC response was written. That is a false affirmative, which is worse than an honest "unknown". I also agree that generic run output afterwards is not evidence correlated to this intent.
3. **The remaining costs have workarounds and lose nothing.** They are:
   - one exact, durable confirmation per affected session per relaunch;
   - one removable row per wait reply.

   Every workflow I can find can use the existing confirm and remove actions. Under the policy that is P2.

One cost that wasn't stated should go into the deferral record so the owner sees all of it. `hasUnresolvedSession(inWorkspace:excluding:)` counts unconfirmed holds on **closed** sessions. `confirmCrashHold` needs a live lane. So after a clean relaunch, a closed session with a wait reply from the previous launch keeps the whole workspace's scheduler busy until the owner opens that session and confirms it. Scheduled sends are delayed, never lost or auto-sent, so this stays P2, but the deferral entry should name it.

**Smallest follow-up, for later recovery work:** use exact consumption evidence. For example, completion of the RPC response write for that tool-call ID, or the provider's next request that references the tool call, then move the intent to `providerAccepted`. Record it in the status line under `downgraded:`, not as owner-accepted.

## New findings

### P2 — R3-1: The placement fence misses changes that can't be stored yet (open, deferred-eligible)
- **Where:** `AgentRecoveryComposerPersistenceController.resolveProtectedRestore`.
  - The fence compares `liveRevision` only.
  - `noteUnrepresentableComposerChange()` trips only `activeResolutionFence`, which this path never arms.
- **Scenario:**
  1. The user clicks Restore on the protected copy while the gate is busy.
  2. They paste an image that is waiting for promotion, or type next to one. This goes through `composerContentUnrepresentable` and doesn't advance `liveRevision`.
  3. The placement commits and returns `.success(placing)`.
  4. The app then puts the restored content into the composer UI, which can replace the user's unpromoted attachment edit.

  The held-composer restore path is fenced against this case; the new path is not.
- **Impact:** Edits made during a manual click with a busy gate. Unlikely.
- **Smallest fix:** arm an `AgentRecoveryResolutionFence` as `activeResolutionFence` for the placement. Treat a trip as a `liveRevision` change, both before and after the write.

### P2 — R3-2: The new put-back-failure branch has no test (open)
- **Where:**
  - the lane's `resolveProtectedRestore` update branch (`current != obligation` → `restoreRollback = current`);
  - the matching retirement path.
- **Gap:** The failed-write test fails the placement write itself. The committed-write test lets the put-back succeed. No test covers "placement committed, put-back failed", which is the only path that creates the new obligation O2.
- I traced it as correct, but nothing protects it against regression.
- **Fix:** reuse the `commitPublisher` handler pattern to set `shouldFailWrites = true` after the placement commit. Assert that the entry carries O2, that `stored.revision == placement`, and that a later handover rolls back to `held`.

### P3 — R3-3: The controller's own "never consume a protected draft" guard is weaker now
- **Where:** `consumption(for:)`.
- **What changed:** Before, `restoredRevision` was never an issued revision. Now it can be the placement revision, which *is* in `issuedRevisions`. The prefix `issuedRevisions[...index]` would therefore include it if "newer typing" were submitted.
- **Why it's P3:** It is unreachable today. Lane admission refuses while the protected entry exists, and successors use fresh controllers. It still breaks the controller's documented guard.
- **Fix (one line):** `superseded.remove(unrevertedRestore?.restoredRevision)` before returning.

## Recommendations
1. No P0 or P1 is open. Record R2-1 as `downgraded: R2-1 → P2`, owner decision pending, with the scheduler-busy cost written in. Then commit the Phase 1b checkpoint with signing.
2. Fix R3-3 now (one line) and add the R3-2 test if it's cheap. Neither needs another review round; rerun the focused Coordinator and Composer suites. Defer R3-1 unless you are already editing that function.
3. Move on to the R4 quit and window-close contract as the owner prioritised. Do the R2-1 follow-up (correlated consumption evidence) with the next recovery work. Live acceptance (O3) is still pending.
