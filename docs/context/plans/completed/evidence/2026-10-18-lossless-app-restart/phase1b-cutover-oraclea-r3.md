# Phase 1b production cutover — OracleA R3

Scope: read when the task touches the owner-authorized third re-review findings for lossless-restart Phase 1b input integration.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by main. Snapshot `a2617a770d9bd8bafb8c68aa69d43e912e4a0c7b`. Decision O7 authorized this extra round; verbatim response follows.

# Oracle Review

The delta closes the in-flight retirement gap and fixes protected restores racing **representable text edits**, with three targeted regression tests. One part of R02-R2 remains open: the new revision-only checks do not detect image changes awaiting promotion. This review uses the supplied diff and context; the reported 802-test pass is source-validation evidence, not live acceptance.

## P1 — Should fix

### R02-R2 — Open: protected restoration misses unrepresentable composer changes

- **Failure scenario:** Restore a protected copy into an empty composer, then attach an image while its placement write is suspended. While image promotion is pending, `composerContentUnrepresentable()` calls `noteUnrepresentableComposerChange()`, which trips only `activeResolutionFence`; it does **not** advance `liveRevision`. Unlike ordinary held restoration, `resolveProtectedRestore()` never installs that fence.
- **Impact:** The placement can commit and return success with stale content despite the intervening composer change. The lane removes the protected entry and returns that content for UI placement instead of rejecting the raced restoration. The supplied context establishes this incorrect result, though not whether the UI ultimately loses the attachment.
- **Evidence:** `AgentRecoveryComposerPersistenceController.swift:479–498` checks only `liveRevision != placement` before and after the write. The same file’s `noteUnrepresentableComposerChange()` only notifies `activeResolutionFence`. `AgentRecoveryCoordinator.swift:1334–1350` consequently treats the controller’s success as permission to remove the entry and return the placement.
- **Smallest fix:** Include unrepresentable mutations in the protected-placement fence. Check it before writing and after commit; if a mutation raced a committed placement, use the existing protected rollback path. Add a suspended-write test invoking `composerContentUnrepresentable()` before completion and verify rejection, preservation of the original draft, and retention of the pending attachment obligation.

The previously reported **failed-write clearing of newer text is fixed**. This remaining stale-success case is classified **P1**, rather than asserting proven data loss.

## Finding dispositions

| Finding | Status | Assessment |
|---|---|---|
| R02-R1 | **Closed** | Retirement now inspects the final outstanding obligation after controller settlement and synthesizes a deduplicated protected entry before pending residue. The new test covers an in-flight restore during ownership transfer. |
| R02-R2 | **Open, partially fixed** | Revision guards preserve newer representable edits on failure and reject raced successful placements. Unrepresentable image edits bypass those guards. |
| R05-R1a | **Closed, unchanged** | Prior disposition retained; not re-audited. |
| R05-R1b | **Closed, unchanged** | Prior disposition retained; not re-audited. |

## Recommendations

Do not mark this lane approved yet. Fix the bounded protected-placement fence gap and rerun affected validation. This consumes O7’s additional R3 review; any unresolved finding goes to the owner, not an automatic further round. Keep live acceptance pending and the complete quit/window-close contract in its separate scoped package.
