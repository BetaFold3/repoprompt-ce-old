# Step 8-attention-1 review — OracleA (round 0)

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat review of the att1-r0 diff against review-policy.md.

## Summary

The changes implement the requested attention classification, hide ready-state banners without applicable rows, exclude informational and dismissed items from the sidebar count, and separate the sheet into Needs action and initially collapsed Information sections. Changes remain presentation-focused; the supplied diff does not modify recovery gates, send paths, or revision-checked Dismiss behavior.

## Findings

**No actionable findings identified in the supplied diff and context.**

- **Classification:** The switch covers every payload without a `default` and matches the requested table. All three run payloads become needs-action when `hasUnfinishedAction` is true.
- **Unfinished actions:** Projection uses the existing `unresolvedAction(for:)`, which excludes resolved and superseded actions. The `nonisolated` classifier reads only its arguments, not coordinator or actor-isolated state.
- **Banner and counts:** Loading/failure notices and dismissed-crash-hold indicators remain. Sessionless preparation failures retain tab matching; applicable runtime/workspace warnings remain visible. Schedule exclusions are unchanged and intentional; those items still contribute to the app-wide needs-action count.
- **Sheet:** Filtering preserves snapshot order within each section, and Information starts collapsed. Dismissed-item visibility remains independently controlled.
- **Tests:** Existing expectation changes match the deliberate behavior changes. Added tests cover all current payloads, unfinished-action promotion, recorded-outcome demotion, and banner/count integration.

Validation results are **worker-reported**, not independently executed. Live SwiftUI rendering remains unverified.

## Recommendations

- Perform a focused UI check of disclosure behavior, Show dismissed, and a run row moving between sections while a recovery action executes.
- Consider regression tests for superseded actions and sessionless-tab preparation failures under the new banner rule.
- No blocking changes recommended from this review.