# Restart fix F5obs — OracleB initial review
Scope: read when the task touches restart-spec Step 7-F5obs review findings (quit-failure dialog and shutdown phase logging).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleB fresh-chat initial review of the F5obs diff (review mode, explicit slices incl. review policy). Verbatim export follows.

# Oracle Review

# Review of Step 7-F5obs: shutdown-phase and quit-failure-dialog logging

## Summary

The diff adds `AgentLifecycleShutdownDiagnostics`, which writes one persisted (`.notice`) unified-log line for each shutdown event. That covers requests (started, joined or refused), every Stage A step, deadline firings, the point of no return, teardown and finalization, each failure dialog with its stage token, the user's answer, and how the request ended. `AppDelegate` logs where termination is entered and the reply it gives, and Stage A logs both ends of the unbounded wait on a pending composer preparation. Four tests were added.

**The logging doesn't change behaviour.** All the calls are synchronous and placed outside the control flow. No `await` was added. The values being logged are computed by pure helpers (`scopeToken`, `phaseToken`, `dialogStage`, `isCurrent`). The two small restructurings keep their meaning:
- `armsDeadline` is the same condition as before.
- `participants.enumerated()` iterates over the same array value that `for … in request.preparationParticipants` did.
- `isCurrentAnswer` reproduces the old guard exactly.

**Privacy is fine.** Every field is a UUID, a count, a boolean, a fixed token or a window number. Blocker text, draft content and paths are never logged.

**Tokens and tests mostly work, with exceptions.** The dialog-stage tokens follow the alert builder's branch order. A few `request=`/`cause=` fields can name the wrong request or the wrong cause; details below. The tests do prove the three required properties, with two weaker spots also listed below.

**No P0 or P1 findings.**

## P2

### F5OBS-01 — `request=` fields fall back to an old, finished request's ID
- **Evidence:**
  - `AppDelegate.swift:176-181` (`terminateRequested(current: …applicationRequest?.id)`)
  - `AppDelegate.swift:291-295, 311, 317`
  - `AgentLifecycleShutdownCoordinator.swift:450-455, 459-465` (`current: applicationRequest?.id`)
  - `applicationRequest` keeps pointing at a finished request until the next one replaces it.
- **Failure scenario:**
  1. The user quits, Stage A times out, and they click Cancel. Request R1 ends as `cancelled`.
  2. Later they quit again. The new `app_terminate_requested … decision=begin_termination` line carries `request=R1`.
  3. Only the following `app_termination_began` carries the new R2.
  4. Someone reading the trace for F5 (which is exactly a Cancel-then-quit-again investigation) can match this attempt to R1's history.
  5. The same happens on the `refused_reason_unavailable` coalesced line and on `terminateReply` when the refusal replies synchronously.
- **Impact:** wrong correlation when reading the log. Easy to catch if you also look at the `shutdown_ended` line.
- **Smallest fix:** log a request only if it's unfinished, for example `applicationRequest.flatMap { $0.isFinished ? nil : $0.id }`. A small computed `activeApplicationRequestID` on the coordinator would do this. That way `none` means none, which is what the doc comment on `requestCoalesced` already says.

### F5OBS-02 — `app_termination_began cause=joined_in_progress` is logged for a refused quit
- **Evidence:** `AppDelegate.swift:315-319` sets `cause: started ? "started" : "joined_in_progress"`. But `requestApplicationQuit` also returns `false` in two other cases (`AgentLifecycleShutdownCoordinator.swift:448-457`):
  - Restart safely was refused because its hooks aren't composed. In that case it has already called `reply(false)`.
  - `admission_sealed`.
- **Failure scenario:** a Restart safely without relaunch hooks produces these lines in order:
  1. `shutdown_request_coalesced cause=refused_reason_unavailable`
  2. `app_terminate_reply should_terminate=false`
  3. `app_termination_began started=false cause=joined_in_progress request=<stale id>`

  The last line contradicts the first two. (The existing `appDelegateDebugLog` text has the same mistake.)
- **Impact:** a misleading token in exactly the "was the Quit accepted?" question F5 is trying to answer. The path is rare.
- **Smallest fix:** check `quitRequestPhase` after the call. The refusal path's reply has already reset it to `.idle`, so log `refused` in that case and `joined_in_progress` otherwise. Alternatively, have the coordinator return a three-state result.

