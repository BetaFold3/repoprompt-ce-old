# Phase 1b foundation final re-review — OracleA

Scope: read when the task touches lossless restart lifecycle foundation final re-review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` (OracleA). Round 2/2; independent code inspection, supplied validation.

The delta correctly separates durable creation from a clean save outcome, retains creation authority for the originating owner, and closes F3 by sharing resolved-directory keys across metadata and session caches. Restored tombstoned bindings now avoid becoming unsaveable creators, but the new automatic cleanup path exposes an asynchronous ownership race. Review is source-only; validation results are supplied, not independently executed.

## P1 — Should fix

### F4 — Restored-deletion cleanup can remove a replacement owner

**Evidence:** `AgentModeViewModel.swift:5432–5440` launches `finalizeDeletedAgentSessionReferences` asynchronously. In that helper, `:20742–20762` checks the session identity once, performs multiple awaited teardown operations, then unconditionally calls `sessions.removeValue(forKey: tabID)` and tab-scoped remote cleanup.

- **Failure scenario:** Cold restore discovers tombstoned session A and starts cleanup. After cleanup clears A’s workspace binding and suspends during teardown, the tab is rebound to session B or receives a replacement `AgentTabSession`. Cleanup then resumes and removes whichever session currently occupies that tab. The earlier workspace CAS does not protect this later in-memory removal.
- **Impact:** B’s live owner can disappear, disrupting its run and potentially discarding unsaved changes. The new restoration test waits for cleanup to finish before creating the fresh owner, so it does not exercise this overlap.
- **Smallest fix:** Fence teardown and removal to the captured owner/binding across suspension points. Prefer retiring or detaching that exact owner synchronously before awaited teardown; ensure subsequent cleanup cannot target replacement tab resources. At minimum, revalidate object identity and binding before each subsequent destructive operation.
- **Targeted test:** Hold cleanup at an awaited teardown boundary, install a replacement owner with a fresh UUID and dirty content, then release cleanup. Verify the replacement remains installed, retains its content, and saves successfully.

## Recommendations

- Close F3; the shared canonicalization and alias test address it.
- Keep the durable-creation outcome changes.
- Resolve F4 before approval. At round **2/2**, carry any unresolved disposition to the owner rather than starting another review loop.
- Retain the credential/signing gate; no additional environment validation is requested.
