# Step 7-F2 — OracleA re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F2 (blocked Send-now feedback for scheduled sends) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F2, local fix-f2-r1-delta.diff and fix-f2-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review

The delta closes the earlier wording and diagnostic-evidence findings, adds recovery-blocked feedback to Scheduled Messages, and consolidates new-session recovery admission around one computed blocker. Based on the supplied diffs and context, I found no new regressions or remaining P0/P1 issues.

## Re-review results

- **F2-01 — closed.** `AgentComposerUIModels.swift:273–286` removes the unsupported “Open it” remedy for restrictions and the misleading Needs Attention pointer for own-session recovery.
- **F2-02 — closed.** `fix-f2-worker.md` now distinguishes a reproduced mechanism from an unverified live explanation.
- **Admission equivalence — preserved.** `AgentScheduledSendCoordinator.swift:1883–1898` gates on the merged blocker. Both supplied conformers derive `hasUnresolvedRecoverySession` from that same blocker’s presence, so the unchanged handoff-time boolean check remains consistent. The real host preserves workspace scoping, destination exclusion, and the previous open-tab predicate. Run alongside still cannot bypass recovery.
- **Dashboard — correctly connected.** Both changed row-construction paths supply the coordinator’s blocker, and the view reloads on disposition changes. The extended test verifies dashboard/composer message parity and clearing after dispatch.
- **Recovery regression coverage — improved.** The composition test exercises a real startup crash hold, verifies that Dismiss leaves it blocking, and observes one run-starter invocation after It stopped. This establishes the handoff behavior, not provider acceptance or live delivery.

No new P2 findings.

## Validation limits

The worker reports a passing build, lint, and **343 focused tests with zero failures**. I did not independently run them. Rendered banner layout and live recovery remain unverified; the fixed-height adjustment alone does not establish visual correctness.

## Recommendations

Accept this re-review at code-review level; no further round is warranted. Link the F2 evidence documents and rerun `Scripts/check-agent-context` before committing. Keep rendered-UI and live-runtime acceptance explicitly unclaimed.