# Phase 4 OracleB first re-review

Scope: read when the task touches lossless restart Phase 4 first re-review findings or their disposition.
Authority: Reference

Reviewed tree: `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`, delta from `e876de21cca35adeda4d007930080f8ee9cb199b`. Main verified the exact requested OracleB preset identity and read the complete response. This is raw findings evidence, not source acceptance. Whitespace-only normalization removes trailing spaces for the staged check; the original export `prompt-exports/oracle-review-2026-10-22-175729-lossless-restart-pha-18a9.md` retains exact source bytes.

# Oracle Review



# Phase 4 bounded checkpoint: re-review R1 (fixes, regressions, and my own F1–F5)

**What the delta does.** It closes my five required findings:
- **Codex history:** imports nothing when its rows overlap output already in the transcript, but keeps a confirmed completion. Completion is decided before rows are saved and travels on every `.blocked` result.
- **Busy aggregation and holds:** recovery actions now use an app-shared coordinator hold. Exact authorization is carried through admission, dispatch commit and final handoff, and the runner waits for the real handoff settlement before recording an outcome.
- **No duplicate sends:** an item that was already sent, or proven finished, refuses another send.
- **Continue offers:** Continue appears only for current-generation runs that were interrupted after their input was handed off. A completion recorded on the source run attempt stops the dispatch.
- **Continuation payload:** continuations send only their reserved payload.
- **Send saved:** it reuses its intent's bubble through the normal append path.
- **Restart safely:** the helper gets one cleanup budget inside R4's deadline. A delivered signal no longer counts as proof of exit, and ownership is kept when the stop is unresolved.

I reviewed only the fixes, their regressions and my own findings. All of this is from reading the supplied delta and context; I ran no tools. Items marked PLAUSIBLE depend on code that was not supplied (mainly `startAgentRun`, `runStartDidNotHandOff`, and how the live queue handles a refused drain).

**Verdict.**
- **P0:** none.
- **P1:** all of my original findings are closed. The new shared action hold introduces two P1 regressions (N1 confirmed, N2 plausible).
- **Status:** I don't recommend marking this checkpoint free of P1s until N1 and N2 are fixed or explicitly contested. Neither one makes this a complete R4/R7 contract.

---

## Disposition of my findings

| ID | Main disposition | My verdict | Notes |
|---|---|---|---|
| **F1** Codex duplicate import | Fixed | **Closed** | `codexOverlapRefusal` withholds all rows whenever provider output at or after the turn's user item has no association (compacted turns and suffix included). Completion is kept as `.imported(confirmed, 0)`. If `runTurnID` is missing or doesn't resolve to a transcript turn (for example a recovery-only run whose `transcriptTurnID` is a user-item ID), it falls back to `.baselineTargetMismatch`, which withholds rows. That fails closed and is acceptable. |
| **F2** Completion lost on save failure | Fixed | **Closed** | `completion` is computed from the observation before the revalidation and save guards and is carried on every `.blocked`. The runner's `stopBeforeDispatch` and the reconcile-only branch both bind it to the source attempt. |
| **F3a** Not connected to busy aggregation | Fixed | **Closed, with regressions N1 and N2** | Scheduler busy, new-session/`runAlongsideOtherSessions` and cross-window projections are now present and tested. The enforcement scope and the release liveness are the new problems. |
| **F3b** Item resolution / duplicate send | Fixed | **Closed** | `resolvingAction` is enforced both at the store (`validateActionParameters`) and in the row actions. Reconcile stays available. |
| **F4** Continue on finished runs; record evidence ignored | Fixed | **Closed** | `hasVerifiedCompletion` now uses the shared classifier, and status, never-handed-off and reset-generation checks happen in both the UI and the runner. Minor point: the catalog facts parse `key.entityID` as a run-attempt ID. If a turn card's entity is not one, the UI may still offer Continue, but the runner refuses it durably (P3). |
| **F5** Continuation consumes composer | Partially rejected, workflow leak fixed | **Accept the partial rejection; closed** | The supplied source shows `consumesComposer = origin == .composer`, so `.followUp` never took the draft, images, tags or interview choice. The real leak was the selected workflow, and `reservedPayloadOnly` fixes it. The VM test covers it. |
| P2: 16 s abandon wait | Fixed | Closed | `pending(.seconds(16)) == 0` is asserted. Budgets are absolute and never renewed. |
| P2: stale `pendingShutdownReason` | Fixed | Closed | `take()` is the first statement in `applicationShouldTerminate`, and `disarm()` runs after `terminate`. A confirmation that is already showing keeps its own `.appQuit`. |
| P2: SIGPIPE / helper path / ready deadline / restart timeout text | Fixed | Closed | |
| P2: typed cold-observation failures | Listed as deferred | **Effectively fixed** | Every Codex observation error except "no matching record" now returns `.blocked`, so none of them falls through to a send. |

