# Phase 1a final review — OracleB

Scope: read when the task touches lossless restart Phase 1a review evidence.
Authority: Reference
Last-verified: 2026-10-20

Preset identity verified: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` (OracleB). Final re-review round 2/2; code inspection, not independently executed validation.



# Phase 1a re-review, round 2/2 (OracleB lane, delta only)

## Summary

This round changes four things since round 1:

- **Window close no longer cancels the pending debounce.** `prepareSessionForWindowClose` now calls only `clearTranscriptSaveMaxWait`, and `noteTranscriptPersistenceMutation` refuses to re-arm once `hasPreparedForWindowClose` is set.
- **Rebases of an expired deadline wait 1 s.** `rebasedTranscriptSaveDeadline` keeps `T+10 s` whenever it is still in the future. Only an already-expired deadline gets the 1 s floor after completion.
- **The save-first activation regression test now activates afterwards.** It compares every projection against a reference built from the original stored items, and its held timers are now cancelled explicitly.
- **Docs.** The allowlist and comments were updated to match.

**F1 (mine, P1) is resolved.** At window close the pending debounce now behaves as it did at HEAD:
- `sessions[tabID]` is kept.
- The task still captures `[weak self]`.
- The save still re-checks that its context is current.

The test now requires that the edit made before close is persisted, so it no longer asserts that the edit is lost. The workspace-switch discard path is unchanged and still correct. I found no new P0 or P1.

### Regression check on the fixes
- **Max wait vs. a save already running at close.** If a max-wait loop is suspended inside `saveSessionDetailed` when the close clears it, `transcriptSaveMaxWaitIsCurrent` fails afterwards, so it stops. Teardown's own re-dirty, or a `resetAlreadyCommitted` re-dirty during the kept debounce save, cannot re-arm the max wait because of the `hasPreparedForWindowClose` guard. A debounce save that fails after close is not retried, which matches HEAD.
- **Rebase floor.**
  - Can it loop? No. A rebase only happens after a write lands while newer changes arrive. The next stale-covering write rebases to a fresh capture, roughly `now + 10 s`, so there is no tight loop.
  - Is the 10 s bound still met? Yes, for every deadline that is still in the future.
  - Is the boundary handled? Yes. `>` sends exactly `T+10 s` to the floor, which is what the pure-function test asserts.
- **Activation test.** Cleanup cancels each owner's debounce and max-wait timers first, then ends the held sleeps. Cancelled debounce tasks hit `guard !Task.isCancelled` and return, so no held save runs late. The 86400 s sleep is gone.

## P3 (listed, not a reason for another round)

**N1 — The post-close debounce in the window-close test is picked by "latest pending", not tied to the actual task.**
- **Where:** `AgentTranscriptSaveMaxWaitTests.swift`, `testWindowCloseKeepsPendingDebounceSaveAndWorkspaceDiscardCancelsBothTimers`.
- **Failure scenario:** `ManualSaveTimer` ignores cancellation, so the replaced pre-close debounce still has a pending continuation. If the newest debounce task has not started its sleep when `awaitPendingRequest` scans, the scan returns the old, cancelled request. Firing it does nothing, and `await debounceTask.value` then hangs.
- **Impact:** This is unlikely, because several awaits follow the re-dirty inside `prepareForWindowClose`. If it happens, the test hangs loudly rather than passing falsely.
- **Smallest fix:** Pick a debounce request whose `requestedAt` is after `prepareForWindowClose` returned. Or have the override drop the continuations of cancelled tasks.

**N2 — The "cannot re-arm after close" claim is only checked indirectly.**
- **Where:** the same test.
- **Problem:** The final `XCTAssertNil(transcriptSaveFirstUnsavedAt, "No change re-armed…")` comes after a clean debounce save, which clears the max wait anyway. So that assertion does not prove the guard works.
- **Smallest fix:** After `prepareForWindowClose`, call `harness.session.appendItem(...)` (or set `isDirty = true`) and assert that `transcriptSaveFirstUnsavedAt` is still `nil`.

**N3 — The writer view model in the activation test runs real-clock save timers again.**
- **Where:** `AgentModeChatSwitchActivationTests.swift`, `testSaveBeforeActivationCatchUp…`.
- **Problem:** Window close now keeps the debounce. If `writer.prepareForWindowClose()` re-dirties its session, which the max-wait test comment says teardown does, the writer has a live 1 s debounce aimed at the same session file the test then writes and reads.
- **Impact:** Probably harmless. The writer is likely released before the timer fires, and its snapshot equals the input. But it is an unheld timer touching the file under test.
- **Smallest fix:** Point `writer.test_saveTimerSleepOverride` at the same `heldSaveTimers`, or call `writer.cancelTranscriptSaveTimers` after its close.

## Recommendations
1. Close F1 as **fixed**. Nothing is open at P0 or P1 in this lane, so the step can be committed once the pre-commit checks pass.
2. Record N1–N3 as `deferred:` P3s. N2 and N3 are one-line test edits, so fix them now if that's cheap; changing tests alone doesn't need another review round under the policy.
3. Keep "lifecycle flush deferred to 1b" on the status line. Until 1b exists, a close within about 1 s of an edit is only as durable as it was at HEAD (it depends on the view model outliving the debounce), and nothing better.
