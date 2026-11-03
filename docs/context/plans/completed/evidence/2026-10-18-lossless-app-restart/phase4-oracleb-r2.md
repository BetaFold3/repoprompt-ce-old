# Phase 4 OracleB final re-review

Scope: read when the task touches lossless restart Phase 4 final re-review findings, checkpoint scope or activation blockers.
Authority: Reference

Reviewed source tree: `5f9151eb9c92b78ebb42b28226633c1e7652e6e0`, delta from `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`. Main verified the exact requested OracleB preset identity and read the complete response. The owner-approved inactive checkpoint is not full Phase 4 completion or activation approval.

# Oracle Review



# Phase 4 R2 re-review (lane B): inactive checkpoint, my R1 items only

## Summary

The delta fixes the two required regressions I raised in R1, plus one of my P2s:

- **N1:** the hard exclusion now covers only the action's own durable session.
- **N2:** a non-Codex start that ends before any runner owns its input now ends the recovery action, behind the existing fence.
- **N3:** a helper that was never sent `arm` now keeps the normal Stage A choices.

It also adds two related fixes:

- A stale dispatch commit settles against its exact attempt, even when a shutdown freeze lands mid-commit.
- The helper's work and cleanup budgets are now absolute instants, carried through serialization, identity, spawn and the stop cap.

I checked these against the current source, not against the descriptions of it. The owner decision (O9) puts this on record as an inactive partial checkpoint, and I reviewed it that way. Everything below comes from reading the supplied patch and source; I ran nothing.

## Verdict

| Scope | P0 | P1 |
|---|---|---|
| My R1 required repairs (N1, N2) and regressions they caused | none | **none.** Both are closed. |
| Related fixes (exact-attempt stale settlement, absolute R4/helper budget, N3) | none | none |
| **Full contract, outside this checkpoint** | — | **One stays open and owner-blocked:** Send saved for an older bubble (below) |

On the checkpoint gate, I see no reason in my lane not to commit this as a bounded inactive checkpoint.

---

## Disposition of my R1 items

| ID | Main disposition | My verdict | Evidence |
|---|---|---|---|
| **N1** workspace-wide hard refusal | Fixed (scope cut) | **Closed** | See the N1 notes below. |
| **N2** settlement had no liveness backstop | Trace confirmed, fixed | **Closed** | See the N2 notes below. |
| **N3** Stage A no-choice prompt when nothing could be armed | Cheap fix | **Closed** | See the N3 notes below. |
| **N4** Claude Continue under history reconciliation | Activation blocker | **Accepted** | No fake identity work. It must stay listed under `deferred:` and as an activation blocker. |
| **N5** bubble cleanup on reuse | Traced, no issue | **Accepted** | The trace shows only the two Codex optimistic removals touch user items, and both already use `removableUserItemID`. The remaining test gap is P2 and listed only. |
| P3 `terminateGrace` comment | Fixed | Closed | It now says a delivered signal is not proof of exit. |
| F1–F5 | Closed in R1 | Still closed | The delta does not touch history import or the composer projection. |

**N1 notes** (`AgentRecoveryCoordinator.swift`):
- `ownRecoveryActionHold` now guards all of these:
  - the admission refusal;
  - the dispatch refusal;
  - `finishRecoveryActionDispatchCommit` when no authorization is carried;
  - `recoveryActionPermitsHandoff`;
  - `recoveryActionBlocksUntrackedInput`.
- `isCoveredByRecoveryAction` and `hasRecoveryAction(inWorkspace:excluding:)` keep the workspace-wide automatic projection.
- `beginRecoveryAction` still serializes actions per workspace.
- `currentRecoveryActionHold` still resolves through `coveringRecoveryActionHold`, which prefers the action's own hold, so an authorized payload cannot bypass the check.
- A successor lane of the same session stays held, because the check keys on `authorization.sessionID`, not on the lane.
- The replacement test asserts all of this, including that a sibling's drain is handed off.

**N2 notes** (`AgentModeRunService.startRun`):
- The new `defer` fires only when all of these hold:
  - the provider is not Codex;
  - `!runnerOwnsStagedInput`;
  - a constituent carries an authorization.
- That covers the exits I suspected: the unsupported knowledge-profile provider, the workspace-path throw, the DEBUG Oh My Pi returns and the pre-runner `.stale`/`.failed` returns.
- `prepareRunStart` does not commit (the commit is deferred to the runner), so no attempt can be attached at those exits. `revokeRecoveryAction` then goes through `settleRecoveryActionIfFenced`, which requires `dispatchAttemptID == nil && commitsInFlight == 0`. So it can never claim "not sent" for a committed attempt.
- Double revocation alongside `noteRecoveryActionStartReturned` does no harm, because `settleRecoveryAction` checks `settlement == nil`.
- Runner-owned input is unchanged, since `runnerOwnsStagedInput = true` is set before the Claude and ACP runners start.
- The test covers each part: the return is still `nil`, the run fails, the intent stays queued with no attempt, the action settles as not handed off, a late dispatch is refused, and the hold is released.

**N3 notes:**
- `armWasSent` is set before the `arm` write, so a partly written frame counts as possibly armed.
- `arm` returns early with nothing sent when the budget is spent (`left <= 0`).
- `abandonCurrent` maps an unresolved stop to `.unresolvedUnarmed` only when `!armWasSent`.
- `prepareFresh` refuses both unresolved cases, so a helper whose stop is unresolved is never replaced by a fresh one.
- `present()` keeps the choices only for `.unresolvedUnarmed`. An arm-sent `.unresolved` still offers no choices.
- The helper side opens only from `.armed`, so a never-armed helper can never open anything.

### Related fixes I checked for regressions