### F5OBS-03 — The dialog-stage token copies the alert's branching instead of sharing it
- **Evidence:**
  - `AgentLifecycleShutdownDiagnostics.swift:47-59` (`dialogStage`)
  - `WindowStatesManager+LifecycleShutdown.swift:128-174` (the alert's `switch`)
  - The two use different orders. The alert tests `offersUncertainRelaunchExit` before `relaunchHelperUnresolved`. The token tests `offersUncertainRelaunchExit` only inside the `relaunchHelperUnresolved` branch.
  - `testDialogStageTokenNamesTheStageAndCause` only checks `dialogStage` against itself.
- **Failure scenario:** a later change to the alert's branches (a new prompt kind, or `offersUncertainRelaunchExit` no longer requiring `relaunchHelperUnresolved`) silently makes the persisted token name a dialog that wasn't shown. That is the property the focus asks about.
- **Impact:** today they agree as far as I can tell, assuming `offersUncertainRelaunchExit` implies `relaunchHelperUnresolved`. Nothing guards that agreement.
- **Smallest fix (either one):**
  - Add a parameterized test that builds each failure kind and asserts the `(dialogStage, alert.messageText)` pairs together.
  - Or extract one `AgentLifecycleShutdownFailure.promptKind` enum and use it for both the alert's `switch` and the token.

### F5OBS-04 — The new evidence report fails `Scripts/check-agent-context` (`[reachability]`)
- **Evidence:** `fix-f5obs-worker.md`, under "Validation": `[reachability]` reports the file as an orphan until the restart spec links to it.
- **Impact:** if this check is part of the repository's pre-commit checks, the step can't be committed as-is.
- **Smallest fix:** you (the main agent) add the link to the Step 7 status line in the spec, and mark the two F5 bullets (the "Next" logging item and the cross-cutting item) done. The policy says spec and status edits need no review.

## P3

### F5OBS-05 — `deadline_ms` logs the nominal deadline, not the deadline Stage A actually works against
- **Evidence:** `AgentLifecycleShutdownCoordinator.swift:592-598` logs `environment.deadline`. For `.safeRestart`, `armDeadline` (around line 1240) uses `deadline - cleanupReserve`.
- **Impact:** a Restart-safely trace shows `deadline_ms=8000`, but `deadline_fired` arrives earlier, which looks like a timing anomaly.
- **Fix:** log `expiry - start` from inside `armDeadline` (or have it return the work budget), and log it on `finalization_started` too when `fresh_deadline=true`.

### F5OBS-06 — Stage B has no per-step lines
- **Evidence:**
  - Teardown, around line 778: only `shutdown_teardown_finished` is logged.
  - `runFinalization`'s participant loop, the clean write, and `runRelaunchStep`: nothing is logged.
- **Impact:** for a stalled Stage B, the log shows which half stalled (teardown before or after `teardown_finished`; the clean write via `clean_exit_unacknowledged`). It doesn't show which participant or relaunch hook stalled. Stage A has `index=i/N` for this.
- **Fix, only if cheap:** reuse `stageAStep`-style lines (renamed something like `stageStep`) for `finalize index=i/N`, `clean_write`, `relaunch_verify`, `relaunch_arm`.

### F5OBS-07 — `shutdown_dialog_presented` is logged before AppKit presents anything
- **Evidence:** the coordinator's `present` loop logs `dialogPresented` and then calls `environment.presentFailure`.
- **Impact:** "presented" really means "requested". A sheet that never appears, or appears hidden, logs the same as a visible one. The report already says the screenshot step is still needed. The name may still mislead a later reader.
- **Fix:** rename the event to `shutdown_dialog_requested`, or document that meaning in the doc comment and the report table. Optionally, log sheet vs. app-modal from the adapter.

### F5OBS-08 — The documented `log show` query also picks up lines from test processes
- **Evidence:** the report's query filters only on subsystem and category. The xctest process writes identical lines with the same subsystem (the sample trace's `window:4632` comes from a test).
- **Impact:** after any `make dev-test`, a post-mortem query mixes test traces with the real quit.
- **Fix:** add `AND process == "RepoPrompt"` (or whatever the app's process name is) to the documented query.

### F5OBS-09 — The view-model test doesn't prove Stage A is waiting on the composer preparation specifically
- **Evidence:** `AgentRecoveryResetBoundaryTests.swift`, around lines 1214-1220. `parked` checks the gate and the sleeper. `phase == .preparing` holds wherever Stage A happens to be suspended.
- **Mitigation:** "no prompt before the deadline" indirectly rules out Stage A skipping the wait, because a skipped wait would produce the "draft could not be saved yet" blocker early. The report's real trace also shows `event=waiting`.
- **Fix:** before releasing the gate, also assert that the participant's Stage A task hasn't finished. For example, check a flag set when `viewModel.shutdownPreparationTask` finishes, and assert it's still `false`.

### F5OBS-10 — Test-fixture and closure hygiene
- `ShutdownDeadlineSleeper` and `ShutdownPromptRecorder` duplicate the coordinator tests' clock and recorder. Consider moving them into shared test support.
- `ShutdownPromptRecorder.present` overwrites a pending continuation if it's called twice. The old continuation then leaks without a diagnostic. Assert or `precondition` that `pendingChoice == nil`.
- `beginTermination`'s reply closure strongly captures `lifecycleShutdown`, which creates a cycle: coordinator → request → completion → coordinator. It's harmless because the coordinator lives as long as the app, and `ended` already logs the request ID. Either drop `current:` from `terminateReply` or capture weakly.

## Do the tests prove the three properties?

- **Repeated quits don't extend the deadline:** proven at coordinator level by `testRepeatedQuitRequestsNeverExtendTheSingleDeadline`:
  - `requestedDeadlines` stays `[8s]`, and `prepareCalls == 1`;
  - nothing at 7.9 s and the prompt at 8.0 s;
  - no second prompt, re-arm or reply while the prompt is up.

  In production a second terminate is stopped earlier, by `AppQuitPolicy` returning `.awaitCurrentRequest`. That is covered separately by `AppQuitPolicyTests`, so together they cover both layers.
- **A suspended preparation or stalled teardown shows the right dialog at the single deadline:** proven.
  - Coordinator tests: a stuck preparation (exact 8.0 s boundary) and a stuck teardown (`finalization.deadline_expired`, request ID, no second deadline armed at the point of no return).
  - View-model test: a real composer-preparation wait gets the Retry/Cancel prompt with the request's ID and the timeout message.
- **A late completion can't complete an expired request:** proven in both the teardown test and the view-model test:
  - the phase stays at `*Failed`;
  - `finalizeCalls == 0`;
  - no clean mark, no point of no return, no finish or reply until the user chooses.

## Recommendations

1. **Commit after F5OBS-04.** Add the spec link so `check-agent-context` passes, and mark both F5 observability bullets done. No P0 or P1 is open, so this step doesn't need a re-review round.
2. **Fix F5OBS-01 and F5OBS-02 in this step.** They're cheap, and they touch exactly the "was the Quit accepted, and which request is this?" question the step exists to answer. A small `activeApplicationRequestID` helper plus a `refused` cause covers both. Rerun the three filtered test suites afterwards; no re-review is needed because reviewed behaviour doesn't change.
3. **F5OBS-03:** add the pairing test that checks `dialogStage` against the alert's `messageText`. It costs about 20 lines and stops the persisted token drifting away from the dialog that was actually shown. Extracting a shared `promptKind` enum can be deferred.
4. **F5OBS-05 and F5OBS-08:** worth doing now since each is one or two lines (log the effective expiry; add the process filter to the documented query).
5. **Defer F5OBS-06, 07, 09 and 10.** Record them under `deferred:` on the Step 7-F5obs status line. Do F5OBS-06 (Stage B step lines) only if a live trace actually shows a Stage B stall.
6. **For live F5 acceptance:** after the next quit that hangs, read the `LifecycleShutdown` category (with the process filter) and the screenshot (pending owner approval) side by side. Two cases still can't be told apart from the log alone:
   - `dialog_presented` with no `dialog_choice`, which could be an obscured sheet or an unanswered one;
   - a gap of well over 8 s before `deadline_fired`, which points to main-actor starvation.