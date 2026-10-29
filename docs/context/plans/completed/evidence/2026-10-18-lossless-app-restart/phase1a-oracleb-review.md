# Lossless restart Phase 1a — OracleB initial review

Scope: read when the task touches independent review evidence for lossless restart Phase 1a.
Authority: Reference
Last-verified: 2026-10-20

The requested OracleB preset identity was verified. Fresh independent review of the same implementation snapshot and validation evidence, including the unresolved cold-activation failure. Dispositions belong in [Phase 1a evidence](phase1a.md).

## Verbatim review

# Review: lossless-restart Phase 1a (transcript save maximum wait and buffered-text drain)

## Summary

The diff does what the recorded 1a scope says, and nothing beyond it:
- It adds a 10 s maximum wait on transcript saves, measured on `ContinuousClock` from the first unsaved mutation. Both the source-items callback (which runs before the dirty mark) and every `isDirty = true` arm it.
- The 1 s debounce is still there, now behind a sleep seam that tests can replace.
- All saves still go through `saveSessionDetailed`; there is no new writer.
- Only a clean receipt for the current owner clears the obligation. Older-snapshot writes, acknowledged resets and saves deferred behind an in-flight write are followed by an immediate save. A save that writes nothing retries with backoff (1 s, 2 s, 4 s … 30 s).
- Paired hydration authority, not the UI-only `authoritativeHydratedBinding`, decides whether a bound owner may be saved. Binding replacement and disposal make old timers obsolete.
- Buffered assistant text is now applied through the producer that buffered it (`assistantDeltaDrain`): before every save snapshot, and at the cleanup sites where the conversation is kept. Deletion and reset still discard it.
- The guardrail allowlist gains 8 exact paths, no wildcards.

I found **no P0 or P1** in the new code. Ownership fencing (generation, `===` identity and commit-token re-checks after every suspension) and exactly-once draining (generation bump plus cancel before apply, for both producers) hold up under the interleavings I traced. One thing blocks commit: the unresolved cold-activation validation failure (V1 below). The policy requires validation to pass, and nothing so far shows the failure is unrelated to 1a.

---

## V1 — Open validation failure: `testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly`

### Facts (from the code and the run table)
- **Which filter fails is unknown.** `catchUps.count == 0` means one of two things: the handler never ran, or every run was rejected by one of its three filters (`currentTabID == tabID`, `sessions[tabID]` exists, revision match). The helper doesn't record which.
- **The 1a maximum wait cannot fire inside a 7 s run if it was armed inside the test.** The fixture installs no `test_saveTimerSleepOverride`, so it uses a real 10 s sleep. A retry needs a prior wakeup, so no retry can fire either.
- **The 1 s debounce can fire in failing runs.** Passing runs (0.43–0.55 s) finish before any debounce fires. Failing runs (7.1–7.5 s) last long enough for debounce saves to run, on any session the test dirtied, including the cold target after hydration.
- **There is no baseline.** Nobody has run the test at HEAD without 1a. The A/B run with arming disabled was a single run.
- **1a changes three things at runtime when no assistant text is buffered:**
  1. Arming creates a `Task`, which adds a job to the main actor.
  2. The debounce deadline is now computed when `scheduleSave` is called, not when its task starts. It also now uses `Task.sleep(until:clock:)` with the default tolerance, instead of `Task.sleep(nanoseconds:)`.
  3. `beginPersistentBindingTransition` cancels the maximum-wait task.

  None of these synchronously changes `currentTabID`, `sourceItemsRevision`, or anything the catch-up handler reads.

### Inference (not established)
- **The 7 s is the real signal.** Something stalls for about 7 s. It could be the hydration poll, a gate held by a save, or slow fixture setup or teardown; the run duration includes the fixture. During that stall, a debounce save of the target can run before the activation catch-up. The save path's `refreshDerivedTranscriptState(… .saveSession)` / `flushDeferredDerivedTranscriptRefresh` could then consume the run-state delta while `currentTabID` or the revision differs, so no catch-up passes the handler's filters. That would be a latent ordering race, and 1a could change how often it happens: an extra main-actor job, an earlier debounce deadline, or a different timer tolerance.
- **The 1 + 2 + 4 = 7 s retry sum looks like the failure duration.** It is probably a coincidence, since a retry chain needs a 10 s first wakeup. It costs nothing to rule out with the same probe.