---

## New regressions caused by the fixes

### P1

**N1: the action hold hard-refuses all live work in sibling sessions across the whole workspace, which goes beyond what R9 asks for (CONFIRMED)**

- **Evidence**
  - In `AgentRecoveryCoordinator`, three functions refuse unauthorized work whenever `coveringRecoveryActionHold(sessionID:)` finds a hold anywhere in the workspace:
    - `recoveryActionAdmissionRefusal` (authorization `nil`);
    - `recoveryActionDispatchRefusal`;
    - `recoveryActionPermitsHandoff`.
  - `AgentRecoveryDispatchEvidence.isValidForHandoff` and `dispatchRefusal` apply these checks to every session.
  - `testRecoveryActionHoldCoversItsWorkspaceAcrossWindowsUntilItEnds` asserts that the sibling's queued drain, its MCP input and its manual input are all refused.
- **Failure scenario**
  1. Session B in the same workspace is running and has a queued follow-up, or Claude/ACP steering.
  2. The user clicks Continue on session A.
  3. The hold lasts through A's reconciliation (a Codex observation can take up to 15 s) and until A's handoff begins (a Claude spawn).
  4. During that time:
     - B's turn-boundary drain fails `beginDispatch` with `.recoveryActionInProgress`. That input becomes held ("It stays saved"; the existing `holdBlockedDurableInput` path), so B's run ends without the follow-up.
     - A send in B that was already committed but not yet handed off fails `isValidForHandoff` and is settled back to `queued`.
     - Manual sends in every tab of that workspace are refused.
- **Impact:** instructions the user queued for another agent are silently not delivered, and that agent stops. Nothing is lost, but it needs an explicit resend. This breaks a normal multi-tab workflow.
  - R9 only asks that busy aggregation, which governs automatic admission (scheduler, new sessions, `runAlongsideOtherSessions`), include Resume reservations.
  - A sibling run is already running against the same worktree, so stopping its queue adds no safety.
- **Smallest fix**
  - Keep workspace scope only in the two automatic-work projections, `isCoveredByRecoveryAction` and `hasRecoveryAction(inWorkspace:)`.
  - In the three hard-refusal seams, refuse only when `hold.authorization.sessionID == sessionID`; the action's own session stays exclusive.
  - Change the test to assert that sibling drain, steering and manual input pass while the scheduler and new-session gates stay held.

**N2: action settlement has no liveness backstop, so a start that never settles wedges the session, or with N1 the whole workspace (PLAUSIBLE)**

- **Evidence**
  - `awaitRecoveryActionSettlement` deliberately waits with no timeout.
  - The hold is released only by one of these:
    - handoff began, or evidence was written;
    - the deferred `noteDeferredOutcome` path;
    - a hydration refusal;
    - Codex `.queuedFallback/.stale/.failed/.cancelled/nil`;
    - for non-Codex runs, `runStartDidNotHandOff(outcome)` (`noteRecoveryActionStartReturned`). Its own comment treats a non-Codex `nil` as "admitted; settles through evidence".
- **Failure scenario:** a Claude (or other non-Codex) start fails before any `AgentRecoveryDispatchEvidence` or `AgentProviderHandoff` exists for the payload, for example:
  - provider unavailable;
  - a worktree or registry reservation refused before spawn;
  - another early return in `startAgentRun`.

  If that path returns `nil` and nothing calls `noteNoHandoff`, then:
  - the runner task never returns, and the row spins forever;
  - the hold is never released, so automatic work stays paused;
  - with N1, every input in the workspace is refused until the app relaunches. There is no Cancel for an action.
- **Smallest fix:** add a fenced backstop that can never claim "not sent" for a committed attempt.
  - When the action session's run attempt reaches terminal, or `runState` leaves active, and the hold still has `dispatchAttemptID == nil` and `commitsInFlight == 0`, call `noteRecoveryActionSubmissionEnded`. The existing `settleRecoveryActionIfFenced` rules already guarantee the "never claim not sent" property.
  - Add one VM test with an injected pre-evidence non-Codex start failure that asserts the hold is released.
  - If main can show that every non-Codex start failure already reaches `noteNoHandoff` or `runStartDidNotHandOff == true`, cite those exact lines and this becomes a P2 test gap.

### P2 (listed, not looped)

