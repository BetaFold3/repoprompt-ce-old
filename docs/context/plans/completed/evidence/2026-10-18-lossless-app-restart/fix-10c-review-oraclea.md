# Step 10c review: OracleA

Scope: read when the task touches test isolation of the Partitions store (PartitionStore) or Step 10 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleA review of the Partitions test-isolation change

The change redirects default partition storage to a lazily initialized, stable per-process temporary directory under DEBUG XCTest, creates it before use, and registers normal-exit cleanup, matching `WindowSessionStore`. Production path computation remains unchanged. The reported test results and filesystem checks support the intended isolation; explicit-`baseURL` handling is unchanged by the diff.

## P2 — Consider

- **F1 — DEBUG-only expectations run in release tests**  
  **File:** `Tests/RepoPromptTests/WorkspaceContext/Slices/SelectionSlicePersistenceAndRebaseTests.swift:11–23`  
  **Scenario:** Running this suite with `swift test -c release` makes `partitionsBaseURL()` intentionally return the production path, but the new test unconditionally asserts that it lies outside that path. The prefix assertion therefore fails even though release behavior is correct.  
  **Smallest fix:** Wrap this DEBUG-specific test in `#if DEBUG`, or use configuration-specific expectations.

## Recommendations

Approve with the minor test guard above; no blocking findings in the supplied changes. Keep `AgentWorkflowStore` outside this focused fix. Validation was worker-reported, not independently executed.
