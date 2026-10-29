# Lossless restart Phase 0 — OracleA initial review

Scope: read when the task touches the independent review evidence for Phase 0 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-20

Review identity verified against the requested OracleA preset. Fresh review on the same code/test diff and contextual slices; no other lane's findings were supplied. Validation was provided as command results, not rerun by the reviewer. Dispositions are recorded in [Phase 0 evidence](phase0.md).

## Verbatim review

The Phase 0 changes add DEBUG-only full-save diagnostics, two counter-contract tests, and opt-in streaming/1,500-item fixture reports without changing persistence behavior. Instrumentation runs immediately after successful writer return, excludes thrown failures and early returns, and records timings, sizes, counts, and short IDs—not content. The evidence appropriately distinguishes fixture measurements from live acceptance, records the process-local incarnation mismatch, and leaves later-phase implementation out of scope.

## P2 — Consider

### P2-01 — Stream report waits for an additional write rather than final-text persistence

**File:** `Tests/RepoPromptTests/AgentMode/AgentStaleResetOwnershipTests.swift:2131–2136`

**Failure scenario:** On the shared, noisy host, the stream task can resume late from its final sleep, after the buffer flush and debounce save have already completed. The final loop sample then incorporates that write into `lastObservedWritten`. The subsequent wait requires another write, although the final text is already persisted and no further mutation will schedule one.

**Impact:** The opt-in report can time out despite correct persistence. Conversely, an observed write need not contain the final buffered chunk, so the current condition is not sufficient evidence for the assertion that follows.

**Smallest fix:** Wait until the atomically replaced session file contains `finalToken`, allowing that condition to be satisfied immediately. Keep counter sampling for reporting; do not force a save, which would change the experiment.

## Evidence assessment

- The counter placement, timing boundaries, metadata-only fields, and process-local ownership conclusion are supported by the supplied code.
- The fixture measurements are suitably qualified: writer-await is not disk-only latency, VM elapsed time is not isolated main-actor cost, and historical 6,000-item figures are clearly distinguished from retained coverage.
- Most send-route and hydration implementations are referenced but not included. Their inventory is useful documented evidence, but its completeness cannot be independently verified from these slices.
- Validation results are supplied reports, not independently rerun here. The absent release build, live sampling, and isolated main-actor measurement are explicit limitations—not additional Phase 0 blockers.

## Recommendations

Accept Phase 0 with the minor report-test fix above; no blocking correctness issue was found in the supplied changes. Preserve the documented pending/deferred validation and leave durable-incarnation design and recovery behavior to their planned phases.