- **N3: a no-choice prompt where no helper could be armed turns a reversible Stage A into an app-wide freeze.**
  - **Where:** `present()` in `AgentLifecycleShutdownCoordinator`; `testSafeRestartStageAUnresolvedHelperStopWithholdsCancelAndRetry` asserts that participants stay frozen.
  - **Why it's unnecessary:** in Stage A, and in Stage B before `arm` was ever sent, the helper is at most *ready*. A ready helper never opens anything: it opens only after `armed` plus a verified parent exit, and it now expires on its own 8 s ready deadline. Withholding Cancel there breaks R4 Stage A ("any failure cancels the quit and leaves the app fully usable") and leaves force-quit as the only way out.
  - **Fix (also input for the owner's open question):**
    - Track `armSent` in `ProcessRelaunchParentSession`.
    - Withhold choices only for an unresolved helper that may have received `arm`.
    - Otherwise show the normal choices and keep ownership; `prepareFresh` already refuses a fresh helper.
  - The trigger is unlikely: no `aborted` within 750 ms *and* no observed exit within 250 ms of SIGKILL. Production is OFF.
- **N4: under `historyReconciliation`, Claude Continue can never dispatch.**
  - After the A P1-02 adoption, `.associationUnavailable` blocks every continuation. In this build, normal-live Claude always returns `.baselineUnavailable` or `.nativeUserAssociationUnavailable`; nothing ever writes a user association.
  - The run row still offers Continue, and it always refuses. That departs from R7's Claude rule ("completion unconfirmed … keeps Continue").
  - **Fix:** hide Claude Continue while the merge is BLOCKED, or record it as an explicit activation blocker. It is not a defect of this inactive cut.
- **N5: reused-bubble cleanup is only proven for Codex.**
  - Only the two Codex removal sites use `removableUserItemID`. Any non-Codex start-failure cleanup that deletes the optimistic `userItem.id` would delete an *earlier* shown bubble (the intent stays queued, so nothing is lost).
  - Reuse of a canonical-only bubble is tested only through the resolver, not end to end: output appended to the suffix with no request item there.
  - **Fix:** route every removal through `removableUserItemID`, and add one Claude-route failure test.
- **P3**
  - A reused bubble records a second runtime anchor for the same `userItemID` if the original anchor survived within the same launch.
  - The `terminateGrace` doc comment says a SIGKILLed child "can no longer arm or open", which reads like the proof the code correctly rejects. Reword it.

---

## The two disclosed limits

**1. A shown saved bubble followed by newer user messages is refused.**
- **The required workflow remains open for R1a/R7 step 4.** The common case is several queued follow-ups held across a quit. Each one has its own bubble, so Send saved works only for the last; the earlier ones must go through Edit.
- For *this checkpoint* it is not a P1: it fails closed, creates no duplicate, loses nothing, and Edit is available.
- It is an activation blocker and must not be reported as Send saved being done.
- **Smallest normal-path fix:** when the intent's `unacceptedDelivery == .notSent` and its bubble exists only in the working suffix, move that same item (same ID, new tail `sequenceIndex`) to the tail inside `appendPreparedUserTurn` with `disposition: .reused`. That means no second bubble, correct chronology (it was never delivered), and the reply follows it. Keep the refusal only for bubbles already in persisted canonical turns that have newer turns. No retry on uncertain delivery is involved.

**2. Ambiguous armed helper, the 8 s limit, and safe ownership.**

As far as the supplied source shows, it complies:
- The R4 deadline has a 1 s reserve: work expires at 7 s.
- Any hook still in flight finishes within its own remaining time plus at most 1 s of stop.
- `abandon` joins it, and the helper's cleanup budget is absolute and never renewed. The prompt therefore appears by about 8 s.
- There is no 16 s bonus, and a delivered SIGKILL is never treated as proof.
- `prepareFresh` and `arm` refuse while a stop is unresolved.
- Ordinary quit and window close are unaffected: `relaunch` is `nil` unless `reason == .safeRestart`.

The only problem is that the no-choice prompt is broader than safety requires (N3). Keeping Restart safely DISABLED, with activation blocked, is the right reversible assumption.

---

## Recommendations

1. **Fix N1** by narrowing the hard refusals to the action's own session and keeping workspace scope for automatic work only. Update the cross-window test accordingly. This is the smallest change and removes most of N2's blast radius.
2. **Fix N2** with the fenced run-ended backstop and one injected non-Codex pre-evidence failure test, or contest it with exact `startAgentRun` evidence.
3. **Then commit** this as a *bounded inactive checkpoint*. Set the step status to record N3–N5, limit 1 (Send saved ordering) and the Claude Continue/merge block as `deferred:` and activation blockers, not as done.
4. **Owner decision on the helper:** I recommend withholding choices only after `arm` was sent and keeping normal choices otherwise (N3). Restart safely stays gated until that is decided and O3 passes.
5. **Rerun after the N1/N2 edits:** AgentRecoveryActionTests, AgentRecoveryCoordinatorTests, AgentRecoveryVMProducerAdmissionTests, AgentRecoveryReconciliationTests, AgentScheduledSend\*, and CodexFallbackFIFOTests. Re-review only those seams. No round is needed for the P2/P3 items.