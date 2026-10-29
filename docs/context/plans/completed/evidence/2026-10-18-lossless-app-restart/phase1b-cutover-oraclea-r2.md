# Phase 1b production cutover — OracleA R2

Scope: read when the task touches the final re-review findings for lossless-restart Phase 1b production input integration.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by main. Snapshot: `6d2ed2ec080604b02988df923c6a2e37fa0e70ba`. Final allowed re-review; verbatim response follows.

# Oracle Review

The delta fixes local-handoff certainty and older-head FIFO priority, and protects restored drafts during the tested rollback/reclaim sequences. However, R02 remains open: retirement during the original resolution can lose the new protection, and explicit protected restoration can erase newer pending typing. This review uses only the supplied snapshot and context; the reported 799-test pass is fixture/source-validation evidence, not live acceptance.

## P0 — Must fix

### R02-R1 — Retirement can miss an outstanding rollback created during resolution

- **Scenario:** A held restore commits, newer typing races it, and rollback suspends before failing. During that suspension, another owner claims the session. Retirement snapshots `unsavedPredecessorInputs` before the protected entry exists. When resolution finishes, the retired lane deliberately skips appending that entry. The retiring flush also fails its rollback retry.
- **Impact:** Retirement forwards the newer typing but not the outstanding rollback obligation. The successor learns the original draft as an ordinary same-generation composer baseline; its next successful composer write can overwrite that draft without preserving another durable copy.
- **Evidence:** `AgentRecoveryCoordinator.swift:1367–1376` appends the protected entry only while the lane is not retired. At `:1900–1915`, retirement captures the entries before awaiting preservation, then only **filters** them against `composer.outstandingRestoreRollback`; it never adds an obligation created during that await. `preserveForRetirement` returns pending-content residue without `restoreRollback`.
- **Smallest fix:** After controller settlement, ensure the retirement result carries every outstanding rollback obligation, synthesizing its protected entry when none was captured. Deduplicate against existing entries. Extend the ownership test to claim the successor **while the original restore/failed rollback is still in flight**, then verify successor typing cannot overwrite the original.

**Disposition:** The ordinary post-failure overwrite and completed-resolution handovers are fixed, but R02-R1 cannot close.

### R02-R2 — Failed protected restoration clears typing made during its write

- **Scenario:** The user restores a protected copy into an empty composer. `resolveProtectedRestore` stages that content and awaits its serialized write. The user types newer content while the write is suspended. The write fails.
- **Impact:** The failure branch unconditionally replaces the newer pending snapshot with empty content. Persistence and subsequent retirement now carry the empty snapshot instead of the user's typing; a later successful retry cannot recover the erased pending content.
- **Evidence:** `AgentRecoveryComposerPersistenceController.swift:454–485`, especially the unconditional `composerDidChange(empty)` at `:482–484`. This new resolution path has neither the existing held-restore fence nor a revision check after suspension. The lane’s checks in `AgentRecoveryCoordinator.swift`, `resolveProtectedRestore`, happen only before awaiting the controller.
- **Smallest fix:** Track the placement revision and clear it on failure only if it remains the current live revision. Preserve newer pending edits. Apply the existing restore fence/revalidation discipline across this operation so success also cannot resolve or return stale placement content after intervening typing. Add a suspended-write test that types newer content, fails the write, and verifies that content survives retry and handover.

## Previous finding disposition

| Finding | Status | Assessment |
|---|---|---|
| R02-R1 | **Open** | Protection works after completed resolution, but the in-flight retirement gap remains. |
| R05-R1a | **Closed** | Both local instruction-result boundaries now record `deliveryUnknown`, not provider acceptance. |
| R05-R1b | **Closed** | Queue priority is checked before preparation, after preparation, and at atomic claim; attachment-bearing durable input is held. |

Previously closed baseline findings were not reopened or re-audited.

## Recommendations

**Do not mark Phase1b input integration approved yet.** This is the final allowed re-review: report the remaining P0s to the owner rather than starting another review round. Fix the two bounded preservation paths and rerun affected validation under the owner’s disposition. Keep live acceptance explicitly pending and complete quit/window-close preservation as the next scoped package.