**Exact-attempt stale commit** (`noteRecoveryActionStaleCommitSettled`)

The scenario is a commit that passed the action check, attached `dispatchAttemptID`, and then failed `isValidForHandoff` because a freeze landed during the write.
- In that case the attached attempt must be in `attemptIDs`. The hold is then revoked and settled, as `notHandedOff` only if the settle write landed, otherwise as `uncertain`.
- An unrelated attempt list returns without effect.
- The path with no attempt attached keeps its earlier behaviour.

I see no route where this produces "not sent" for a handed-off attempt. The handoff gate (`permitsHandoff` → `isValidForHandoff`) runs before the provider boundary, and the settlement is guarded by `settlement == nil`. The test cancels Stage A and the runner records `.notDispatched`, which is correct.

**Absolute budget** (`relaunchBudget`, `armDeadline`, `prepareFresh`, `ParentSession.prepare/arm/stopUnarmed`)
- `workExpiry` is the R4 expiry (8 s minus the 1 s reserve), and `cleanupExpiry` is start + 8 s.
- `cleanupCap` is set once per session and can only be lowered.
- `stopUnarmed` clamps both the acknowledgement deadline (cap − `terminateGrace`) and the cleanup deadline to that cap.
- So a retained helper on a later Retry gets zero-length waits, which still drain any exit that is already queued. Its budget is never renewed.
- `prepareFresh` re-checks `now < workExpiry` after cleaning up the earlier helper, and the session recomputes the remaining time when its timer starts.
- The composed test, on one shared clock with 2 s used before the timer starts, shows every requested deadline at or before 8 s and the prompt appearing at 8 s.
- This adds no 16 s bonus, does not treat signal 0 as proof and does not treat elapsed time as proof.

**Plain quit and window close:** `relaunch` is `nil` unless `reason == .safeRestart`, so neither path changes.

---

## Full contract: blocked, not a checkpoint regression

### FC-1 (full-contract P1, owner-blocked by O9): Send saved cannot send an older saved bubble

- **Scenario:** several follow-ups are held across a quit, each with its own bubble. Send saved works only for the newest one. Every earlier one is refused with `recoverySavedBubbleNotLatestText` and has to go through Edit as a new message.
- **Impact under the full contract:** R1a/R7 step 4 ("Send reuses that item ID, so it never appends a second bubble") is unmet for the common multi-follow-up case. That is a broken workflow, so it stays a **P1 against the full Phase 4 contract**.
- **Why it can't be fixed within this checkpoint's limits:**
  - `AgentChatItem` has no owning turn.
  - `appendItem` assigns the next tail sequence.
  - `importLegacyItems` and `finalTurnStartIndex` split turns at user items.
  - Runtime anchors only place timers and footers.

  So streaming output after a later user item cannot be routed back to an older bubble without either a membership redesign or reordering. O9 rules out both. My R1 suggestion to move a suffix-only bubble to the tail is a positional reordering, so I withdraw it under O9.
- **Why it is not a checkpoint P1:** the refusal fails closed. Nothing is sent, nothing is duplicated, nothing is lost, the new wording is accurate, and Edit is offered.
- **Status:** it must stay `blocked`, as an activation blocker, and not be reported as done. I am not claiming no solution could ever exist, only that none has a basis within the current architecture limits.

**Other activation blockers that remain:**
- O3 live acceptance.
- The owner's policy on an ambiguous arm-sent helper. Unanswered, so it fails closed.
- N4: the Claude normal-live merge.
- Production registry, Stop, Resume, history and restart all OFF.

---

## P2 (listed, not looped)

- **R2-P2-1: untracked input with no session identity no longer fails closed.**
  - Where: `AgentRecoveryCoordinator.swift`, `recoveryActionBlocksUntrackedInput`, called from `AgentRecoveryDispatchEvidence.untrackedInputIsHeld` with `session.activeAgentSessionID`.
  - Before, a nil ID was blocked by any hold. Now only the automatic projection applies to it. The reasoning holds: the action's tab is bound to its session. Reaching this needs inactive admission *and* an action, and actions are disabled in production, so the case is contrived.
  - Cheap hardening: if `session.recoveryLane?.sessionID` is present, check that instead.
- **R2-P2-2: Restart safely stays unusable while an unresolved never-armed helper is retained.**
  - After an `.unresolvedUnarmed` stop, every Retry re-shows the same reason until the helper's exit is observed. Cancel works, and the reason is shown, so this fails visibly. Polish only.
- **R2-P2-3: two places end a recovery action's submission for non-Codex runs.**
  - Both the `startRun` defer and `noteRecoveryActionStartReturned` do it. They are idempotent and correct. If this is touched again, consider keeping only one seam.
- **R2-P2-4 (carried from N5):** there is still no end-to-end test of a Claude-route start failure with a reused canonical-only bubble. The trace is credible.

---

## Recommendations

1. **Commit** this as the bounded inactive Phase 4 checkpoint. My lane has no open P0 or P1 against the checkpoint.
2. **Step status:** keep the step `blocked`, not `done`. Use this status line:
   `open: FC-1 (older-bubble Send saved, owner O9) | deferred: N4, R2-P2-1..4, prior P2/P3 | activation blockers: O3, arm-sent helper policy, Claude merge identity`.
3. **Keep Restart safely gated off.** The arm-sent no-choice behaviour stays fail-closed pending the owner's answer. The never-armed relaxation (N3) is safe to keep.
4. **Before any activation**, FC-1 needs an owner-authorized design for turn membership or routing. Don't treat this checkpoint as evidence that the R1a/R7 Send-saved contract is met.
5. **No further review round** is needed. Rerun validation only if source changes beyond docs or status.