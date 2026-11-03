# Step 7-F2 — OracleA initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F2 (blocked Send-now feedback for scheduled sends) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F2, local fix-f2-review.diff, worker report, code context); preset identity verified from the result.

# Oracle Review

The change adds explicit Send-now refusals, itemized recovery blockers, and persistent banner feedback without changing the two recovery admission checks or revision-scoped consent storage. The supplied tests cover both menu choices, blocker removal, exactly-once dispatch, and Dismiss versus It stopped behavior. I found no confirmed P0/P1 issue in the supplied changes. The reported validation was not independently rerun; rendered UI and live recovery remain unverified.

## P2 — Consider

### F2-01 — Restricted-session guidance suggests an action that cannot clear every restriction

- **Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift:282–285`, `recoveryBlockedMessage(for:)`.
- **Scenario:** Another session is restricted because of unknown recovery status or a duplicate destination. The banner says “Open it or restart RepoPrompt to check again,” but opening the session does not clear those restrictions. The worker report explicitly acknowledges this distinction.
- **Impact:** A user follows the suggested action and remains blocked—the feedback explains the wait but gives an ineffective recovery instruction.
- **Smallest fix:** Distinguish held-transfer restrictions from startup-only restrictions, or use conservative shared wording: “Review Needs Attention for unresolved transfers, or restart RepoPrompt to rerun the recovery check.” Avoid implying that opening alone resolves every restriction.

### F2-02 — The report presents the live blocker as established more strongly than the evidence supports

- **Evidence:** `docs/context/plans/evidence/2026-10-18-lossless-app-restart/fix-f2-worker.md:9–23`.
- **Scenario:** The report labels startup admission and other alternatives “ruled out,” then concludes that consent was installed. The supplied code and tests demonstrate a matching recovery-gate failure mode, but do not establish the coordinator’s state during the original live clicks. Recovery cards being available is not, by itself, evidence that scheduler admission was open.
- **Impact:** The evidence record converts the specification’s explicitly qualified live-blocker inference into a definitive diagnosis, potentially misdirecting later investigation.
- **Smallest fix:** Describe the recovery gate as the reproduced, likely explanation; retain the live alternatives as unverified without contemporaneous admission/disposition evidence.

## Recommendations

- Address the wording and evidence qualifications above; neither requires changing admission behavior.
- Check the rendered banner at narrow composer widths before claiming UI acceptance.
- Keep an eye on refresh cost: boolean recovery checks now construct sets and scan all relevant state, and blocker collection repeats that work across hosts. Per-evaluation reuse is worth considering if profiling shows a meaningful cost; the supplied evidence does not establish a performance regression.