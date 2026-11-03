# Step 8-attention-1 re-review — OracleA (round 1)

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat re-review of the round-1 fixes (att1-delta, att1-r1 diffs). The OracleB round-1 lane was refused by the app's Oracle concurrency limit and did not run.

## Summary

The delta keeps run cards needs-action during their live recovery hold, adds detection of unsent continuation text, excludes dismissed rows from section counts, and strengthens startup coverage. No send, admission, or Dismiss path is weakened. One completeness issue remains: an unrelated reconciliation can hide continuation text that still needs a decision. Validation below is based on supplied code and worker reports, not independently executed tests.

## P1 — Should fix

### ATT1-R1-1: An unsuccessful reconciliation clears attention for still-unsent text

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift:319–325`, `hasUnsentContinuation(for:)`.

The helper examines only the latest action on the card. Any subsequent action without text therefore clears the flag—even when that action neither sends the earlier text nor proves completion.

**Failure scenario, with recovery capabilities enabled:**
1. A typed continuation receives `.notDispatched` before creating an intent. The card correctly remains needs-action.
2. The user chooses Reconcile to check provider history.
3. Reconciliation fails, recording `.notDispatched`, or imports history without confirming completion, recording `.importedUnconfirmed`.
4. The latest action has no text, so `hasUnsentContinuation` returns `false`. After the hold ends, the card becomes informational and leaves the banner/count despite its earlier text remaining unsent.

The new `testRunCardWithAnUnsentContinuationNeedsAction` explicitly expects this demotion after `.importedUnconfirmed`; it currently enshrines the problematic behavior. Checking history is not an explicit decision to discard a continuation.

**Smallest fix:** Preserve outstanding continuation attention across non-resolving, textless reconciliation actions. Clear it only when the text is represented by an intent, a relevant successful resolution occurs, or the user explicitly replaces/discards it. Change the test to retain needs-action after both failed and unconfirmed reconciliation, and separately test legitimate clearing.

## Other checks

- **Hold keying:** Matching both session ID and exact card key is appropriate. Including revoked-but-not-ended holds correctly covers the remaining settlement/outcome-write interval.
- **Invalidation:** Both `beginRecoveryAction` and `endRecoveryAction` call `postCoordinatorDidChange()`. The worker reports that this invalidates the catalog; the added test checks projection changes before reservation and after release. The invalidation implementation itself is not included.
- **Actor isolation:** The coordinator query is called from the main-actor projection builder, not the `nonisolated` classifier. No isolation issue identified.
- **Intent matching:** Matching `plannedUserItemID` against intent `userItemID` agrees with the existing `join(_:)` association. The new tests do not exercise this suppression branch.
- **Other fixes:** Dismissed-row counts, required `attention`, startup unfinished-action coverage, crash-hold visibility, and sessionless preparation-failure assertions address their reported issues.

No additional correctness findings identified in the supplied delta.

## Recommendations

1. Fix ATT1-R1-1 and add the failed/unconfirmed reconciliation regressions.
2. Add tests for a matching saved intent and for the interval after outcome recording but before hold release.
3. Perform the deferred live check of row movement between sections.
4. Resolve the reported orphan evidence-document links and rerun guardrails before commit.