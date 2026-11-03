# Step 4d3a initial review: OracleA (verbatim)

Scope: read when the task touches the Step 4d3a initial OracleA review of the canonical payload and order check, or its R1 finding.
Authority: Reference
Last-verified: 2026-10-23

Raw OracleA response to main's initial Step 4d3a review (snapshot 2226), saved verbatim below the rule from `prompt-exports/oracle-review-2026-10-23-223114-step4d3a-canonical-p-be38.md`. Main verified the preset identity. Main's selected disposition and the repairs are in [phase4d3a-worker.md](phase4d3a-worker.md#initial-review-repairs).

---

# Oracle Review

The changes retain the full native projection transiently, compare canonical payloads and existing-row order before Claude deduplication, expand deduplication to persisted-turn IDs, and protect ledger-associated assistant rows from live text mutation. The implementation largely follows the bounded goal, but the new order check can reject a transcript produced by its own successful import.

## P1 — Should fix

### R1: An accepted import can make subsequent reconciliation fail

**Evidence:** `AgentProviderHistoryImport.swift:463–570` (`canonicalPayloadRefusal`); `AgentModeViewModel+RecoveryActions.swift:1198–1227` (planning and append).

**Scenario:** Native history contains `user1 → reply1 → steer → reply2`, while canonical history contains only `user1 → steer`. Both claims match. The preflight checks the user anchors but skips both replies because they are not already canonical. The append-only planner then produces `user1 → steer → reply1 → reply2`.

On the next reconciliation, those replies are ledger-mapped, so the new relative-order check rejects `reply1` for appearing after `steer`. Thus an unchanged replay of a successful import returns `canonicalPayloadMismatch`; additional recoverable output is blocked too.

The positive control in `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` already exercises this initial import, but does not reconcile again.

**Smallest fix:** Before committing, validate the proposed append-only result against native order, including the claimed user anchors. Refuse an import that would introduce an order inversion, without changing rows, ledger, or cursor. This avoids requiring insertion or carrier redesign. Add a two-dispatch regression covering the initial decision and subsequent reconciliation.

## Recommendations

Fix R1 before accepting Step4d3a. Retain the existing gates and conservative refusal model. This assessment is based on the supplied snapshot; validation results were supplied, not independently rerun.