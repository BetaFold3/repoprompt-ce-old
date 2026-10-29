# Phase 3 Platform initial review — OracleA

Scope: read when the task touches review of the bounded process-inspection and launcher-marker slice.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Complete-source initial review; earlier invalid packaging was not counted as approval. Chat: `restart-platform-complet-072431`.

# Oracle Review

This slice adds read-only, single-PID inspection with birth-identity revalidation and an optional runtime marker at launch. **No P0/P1 findings in the supplied snapshot.** Ambiguous basic-info responses remain unavailable; only basic-info `ESRCH` produces `.notFound`. Supporting-field failures preserve the observed birth identity without asserting ownership. The launcher’s `runtimeID: nil` path preserves the supplied environment and existing spawn/cleanup behavior. The reported synthetic tests support these contracts, not live marker propagation or complete child-ownership recovery, which remain explicitly deferred.

## P2 — Consider

- **P2-1 — Avoid copying unrelated environment values.**
  **File:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessInspection.swift:296–303`
  **Scenario:** Every environment entry containing `=` executes `Array(entry[(separator + 1)...])` before checking whether its key is selected. Consequently, unrelated values—including credentials—are unnecessarily copied into temporary allocations.
  **Impact:** Avoidable allocations and weaker data minimization; this is **not** a demonstrated logging, persistence, or result leak.
  **Smallest fix:** Move value-array construction inside each matching-key branch, after its duplicate check. Unselected values then remain unexamined slices of the original syscall buffer.
