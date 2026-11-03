# 9-live fix 4 (Claude history location): OracleA review, round 2

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 2) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md


## Verdict

**Round-1 P1 fixed; one new P1 in refresh settlement.** Based on the supplied diff; tests were not run.

The `.unknown` ancestor now blocks nested-home attribution. The two-pass regression test pins this, and the direct shim → CLI test preserves the normal case.

### P1 — A homeless nested writer prematurely ends discovery retries

**Evidence:** `observedHomelessWriter` accepts **any non-root writer** with a readable environment and no home. `discoveryPass` permanently inserts its runtime into `homeSettledRuntimeIDs`, which excludes subsequent home-lookup refreshes. It does not apply `closestWriterHome`’s ancestry restrictions.

**Failure scenario:**

```text
shim: no home
└─ outer CLI: environment temporarily unreadable; actual home A
   └─ tool
      └─ nested Claude: readable marker, no CLAUDE_CONFIG_DIR
```

The first lookup correctly records no home, but the nested writer marks the runtime settled. When the outer CLI becomes readable, later lookups never refresh it—even with retry budget remaining. If A is a custom profile absent from the fallback candidates, automatic baseline discovery remains unavailable unless another event triggers refresh.

The new unknown-ancestor test does not catch this: its nested writer has home B, and its second pass explicitly calls `refresh()`.

**Smallest fix:** Settle only from a writer established as the conversation’s outer writer using the same ancestry rules as home attribution. Uncertain or nested writers must not consume the remaining retry opportunity.

**Test:** Use the tree above; expose home A after the first lookup, then call `claudeProviderHomesRefreshingOnce` again. Assert another inventory pass and home A returned.

No new ordinary-send refusal or unbounded refresh loop is shown; the three-attempt cap remains enforced.

## Recommendations

Fix nested-writer settlement and add the lookup-driven regression test before approval. Keep the unknown-ancestor barrier.