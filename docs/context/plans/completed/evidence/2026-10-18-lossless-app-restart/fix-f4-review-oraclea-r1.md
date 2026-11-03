# Step 7-F4 — OracleA re-review 1 (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F4 (/compact after a cancelled Codex compaction) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F4, local fix-f4-r1-delta.diff and fix-f4-current.diff, worker Review fixes section); preset identity verified from the result.

# Oracle Review

The round-1 delta addresses the supersession-test gap, extends reconnect tracking across startup-lease waits, and strengthens cancellation and retry coverage. The simplified overlap check retains protection against newly started turns without treating an older ownership ending as a new turn. **No new findings in the supplied delta; no P0/P1 remains open in this lane.**

### Re-review assessment

- **F4-R1 resolved — independent guard coverage.** The two new tests in `CodexCompactReadinessTests.swift` separately exercise a run that starts and finishes during readiness and an agent-session rebind. Both assert refusal and zero compactions. The reported mutation failures support their effectiveness.

- **In-flight marks remain balanced.** At `CodexAgentModeCoordinator.swift:5168`, each non-nil mark receives a function-scope `defer`. Returns and thrown-error exits—including lease failure—therefore clear that invocation’s mark. Recursive readiness increments/decrements independently. Holding the original controller strongly ensures replacement neither redirects cleanup to the successor nor allows identifier reuse. Nothing in this delta introduces a persistent “still reconnecting” mark after all marked readiness calls settle.

- **The simplified overlap check remains sound.** At `CodexAgentModeCoordinator.swift:1700`, generation changes catch intervening attempts even after they finish; `runState.isActive` catches an ongoing run. Given the documented single ownership-creation authority, dropping the ownership comparison removes no independent protection. The subsequent eligibility checks and synchronous transition into compaction preserve the admission fence.

### Validation limits

Build, lint, 410 passing focused tests, and mutation results are worker-reported, not independently executed here. The omitted lease/recovery implementations prevent independently confirming their documented run-identity behavior from this packet alone.

## Recommendations

Accept this re-review without another round for this lane. Retain lease-enabled integration coverage as a non-blocking follow-up, particularly lease failure and controller replacement during the lease wait. No live-race reproduction or production-lease validation should be claimed from these fixture results.