### Smallest next diagnostic (test-local, no framework change)
1. **Get a baseline.** Stash only the `Sources/` changes, keep the test, and run the single test 20 times at HEAD. Then run it 20 times with 1a. If HEAD also fails at a similar rate, the flake predates 1a: record it as such and stop attributing it to 1a. If HEAD is 0/20 and 1a is ≥ 3/20, bisect the three runtime changes, one variable per arm, 20 runs each:
   - (a) a DEBUG static flag that turns `noteTranscriptPersistenceMutation` into a no-op;
   - (b) the debounce restored to `Task.sleep(nanoseconds:)` inside the task;
   - (c) the `beginPersistentBindingTransition` invalidation disabled.
2. **Instrument one failing run** (temporary prints in `observeColdActivationCatchUp`):
   - **In `refreshAttemptHandler`, before the guard:** log `metrics.reason`, `metrics.sourceItemsRevision`, the target's revision, `viewModel.currentTabID == tabID`, whether `sessions[tabID]` exists, and a `ContinuousClock.now` timestamp. This shows which filter rejected the catch-up.
   - **Phase timestamps:** fixture ready, writer `flushSave` returned, `switchComposeTab` returned, hydration poll exited, cleanup finished. This shows where the 7 s goes.
   - **Perf events for the fixture VM:** enable `AgentModePerfDiagnostics` events for `save.schedule`, `save.session.invoked/skipped/complete`, `save.maxWait.save/retry`. Any `save.session.invoked` for the target tab before the poll exits supports the debounce-save-first hypothesis. Any `save.maxWait.*` confirms or rules out the retry-chain coincidence.

Do not weaken the assertion. The policy treats this as an open validation result, so the step should stay `doing` until (1) has run.

---

## P2 findings

