# Step 4d3b OracleA re-review 1

Scope: read when the task touches Step 4d3b live identity review evidence.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: repair 2026-10-24/0010. Returned preset identity verified by main. Verbatim response follows.

# Oracle Review

The repair closes both notification gaps while preserving the inactive, default-off contract: direct disqualification now emits an immediate metadata-only refusal, and EOF draining retains the exiting producer’s qualification through its buffered tail before token-matched retirement. The owner also validates reader-derived identity/digest and the known conversation before inserting canonical rows. Review is based on the supplied diff and context; test results are owner-reported, not independently rerun.

## Previous P1 findings — closed

- **R1 — Closed.** `ClaudeNativeProcessSessionController.swift:3627–3658` emits refusal on an eligible producer’s first direct disqualification, preserves sticky payload repetition, and suppresses disabled/ineligible evidence. Added controller and run-service/owner tests cover malformed input with no subsequent payload and verify proof invalidation.
- **R2 — Closed.** `ClaudeNativeProcessSessionController.swift:3364–3377, 3614–3624` keeps the exiting token available during EOF-tail classification and retires only matching qualification state. Added tests cover a newline-free contradictory result, refusal delivery, retirement, and gate-off output parity.

**No remaining P0/P1 identified within this repair scope.**

## P2 — Consider

### R3 — Replacement-during-drain protection lacks executable coverage
**Files:** `ClaudeNativeProcessSessionController.swift:3588–3624`; `ClaudeLiveTranscriptQualificationTests.swift`

- **Scenario:** A replacement is installed while fatal EOF-tail handling suspends. The new protection depends on drain-token precedence and permanent replacement disqualification; existing tests cover ordinary EOF and sequential replacement, not this interleaving.
- **Impact:** A future change could weaken these safeguards without failing the current tests. This is a coverage gap, not a demonstrated runtime regression.
- **Smallest improvement:** Add a deterministic suspension/interleaving test asserting that replacement output never qualifies and old-tail processing never stamps replacement evidence. Defer if this requires broader teardown changes; no additional review round solely for this item.

## Recommendations

Close R1/R2 and proceed with the planned guardrail/pre-commit checks. Record R3 as deferred coverage. Keep production activation and the explicitly blocked qualification, durability, and recovery limitations blocked; this review does not establish live-provider or final acceptance.
