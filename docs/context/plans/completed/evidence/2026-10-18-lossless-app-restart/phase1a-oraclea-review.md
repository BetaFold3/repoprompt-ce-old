# Lossless restart Phase 1a — OracleA initial review

Scope: read when the task touches independent review evidence for lossless restart Phase 1a.
Authority: Reference
Last-verified: 2026-10-20

The requested OracleA preset identity was verified. Fresh independent review of the same implementation snapshot and validation evidence, including the unresolved cold-activation failure. Dispositions belong in [Phase 1a evidence](phase1a.md).

## Verbatim review

The patch implements the narrowed Phase 1a scope: an absolute, mutation-origin 10-second save-request deadline alongside the existing debounce, bounded retries through the existing writer, and producer-specific assistant-buffer draining. The supplied code preserves the important current-receipt and ownership checks; the hydration predicate appropriately avoids the active-tab-only presentation fence. I found no confirmed production data-loss defect in the supplied excerpts, but **validation is not complete**, particularly the reproducible cold-activation failure. This review used only the supplied diff, context, and reported results.

## P2 — Consider

### R1 — Cold-activation validation remains unresolved
**References:** `AgentModeChatSwitchActivationTests.swift:1722–1723, 1973–1999`; `phase1a.md:§9`

- **Scenario:** The patched test repeatedly records zero catch-ups, including in isolation. Its observation handler discards events unless the active tab and source revision match, so zero observations does not establish that no refresh occurred.
- **Impact:** There is currently no evidence distinguishing a production activation regression from an observation/order race. Earlier passing suites and one passing arming-disabled run do not resolve this.
- **Smallest remedy:** Obtain the focused event trace and rebuilt baseline comparison described below. Keep the assertions unchanged. Treat this as an unresolved validation blocker, **not an established production bug or an established baseline flake**.

### R2 — Manual timer teardown can leave late-starting tasks suspended
**Reference:** `AgentTranscriptSaveMaxWaitTests.swift:433–467`, `ManualSaveTimer.sleep` / `cancelAll`

- **Scenario:** Timer tasks register their continuations asynchronously. `cancelAll()` resumes only continuations already registered. A scheduled task that enters `sleep` afterward registers a continuation that nothing will resume; task cancellation is deliberately ignored.
- **Impact:** The test harness can leak suspended tasks and timer state. This undermines isolation even though production timers do not use this implementation.
- **Smallest fix:** Add a terminal `isClosed` flag. Set it before draining continuations in `cancelAll()`, and make subsequent `sleep` calls throw `CancellationError`. Preserve cancellation-ignoring behavior before teardown so obsolete-wakeup tests remain effective.

### R3 — Drain tests do not discriminate two important new behaviors
**References:** `AgentTranscriptSaveMaxWaitTests.swift:280–310`; `AgentModeViewModel.swift:14220–14253`; `CodexAgentModeCoordinator.swift:5440–5484`

- **Scenario:** Both save-drain cases begin with an unbound, dirty session. The Codex case also uses an unscoped trailing assistant row.
- **Impact:** The tests would not catch removal of the new **clean-but-buffered** entry condition. Nor do they establish that a scoped Codex buffer reaches its intended row rather than being appended using VM semantics.
- **Smallest fix:** Add focused cases:
  1. Persist a session clean, enqueue text without flushing, and verify an explicit save persists the tail.
  2. Buffer Codex text for an explicit scope whose target is not the ordinary trailing assistant row; verify only that scoped row changes and the cancelled timer cannot replay it.

## Cold-activation failure: analysis and next probe

### Facts

- Three of seven reported patched runs failed; an isolated run also failed.
- The supplied evidence has no comparable unpatched baseline.
- The helper filters refresh observations by active tab and revision.
- The helper already contains `holdsHydrationUntilSwitchSettles`, explicitly intended to separate hydration from the switch’s workspace-save flush.
- The arming-disabled artifact must be rebuilt before further comparisons.

### Plausible connection—not yet a diagnosis

The strongest visible ordering hypothesis is **hydration versus the switch-triggered save/refresh**, rather than a 10-second timer firing early. A refresh could happen before the observation predicate accepts it, or another refresh could reconcile the state before the expected activation catch-up.

The patch can perturb scheduling through additional tasks and the changed debounce deadline. However, an empty-buffer drain does nothing, and a newly armed 10-second timer cannot itself expire within a genuinely shorter-than-10-second test interval. Neither observation excludes an ordering regression.

### Smallest diagnostic sequence

1. **Rebuild without packaging or launching**, identifying the exact source variant used.
2. Add a temporary, test-local trace **before the observation guard**. Record:
   - monotonic elapsed time;
   - current tab, target revision, and event revision;
   - refresh reason/path and whether the predicate accepted the event;
   - switch entry/return, hydration completion, and target save entry.

   Record fixture completion separately: the reported seven-second duration may include setup rather than the failing activation.
3. Repeat the isolated test against the rebuilt patch and a comparable pre-patch baseline. One passing run is insufficient.
4. Use the existing `holdsHydrationUntilSwitchSettles: true` option as a controlled diagnostic, retaining every assertion. If it removes the failure, inspect the trace to establish the ordering difference.

**Fix according to evidence:** If production readiness/publication is wrong, repair that ordering. If production state is correct and the test observes the wrong interval, use the existing barrier to establish the test’s intended precondition. Do not merely increase sleeps, accept zero catch-ups, or disable maximum-wait arming.

## Recommendations

- **Do not commit yet:** resolve or demonstrably attribute the cold-activation failure first.
- Close the manual-timer teardown hole and add the two discriminating drain cases.
- Keep the current single-writer design and paired-load eligibility; no broad redesign is indicated.
- The eight exact documentation allowlist additions appear appropriately scoped. Rerun guardrails after staging and inspect the complete staged diff.
- Continue reporting lifecycle durability and live/crash acceptance as deferred to later work.
