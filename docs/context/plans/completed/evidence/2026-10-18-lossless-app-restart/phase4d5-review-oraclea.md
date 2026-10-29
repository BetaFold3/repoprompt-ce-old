# Step 4d5 — OracleA initial review

Scope: read when the task touches Step 4d5 bounded source review and findings.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/1009, 14 files (+1926/−126). Fresh independent lanes received identical context and verbatim review policy. Exact requested/returned OracleA identity verified. Main read the full reply. No P0/P1. This is source review, not live acceptance.

## Verbatim response

# Oracle Review

The snapshot extends default-off Claude qualification to the bounded O20 Read chain, reusing history-reader identities and projections, checking predecessor payloads/proofs, preserving translated tool accounting, and protecting associated tool rows during mutation and finalization. The inspected changes preserve the existing O19 classification logic. Two boundary defects remain; neither establishes a normal-path P0/P1 failure in this inactive implementation.

## P2 — Consider

### R1 — Prefix-only answer duplicates are not recognized
**File:** `AgentModeViewModel.swift:20240–20249`, `applyClaudeLiveTranscriptCompleteText`

- **Scenario:** A qualified `.readAnswer` duplicates an already recorded answer held only in persisted transcript turns, outside `session.items`. Its call/result prerequisites pass the full canonical-view checks, but answer deduplication searches only `session.items`.
- **Impact:** The owner unnecessarily refuses the producer, invalidates any producer-owned proofs, and sends the answer through unidentified fallback despite its canonical copy already existing. This can introduce duplicate output and prevent subsequent reconciliation.
- **Smallest fix:** For the new Read-answer path, use `holdsClaudeLiveTranscriptRow` against the full canonical view when checking an existing ledger entry. Add a prefix-only duplicate-answer regression asserting no new row, accounting, ownership, or proof invalidation. Preserve O19 behavior explicitly if changing that path is outside scope.

### R2 — Batch replacement can bypass protected-row preservation
**File:** `AgentTabSession.swift:2859–2868`, `preserveClaudeAssociatedToolPayloads`

- **Scenario:** A batch replaces a Claude-associated tool row with an item having a different ID. Protection looks up only IDs remaining in the updated array, so the displaced original is never examined. The equivalent single-item replacement is correctly blocked.
- **Impact:** The batch API can remove a protected canonical payload while retaining its ledger entry and proof, contrary to the stated mutation invariant. Later prerequisites or reconciliation then fail. The supplied tests exercise same-ID batch mutations, not this displacement case; no triggering production caller is established by the supplied excerpts.
- **Smallest fix:** Reject protected-ID displacement in ordinary batch mutations, keeping intentional removal/hydration/retention on explicitly exempt paths. Add the batch equivalent of the existing different-ID `replaceItem` test, with both valid and cleared proofs.

## Recommendations

Fix these bounded P2 cases and rerun the affected lifecycle/reconciliation tests. Keep activation and installed/no-replay acceptance blocked as documented. This was a source-only review of the supplied snapshot; validation was not independently rerun.
