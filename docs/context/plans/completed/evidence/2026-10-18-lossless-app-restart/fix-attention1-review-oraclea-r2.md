# Step 8-attention-1 final re-review — OracleA (round 2)

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat final re-review of att1-delta and att1-delta2.

The fixes preserve needs-action status for unsent continuation text across failed or unconfirmed textless reconciliation, retain attention throughout a live recovery hold, and exclude dismissed rows from section counts. The changes remain presentation-focused; no supplied delta weakens send, admission, or Dismiss behavior. **ATT1-R1-1 is addressed. No P0 or P1 findings identified.**

## P2 — Consider

### ATT1-R2-1: Supersession-before-outcome lacks regression coverage

**Reference:** `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift:329–340`; `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryCoordinatorTests.swift`, continuation tests.

The new tests start with a continuation that already has a `.notDispatched` outcome. They do not exercise the new `isSuperseded` branch.

**Scenario:** A typed continuation is reserved, the app crashes before its outcome or intent is written, and a later textless Reconcile explicitly supersedes it before finishing with `.notDispatched` or `.importedUnconfirmed`. Neither action then qualifies as unfinished, so retaining needs-action depends entirely on this branch.

The implementation appears correct, but this distinct restart path is unprotected against regression.

**Smallest suggestion:** Add a test with an outcome-less typed action and a textless successor referencing its `supersedesActionID`; after the successor finishes unsuccessfully, assert `hasUnsentContinuation == true`, `hasUnfinishedAction == false`, and `.needsAction`.

## Other checks

- **Resolution semantics:** Extracting `resolvesItem` preserves the exact predicate previously used by `resolvingAction(for:)`.
- **Intent matching:** Matching `plannedUserItemID` to intent `userItemID` agrees with the existing `join(_:)` association.
- **Supersession:** An open, unsuperseded continuation remains covered by `unresolvedAction`; a superseded one retains unsent attention unless an intent or later resolving action covers it.
- **Isolation:** The added coordinator lookup remains outside the pure `nonisolated` classifier.
- **Hold invalidation:** Supplied tests assert attention before reservation and after outcome recording until hold release. The actual begin/end invalidation implementations are not attached, so their wiring remains supported by prior reports rather than independently inspected here.

Validation results are worker-reported; I did not execute tests or inspect live rendering.

## Recommendations

1. Close ATT1-R1-1; no further blocking code change is identified.
2. Add the supersession regression test if inexpensive; it does not warrant another review round.
3. Retain the deferred live check for row movement between sections and confirmation-state preservation.