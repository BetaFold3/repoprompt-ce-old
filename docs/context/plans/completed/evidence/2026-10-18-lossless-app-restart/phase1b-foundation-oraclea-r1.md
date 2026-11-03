# Phase 1b foundation re-review — OracleA

Scope: read when the task touches lossless restart lifecycle foundation re-review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` (OracleA). Round 1/2; supplied validation, independent code inspection.

The revised foundation fixes F1 by retaining creation authority for the exact originating binding while keeping its return context-sensitive, and fixes F2 by resolving parent-directory aliases for session authority. Removing hard-link creation is consistent with the stated sole-writer contract; the deletion and optional-load changes preserve fail-closed behavior. One nonblocking alias-related regression remains. Review is based on the supplied snapshots and source; validation results were supplied, not independently executed.

## P2 — Consider

### F3 — Canonicalized save destinations can leave the original metadata cache stale

**Evidence:** `AgentSessionDataService.swift:880–882` (`canonicalMetadataFolderKey`), `canonicalSessionFileKey`, and `saveAgentSessionLocked`.

- **Scenario:** A workspace uses a symlinked custom storage directory. Initial creation populates the metadata cache under that directory’s spelling, but its returned persistence stamp now pins the resolved path. Subsequent owner saves update the metadata cache under the resolved directory, while sidebar queries continue reading the original cached entry.
- **Impact:** After the one-time reconciliation, session names, counts, run states, or schedule summaries can remain stale in metadata-backed listings despite successful saves.
- **Smallest fix:** Canonicalize metadata-folder keys using the same existing-directory resolution as session authority, including reconciliation-task keys.
- **Targeted test:** Create through a symlinked workspace, save changed metadata through its returned persistence state, then verify `fastMetadataRecordsIfAvailable` through the original workspace returns the changes without forcing reconciliation.

## Recommendations

- **Close F1 and F2:** the supplied fixes and targeted tests address both prior findings.
- Address F3 if cheap; otherwise record it as a nonblocking deferral. No additional review round solely for it.
- No remaining P0/P1 identified within this re-review scope. Proceed subject to the other required lane and normal commit checks; retain the credential/signing gate.
