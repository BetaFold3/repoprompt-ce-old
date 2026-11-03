# Step 8-verifier-fixes review round 0: OracleA

Scope: read when the task touches Needs Attention session deletion (F8), View popover placement, or recovery accessibility identifiers (Step 8-verifier-fixes of the lossless app restart plan).
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleA round-0 review

The changes address F8 by retiring deleted sessions’ startup holds and filtering their catalog entries, move View popovers toward the outside of their containers, and make the Needs Attention sheet an accessibility container. The verifier-guide changes are focused. I reviewed only Step 8’s changes, using the current coordinator slices to resolve the misplaced hunks in the exported diff; the parallel worker’s changes are excluded.

## P1 — Should fix

### VF-01 — Preferred placement does not guarantee that the popover avoids other rows

**File:** `AgentRecoveryNativePopover.swift:44–55, 205–213`

**Failure scenario:** Open View in the centered Needs Attention sheet on a screen without enough space beside it. `preferredEdge` is a preference, not an exclusion constraint: AppKit can select another edge. For horizontal placement, the supplied positioning rectangle spans the sheet’s width but only the clicked button’s height. A vertical fallback therefore positions against that narrow strip **inside the sheet**, potentially covering other rows again. The banner has the equivalent problem with a horizontal fallback.

**Impact:** The overlap and blocked row clicks that this step intends to fix remain possible in ordinary constrained-window layouts. The new rectangle tests verify the requested geometry, not AppKit’s final placement.

**Smallest fix:** Use the entire container bounds as the positioning rectangle so alternative edges also reference the container boundary. Handle layouts where no outside placement fits with an explicit fallback rather than promising non-overlap. Keeping the arrow aligned precisely with View should be secondary to keeping actions accessible.

## Recommendations

- Address VF-01, then live-check banner and sheet placement near screen edges and on a smaller display, including one-click actions on other rows.
- Verify that both the sheet identifier and `agent.recoveryNeedsAttention.checkReport` appear independently in the accessibility tree.
- Confirm the new F8 tests fail without the fix, and add a controlled deletion-during-startup test for the new retirement safeguard.
- Rerun affected tests after the parallel worker settles. The reported live results concern the earlier build, not these fixes.
