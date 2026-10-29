# 9-live fix 5 (Codex turn ID): OracleA review, round 1

Scope: read when the task touches how recovery identifies the interrupted Codex turn, the run attempt's provider turn ID, or the Codex history matcher's text.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 1) of the Step 5 diff, copied from its export; the fixes are in fix-9live-codex-turn-worker.md


## Verdict

**The previous P1 ordering issue is fixed.** The tail is installed synchronously, and each write awaits its predecessor before entering the lane. Event handling does not await the chain. No new chain-related deadlock or cross-session write defect is evident in the supplied diff.

### New P1 — Clearing the record re-enables stale span fallback

**Evidence:** `recordRunProviderTurn(..., providerTurnID: nil)` removes the extras member. However, `performRecoveryResumeAction` first obtains the span ID and overrides it **only when the recorded ID is non-nil**.

**Failure scenario:** A run’s transcript span names user turn T1. A later non-user turn becomes authoritative and successfully clears the recorded ID. After a kill, recovery falls back to T1. If T1 completed, recovery can import it or resolve the interrupted run using the wrong turn. This defeats the new clear’s stated purpose whenever a span ID exists.

**Smallest fix:** Persist an explicit “native turn invalidated/non-user” marker and suppress span fallback for that state. Preserve fallback only for legacy/unrecorded attempts. Ensure clearing an already-absent ID still persists this marker—the current equality shortcut would otherwise skip it.

The neutral matcher text resolves the earlier wording concern. Reported test execution was not independently verified.

## Recommendations

- Keep the write chain.
- Add explicit invalidation semantics and a regression: **span T1 → non-user authoritative clear → recovery must not observe T1**.