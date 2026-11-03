# Step 9-activation-b re-review round 1: OracleB

Scope: read when the task touches crash-hold confirmation from process-registry proof, the run-start registration mark, or Step 9-activation-b of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleB round-1 re-review of the delta

# Re-review, round 1: Step 9-activation-b (crash-hold confirmation from process records)

**Summary.** I found no P0 or P1 regressions in this delta. Two of the fixes are sound:

- **Atomic card check at the write.** `undismissedCard` is checked inside the store's acknowledgement transaction, after `writableRecord` and before the `covers` early return. The live-lane and closed-session paths both pass it, and the new hook lets a test place a real Dismiss after the last re-check.
- **Wider touched keys.** The registry's touched set now also takes record-level keys from records that name the session. This can only add refusals, never remove one, so it cannot cause a false confirmation.

Other points checked:

- Moving the snapshot checks into the commit loop is ordered correctly: Stop/card, then snapshot, then write destination.
- Removing the duplicate card guard in `checkOutcome` loses nothing. `crashHoldCheckRefusal` performs the same comparison first.
- `.working` handling is now different for each kind of work. Stop releases the row for Reconcile work, and the confirmation's own `defer` releases it for crash-hold work.

What remains is one validation gap (P2) and minor P3 items.

## P2

### B-R1-01: The Stop-after-commit test doesn't check what it claims (B A8)
- **Where:** `AgentRecoveryCrashHoldProofTests.swift` ≈431–434, `testStopAfterTheCommitStartedLetsItLand`.
- **What's wrong:** The hook calls `requestRecoveryCheckCancel()` and then immediately asserts that the row is `.working`.
  - `requestRecoveryCheckCancel()` only resumes the item's wait continuation. The Stop branch of `checkCatalogItems` (the code that used to clear `.working`) can't run until the hook returns and the confirmation suspends in the write.
  - So the assertion runs before the code it's meant to test. It would also pass with round-0 behaviour (Stop clears `.working` unconditionally).
  - The later `waitUntil { … != .working }` passes under both versions too.
  - Result: nothing verifies that Stop now leaves the confirmation's row alone. A regression back to the old clearing would go unnoticed.
- **Smallest fix:** Inside the hook, after `requestRecoveryCheckCancel()`, wait for the Stop branch to run before asserting. For example, `await waitUntil { coordinator.recoveryCheck?.entries.count == 1 }` (or whatever marks the check as finished), then `XCTAssertEqual(coordinator.catalogActionStates[itemID], .working)`. The confirmation is suspended in the hook at that point, so the row can only still be `.working` if Stop left it.

## P3

### B-R1-02: A second confirmation can share the row's `.working` and clear it early
- **Where:** `AgentRecoveryCoordinator+CrashHoldProof.swift` ≈78–86.
- **What's wrong:** The confirmation sets `.working` without checking whether the row is already `.working`. Its `defer` then clears the state unconditionally.
- **Scenario:**
  1. Stop ends Check while confirmation C1 is still in its write. C1 still holds the row's `.working`.
  2. The user presses Check again. Unless `checkOutcome` skips `.working` rows (not visible here), C2 starts on the same item: it passes `crashHoldCheckRefusal` and sets `.working` again.
  3. C1 finishes, and its `defer` clears `.working` while C2 is still writing.
  4. The row now looks idle and accepts Dismiss or "It stopped" while C2 commits.
- **Impact:** None on data. The store's card check catches a Dismiss, and the acknowledgement is idempotent (`covers` → `.unchanged`). It is a UI-state inaccuracy only. The same overlap applies if any other action that sets `.working` without a recovery-action hold is in flight.
- **Smallest fix:** Before line 78, add `if catalogActionStates[item.id] == .working { return .couldNotCheck(Text.busy) }`.

### B-R1-03: Comment about deleted sessions may not hold in this step's build alone
- **Where:** `AgentRecoveryCoordinator+CrashHoldProof.swift` ≈142–144.
- **What's wrong:** The comment says "A deleted session's hold is no longer published, so `crashHold(for:)` no longer equals it". With `deletedSessionIDs` removed because it comes from the other worker's hunks, unpublishing on delete may also live only in those hunks.
- **Impact:** Safety doesn't depend on this claim. Writes are still guarded by the closed gate's tombstone validation and by the `lane.isRetired` check in `crashHoldWriteDestinationRefusal`.
- **Smallest fix:** Confirm the claim holds without the other worker's hunks. If it doesn't, reword the comment to cite the write-time guards instead.

### B-R1-04: Multi-session records widen the touched set to other sessions' keys
- **Where:** `AgentProcessRegistry.swift` ≈170–176.
- **What's wrong:** The expansion loop runs over all records, including current-launch ones. A record with associations for several sessions (for example a shared Codex app-server family) adds all of its record-level conversations and worktrees.
- **Impact:** Checking session A can then refuse "may still be running" because of an earlier-launch record that only touches session B's worktree. This is safe (it only over-refuses, and "It stopped" remains available). It is worth watching during the live checks before the flip.
- **Fix:** None needed now. If false refusals show up, restrict record-level keys to records whose associations all name this session.

### B-R1-05: The commit retry loop is effectively unreachable
- **Where:** `AgentRecoveryCoordinator+CrashHoldProof.swift` ≈108–139.
- **What's wrong:** The worker reports that a revision conflict can't happen on either path, which I agree with. Each `continue` would also re-run both DEBUG hooks.
- **Fix:** Keeping it as a defensive branch is acceptable. Alternatively, collapse it to a single attempt and map `.revisionConflict` to `.couldNotCheck(Text.changed)`, which removes an untested branch.

## Recommendations
1. Fix B-R1-01 before committing. It's a one-line wait in the test and is the only coverage of the changed Stop/`.working` ownership.
2. Take B-R1-02's one-line `.working` guard if it's cheap; otherwise list it as deferred.
3. Re-check the B-R1-03 comment against this step's hunks only.
4. Accept the A4 deferral (one shared launch-authority source) as recorded. It is safe while `AgentRecoveryActivation.production = .off`, and it must stay a blocking gate on the activation-flip commit, together with the composition-level shared-store assertion.
5. Optional wording tweak: "If it was saved, sending resumes on its card." reads ambiguously. Something like "If it was saved, its card shows sending resumed." would be clearer.
