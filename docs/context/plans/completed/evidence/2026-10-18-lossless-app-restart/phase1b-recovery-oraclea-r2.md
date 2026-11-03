# Recovery transactions — OracleA re-review 2

Scope: read when the task touches lossless restart recovery transaction review evidence.
Authority: Reference
Last-verified: 2026-10-21

Verified preset: OracleA. Source review; no independent execution.

The delta resolves REC-02a: queued and direct submissions retain their call-time revision cutoff while incorporating a baseline learned by a preceding serialized restore, only while that baseline remains current. Newer typing remains protected, held-generation composers stay separate, successful writes clear stale held-state bookkeeping, and the restore-before-edit contract is documented.

## Review result

**Approve the scoped inactive-recovery delta. REC-02a is closed.** No new findings within the fixes or their regressions.

- Both submission paths use the same effective-consumption logic.
- The new race tests enforce submission enqueueing before restoration completes and verify durable R1 intent, removal of R0, and preservation/subsequent persistence of R2.
- The newer-stored-revision test covers preservation after an intervening write.
- The held-state clearing test explicitly simulates resolution; it does not imply production resolution is implemented.

## Validation boundary

Source-and-diff review only; no tools or tests run independently. Reported evidence is 37 passing tests, successful lint, and a negative control producing eight assertion failures with the fix disabled.

Production integration and explicit held-input resolution remain deferred; foundation behavior was not reopened.
