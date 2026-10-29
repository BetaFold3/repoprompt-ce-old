# Lossless restart Phase 1a — OracleB revised-contract review

Scope: read when the task touches Phase 1a's revised receipt-based deadline and validation-test correction review.
Authority: Reference
Last-verified: 2026-10-20

Fresh review identity verified for OracleB. This round reviews newly introduced receipt-based scheduling behavior and the validation correction, not a minor-polish-only loop. See [Phase 1a evidence](phase1a.md) for disposition.

## Verbatim review

# Phase 1a re-review, round 1 (A → B delta)

## Summary

The delta changes how the save deadline behaves after a stale write. When a max-wait save writes an older snapshot, and that write provably covers everything before the save call, the deadline now rebases to the pre-call instant + 10 s. In every other case the deadline stays and the save is retried immediately. Other changes in the delta:
- A removal reservation now parks the obligation instead of clearing it.
- Waiting for authority retries at a fixed 1 s.
- Window close and workspace-switch discard now cancel both the debounce and the max-wait timers, and no timer is armed after window close.
- The manual timer gets a close flag.
- Two new buffered-text cases are covered: a clean session with buffered text, and a scoped Codex buffer.
- The cold-activation test now holds hydration, and a new deterministic test covers a save that runs before the catch-up.

I traced the rebase invariant through `saveSessionDetailed`. Between `captureTranscriptSaveState` and `makeSaveCommitToken` there is no suspension, and the buffer drain, pending-tool repair and reconcile all run before the token. So the payload covers every change before `capture.instant`, and the rebased deadline is ≤ each unsaved change + 10 s. That holds. Owner, binding and context replacement during the write is fenced by the generation check plus `staleWriteCoversCapture`. I found no new data-loss path in the rebase logic.

## P1 (provisional; confirm with one check)

**F1 — Window close now cancels a pending debounce save that HEAD would have run.**
- **Evidence:** `AgentModeViewModel.swift` ~3832 calls `cancelTranscriptSaveTimers(session)`, which cancels `saveDebounceTask`. `testRetainedTeardownCancelsBothSaveTimersSoNoSaveFollows` asserts that `"Edit before close"` is **not** persisted.
- **Failure scenario:** The user or a stream edits, and the window is closed less than about 1 s later, or teardown (`cancelAgentRun`, pending-tool finalization) re-dirties the session. At HEAD:
  - `prepareForWindowClose` does not remove `sessions[tabID]`;
  - the debounce task holds `[weak self]`;
  - `saveSession` re-checks that the context is current.

  So if the view model outlives teardown by the debounce interval, HEAD writes the edit. B drops it.
- **Impact:** Phase 1b's lifecycle flush doesn't exist yet. Until it does, B can lose up to ~1 s of edits plus teardown-time state.
- **Check:** Does the window-close caller flush dirty sessions before `prepareForWindowClose`? Does HEAD's `cancelEphemeralRuntimeState()` already cancel `saveDebounceTask`? If either is true, downgrade to P3.
- **Smallest fix:** At window close, clear only the max wait and leave the debounce as HEAD has it. Alternatively, `await saveSession(for:)` before cancelling when the session is dirty and has authority. Either way, change the test assertion so it no longer requires the edit to be lost.

The workspace-switch discard is **not** a regression. HEAD already discarded the buffer (`clearPendingAssistantDelta`), and the discarded owner fails the `sessions[tabID]`/context checks.

## P2

**F2 — When one write takes more than 10 s, rebases chain into back-to-back full writes.**
- **Evidence:** In `rebaseTranscriptSaveMaxWait`, if the write takes longer than 10 s, `instant + 10 s` is already in the past. The timer wakes immediately, saves, gets a stale receipt and rebases again. `immediateFollowOns` resets on every wakeup, so the retry floor never applies.
- **Impact:** On slow or contended storage during a continuous stream, the app writes with no pause, which adds I/O pressure. This doesn't lose data.
- **Fix:** Arm at `max(instant + maxWait, .now + transcriptSaveRetryFloor)`. This never matters on healthy storage, and the existing test equality still holds.

**F3 — The new save-before-catch-up test stops at the save.**
- **Evidence:** `testSaveBeforeActivationCatchUpReconcilesOnlyGeneratedToolSummaries` asserts memory and durable items, but it never activates the tab afterwards.
- **What it misses:** The original V1 symptom was "no catch-up observed". This test doesn't show that a later activation still produces a transcript and projections equal to the cold reference, or that the save legitimately consumed the run-state delta.
- **Fix:** After the save, run `switchComposeTab(tabID)` and assert that `session.transcript` and the base, full and working projections equal `observeColdActivationCatchUp`'s reference build.

## P3

- **Tautological counter guard.** The `receipt.* >= capture.*` checks in `staleWriteCoversCapture` always pass for the call's own receipt, because the counters are monotonic and the token is taken after the capture. What actually guarantees coverage is the structural rule that the token is captured before the first `await`. Say that in the doc comment, or add a DEBUG assertion near `makeSaveCommitToken`, so a future `await` added before the token fails loudly.
- **Unbounded authority polling.** A tab stuck at `.unresolved` or `.failed`, or under a stuck reservation, now polls every 1 s indefinitely; A escalated to 30 s. The check is synchronous, so the cost is energy only. Consider escalating after N tries.
- **Long test sleeps leak.** The 86400 s override sleeps in the new test are never cancelled; the `defer` only nils the override.

## Test-correction verdict

The assertions are **not weakened**:
- **Original test:** every assertion in `testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly` is unchanged. It now uses the same hydration hold as its sibling tests.
- **Narrow exception:** `isGeneratedSummaryRemoval` allows a difference only when all of these hold:
  - `summary_only == true`;
  - `summary_text` exactly equals `"<toolName> • <status>"`;
  - the field is absent afterwards;
  - every other key is identical.
- **Durable check:** the durable comparison runs with `allowGeneratedSummaryRemoval: false`, which is strict equality.
- **Reconciliation guard:** `revisionAtWrite > revisionBeforeSave` makes sure the reconcile path actually ran.

This is a defensible precondition fix, provided F3 adds post-save activation coverage. The "frequency unknown, no baseline claim" statement is accurate and should stay in the evidence file.

## Recommendations

1. Settle F1 with the two-line check (does the caller flush before close; does `cancelEphemeralRuntimeState` already cancel the debounce). If neither holds, leave the debounce alone at window close and flip the test's "not saved" assertion. This is the only item that could block the commit.
2. Apply the F2 floor; it's a one-line change.
3. Extend the new regression test with post-save activation and reference equality (F3).
4. Record the P3 items as deferred. No further review round is needed unless the F1 fix changes reviewed behavior.
