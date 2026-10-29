# Step 7-F1 — OracleB re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F1 (scheduled follow-up handoff hold and terminal attribution) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F1, local fix-f1-r1-delta.diff and fix-f1-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review



# Re-review round 1: Step 7-F1, scheduled follow-up withdrawn before the non-Codex runner dispatches

**Basis:** I had only `fix-f1-r1-delta.diff`, `fix-f1-current.diff`, the worker's "Review fixes" section and the spec. I could not open the repository files. Line references point into those diffs, or into code the worker cited. Where a claim rests on code I could not see, I say so.

## Summary

The delta fixes the round-0 findings:
- **Coordinator registry.** The deferred run-start registry moved from the lane to the coordinator, so a successor tab can see its predecessor's pending handoff.
- **Successor path.** `resolveScheduledSendTransfer` now checks that registry before the R9 repair. The settle-signal observer also wakes other owners of the same durable session.
- **`.undecided`.** A new `.undecided` result separates "could not read safely" from "pending".
- **Attribution.** The prepare-time fallback to the session's last user item is gone, so durable input is attributed only to its own item.
- **Cleanup.** Only intents the scheduled owner marked as awaited keep a no-handoff settlement. Every other entry is cleared when it settles.
- **Banner and failure commit.** The banner always shows the generic scheduled message, and the handoff's own reason is logged. A failed failure-commit keeps an unresolved hold.

I found no new P0 or P1. Three small P2s and a few P3s are listed below.

## My round-0 items

