# Step 5c round 1 review — OracleB

Scope: read when the task touches Step5c repair acceptance, findings or deferred review polish.
Authority: Reference
Last-verified: 2026-10-23

Returned identity verified: OracleB (7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C), explicit selection. Chat step5c-r1-b-B4E2A8; operation 726AC58A-5E2B-4AC5-BCB5-877297692212; completed/ok. Same repair snapshot2026-10-23/1656,11files +742/-72 over initial index tree e86152af1da0579a94fcd6a7cbb091782d24fa82. Full response follows. Markdown hard breaks normalized and trailing spaces removed; original export unchanged at /Users/tnguyen/workspace/repoprompt-ce-personal-touch/prompt-exports/oracle-review-2026-10-23-165930-step5c-r1-b-b4e2a8-c8ab.md.

# Oracle Review



# Step 5c re-review, round 1: repair delta (snapshot 2026-10-23/1656)

## Summary

I found no new P0 or P1 in this repair, and I did not find a regression in it that breaks correctness. The findings below are four new P3s and one P3 test gap.

The repair does six things:
- **Decisions stay "shown" until processed.** It adds `resolvingWorktreeMergeReviewOperationIDs`. If a run end, reset or replacement lands in the same MainActor turn as a submitted decision, the review is kept as history instead of being withdrawn.
- **Withdrawal outcomes are explicit.** `withdrawWorktreeMergeReviewDurably` now returns `withdrawn`, `kept`, `uncertain` or `changed`. The await hook runs before the last owner and operation recheck. A `kept` result is claimed only after a covering compensating save.
- **Discard state is session-owned.** Discard progress and failure live on `worktreeMergeReviewDiscard` and are projected into the run-interaction snapshot.
- **Attention ranking is shared.** Live sessions, closed-summary sidebar rows and the HUD use one ranking (`attentionRanksBelow`), and the implicit `status` lookup skips historical reviews.
- **Pre-show refusals restore the previewed operation.** Through `refuseUnshownWorktreeMergeReview`, a refusal before the review is shown puts a stored `previewed` operation back.
- **Small fixes.** Patch text is decoded as strict UTF-8, and the replacement text is now neutral.

What I checked:
- **Every path clears the resolving ID.** The continuation is always resumed, and the `defer` covers apply, withdrawal and the preserve paths.
- **Lifecycle ends only touch live `awaitingApproval` operations.** They can't touch an operation that is mid-apply or mid-withdrawal.
- **Withdrawal decisions follow exact identity.** Each `installKeptWorktreeMergeReview` and `restored` comparison tracks the operation exactly, including `updatedAt` being bumped on every update.
- **The new snapshot field compiles everywhere.** It is an optional `var`, so the existing memberwise and `.empty` initializers still work.

## P3: new findings, listed for deferral only, not a reason for another round

**P3-1: A submitted decision overtaken by a lifecycle end is later described as "without a decision"**
- **Where:** `submitWorktreeMergeReviewDecision`, `cancelPendingWorktreeMergeReview`, `endWorktreeMergeReviewsForLifecycle`, `historicalWorktreeMergeReviewEndedText` (AgentModeViewModel+WorktreeMerge.swift).
- **Scenario:** The user clicks Merge or Reject. In the same turn a run end or reset calls `cancelPendingWorktreeMergeReview`. The resolving ID makes the review historical with reason "Run ended".
  - For Accept, the request then fails the exact check and throws `worktreeMergeNotStartedText`.
  - For Reject, the request returns `.changed` and throws `worktreeMergeRejectChangedText`.
  - In both cases the card reads "This merge was proposed but its review ended without a decision (Run ended)", even though the user did decide.
- **Impact:** Wording only. The proposal is kept, Git is not touched, and nothing is falsely claimed as withdrawn. The test `acceptThenLifecycle` pins the "Run ended" reason.
- **Smallest fix:** In `endWorktreeMergeReviewsForLifecycle`, give IDs that came from the resolving set a reason like "Ended before the submitted decision was processed (…)". Alternatively, leave the wording as is and record that it is accepted.

**P3-2: A card recreated during an in-flight Discard can keep stale "unavailable" text after Discard fails**
- **Where:** `historicalWorktreeMergeReviewOperation(for:)` and the card's `.task(id: operation.id)` in AgentWorktreeMergeReviewCard.swift.
- **Scenario:** While `isDiscarding`, the snapshot projects `discard.review`, but the stored operation is `.cancelled`. If the card is rebuilt in that window (for example after a tab switch), it loads its data through `historicalWorktreeMergeOperation`. That lookup requires `isHistoricalReview` on the stored operation, so the card shows "prediction unavailable" and "Current source and target state is unavailable".
  - When Discard then fails and the history is restored, the operation ID hasn't changed, so neither `.id(...)` nor `.task(id:)` triggers a reload.
  - The stale text stays until the card is next rebuilt.
- **Impact:** Cosmetic, and recovered by switching away and back.
- **Smallest fix:** Key the task on `"\(operation.id)-\(isDiscarding)"`, or skip the loads while `isDiscarding` is true.

**P3-3: The sidebar and the card disagree while Discard runs**
- **Where:** `sidebarAttention(in:)` reads the live operations directly.
- **Scenario:** During Discard the operation is `.cancelled`, so the sidebar badge and root capsule disappear while the blocker card still shows the review. If Discard fails, the badge comes back.
- **Impact:** A brief cosmetic flicker.
- **Fix:** Optional. Project `worktreeMergeReviewDiscard` in the live selector as well.

**P3-4: A pre-show refusal on a previewed operation leaves the retained bundle unreferenced**
- **Where:** `refuseUnshownWorktreeMergeReview`, called after the `publicationSave` failure in `reviewAndApplyWorktreeMerge`.
- **Scenario:** The bundle has already been retained (`previewArtifacts = retained`). Restoring `prior` puts the original artifact references back. Under the old withdraw-to-`cancelled` path the cancelled operation still pointed at the copy; now no record points at it. Each retry of a review on the same previewed operation adds another copy.
- **Impact:** Disk only, and it fits the already deferred retention/GC item.
- **Fix:** Either note it under the existing retention deferral, or remove the retained directory on this one refusal path. Removal is safe because the directory was never published to a shown review.

**P3-5: Withdrawal now mutates state when the owner is already invalid at entry, including the shutdown freeze**
- **Where:** `withdrawWorktreeMergeReviewDurably`, in the first `guard worktreeMergeOwnerMatches(owner) else { installKept…(kept(false)…) }`.
- **Change:** `worktreeMergeOwnerMatches` also returns false when `isRecoveryShutdownFrozen` is set. The old code returned without mutating; the new code installs the kept history, which also calls `persistWorktreeMergeOperationsChange` (marks the session dirty and schedules a save).
- **Impact:** Harmless as far as I can see: disk already holds `.live`, which reloads as history. But it is a session mutation during the R4 edit freeze that the previous code didn't make.
- **Smallest fix:** In that branch, also skip the install when `isRecoveryShutdownFrozen(session)` is true.

## P3: test gaps

- In `testOwnerOrOperationChangeAtWithdrawalSaveNeverClaimsWithdrawal`, the Reject/`reset` case has no assertion on the error text (`case .reset: break`). Asserting that the message is not the bare reject reason would pin that a reset never yields `.withdrawn`.
- No test covers the path where the withdrawn operation is changed during the first save. In that path `installKeptWorktreeMergeReview` returns `nil` and the outcome is `.uncertain`.
- The `withdrawn.status == .cancelled else { return .changed }` branch can't be reached, because exactness was checked synchronously just before. It could become an assertion, or be dropped.