### P2-1 — Older-snapshot writes keep the expired deadline, which during sustained streaming bypasses the existing command-output save throttle
- **Evidence:** `AgentModeViewModel+TranscriptSaveMaxWait.swift` ~`:167–169` (`case .written, .resetAcknowledged:` resets `retryCount` and loops), and `transcriptSaveMaxImmediateFollowOns = 2`, which then arms a 1 s retry.
- **Scenario:** a large session (Phase 0 measured a 0.208 s first save for 1,500 items) streams text or command output past the 10 s deadline. If a mutation lands during almost every write's suspension, every save returns `.written(projectionClean: false)`. The loop then runs 3 full rewrites, waits 1 s (the retry count was reset), runs 3 more, and so on, until a write happens to finish clean. With high-rate command output, a clean write may never happen while the stream lasts.
- **Impact:** no data is lost; each write is real durable progress. But it costs about 30 ms of main-actor time per save, and full-file rewrites run at roughly 2 per second. That overrides the deliberate 5 s `scheduleSaveForCommandOutput` throttle, in exactly the long-running, large-session case this feature targets (the owner's "sluggishness" restarts). It is also stricter than the spec, which says the clock "resets only when a save commits" (R3).
- **Smallest fix:** after a committed but stale snapshot, keep the obligation and move its deadline to the snapshot's capture time, with no immediate follow-up:
  - set `transcriptSaveFirstUnsavedAt = <instant before the save>`;
  - arm `.maxWait` at that instant + 10 s.

  Every change made after the capture is then still saved within about 10 s of when it happened, so the bound holds. Keep immediate follow-ups only for `.deferredBehindInFlightSave` and `.resetAcknowledged`. Update `testExpiredDeadlineFollowsOlderSnapshot…` to match. The owner should confirm this interpretation: the obligation is kept but re-based, not erased.

### P2-2 — Removal admission clears the obligation instead of parking it
- **Evidence:** `+TranscriptSaveMaxWait.swift` ~`:101–104` maps `staleResetRemovalAdmission?.blocksScheduledSaves == true` to `.nothingToSave`, which clears the obligation.
- **Scenario:** a tab removal reserves the owner, then is aborted (for example, the user cancels the confirmation or the preflight fails), so the tab stays. The dirty edits now have no maximum wait until some new mutation re-arms it. `scheduleSave` is also blocked while the admission is active.
- **Impact:** for that window, dirty data depends again on a later mutation or a lifecycle save. It's unlikely, but it's a silent loss of the obligation.
- **Smallest fix:** return `.waitForAuthority` for `blocksScheduledSaves`; `staleResetRecovery` stays `.nothingToSave`, which is correct there. If the removal commits, the wakeup fails the `sessions[tabID] === session` check and becomes obsolete. If the removal aborts, the next retry saves.

### P2-3 — Drains at discard and close sites arm save timers on owners being torn down
- **Evidence:** VM `:3812` (`prepareSessionForWindowClose`) and VM `:12785` (`prepareWorkspaceSwitchSessionDiscard`). The drain mutates source items, so `onSourceItemsChanged` runs `noteTranscriptPersistenceMutation`, `scheduleSave` and a derived refresh. `cancelEphemeralRuntimeState()` cancels the derived refresh but not `saveDebounceTask` or `transcriptSaveMaxWaitTask`.
- **Scenario:** if the VM or session outlives teardown, a debounce wakeup 1 s later or a maximum-wait wakeup 10 s later calls `saveSessionDetailed`. That call resolves `currentSessionPersistenceContext()` at wake time, not the context in effect when the mutation happened.
  - After a window close, this is a best-effort save after teardown, which the 1a scope note explicitly excludes.
  - After a workspace switch, I couldn't verify from the provided code whether the old owner can still be `sessions[tabID]` under the new context. If it can, only the downstream persistence-state checks stand between it and a cross-workspace write.
- **Impact:** most likely none. The debounce already has the same weakness, and weak captures usually make the wakeup obsolete. But this is a teardown writer the spec's two-stage design forbids.
- **Smallest fix:** at both sites, call `session.invalidateTranscriptSaveMaxWait()` and cancel `session.saveDebounceTask` right after `cancelEphemeralRuntimeState()`. That leaves durability at these sites to 1b, as the scope note says. Also confirm that the workspace-switch drain runs before the switch's save; otherwise it is memory-only on a discarded owner and can be removed.

### P2-4 — Authority arriving late waits out the backoff
- **Evidence:** `.waitForAuthority` → `scheduleTranscriptSaveRetry` (~`:150–152`). The backoff grows to 30 s, and nothing re-arms the timer when hydration publishes `.applied`.
- **Impact:** a background tab whose load finishes during the backoff can sit unsaved for up to about 40 s. That's still bounded, and the debounce may cover it sooner.
- **Smallest fix:** don't grow the retry exponent on `.waitForAuthority`, so it retries at a fixed 1 s. That's cheap, because the check is synchronous and does no I/O. Alternatively, re-arm immediately where the disposition becomes `.applied`.

---

## P3 findings

- **P3-1 — A buffer with no live producer retries forever.** If `pendingAssistantDelta` is non-empty but `assistantDeltaDrain` is nil or its producer is gone (both closures capture `weak self`), the action returns `.save`, `saveSessionDetailed` returns `.notWritten`, and the retry repeats every 30 s indefinitely. Both producers currently set the drain, so this isn't reachable today. **Fix:** in `transcriptSaveMaxWaitAction`, treat `!isDirty && drain == nil` as `.nothingToSave`.
- **P3-2 — A session dirtied before it is inserted into `sessions` never arms.** `noteTranscriptPersistenceMutation` requires `sessions[tabID] === session`. A session marked dirty before insertion stays unarmed until its next mutation. That's harmless for the starvation case, but worth a comment.
- **P3-3 — A mixed-producer buffer drains through whichever producer armed it.** If the VM appends while Codex's timer is armed (or the reverse), the text goes through the other producer's flush. The previous timer behaved the same way; this isn't new.
- **P3-4 — Test gaps.** There are no tests for:
  - the drain after shutdown in `prepareComposeTabRemoval`;
  - the stale-reset stop drain;
  - the drain on execution-location change, including confirming that `shutdownCodexSession` doesn't clear the buffer before the drain at VM `:8303`;
  - authority granted later leading to a save;
  - reset or deletion still discarding buffered text. You named this in the contract, but no test covers it.
- **P3-5 — The guardrail allowlist names review files that don't exist yet** (`phase1a-oracle{a,b}-review.md`). That's acceptable: it's an exact list and fails loudly if the names differ. The missing tracked-docs check before commit should be fixed separately, not in this step.

---

## Recommendations

1. **Don't commit yet.** First run the V1 baseline probe: 20 single-test runs at HEAD without 1a versus 20 with it, plus the unfiltered handler logging and timestamps. If HEAD also fails, record the flake as pre-existing evidence and proceed. If not, bisect the three runtime changes (a/b/c).
2. **Apply P2-1** (re-base the deadline on stale committed writes) and **P2-2** (park the obligation instead of clearing it under removal admission). Both are a few lines in `+TranscriptSaveMaxWait.swift` and cheap; adjust the one affected test. The owner should confirm that P2-1's interpretation ("obligation kept, deadline re-based to the snapshot") meets the contract.
3. **Apply P2-3** (cancel both save timers at the close and discard sites) so 1a doesn't introduce a save after teardown that the scope note excludes.
4. **Defer P2-4 and P3-1 through P3-5** unless cheap. Fixing P2-4 by not escalating on `.waitForAuthority` is one line.
5. **After any fix,** rerun `AgentTranscriptSaveMaxWaitTests`, the affected-suite set and `make guardrails` after staging, then re-review only the changed behavior.