| Item | Status | Notes |
|---|---|---|
| **F1-R2** (successor repair ignores the registry; conditional P1) | **Resolved, accepted** | Three things now hold. (1) The successor's claim retires the old lane. A late commit through the old session then fails at `dispatchRefusal` (`session.recoveryLane` is the retired lane). The new test checks for `.refused(.laneRetired)` and that the intent stays `queued`. So the duplicate-delivery case does not occur. (2) The registry is per coordinator, so the successor sees `.pending` and holds instead of moving the input to the saved queue (`savedInQueue`). (3) The observer's `sessionID` match lets the retired lane's settle signal wake the successor. One case I checked: if the old runner settles before the successor hydrates, the entry stays `.notHandedOff`, because the scheduled owner marked it awaited. The successor's resolve then settles it directly. |
| R1/R11 `runnerOwnsInputOnNil` | Fixed | It is a non-defaulted `let`, computed the same way before the await at both start sites. Every other construction passes an explicit `false`. |
| R3 settle only after a successful read | Fixed | The guard is split. `.notDeferred` is returned only after a successful read. Owner-not-current, lane problems and read failures all return `.undecided`. |
| R4 prepare-time pin | Fixed | `attributedUserItemID(of:)` no longer looks at the session. Durable input always carries a `userItemID` (non-optional by type, per the worker's citations). Untracked input with no item keeps the old behaviour of attributing to the last user item at terminal time. |
| R5 exact regression | Fixed | The test covers `[earlier(completed), own]` with own removed, an ordinary `.failed` with error text, the earlier turn unchanged, and the error shown once. |
| R6 tests | Partially fixed; deferral accepted | The `.appQuit` variant with persisted-state checks is a good addition. Driving the real Claude runner from a scheduled send is reasonably deferred as P2. Coverage is split across the lifecycle tests and the scheduled tests through `prepareRunStart`. |
| R7 `startRun` call-site audit | Accepted | |
| R8 registry cleanup | Fixed | Some memory is still retained in rare cases (see P3-a). |
| R9 banner text, R10 doc comment | Fixed | |

I am not contesting any disposition.

## Regression check (scope items)

- **Registry lifetime and cleanup.**
  - Entries are created only in `prepareRunStart`.
  - They are cleared on commit (now through `clearDeferredRunStartHandoff`, which also drops the mark) and on a no-handoff settlement unless the intent was marked awaited.
  - The scheduled owner clears them on the revoked, delivery-unknown and explicit-outcome exits, and before `withdraw` in the settlement.
  - Clearing before `withdraw` is safe. If `withdraw` fails, the hold is `.unresolved`, the runner has already settled and cannot commit late, and any later R9 run reads a `queued` intent that really was never handed off.
- **Cross-owner wakeups.** Only live sessions are iterated. Each recheck still goes through `scheduledSendTransferOwnerIsCurrent` and `session.recoveryLane === lane`, so the replaced predecessor never acts. `testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput` still covers that.
- **Race between the registry check and the commit.** The registry is checked synchronously after the `readRecord()` await.
  - If a commit lands during that await, the entry is already cleared, the result is `.notDeferred`, and the R9 repair re-reads and finds `dispatching`, which it holds.
  - If the commit is still in flight, the entry is still `.pending`, so the owner holds.
  
  Neither order produces a wrong decision.
- **`.undecided` in the recheck path.** It behaves exactly as `.pending` did in round 0: it breaks and keeps the `.awaitingProviderEvidence` hold until the next signal or run-state change. That is not a regression. The new `.undecided` handling in `resolveScheduledSendTransfer` is covered under P2-b.
- **Codex.**
  - `runnerOwnsInputOnNil` is `false` on every Codex result.
  - The new explicit-outcome `clearDeferredRunStartHandoff` is a no-op for Codex, which never prepares a deferred handoff.
  - The Codex returns from the knowledge and workspace exits were already `.failed`.
  - The one change that reaches Codex is the pre-check in `resolveScheduledSendTransfer` (P2-b).

## Findings

### P2

**F1-r1-N1: a failed failure-commit leaves the in-memory record and the hold disagreeing**
- **Where:** `AgentModeViewModel+ScheduledSend.swift`, settlement around delta lines 1714–1729, together with `markScheduledSendFailed` (~2318–2340).
- **Scenario:**
  1. The withdraw succeeds and the bubble is removed.
  2. `markScheduledSendFailed` sets `session.scheduledSend = .v1(failed)` and `isDirty = true` before `commitScheduledSend`, and the commit fails.
  3. The settlement then holds `.unresolved` against the old `.dispatching` record.
- **Impact:**
  - **In this session:** the recheck and resolve paths both require `record.state == .dispatching`, but the in-memory record is now `.failed`. Nothing in the session can release the unresolved hold, and a later dirty save may persist `.failed` while the banner still says the status could not be saved.
  - **On relaunch:** if disk is still `.dispatching`, R9 sees a withdrawn linked intent, treats it as a rolled-back admission, and normalizes to `needsConfirmation(deliveryUnknown)`. That marks a message known to be unsent as "may have been sent".
  - Nothing is lost or duplicated, and this needs a schedule-commit failure. The worker says this path is not exercised.
- **Smallest fix:** in this caller, restore `session.scheduledSend` and its dirty flag to the dispatching record when the commit returns `false`, so the hold, memory and disk agree. Alternatively, release the hold once a later save of `.failed` succeeds.

**F1-r1-N2: the new pre-check in `resolveScheduledSendTransfer` puts `.undecided` ahead of R9 for every provider**
- **Where:** delta lines 1752–1782.
- **Scenario:** restart or hydration repair for any record with an attempt, Codex included, where `lane.readRecord()` fails or the lane is retired or for another session. The record now gets the "not available yet" hold. Before, `performScheduledSendTransferRepair` re-read the record under the DataService gate and decided.
  - The worker states equivalence only for a missing lane.
  - Equivalence for a read failure is not shown.
  - The diff does not show what later re-runs the resolve once the lane or record becomes readable. If nothing does, the hold lasts the whole process lifetime.
- **Impact:** conservative (a hold, never a wrong transfer), but it is a behaviour change outside F1's scope and it reaches the Codex path.
- **Smallest fix:** gate the pre-check on registry contents. If the coordinator has no deferred entries at all (no runner in this process can be pending), go straight to the R9 repair, as before. The new path then applies only when a deferred handoff exists.

**F1-r1-N3: the hold on a failed status save is not tested.** This is the same gap the worker reported. It falls in the safety fence of committing before release. One seam-free option is to make the session's scheduled-send commit fail through an expected-`updatedAt` conflict, if the harness allows writing the record behind the session.

### P3

- **P3-a: memory retained in rare cases.** A `.notHandedOff` entry and its mark stay in the coordinator when the scheduled hold ends by another route: schedule cancelled or deleted, session deleted, or any `finishMandatoryScheduledDispatch` exit before the revoked branch (not visible in the diff). The cost is memory only. A stale entry can act only when a linked `.dispatching` attempt exists and its intent was never dispatched, which is the correct case anyway.
- **P3-b: silent no-op without a coordinator.** The registry accessors use `coordinator?`. If a lane's coordinator reference were ever `nil`, `noteDeferredRunStartHandoffPrepared` would do nothing, `deferredRunStartHandoffState` would return `nil`, and the result would be `.notDeferred`. R9 would then read a pending `queued` intent as saved input, which is the original F1 failure class. In production the coordinator presumably outlives its lanes. Consider an `assert`, or treat a missing coordinator as `.undecided`.
- **P3-c: redundant observer condition.** The `session.recoveryLane === lane ||` part (delta line 158) is now redundant. Matching on `sessionID` alone covers it.
- **P3-d: stale comment.** `testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput` says the input "stays saved for its successor owner's repair". Since the registry change, the successor applies the no-handoff settlement and fails the schedule. The comment should say so.

## Recommendations

1. **Commit.** No P0 or P1 is open, so the step can be committed under the policy. Status: `rounds 1/2 | open: — | deferred: R6 (scheduled send through the real Claude runner), N1–N3, P3-a–d`.
2. **Cheap fixes if time allows:** N2 (registry-empty fast path, which also keeps the Codex restart repair exactly as before) and N1 (restore the in-memory record on a failed commit). Neither needs another review round. Per the policy, re-review only if reviewed behaviour changes, and N2 would.
3. **One check I could not do:** confirm that Codex never reaches `guard let handoff else { return .stale(...) }` in `AgentModeRunService.startRun` (~line 718). The new comment says every non-Codex route prepared a handoff, which means Codex must branch off earlier. If Codex could reach that line, its `nil` meaning would change. A one-line read of the code between lines 663 and 715 settles it.
4. **Before calling F1 done:** run the full `make dev-test` and `make dev-core-test`. The step's own change touches every provider's pre-runner exits, the terminal barrier and the shared recovery coordinator, so the 20 focused suites are not enough on their own.